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

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Paths;
use FM::Config;
use FM::State;
use FM::Loxlog;
use FM::Miniserver;
use FM::Backup::Fetch;
use FM::Backup::Pack;
use FM::Loxplan;
use FM::Projekt::Upload;
use FM::Events;

use constant MAX_PROJEKT_GROESSE => 67108864;

my ($dir, $msno_wahl, $verbose);
GetOptions(
    'dir=s'  => \$dir,
    'msno=i' => \$msno_wahl,
    'verbose' => \$verbose,
) or die "Aufruf: fm_projekt.pl --dir <konfigdir> [--msno N] [--verbose]\n";
die "fm_projekt: --dir fehlt\n" if !$dir;

my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $cfg = FM::Config::load($dir);
if (!$cfg->{site} || !$cfg->{server}) {
    say_v('Dieser Standort ist noch nicht angemeldet. fm_enroll.pl zuerst ausfuehren.');
    exit 0;
}
my $keyfile = FM::Config::keyfile($dir);

my $log;
sub say_v    { print "$_[0]\n" if $verbose; FM::Loxlog::inf($log, $_[0]); }
sub say_ok   { print "$_[0]\n" if $verbose; FM::Loxlog::ok($log, $_[0]); }
sub say_warn { print "$_[0]\n" if $verbose; FM::Loxlog::warn($log, $_[0]); }
sub say_err  { print "$_[0]\n" if $verbose; FM::Loxlog::err($log, $_[0]); }
sub say_deb  { print "$_[0]\n" if $verbose; FM::Loxlog::deb($log, $_[0]); }
sub log_oeffnen { return if $log; $log = FM::Loxlog::start('projekt', 'Programmsicherung laeuft'); }

sub voll_herunterladen_und_entpacken {
    my ($base, $cred, $msno, $datei, $arbeitsdir) = @_;

    remove_tree($arbeitsdir) if -d $arbeitsdir;
    make_path($arbeitsdir);

    my $rohziel = File::Spec->catfile($arbeitsdir, $datei);
    my ($got, undef) = FM::Backup::Fetch::get_to_file($base, $cred, "/prog/$datei", $rohziel,
        sub { say_deb("Miniserver $msno: $_[0]") });
    return (0, "$datei nicht holbar") if !$got;

    my ($eok, $eziel_oder_fehler) = FM::Loxplan::entpacke($rohziel, $arbeitsdir);
    return (0, "Entpacken fehlgeschlagen - $eziel_oder_fehler") if !$eok;

    my $loxone    = $eziel_oder_fehler;
    my $groesse   = -s $loxone;
    my $sha256    = FM::Backup::Pack::sha256_file($loxone);
    my $metadaten = FM::Loxplan::metadaten($loxone);
    return (1, $loxone, $groesse, $sha256, $metadaten);
}

my $lock = FM::State::lock($rt, 'projekt');
if (!$lock) {
    say_v('Eine Programmsicherung laeuft bereits - die Sperre ist belegt.');
    exit 0;
}

my $state = FM::State::load($rt);
$state->{projekt} = {} if ref($state->{projekt}) ne 'HASH';

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
for my $msno (keys %miniservers) {
    next if FM::Miniserver::ist_lokal($miniservers{$msno});
    delete $miniservers{$msno};
}
if (!%miniservers) {
    say_v('Kein lokal angebundener Miniserver konfiguriert.');
    exit 0;
}

my $fehler_gesamt = 0;

my $marker = File::Spec->catfile($rt, 'projekt_neu.req');
my $marker_mtime = -e $marker ? (stat $marker)[9] : undef;
my @lokal = sort { $a <=> $b } keys %miniservers;
my %erledigt = map { $_ => $state->{projekt}{$_}{erzwungen_ts} }
    grep { ref($state->{projekt}{$_}) eq 'HASH' && defined $state->{projekt}{$_}{erzwungen_ts} } @lokal;
my ($erzwingen_von, $marker_verwerfen) = FM::Loxplan::projekt_neu_plan(
    $marker_mtime, time(), ($cfg->{site} && $cfg->{server}) ? 1 : 0, \@lokal, \%erledigt);
unlink $marker if $marker_verwerfen;

sub projekt_speichern {
    my $frisch = FM::State::load($rt);
    $frisch->{projekt} = $state->{projekt};
    FM::State::save($rt, $frisch);
}

sub marker_aufraeumen {
    return if !defined $marker_mtime;
    my %ts = map { $_ => $state->{projekt}{$_}{erzwungen_ts} }
        grep { ref($state->{projekt}{$_}) eq 'HASH' } @lokal;
    unlink $marker if FM::Loxplan::projekt_neu_erledigt($marker_mtime, \@lokal, \%ts);
}

for my $msno (sort { $a <=> $b } keys %miniservers) {
    next if defined $msno_wahl && $msno != $msno_wahl;
    my $erzwingen = $erzwingen_von->{$msno} ? 1 : 0;
    my $ms   = $miniservers{$msno};
    my $base = FM::Miniserver::base_url($ms);
    my $cred = $ms->{Credentials_RAW};

    my ($vok, $vbody) = FM::Miniserver::get($base, $cred, '/jdev/sps/LoxAPPversion3',
        sub { say_deb("Miniserver $msno: $_[0]") });
    if (!$vok) {
        say_v("Miniserver $msno: nicht erreichbar");
        next;
    }
    my $app_version = FM::Miniserver::ll_value($vbody);
    if (!defined $app_version || $app_version eq '') {
        say_v("Miniserver $msno: LoxAPPversion3 nicht lesbar");
        next;
    }
    my $bekannt = $state->{projekt}{$msno}{app_version};
    if (!$erzwingen && !FM::Loxplan::app_version_geaendert($bekannt, $app_version)) {
        say_v("Miniserver $msno: Programm unveraendert");
        next;
    }

    log_oeffnen();
    say_v("Miniserver $msno: Programmaenderung erkannt");

    my ($lok, $lbody) = FM::Miniserver::get($base, $cred, '/dev/fslist/prog',
        sub { say_deb("Miniserver $msno: $_[0]") });
    if (!$lok) {
        FM::Events::add($rt, 'warn', 'projekt', "Miniserver $msno: Programmverzeichnis nicht auflistbar", msno => 0);
        say_warn("Miniserver $msno: /prog nicht auflistbar");
        $fehler_gesamt++;
        next;
    }
    my $eintraege = FM::Backup::Fetch::parse_list($lbody);
    my $datei = FM::Loxplan::waehle_projektdatei($eintraege);
    if (!defined $datei) {
        FM::Events::add($rt, 'warn', 'projekt', "Miniserver $msno: kein Programmstand gefunden", msno => 0);
        say_warn("Miniserver $msno: kein Programmstand gefunden");
        $fehler_gesamt++;
        next;
    }

    my ($groesse_gefunden) = map { $_->{size} } grep { $_->{name} eq $datei } @$eintraege;
    if (defined $groesse_gefunden && $groesse_gefunden > MAX_PROJEKT_GROESSE) {
        my $meldung = sprintf('Miniserver %d: Programmdatei zu gross (%.1f MB, Grenze %.1f MB)',
            $msno, $groesse_gefunden / 1048576, MAX_PROJEKT_GROESSE / 1048576);
        FM::Events::add($rt, 'warn', 'projekt', $meldung, msno => 0);
        say_warn($meldung);
        $fehler_gesamt++;
        next;
    }

    my $arbeitsdir = File::Spec->catdir($rt, 'projekt', "ms$msno");

    my $bekannt_datei   = $state->{projekt}{$msno}{dateiname};
    my $bekannt_sha256  = $state->{projekt}{$msno}{sha256};
    my $bekannt_groesse = $state->{projekt}{$msno}{groesse};
    my $schnellpfad = !$erzwingen && defined $bekannt_datei && $bekannt_datei eq $datei
                    && defined $bekannt_sha256 && defined $bekannt_groesse;

    my ($loxone, $groesse, $sha256, $metadaten);
    if ($schnellpfad) {
        say_v("Miniserver $msno: Programmdatei unveraendert ($datei) - Download uebersprungen");
        ($groesse, $sha256, $metadaten) = ($bekannt_groesse, $bekannt_sha256, undef);
    } else {
        my ($ok, @rest) = voll_herunterladen_und_entpacken($base, $cred, $msno, $datei, $arbeitsdir);
        if (!$ok) {
            FM::Events::add($rt, 'warn', 'projekt', "Miniserver $msno: $rest[0]", msno => 0);
            say_warn("Miniserver $msno: $rest[0]");
            $fehler_gesamt++;
            remove_tree($arbeitsdir);
            next;
        }
        ($loxone, $groesse, $sha256, $metadaten) = @rest;
    }

    my ($jok, $jbody) = FM::Miniserver::get($base, $cred, '/data/LoxAPP3.json',
        sub { say_deb("Miniserver $msno: $_[0]") });
    if (!$jok) {
        say_deb("Miniserver $msno: LoxAPP3.json nicht holbar - wird ohne sie hochgeladen");
    }
    my $loxapp3 = $jok ? $jbody : undef;

    if ($cfg->{site} && $cfg->{server}) {
        my ($lage, $meldung) = FM::Projekt::Upload::hochladen(
            $cfg, $keyfile, $msno, $app_version, $groesse, $sha256, $loxone,
            $metadaten, $loxapp3, \&say_v, \&say_deb);

        if ($lage eq 'retry') {
            say_v("Miniserver $msno: Server kennt die zwischengespeicherte Version nicht mehr - hole sie jetzt wirklich");
            my ($ok, @rest) = voll_herunterladen_und_entpacken($base, $cred, $msno, $datei, $arbeitsdir);
            if ($ok) {
                ($loxone, $groesse, $sha256, $metadaten) = @rest;
                ($lage, $meldung) = FM::Projekt::Upload::hochladen(
                    $cfg, $keyfile, $msno, $app_version, $groesse, $sha256, $loxone,
                    $metadaten, $loxapp3, \&say_v, \&say_deb);
            } else {
                ($lage, $meldung) = ('error', $rest[0]);
            }
        }

        if ($lage eq 'error') {
            FM::Events::add($rt, 'error', 'projekt', "Miniserver $msno: Uebertragung fehlgeschlagen - $meldung", msno => 0);
            say_err("Miniserver $msno: Uebertragung fehlgeschlagen - $meldung");
            $fehler_gesamt++;
        } else {
            $state->{projekt}{$msno}{app_version} = $app_version;
            $state->{projekt}{$msno}{dateiname}   = $datei;
            $state->{projekt}{$msno}{sha256}      = $sha256;
            $state->{projekt}{$msno}{groesse}     = $groesse;
            $state->{projekt}{$msno}{erzwungen_ts} = $marker_mtime if $erzwingen;
            projekt_speichern();
            FM::Events::add($rt, 'info', 'projekt', "Miniserver $msno: Programm aktualisiert", msno => 0);
            say_ok("Miniserver $msno: Programm hochgeladen ($groesse Byte)");
        }
    }

    remove_tree($arbeitsdir);
}

marker_aufraeumen();
FM::Loxlog::ende($log);
exit($fehler_gesamt > 0 ? 1 : 0);

