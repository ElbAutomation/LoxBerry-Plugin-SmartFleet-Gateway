#!/usr/bin/perl
# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use Getopt::Long;
use File::Spec;
use File::Path qw(make_path remove_tree);
use JSON::PP;

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Paths;
use FM::Config;
use FM::Settings;
use FM::State;
use FM::Loxlog;
use FM::Cron;
use FM::Miniserver;
use FM::Backup::Catalog;
use FM::Backup::Fetch;
use FM::Backup::Pack;
use FM::Backup::Strom;
use FM::Backup::Strom7z;
use FM::Events;

my ($dir, $msno_wahl, $force, $dry, $verbose);
GetOptions(
    'dir=s'   => \$dir,
    'msno=i'  => \$msno_wahl,
    'force'   => \$force,
    'dry-run' => \$dry,
    'verbose' => \$verbose,
) or die "Aufruf: fm_backup.pl --dir <konfigdir> [--msno N] [--force] [--dry-run] [--verbose]\n";
die "fm_backup: --dir fehlt\n"   if !$dir;
my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $cfg = FM::Config::load($dir);
if (!$cfg->{site} || !$cfg->{server}) {
    print "Dieser Standort ist noch nicht angemeldet - es wird nicht gesichert." . chr(10) if $verbose;
    exit 0;
}
my $keyfile = FM::Config::keyfile($dir);

my $log;
sub say_v {
    print "$_[0]\n" if $verbose;
    FM::Loxlog::inf($log, $_[0]);
}
sub say_ok   { print "$_[0]\n" if $verbose; FM::Loxlog::ok($log, $_[0]); }
sub say_warn { print "$_[0]\n" if $verbose; FM::Loxlog::warn($log, $_[0]); }
sub say_err  { print "$_[0]\n" if $verbose; FM::Loxlog::err($log, $_[0]); }
sub say_deb  { print "$_[0]\n" if $verbose; FM::Loxlog::deb($log, $_[0]); }

sub log_oeffnen {
    return if $log;
    $log = FM::Loxlog::start('backup', 'Sicherung laeuft');
}

my $lock = FM::State::lock($rt, 'backup');
if (!$lock) {
    say_v('Ein Backup laeuft bereits - die Sperre ist belegt.');
    exit 0;
}

my $state = FM::State::load($rt);
my $now   = time();

my $desired = ref($state->{desired}) eq 'HASH' ? $state->{desired} : {};
my $bcfg    = ref($desired->{backup}) eq 'HASH' ? $desired->{backup} : {};
my $cron    = $bcfg->{cron};
my $scope   = ref($bcfg->{scope}) eq 'HASH' ? $bcfg->{scope} : FM::Backup::Catalog::DEFAULT_SCOPE();

if (!$force && !$dry) {
    if (!defined $cron || $cron eq '') {
        say_v('Kein Zeitplan im Sollzustand - es wird nicht gesichert.');
        exit 0;
    }
    if (!FM::Cron::due($cron, $now, $state->{backup_last})) {
        if (!defined $state->{backup_last}) {
            $state->{backup_last} = $now;
            FM::State::save($rt, $state);
        }
        say_v('Zeitplan noch nicht faellig.');
        exit 0;
    }
}

my $ok_lb = eval {
    require LoxBerry::System;
    no strict 'refs';
    die "get_miniservers fehlt\n"
        if !defined &{"LoxBerry::System::get_miniservers"};
    1;
};
if (!$ok_lb) {
    say_v('LoxBerry::System ist hier nicht verfuegbar - der Laeufer beendet sich.');
    exit 0;
}

my %miniservers = LoxBerry::System::get_miniservers();
%miniservers = FM::Miniserver::auswahl(\%miniservers, FM::Settings::get($dir, 'ms_weglassen', {}));

for my $msno (keys %miniservers) {
    next if FM::Miniserver::ist_lokal($miniservers{$msno});
    say_v("Miniserver $msno: per Cloud DNS angebunden - wird nicht gesichert");
    delete $miniservers{$msno};
}

if (!%miniservers) {
    say_v('Kein lokal angebundener Miniserver konfiguriert.');
}

if (!FM::Backup::Strom7z::verfuegbar()) {
    FM::Events::add($rt, 'error', 'backup',
        'Paket libcryptx-perl oder libcompress-raw-lzma-perl fehlt - es wird NICHT unverschluesselt gesichert', msno => 0);
    log_oeffnen();
    say_err('libcryptx-perl oder libcompress-raw-lzma-perl fehlt - keine Sicherung ohne Verschluesselung.');
    exit 1;
}

my $tmpdir = File::Spec->catdir($rt, 'backup');
remove_tree($tmpdir) if -d $tmpdir;
make_path($tmpdir);

if (!$dry) {
    $state->{backup_last} = $now;
    FM::State::save($rt, $state);
}

my $fehler_gesamt = 0;
my $erfolg = 0;

sub melden {
    my ($wer, $r) = @_;
    my $l = $r->{lage};
    if ($l eq 'error') {
        FM::Events::add($rt, 'error', 'backup', "$wer: Backup fehlgeschlagen - $r->{meldung}", msno => 0);
        say_err("$wer: Backup fehlgeschlagen - $r->{meldung}"
            . ($r->{stuecke} ? " (nach $r->{stuecke} Stueck(en))" : ''));
        $fehler_gesamt++;
    } elsif ($l eq 'abgelehnt') {
        FM::Events::add($rt, 'warn', 'backup',
            "$wer: nicht hochgeladen - $r->{meldung} (in den Einstellungen des Plugins abwaehlen)", msno => 0);
        say_warn("$wer: nicht hochgeladen - $r->{meldung}");
    } elsif ($l eq 'voll') {
        FM::Events::add($rt, 'warn', 'backup', "$wer: nicht hochgeladen - $r->{meldung}", msno => 0);
        say_warn("$wer: nicht hochgeladen - $r->{meldung}");
    } elsif ($l eq 'known') {
        say_ok("$wer: unveraendert ($r->{meldung}) - keine neue Generation");
        $erfolg++;
    } else {
        FM::Events::add($rt, 'info', 'backup', "$wer: Backup erfolgreich hochgeladen", msno => 0);
        say_ok(sprintf('%s: Backup hochgeladen, %.2f MB, %d Dateien, %d Stueck(e)',
                       $wer, ($r->{size} || 0) / 1048576, $r->{files}, $r->{stuecke}));
        $erfolg++;
    }
    if (@{ $r->{fehlend} || [] } && $l ne 'error') {
        my $text = sprintf('%s: %d von %d Dateien nicht gesichert', $wer,
                           scalar @{ $r->{fehlend} }, scalar(@{ $r->{fehlend} }) + $r->{files});
        FM::Events::add($rt, 'warn', 'backup', $text, msno => 0);
        say_warn($text);
    }
}

my %strom_basis = (
    cfg => $cfg, keyfile => $keyfile, ts => $now,
    sagen => \&say_v, roh => \&say_deb,
);

if (!defined $msno_wahl || $msno_wahl == 0) {
    my @lb_dateien;
    if (opendir(my $dh, $dir)) {
        for my $name (sort readdir $dh) {
            next if $name eq '.' || $name eq '..';
            next if $name =~ /\.lock\z/ || $name eq 'pin.session';
            my $pfad = File::Spec->catfile($dir, $name);
            next if !-f $pfad;
            my @st = stat $pfad;
            push @lb_dateien, { name => $name, fp_pfad => $name, size => $st[7] + 0,
                                datum => $st[9], modus => $st[2] & 07777, holen => sub { $pfad } };
        }
        closedir $dh;
    }

    my ($erster_msno) = sort { $a <=> $b } keys %miniservers;
    my $pw0 = defined $erster_msno
        ? FM::Miniserver::backup_passwort($miniservers{$erster_msno}) : undef;

    if (!@lb_dateien) {
        say_v('Plugin (msno 0): keine Datei im Konfigurationsverzeichnis');
    }
    elsif (!defined $pw0 || $pw0 eq '') {
        log_oeffnen();
        FM::Events::add($rt, 'error', 'backup',
            'Plugin: kein Miniserver-Passwort verfuegbar - Verschluesselung nicht moeglich, kein Eigenbackup',
            msno => 0);
        say_err('Plugin (msno 0): kein Miniserver-Passwort verfuegbar - kein Eigenbackup');
        $fehler_gesamt++;
    }
    elsif ($dry) {
        say_v('Plugin (msno 0): Trockenlauf - ' . scalar(@lb_dateien) . ' Dateien, nichts uebertragen');
    }
    else {
        log_oeffnen();
        my $mversion = eval {
            no strict 'refs';
            defined &{'LoxBerry::System::pluginversion'}
                ? LoxBerry::System::pluginversion() : undef;
        } || '';
        my $manifest = JSON::PP->new->canonical->encode({
            typ => FM::Backup::Pack::MANIFEST_TYP(),
            plugin_version => $mversion,
            erzeugt_am => $now,
        });
        my $r = FM::Backup::Strom::senden(%strom_basis,
            msno => 0, scope => 'system', passwort => $pw0,
            dateien => [ @lb_dateien,
                         { name => 'manifest.json', size => length $manifest, ohne_fp => 1,
                           holen => sub { \$manifest } } ]);
        melden('Plugin', $r);
    }
}

for my $msno (sort { $a <=> $b } keys %miniservers) {
    next if defined $msno_wahl && $msno != $msno_wahl;

    my $ms   = $miniservers{$msno};
    my $base = FM::Miniserver::base_url($ms);
    my $cred = $ms->{Credentials_RAW};

    log_oeffnen();
    say_v("Miniserver $msno: Auflisten");
    my $dirs = FM::Backup::Catalog::scope_dirs($scope);
    my ($dateien, $fehler) = FM::Backup::Fetch::walk($base, $cred, $dirs, undef,
        sub { say_deb("Miniserver $msno: $_[0]") });

    if (@$fehler) {
        FM::Events::add($rt, 'error', 'backup',
            "Miniserver $msno: " . $fehler->[0], msno => 0);
        say_err("Miniserver $msno: " . $fehler->[0]);
        $fehler_gesamt++;
        next;
    }
    say_v("Miniserver $msno: " . scalar(@$dateien) . ' Dateien');

    if ($dry) {
        say_v("Miniserver $msno: Trockenlauf - nichts uebertragen");
        next;
    }

    my $pw = FM::Miniserver::backup_passwort($ms);
    if (!defined $pw || $pw eq '') {
        FM::Events::add($rt, 'error', 'backup',
            "Miniserver $msno: kein Miniserver-Passwort hinterlegt - Verschluesselung nicht moeglich",
            msno => 0);
        say_err("Miniserver $msno: kein Passwort hinterlegt - wird nicht gesichert");
        $fehler_gesamt++;
        next;
    }

    my $ms_ip = FM::Miniserver::ip($ms, sub { say_deb("Miniserver $msno: $_[0]") });
    my $ms_version = FM::Miniserver::firmware_version($ms, sub { say_deb("Miniserver $msno: $_[0]") });
    my $loxname = FM::Miniserver::loxname($ms_ip, $ms_version, $now);

    my $ziel = File::Spec->catfile($tmpdir, 'datei');
    my @liste = map {
        my $d = $_;
        { name => substr($d->{path}, 1), size => $d->{size}, datum => $d->{datum}, weg => 1,
          holen => sub {
              my ($got, $bytes) = FM::Backup::Fetch::get_to_file($base, $cred, $d->{path}, $ziel,
                  sub { say_deb("Miniserver $msno: $_[0]") });
              return undef if !$got;
              say_deb("Miniserver $msno: $d->{path} ($bytes Byte)");
              return $ziel;
          } }
    } @$dateien;
    my $r = FM::Backup::Strom::senden(%strom_basis,
        msno => $msno, scope => FM::Backup::Strom::scope_string($scope),
        loxname => $loxname, passwort => $pw, dateien => \@liste,
        sagen => sub { say_deb("Miniserver $msno: $_[0]") });
    melden("Miniserver $msno", $r);
}

remove_tree($tmpdir);

if ($erfolg && !$dry) {
    my $frisch = FM::State::load($rt);
    $frisch->{backup_ok} = $now;
    FM::State::save($rt, $frisch);
}

FM::Loxlog::ende($log);

exit($fehler_gesamt > 0 ? 1 : 0);

