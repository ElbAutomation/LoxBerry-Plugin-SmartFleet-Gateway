#!/usr/bin/perl
# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use Getopt::Long;
use File::Spec;

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Paths;
use FM::Config;
use FM::Loxlog;
use FM::Events;
use FM::Healthcheck;

my ($dir, $lbhomedir, $verbose);
GetOptions(
    'dir=s'         => \$dir,
    'lbhomedir=s'   => \$lbhomedir,
    'verbose'       => \$verbose,
) or die "Aufruf: fm_healthcheck.pl --dir <konfigdir> --lbhomedir <pfad> [--verbose]\n";
die "fm_healthcheck: --dir fehlt\n" if !$dir;

my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $cfg = FM::Config::load($dir);
if (!$cfg->{site}) {
    print "Noch nicht angemeldet - kein Healthcheck.\n" if $verbose;
    exit 0;
}

my $log;
my $hatte_problem = 0;
sub say_v    { print "$_[0]\n" if $verbose; FM::Loxlog::inf($log, $_[0]); }
sub say_warn { $hatte_problem = 1; print "$_[0]\n" if $verbose; FM::Loxlog::warn($log, $_[0]); }
sub say_err  { $hatte_problem = 1; print "$_[0]\n" if $verbose; FM::Loxlog::err($log, $_[0]); }
sub say_deb  { print "$_[0]\n" if $verbose; FM::Loxlog::deb($log, $_[0]); }

$log = FM::Loxlog::start('healthcheck', 'Healthcheck-Lauf');

my $hc = $lbhomedir ? File::Spec->catfile($lbhomedir, 'sbin', 'healthcheck.pl') : undef;
if (!$hc || !-x $hc) {
    say_err('healthcheck.pl nicht gefunden oder nicht ausfuehrbar'
        . (defined $hc ? " ($hc)" : ' (kein --lbhomedir angegeben)'));
    FM::Events::add($rt, 'error', 'healthcheck', 'LoxBerry-Healthcheck nicht verfuegbar', msno => 0);
    FM::Loxlog::ende($log);
    exit 1;
}

say_deb("-> $^X $hc action=check output=json");
my $json;
my $gestartet = open(my $fh, '-|', $^X, $hc, 'action=check', 'output=json');
if (!$gestartet) {
    say_err("healthcheck.pl liess sich nicht starten: $!");
    FM::Events::add($rt, 'error', 'healthcheck', 'LoxBerry-Healthcheck liess sich nicht starten', msno => 0);
    FM::Loxlog::ende($log);
    exit 1;
}
{
    local $/;
    $json = <$fh>;
}
close $fh;
my $rc = $? >> 8;
say_deb('<- Exitcode ' . $rc . ', ' . length($json // '') . ' Byte');

my @events = FM::Healthcheck::events($json // '');

if (!@events && $rc != 0) {
    say_err("healthcheck.pl beendete sich mit Exitcode $rc, keine auswertbare Antwort");
    FM::Events::add($rt, 'error', 'healthcheck',
        "LoxBerry-Healthcheck fehlgeschlagen (Exitcode $rc)", msno => 0);
    FM::Loxlog::ende($log);
    exit 1;
}

for my $e (@events) {
    FM::Events::add($rt, $e->{sev}, 'healthcheck', $e->{msg}, msno => 0);
    if ($e->{sev} eq 'error') { say_err($e->{msg}); }
    else                      { say_warn($e->{msg}); }
}
say_v('Healthcheck abgeschlossen: ' . scalar(@events) . ' Ereignis(se) gemeldet');

FM::Loxlog::ok($log, 'Healthcheck ohne Befund') if !$hatte_problem;
FM::Loxlog::ende($log);
exit 0;

