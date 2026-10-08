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
use File::Temp qw(tempdir);
use JSON::PP;
use Cwd qw(getcwd);

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
use FM::Backup::Keep;
use FM::Backup::Upload;
use FM::Events;

use constant MIN_FREI => 200 * 1024 * 1024;

my ($dir, $store, $msno_wahl, $force, $dry, $verbose);
GetOptions(
    'dir=s'   => \$dir,
    'store=s' => \$store,
    'msno=i'  => \$msno_wahl,
    'force'   => \$force,
    'dry-run' => \$dry,
    'verbose' => \$verbose,
) or die "Aufruf: fm_backup.pl --dir <konfigdir> --store <ablage> [--msno N] [--force] [--dry-run] [--verbose]\n";
die "fm_backup: --dir fehlt\n"   if !$dir;
my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $cfg = FM::Config::load($dir);
if (!$store) {
    $store = FM::Settings::get($dir, 'backup_store', $cfg);
}
my $keyfile = FM::Config::keyfile($dir);
if (!$store) {
    print "Keine Sicherungsablage eingestellt - es wird nicht gesichert." . chr(10) if $verbose;
    exit 0;
}

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
    say_v('Kein lokal angebundener Miniserver konfiguriert - der LoxBerry selbst wird trotzdem gesichert.');
}

my $encrypt = 1;
if (!FM::Backup::Pack::have_7z()) {
    FM::Events::add($rt, 'error', 'backup',
        '7z fehlt - es wird NICHT unverschluesselt gesichert', msno => 0);
    log_oeffnen();
    say_err('7z fehlt - keine Sicherung ohne Verschluesselung.');
    exit 1;
}

make_path($store) if !-d $store;

aufraeumen($store, $now);

my $frei = freier_platz($store);
if (defined $frei && $frei < MIN_FREI) {
    FM::Events::add($rt, 'error', 'backup',
        sprintf('Zu wenig Platz: %d MB frei, %d MB noetig',
                int($frei / 1048576), int(MIN_FREI() / 1048576)), msno => 0);
    log_oeffnen();
    say_err(sprintf('Zu wenig Platz in der Ablage: %d MB frei', int($frei / 1048576)));
    exit 0;
}

if (!$dry) {
    $state->{backup_last} = $now;
    FM::State::save($rt, $state);
}

my $fehler_gesamt = 0;

if (!defined $msno_wahl || $msno_wahl == 0) {
    my @lb_dateien;
    if (opendir(my $dh, $dir)) {
        for my $name (sort readdir $dh) {
            next if $name eq '.' || $name eq '..';
            next if $name =~ /\.lock\z/ || $name eq 'pin.session';
            my $pfad = File::Spec->catfile($dir, $name);
            next if !-f $pfad;
            push @lb_dateien, { path => $name, size => (-s $pfad) + 0,
                                 sha256 => FM::Backup::Pack::sha256_file($pfad) };
        }
        closedir $dh;
    }

    my ($erster_msno) = sort { $a <=> $b } keys %miniservers;
    my $pw0 = defined $erster_msno
        ? FM::Miniserver::backup_passwort($miniservers{$erster_msno}) : undef;

    if (!@lb_dateien) {
        say_v('LoxBerry (msno 0): keine Datei im Konfigurationsverzeichnis');
    }
    elsif (!defined $pw0 || $pw0 eq '') {
        log_oeffnen();
        FM::Events::add($rt, 'error', 'backup',
            'LoxBerry: kein Miniserver-Passwort verfuegbar - Verschluesselung nicht moeglich, kein Eigenbackup',
            msno => 0);
        say_err('LoxBerry (msno 0): kein Miniserver-Passwort verfuegbar - kein Eigenbackup');
        $fehler_gesamt++;
    }
    elsif ($dry) {
        say_v('LoxBerry (msno 0): Trockenlauf - nichts abgelegt');
    }
    else {
        log_oeffnen();
        my $fp0 = FM::Backup::Pack::fingerprint(\@lb_dateien, 1);
        my $gens0 = FM::Backup::Keep::generations($store, 0);
        my $unveraendert0 = 0;
        if (@$gens0) {
            my $alt0 = eval {
                open my $fh, '<', File::Spec->catfile($gens0->[0]{dir}, 'meta.json') or die;
                local $/;
                JSON::PP->new->decode(scalar <$fh>);
            };
            $unveraendert0 = 1 if $alt0 && ($alt0->{fingerprint} // '') eq $fp0;
        }

        if ($unveraendert0) {
            say_v('LoxBerry (msno 0): unveraendert - keine neue Generation');
        }
        else {
            my $tmp0 = eval { tempdir(DIR => $store, CLEANUP => 1) };
            if (!$tmp0) {
                FM::Events::add($rt, 'error', 'backup',
                    "LoxBerry: Ablage $store nicht beschreibbar", msno => 0);
                say_err('LoxBerry (msno 0): Ablage nicht beschreibbar');
                $fehler_gesamt++;
            }
            else {
                my $ziel0 = File::Spec->rel2abs(File::Spec->catfile($tmp0, 'backup.7z'));
                my $vorher0 = getcwd();
                my $konnte_wechseln = chdir $dir;
                my ($zok0, $zsize0, $zfehler0) = (0, 0, undef);
                if ($konnte_wechseln) {
                    ($zok0, $zsize0, $zfehler0) = FM::Backup::Pack::make_7z_encrypted(
                        [ map { $_->{path} } @lb_dateien ], $ziel0, $pw0);
                    chdir $vorher0;
                }

                if (!$konnte_wechseln) {
                    FM::Events::add($rt, 'error', 'backup',
                        'LoxBerry: Konfigurationsverzeichnis nicht erreichbar', msno => 0);
                    say_err('LoxBerry (msno 0): chdir fehlgeschlagen');
                    $fehler_gesamt++;
                }
                elsif (!$zok0) {
                    FM::Events::add($rt, 'error', 'backup',
                        'LoxBerry: Packen fehlgeschlagen'
                            . ($zfehler0 ? " - $zfehler0" : ' - ist 7z vorhanden?'), msno => 0);
                    say_err('LoxBerry (msno 0): Packen fehlgeschlagen'
                          . ($zfehler0 ? " - $zfehler0" : ''));
                    $fehler_gesamt++;
                }
                else {
                    my $mversion = eval {
                        no strict 'refs';
                        defined &{'LoxBerry::System::pluginversion'}
                            ? LoxBerry::System::pluginversion() : undef;
                    } || '';
                    my $manifest_dir = File::Spec->catdir($tmp0, 'manifest');
                    make_path($manifest_dir);
                    if (open my $mfh_in, '>', File::Spec->catfile($manifest_dir, 'manifest.json')) {
                        print {$mfh_in} JSON::PP->new->canonical->encode({
                            typ => FM::Backup::Pack::MANIFEST_TYP(),
                            plugin_version => $mversion,
                            erzeugt_am => $now,
                        });
                        close $mfh_in;
                        FM::Backup::Pack::add_to_7z($ziel0, $manifest_dir, 'manifest.json', $pw0);
                    }
                    $zsize0 = -s $ziel0;

                    my $meta0 = {
                        v => 1, msno => 0, ts => $now + 0,
                        encrypt => 1,
                        fingerprint => $fp0,
                        sha256 => FM::Backup::Pack::sha256_file($ziel0),
                        size => $zsize0 + 0,
                        files => scalar(@lb_dateien),
                        complete => 1,
                        missing => [],
                        uploaded => 0,
                    };
                    my $meta_ok = open my $mfh0, '>', File::Spec->catfile($tmp0, 'meta.json');
                    if (!$meta_ok) {
                        FM::Events::add($rt, 'error', 'backup',
                            'LoxBerry: meta.json nicht schreibbar', msno => 0);
                        say_err('LoxBerry (msno 0): meta.json nicht schreibbar');
                        $fehler_gesamt++;
                    }
                    else {
                        print {$mfh0} JSON::PP->new->canonical->encode($meta0);
                        close $mfh0;

                        my @g0 = gmtime($now);
                        my $stamp0 = sprintf('%04d%02d%02d%02d%02d%02d',
                            $g0[5] + 1900, $g0[4] + 1, $g0[3], $g0[2], $g0[1], $g0[0]);
                        my $ziel_gen0 = FM::Backup::Keep::gen_dir($store, 0, $stamp0);
                        make_path(FM::Backup::Keep::ms_dir($store, 0));
                        if (!rename($tmp0, $ziel_gen0)) {
                            FM::Events::add($rt, 'error', 'backup',
                                'LoxBerry: Generation konnte nicht an den Platz', msno => 0);
                            say_err('LoxBerry (msno 0): Generation konnte nicht an den Platz');
                            $fehler_gesamt++;
                        }
                        else {
                            my $weg0 = FM::Backup::Keep::prune($store, 0);
                            say_ok(sprintf('LoxBerry: Generation %s, %.2f MB, %d Dateien%s',
                                $stamp0, $zsize0 / 1048576, scalar(@lb_dateien),
                                $weg0 ? ", $weg0 weggerollt" : ''));

                            if ($cfg->{site} && $cfg->{server}) {
                                my ($lage0, $meldung0, $stuecke0) = eval {
                                    FM::Backup::Upload::send_all(
                                        $cfg, $keyfile, $store, 0, \&say_v, \&say_deb);
                                };
                                if (my $err0 = $@) {
                                    $err0 =~ s/\s+\z//;
                                    ($lage0, $meldung0, $stuecke0) = ('error', $err0, 0);
                                }
                                if ($lage0 eq 'error') {
                                    FM::Events::add($rt, 'error', 'backup',
                                        "LoxBerry: Uebertragung fehlgeschlagen - $meldung0", msno => 0);
                                    say_err("LoxBerry (msno 0): Uebertragung fehlgeschlagen - $meldung0");
                                    $fehler_gesamt++;
                                }
                                elsif ($lage0 eq 'done') {
                                    FM::Events::add($rt, 'info', 'backup',
                                        'LoxBerry: Backup erfolgreich hochgeladen'
                                            . ($meldung0 eq 'schon bekannt' ? ' (unveraendert, bereits bekannt)' : ''),
                                        msno => 0);
                                    say_ok(sprintf('LoxBerry: Uebertragung abgeschlossen (%d Stueck)', $stuecke0));
                                }
                            }
                        }
                    }
                }
            }
        }
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
        say_v("Miniserver $msno: Trockenlauf - nichts abgelegt");
        next;
    }

    my $tmp = eval { tempdir(DIR => $store, CLEANUP => 1) };
    if (!$tmp) {
        FM::Events::add($rt, 'error', 'backup',
            "Miniserver $msno: Ablage $store nicht beschreibbar", msno => 0);
        say_err("Miniserver $msno: Ablage $store nicht beschreibbar");
        $fehler_gesamt++;
        next;
    }
    my $inhalt = File::Spec->catdir($tmp, 'inhalt');
    make_path($inhalt);

    my (@erfasst, @fehlend);
    for my $d (@$dateien) {
        my $ziel = File::Spec->catfile($inhalt, split m{/}, substr($d->{path}, 1));
        my ($vd) = $ziel =~ m{\A(.*)[/\\][^/\\]+\z};
        make_path($vd) if $vd && !-d $vd;

        my ($got, $bytes) =
            FM::Backup::Fetch::get_to_file($base, $cred, $d->{path}, $ziel,
                sub { say_deb("Miniserver $msno: $_[0]") });
        if (!$got) {
            say_deb("Miniserver $msno: $d->{path} nicht holbar");
            push @fehlend, $d->{path};
            next;
        }
        say_deb("Miniserver $msno: $d->{path} ($bytes Byte)");
        push @erfasst, { path => $d->{path}, size => $bytes,
                         sha256 => FM::Backup::Pack::sha256_file($ziel) };
    }

    if (!@erfasst) {
        FM::Events::add($rt, 'error', 'backup',
                        "Miniserver $msno: keine einzige Datei holbar", msno => 0);
        say_err("Miniserver $msno: keine einzige Datei holbar");
        $fehler_gesamt++;
        next;
    }

    if (@fehlend || @$fehler) {
        my $text = sprintf('Miniserver %d: %d von %d Dateien nicht gesichert',
                           $msno, scalar(@fehlend),
                           scalar(@fehlend) + scalar(@erfasst));
        $text .= sprintf(', %d Verzeichnisse nicht lesbar', scalar @$fehler)
            if @$fehler;
        FM::Events::add($rt, 'warn', 'backup', $text, msno => 0);
        say_warn($text);
    }

    my $fp = FM::Backup::Pack::fingerprint(\@erfasst, $encrypt);

    my $gens = FM::Backup::Keep::generations($store, $msno);
    if (@$gens) {
        my $mf = File::Spec->catfile($gens->[0]{dir}, 'meta.json');
        my $alt = eval {
            open my $fh, '<', $mf or die;
            local $/;
            JSON::PP->new->decode(scalar <$fh>);
        };
        if ($alt && ($alt->{fingerprint} // '') eq $fp) {
            say_v("Miniserver $msno: unveraendert - keine neue Generation");
            next;
        }
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

    my $zip = File::Spec->rel2abs(File::Spec->catfile($tmp, 'backup.7z'));
    my $vorher = getcwd();
    chdir $inhalt or do {
        FM::Events::add($rt, 'error', 'backup',
            "Miniserver $msno: Arbeitsverzeichnis nicht erreichbar", msno => 0);
        say_err("Miniserver $msno: chdir fehlgeschlagen");
        $fehler_gesamt++;
        next;
    };
    my ($zok, $zsize, $zfehler) =
        FM::Backup::Pack::make_7z_encrypted('.', $zip, $pw);
    chdir $vorher;

    if (!$zok) {
        FM::Events::add($rt, 'error', 'backup',
            "Miniserver $msno: Packen fehlgeschlagen"
                . ($zfehler ? " - $zfehler" : ' - ist 7z vorhanden?'), msno => 0);
        say_err("Miniserver $msno: Packen fehlgeschlagen"
              . ($zfehler ? " - $zfehler" : ' - ist 7z vorhanden?'));
        $fehler_gesamt++;
        next;
    }

    my @g = gmtime($now);
    my $stamp = sprintf('%04d%02d%02d%02d%02d%02d',
                        $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);

    my $ms_ip = FM::Miniserver::ip($ms, sub { say_deb("Miniserver $msno: $_[0]") });
    my $ms_version = FM::Miniserver::firmware_version($ms, sub { say_deb("Miniserver $msno: $_[0]") });
    my $loxname = FM::Miniserver::loxname($ms_ip, $ms_version, $now);

    my $meta = {
        v => 1, msno => $msno + 0, ts => $now + 0,
        scope => $scope,
        encrypt => $encrypt,
        fingerprint => $fp,
        sha256 => FM::Backup::Pack::sha256_file($zip),
        size => $zsize + 0,
        files => scalar(@erfasst),
        complete => ((@fehlend || @$fehler) ? 0 : 1),
        missing  => [ @fehlend[0 .. (scalar(@fehlend) > 50 ? 49 : $#fehlend)] ],
        uploaded => 0,
        (defined $loxname ? (loxname => $loxname) : ()),
    };
    open my $mfh, '>', File::Spec->catfile($tmp, 'meta.json') or do {
        FM::Events::add($rt, 'error', 'backup',
            "Miniserver $msno: meta.json nicht schreibbar", msno => 0);
        say_err("Miniserver $msno: meta.json nicht schreibbar");
        $fehler_gesamt++;
        next;
    };
    print {$mfh} JSON::PP->new->canonical->encode($meta);
    close $mfh;

    remove_tree($inhalt);

    my $ziel_gen = FM::Backup::Keep::gen_dir($store, $msno, $stamp);
    make_path(FM::Backup::Keep::ms_dir($store, $msno));
    if (!rename($tmp, $ziel_gen)) {
        FM::Events::add($rt, 'error', 'backup',
            "Miniserver $msno: Generation konnte nicht an den Platz", msno => 0);
        say_err("Miniserver $msno: Generation konnte nicht an den Platz");
        $fehler_gesamt++;
        next;
    }

    my $weg = FM::Backup::Keep::prune($store, $msno);
    say_ok(sprintf('Miniserver %d: Generation %s, %.2f MB, %d Dateien%s',
                  $msno, $stamp, $zsize / 1048576, scalar(@erfasst),
                  $weg ? ", $weg weggerollt" : ''));

    if ($cfg->{site} && $cfg->{server}) {
        my ($lage, $meldung, $stuecke) = FM::Backup::Upload::send_all(
            $cfg, $keyfile, $store, $msno, \&say_v, \&say_deb);
        if ($lage eq 'error') {
            FM::Events::add($rt, 'error', 'backup',
                "Miniserver $msno: Uebertragung fehlgeschlagen - $meldung", msno => 0);
            say_err("Miniserver $msno: Uebertragung fehlgeschlagen - $meldung"
                . ($stuecke ? " (nach $stuecke Stueck(en), naechster Poll setzt fort)" : ''));
            $fehler_gesamt++;
        } elsif ($lage eq 'abgelehnt') {
            FM::Events::add($rt, 'warn', 'backup',
                "Miniserver $msno: nicht hochgeladen - $meldung (in den Einstellungen des Plugins abwaehlen)", msno => 0);
            say_warn("Miniserver $msno: nicht hochgeladen - $meldung");
        } elsif ($lage eq 'done') {
            FM::Events::add($rt, 'info', 'backup',
                "Miniserver $msno: Backup erfolgreich hochgeladen"
                    . ($meldung eq 'schon bekannt' ? ' (unveraendert, bereits bekannt)' : ''),
                msno => 0);
            say_ok(sprintf('Miniserver %d: Uebertragung abgeschlossen (%d Stueck)',
                          $msno, $stuecke));
        }
    }
}

exit($fehler_gesamt > 0 ? 1 : 0);

sub freier_platz {
    my ($pfad) = @_;
    return undef if !-d $pfad;
    my @z = qx{df -kP "$pfad" 2>/dev/null};
    return undef if scalar(@z) < 2;
    my @f = split /\s+/, $z[1];
    return undef if scalar(@f) < 4 || $f[3] !~ /\A[0-9]+\z/;
    return $f[3] * 1024;
}

sub aufraeumen {
    my ($store, $now) = @_;
    return if !-d $store;

    opendir my $sh, $store or return;
    my @oben = grep { !/\A\.\.?\z/ } readdir $sh;
    closedir $sh;

    for my $e (@oben) {
        my $p = File::Spec->catdir($store, $e);
        next if !-d $p;

        if ($e =~ /\Ams[0-9]+\z/) {
            opendir my $mh, $p or next;
            my @gen = grep { /\A[0-9]{14}\z/ } readdir $mh;
            closedir $mh;
            for my $g (@gen) {
                my $gp = File::Spec->catdir($p, $g);
                remove_tree($gp) if !defined FM::Backup::Keep::archiv_datei($gp);
            }
            next;
        }

        my $alter = $now - (stat($p))[9];
        remove_tree($p) if $alter > 86400;
    }
}

FM::Loxlog::ende($log);

