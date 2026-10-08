#!/usr/bin/perl
# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use Getopt::Long;
use JSON::PP;
use FM::B64 qw(b64u_decode);
use FM::Paths;
use FM::Config;
use FM::Loxlog;
use FM::Settings;
use FM::State;
use FM::Sig;
use FM::Http;
use FM::Jobs qw(run_jobs);
use FM::Selftest;
use FM::Sync;
use FM::Spool;
use FM::Events;
use FM::Vault;
use FM::Geraeteupdate;
use POSIX ();
use FM::Chart;
use FM::Element;
use File::Spec;
use FM::Backup::Upload;

my ($dir, $verbose, $mit_log);
my $nachpoll;
GetOptions('dir=s' => \$dir, 'verbose' => \$verbose, 'log' => \$mit_log, 'nachpoll' => \$nachpoll)
    or die "Aufruf: fm_sync.pl --dir <konfigdir> [--verbose]\n";
die "fm_sync: --dir fehlt\n" if !$dir;
my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $log;
sub say_v {
    my $text = "@_";
    print "$text\n" if $verbose;
    FM::Loxlog::inf($log, $text);
}
sub say_err  { my $text = "@_"; print "$text\n" if $verbose; FM::Loxlog::err($log, $text); }
sub say_deb  { my $text = "@_"; print "$text\n" if $verbose; FM::Loxlog::deb($log, $text); }

my $upload_log;
sub upload_log_oeffnen {
    return $upload_log if $upload_log;
    $upload_log = FM::Loxlog::start('backup', 'Uebertragung laeuft');
    return $upload_log;
}
sub say_upload_v {
    my $text = "@_";
    print "$text\n" if $verbose;
    FM::Loxlog::inf($upload_log, $text);
}
sub say_upload_deb {
    my $text = "@_";
    print "$text\n" if $verbose;
    FM::Loxlog::deb($upload_log, $text);
}
sub say_upload_ok  { my $text = "@_"; print "$text\n" if $verbose; FM::Loxlog::ok($upload_log, $text); }
sub say_upload_err { my $text = "@_"; print "$text\n" if $verbose; FM::Loxlog::err($upload_log, $text); }

my $lock = FM::State::lock($rt);
if (!$lock) {
    say_v('Ein anderer Lauf ist noch aktiv - dieser beendet sich.');
    exit 0;
}

$log = FM::Loxlog::start('sync', 'Verbindungstest') if $mit_log;

my $cfg = FM::Config::load($dir);
if (!$cfg->{site} || !$cfg->{server}) {
    say_v('Dieser Standort ist noch nicht angemeldet. fm_enroll.pl zuerst ausfuehren.');
    FM::Loxlog::ende($log);
    exit 0;
}

my $state   = FM::State::load($rt);
my $keyfile = FM::Config::keyfile($dir);
my $srv_pub = b64u_decode($cfg->{srv_pub});

my $now = time();
my $selftest;
my $su = eval { $state->{desired}{selftest}{url} };
if ($su && (!$state->{selftest_last} || $now - $state->{selftest_last} > 86400)) {
    my $st = FM::Selftest::run($cfg->{server}, $su);
    if (defined $st) {
        $selftest = { url => $su, status => $st + 0 };
        $state->{selftest_last} = $now;
        say_v("Selbsttest der Backup-Ablage: HTTP $st"
              . ($st == 403 ? ' - gesperrt, wie es sein soll' : ' - ACHTUNG, nicht gesperrt'));
    }
}

system($^X, "$Bin/fm_tunnel.pl", '--dir', $dir, '--enforce');

$state->{seq}++;
my ($samples, $spool_offset) = FM::Sync::take_samples($rt);

my ($events, $ev_offset) = FM::Events::take($rt, FM::Events::MAX_PER_POLL());

my %body = (
    v       => 1,
    seq     => $state->{seq},
    ts      => $now,
    ack     => $state->{pending_acks},
    samples => $samples,
    events  => $events,
);
$body{selftest} = $selftest if $selftest;
FM::Vault::rumpf_erweitern($dir, \%body);
my $body = JSON::PP->new->canonical->utf8->encode(\%body);

my $path     = '/api/sync.php';
my $sig_path = ($cfg->{path_prefix} || '') . $path;
my $headers  = FM::Sig::headers($keyfile, $cfg->{site}, 'POST', $sig_path, $body);
my ($st, $resp, $rh) = FM::Http::post_json("$cfg->{server}$path", $body, $headers, \&say_deb);

if ($st != 200) {
    $state->{sync_fehler}    = "HTTP $st";
    $state->{sync_fehler_at} = time();
    FM::State::save($rt, $state);
    say_err("Server antwortet mit HTTP $st - naechster Versuch in einer Minute.");
    FM::Loxlog::ende($log);
    exit 0;
}

my $rsig = $rh->{'x-fm-sig'};
if (!FM::Sig::verify_response($resp, $rsig, $srv_pub)) {
    FM::State::save($rt, $state);
    FM::Loxlog::ende($log);
    die "fm_sync: die Antwortsignatur des Servers stimmt nicht - Antwort verworfen.\n";
}

my $ans = eval { JSON::PP->new->utf8->decode($resp) };
if (!$ans) {
    FM::State::save($rt, $state);
    FM::Loxlog::ende($log);
    die "fm_sync: der Server liefert kein gueltiges JSON.\n";
}

if ($ev_offset) {
    FM::Events::truncate_to($rt, $ev_offset);
}

$state->{desired} = ref($ans->{desired}) eq 'HASH' ? $ans->{desired} : {};

eval {
    my $soll = FM::Geraeteupdate::soll_stufe($state->{desired});
    my $eigen = defined $soll ? FM::Geraeteupdate::eigene() : undef;
    FM::Geraeteupdate::stufe_setzen(md5 => $eigen->{md5}, soll => $soll) if $eigen;
    1;
};

if (ref($ans->{charts_auswahl}) eq 'ARRAY') {
    eval { FM::Chart::auswahl_speichern($dir, $ans->{charts_auswahl}); 1 }
        or say_v('Charts: Auswahl nicht gespeichert');
}

if (ref($ans->{chart_anforderungen}) eq 'ARRAY') {
    eval { FM::Chart::anforderungen_speichern($rt, $ans->{chart_anforderungen}) or die "nicht gespeichert\n"; 1 }
        or say_v('Charts: Anforderungen nicht gespeichert');
}

if (ref($ans->{element_pruefung}) eq 'ARRAY') {
    eval { FM::Element::pruefung_speichern($rt, $ans->{element_pruefung}) or die "nicht gespeichert\n"; 1 }
        or say_v('Elementdatei: Pruefliste nicht gespeichert');
}

for my $ev (FM::Vault::antwort_verarbeiten($dir, $cfg->{site}, $ans, \%body)) {
    FM::Events::add($rt, 'warn', 'vault', "$ev->[0]: $ev->[1]");
}

$state->{pending_acks} = [];

if ($spool_offset) {
    my $gesendet = scalar(@$samples);
    if (!FM::Sync::may_truncate($ans, $gesendet)) {
        say_v("Spool: der Server hat nur " . ($ans->{records} // '?')
              . " von $gesendet Datensaetzen verarbeitet - nicht gekuerzt, "
              . 'der Rest geht beim naechsten Lauf erneut mit.');
    }
    else {
        my $ok = FM::Spool::truncate_to($rt, $spool_offset);
        say_v('Spool: Versatz verfallen - der Stapel geht erneut mit.') if !$ok;
    }
}

my $backup_store = FM::Settings::get($dir, 'backup_store', $cfg);
if ($backup_store) {
    my $backup_lock = FM::State::lock($rt, 'backup');
    if ($backup_lock) {
        for my $msno (@{ FM::Backup::Upload::msnos($backup_store) }) {
            next if !FM::Backup::Upload::pending($backup_store, $msno);
            upload_log_oeffnen();
            my ($lage, $meldung, $stuecke) = FM::Backup::Upload::send_all(
                $cfg, $keyfile, $backup_store, $msno, \&say_upload_v, \&say_upload_deb);
            if ($lage eq 'error') {
                FM::Events::add($rt, 'error', 'backup',
                    "Miniserver $msno: Uebertragung fehlgeschlagen - $meldung", msno => 0);
                say_upload_err("Miniserver $msno: Uebertragung fehlgeschlagen - $meldung"
                    . ($stuecke ? " (nach $stuecke Stueck(en))" : ''));
            } elsif ($lage eq 'abgelehnt') {
                FM::Events::add($rt, 'warn', 'backup',
                    "Miniserver $msno: nicht hochgeladen - $meldung (in den Einstellungen des Plugins abwaehlen)", msno => 0);
                say_upload_v("Miniserver $msno: nicht hochgeladen - $meldung");
            } elsif ($lage eq 'done') {
                FM::Events::add($rt, 'info', 'backup',
                    "Miniserver $msno: Backup erfolgreich hochgeladen"
                        . ($meldung eq 'schon bekannt' ? ' (unveraendert, bereits bekannt)' : ''),
                    msno => 0);
                say_upload_ok(sprintf('Miniserver %d: Nachholung abgeschlossen (%d Stueck)',
                              $msno, $stuecke));
            }
        }
        close($backup_lock);
    }
    else {
        say_v('Backup-Sperre belegt - eine Uebertragung laeuft bereits, hier nichts nachzuholen.');
    }
}

my $fernwartung_lief = 0;

my %HANDLER = (
    ping => sub { return (1, 'pong'); },

    backup_now => sub {
        my ($payload) = @_;
        my $store = FM::Settings::get($dir, 'backup_store', $cfg);
        return (0, 'keine Ablage konfiguriert') if !$store;

        my $msno = (ref($payload) eq 'HASH' && defined $payload->{msno}
                    && $payload->{msno} =~ /\A[0-9]{1,10}\z/)
                 ? $payload->{msno} + 0 : undef;

        my @arg = ($^X, "$Bin/fm_backup.pl",
                   '--dir', $dir, '--store', $store, '--force');
        push @arg, ('--msno', $msno) if defined $msno;

        my $rc = system(@arg);
        return ($rc == 0 ? 1 : 0, $rc == 0 ? 'Backup erzeugt' : "Laeufer meldete $rc");
    },

    plugin_update => sub {
        my $eigen = FM::Geraeteupdate::eigene();
        return (0, 'Plugin-Daten nicht lesbar') if !$eigen;
        my ($st, $text) = FM::Http::get_extern(defined $eigen->{releasecfg} ? $eigen->{releasecfg} : '');
        my $rel = (defined $st && $st == 200) ? FM::Geraeteupdate::release_cfg($text) : undef;
        my $tmp = File::Spec->catdir($rt, 'update');
        mkdir $tmp if !-d $tmp;
        return FM::Geraeteupdate::update_starten(
            laufend => $eigen->{version}, release => $rel, temp => $tmp, md5 => $eigen->{md5},
            holen   => sub { my ($s, $c) = FM::Http::get_extern($_[0]); return ($s, $c); },
            starter => sub {
                my ($zip, $md5) = @_;
                no warnings 'once';
                my $pi = File::Spec->catfile($LoxBerry::System::lbhomedir, 'sbin', 'plugininstall.pl');
                my $log = File::Spec->catfile(
                    defined $LoxBerry::System::lbplogdir ? $LoxBerry::System::lbplogdir : $rt, 'plugin_update.log');
                my $pid = fork();
                return 0 if !defined $pid;
                if (!$pid) {
                    POSIX::setsid();
                    open STDIN, '<', File::Spec->devnull;
                    open STDOUT, '>>', $log;
                    open STDERR, '>&', \*STDOUT;
                    exec('sudo', $pi, 'action=autoupdate', "pid=$md5", "file=$zip", 'cgi=1',
                         'tempfile=smartfleet-update-' . time) or POSIX::_exit(1);
                }
                return 1;
            },
        );
    },

    projekt_neu => sub {
        my ($job) = @_;
        my $f = File::Spec->catfile($rt, 'projekt_neu.req');
        open my $fh, '>', $f or return (0, 'Anforderung nicht ablegbar');
        close $fh;
        return (1, 'Projektdatei wird beim naechsten Lauf neu abgerufen');
    },
    vault_resend => sub {
        my ($job) = @_;
        my $payload = (ref($job) eq 'HASH' && ref($job->{payload}) eq 'HASH') ? $job->{payload} : {};
        my $neu = $payload->{neu} ? 1 : 0;
        my $r = FM::Vault::neu_anfordern($dir, $neu);
        return (0, 'Uebermittlung an den Tresor ist nicht aktiviert') if $r ne 'ok';
        return (1, $neu ? 'Neuer Tresor: Schluessel wird uebernommen, Passwoerter werden neu uebertragen'
                        : 'Passwoerter werden neu uebertragen');
    },

    tunnel_open => sub {
        my ($job) = @_;
        $fernwartung_lief = 1;
        my $payload = (ref($job) eq 'HASH' && ref($job->{payload}) eq 'HASH')
                    ? $job->{payload} : {};
        my $nonce   = $payload->{nonce};
        my $ts      = defined $payload->{ts} ? "$payload->{ts}" : undef;
        my $antwort = $payload->{antwort};
        if (!defined $nonce   || $nonce eq ''
            || !defined $ts      || $ts !~ /\A[0-9]+\z/
            || !defined $antwort || $antwort eq '') {
            FM::Events::add($rt, 'error', 'tunnel_error', 'auftrag_unvollstaendig');
            return (0, 'Auftrag unvollstaendig');
        }

        my @arg = ($^X, "$Bin/fm_tunnel.pl", '--dir', $dir, '--start',
                   '--nonce', $nonce, '--ts', $ts, '--antwort', $antwort);
        push @arg, '--dauerhaft' if defined $payload->{dauer} && $payload->{dauer} eq 'dauerhaft';
        my $rc = system(@arg);
        return ($rc == 0 ? 1 : 0, $rc == 0 ? 'Tunnel gestartet' : 'Tunnel nicht gestartet');
    },
    tunnel_close => sub {
        $fernwartung_lief = 1;
        my $rc = system($^X, "$Bin/fm_tunnel.pl", '--dir', $dir, '--stop');
        return ($rc == 0 ? 1 : 0, $rc == 0 ? 'Tunnel beendet' : 'Tunnel nicht beendet');
    },
);

$state->{pending_acks} = run_jobs($ans->{jobs}, \%HANDLER, \&say_v);

$state->{sync_ok_at} = time();
delete $state->{sync_fehler};
delete $state->{sync_fehler_at};

my $frisch = FM::State::load($rt);
$frisch->{$_} = $state->{$_} for qw(selftest_last seq desired pending_acks sync_ok_at);
delete $frisch->{sync_fehler};
delete $frisch->{sync_fehler_at};

FM::State::save($rt, $frisch);
print 'Sync abgeschlossen, Sequenz ' . $state->{seq} . "\n" if $verbose;
FM::Loxlog::ok($log, 'Sync abgeschlossen, Sequenz ' . $state->{seq});
FM::Loxlog::ende($log);
FM::Loxlog::ende($upload_log);

if ($fernwartung_lief && !$nachpoll) {
    close($lock);
    exec($^X, "$Bin/fm_sync.pl", '--dir', $dir, '--nachpoll', ($verbose ? '--verbose' : ()))
        or warn "fm_sync: Nachpoll nicht startbar: $!\n";
}
exit 0;

