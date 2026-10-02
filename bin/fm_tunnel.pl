#!/usr/bin/perl
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use Getopt::Long;
use File::Spec;

use FM::Paths;
use FM::Config;
use FM::Settings;
use FM::TunnelPw;
use FM::Tunnel;
use FM::Events;

my ($dir, $verbose, $start, $stop, $status, $enforce, $nonce, $ts, $antwort, $dauerhaft);
GetOptions(
    'dir=s'     => \$dir,
    'verbose'   => \$verbose,
    'start'     => \$start,
    'stop'      => \$stop,
    'status'    => \$status,
    'enforce'   => \$enforce,
    'nonce=s'   => \$nonce,
    'ts=s'      => \$ts,
    'antwort=s' => \$antwort,
    'dauerhaft' => \$dauerhaft,
) or die "Aufruf: fm_tunnel.pl --dir <konfigdir> --start --nonce <n> --ts <t> --antwort <hex> [--dauerhaft] | --stop | --status | --enforce [--verbose]\n";

die "fm_tunnel: --dir fehlt\n" if !$dir;
my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $anzahl_modi = ($start ? 1 : 0) + ($stop ? 1 : 0) + ($status ? 1 : 0) + ($enforce ? 1 : 0);
die "fm_tunnel: genau eines von --start/--stop/--status/--enforce angeben\n" if $anzahl_modi != 1;

sub say_v { print "$_[0]\n" if $verbose; }

my $cfg = FM::Config::load($dir);

$cfg->{tunnel_erlaubt} = FM::Settings::get($dir, 'tunnel_erlaubt', $cfg);
if (!$cfg->{site}) {
    print "fm_tunnel: Standort ist nicht angemeldet.\n";
    exit 1;
}

if ($stop) {
    FM::Tunnel::stop();
    FM::Events::add($rt, 'info', FM::Tunnel::EVENT_SRC_CLOSED, 'manuell');
    say_v('Tunnel gestoppt (falls einer lief).');
    exit 0;
}

if ($status) {
    my $pid = FM::Tunnel::pid_verfolgt();
    my $url = $pid ? FM::Tunnel::url_aus_log() : undef;
    if ($pid && $url) {
        my $ablauf = FM::Tunnel::ablauf_lesen();
        my $seit   = FM::Tunnel::start_lesen();
        print "url=$url\n";
        print 'ablauf=' . (defined $ablauf ? $ablauf : '') . "\n";
        print 'seit=' . (defined $seit ? $seit : '') . "\n";
        exit 0;
    }
    print "kein Tunnel offen\n";
    exit 1;
}

if ($enforce) {
    my $ergebnis = FM::Tunnel::durchsetzen(riegel => FM::Tunnel::riegel_offen($cfg));
    if ($ergebnis->{status} eq 'geschlossen') {
        my $grund = defined $ergebnis->{grund} ? $ergebnis->{grund} : 'unbekannt';
        FM::Events::add($rt, 'info', FM::Tunnel::EVENT_SRC_CLOSED, $grund);
        say_v("Tunnel beendet: $grund");
    }
    else {
        say_v("Tunnel-Status: $ergebnis->{status}");
    }
    exit 0;
}

my $get_localip;
my $lbwebserverport;
my $lbsbindir;
{
    my $ok = eval {
        require LoxBerry::System;
        no strict 'refs';
        for my $f (qw(get_localip lbwebserverport)) {
            die "LoxBerry::System::$f fehlt\n" if !defined &{"LoxBerry::System::$f"};
        }
        $get_localip     = \&LoxBerry::System::get_localip;
        $lbwebserverport = \&LoxBerry::System::lbwebserverport;
        no warnings 'once';
        $lbsbindir       = $LoxBerry::System::lbsbindir;
        1;
    };
    say_v('LoxBerry::System ist hier nicht verfuegbar - kein Zielpunkt ermittelbar.') if !$ok;
}

my $ziel_url;
if ($get_localip && $lbwebserverport) {
    $ziel_url = 'http://' . $get_localip->() . ':' . $lbwebserverport->();
}
my @zusatzpfade;
push @zusatzpfade, File::Spec->catfile($lbsbindir, 'cloudflared') if $lbsbindir;

my $K = FM::TunnelPw::laden($dir);

my ($ok, $ergebnis) = FM::Tunnel::oeffnen(
    cfg         => $cfg,
    K           => $K,
    nonce       => $nonce,
    ts          => $ts,
    antwort     => $antwort,
    ziel_url    => $ziel_url,
    zusatzpfade => \@zusatzpfade,
    dauerhaft   => ($dauerhaft ? 1 : 0),
);

if ($ok) {
    my $ablauf = FM::Tunnel::ablauf_lesen();
    if (!FM::Events::add($rt, 'info', FM::Tunnel::EVENT_SRC_URL, $ergebnis,
                         (defined $ablauf ? (detail => "$ablauf") : ()))) {
        say_v('URL-Meldung fehlgeschlagen - Tunnel wird wieder geschlossen');
        FM::Tunnel::stop();
        print "meldung_fehlgeschlagen\n";
        exit 1;
    }
    say_v("Tunnel gestartet: $ergebnis");
    print "$ergebnis\n";
    exit 0;
}

FM::Events::add($rt, 'error', FM::Tunnel::EVENT_SRC_ERROR, $ergebnis);
say_v("Tunnel nicht gestartet: $ergebnis");
print "$ergebnis\n";
exit 1;

