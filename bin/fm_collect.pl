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
use Time::HiRes qw(time);
use FM::Paths;
use FM::Config;
use FM::Settings;
use FM::State;
use FM::Spool;
use FM::Catalog;
use FM::Miniserver;
use FM::Linfo;
use FM::Collect;
use FM::Events;
use FM::Loxlog;

my ($dir, $verbose, $dry);
GetOptions('dir=s' => \$dir, 'verbose' => \$verbose, 'dry-run' => \$dry)
    or die "Aufruf: fm_collect.pl --dir <konfigdir> [--verbose] [--dry-run]\n";
die "fm_collect: --dir fehlt\n" if !$dir;
my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $log;
sub log_oeffnen {
    return if $log;
    $log = FM::Loxlog::start('collect', 'Sammellauf');
}
sub say_v   { my $t = "@_"; print "$t\n" if $verbose; FM::Loxlog::inf($log, $t); }
sub say_err { my $t = "@_"; print "$t\n" if $verbose; FM::Loxlog::err($log, $t); }
sub say_deb { my $t = "@_"; print "$t\n" if $verbose; FM::Loxlog::deb($log, $t); }

sub lb_id_lesen {
    no warnings 'once';
    my $pfad = "$LoxBerry::System::lbsconfigdir/loxberryid.cfg";
    open(my $fh, '<', $pfad) or return undef;
    local $/;
    my $inhalt = <$fh>;
    close($fh);
    return undef if !defined $inhalt;
    $inhalt =~ s/^\s+|\s+$//g;
    return $inhalt ne '' ? $inhalt : undef;
}

my $lbwebserverport;
my $get_miniservers;
my $lbfriendlyname;
my $lbversion;
{
    my $ok = eval {
        require LoxBerry::System;
        {
            no strict 'refs';
            for my $f (qw(lbwebserverport get_miniservers lbfriendlyname lbversion)) {
                die "LoxBerry::System::$f fehlt\n"
                    if !defined &{"LoxBerry::System::$f"};
            }
        }
        $lbwebserverport = \&LoxBerry::System::lbwebserverport;
        $get_miniservers = \&LoxBerry::System::get_miniservers;
        $lbfriendlyname  = \&LoxBerry::System::lbfriendlyname;
        $lbversion       = \&LoxBerry::System::lbversion;
        1;
    };
    if (!$ok) {
        say_v('LoxBerry::System ist hier nicht verfuegbar - der Sammler beendet sich.');
        exit 0;
    }
}

my $lock = FM::State::lock($rt, 'collect');
if (!$lock) {
    say_v('Ein anderer Sammellauf ist aktiv - dieser beendet sich.');
    exit 0;
}

my $cfg = FM::Config::load($dir);
if (!$cfg->{site}) {
    say_v('Standort ist nicht angemeldet.');
    exit 0;
}

my $state = FM::State::load($rt);
my $desired = ref($state->{desired}) eq 'HASH' ? $state->{desired} : {};
my $tcfg = ref($desired->{telemetry}) eq 'HASH' ? $desired->{telemetry} : {};
my $interval = $tcfg->{interval} && $tcfg->{interval} >= 60 ? $tcfg->{interval} : 300;

my $now = time();
if (!$dry && !FM::Collect::due($state, $now, $interval)) {
    say_v('Intervall noch nicht erreicht.');
    exit 0;
}
log_oeffnen();
$state->{collect_next} = int($now) + $interval if !$dry;

FM::State::save($rt, $state) if !$dry;

my $lb_metrics = FM::Catalog::select([ FM::Catalog::loxberry_all() ], $tcfg->{loxberry});
my $lb_values  = {};
if (@$lb_metrics) {
    my $port = $lbwebserverport->() || 80;
    my $lb_url = "http://localhost:$port/system/tools/linfo/index.php?out=json";
    my ($v, $lb_missing, $lb_err) = FM::Linfo::collect($lb_url, $lb_metrics);
    $lb_values = $v;
    say_v("LoxBerry: " . scalar(keys %$lb_values) . " Werte"
          . (@$lb_missing ? ', fehlend: ' . join(',', @$lb_missing) : '')
          . ($lb_err ? " ($lb_err)" : ''));
}
else {
    say_v('LoxBerry-Telemetrie ist fuer diesen Standort abgeschaltet.');
}

my $ms_metrics = FM::Catalog::select([ FM::Catalog::miniserver_all() ], $tcfg->{miniserver});

my $want_inventory = (exists $tcfg->{inventory} && !$tcfg->{inventory}) ? 0 : 1;

my $want_devicetree = (exists $tcfg->{devicetree} && !$tcfg->{devicetree}) ? 0 : 1;
my $devtree_every = ($tcfg->{devicetree_every} && $tcfg->{devicetree_every} >= 1) ? $tcfg->{devicetree_every} : 3;

my %miniservers = $get_miniservers->();

for my $msno (keys %miniservers) {
    next if FM::Miniserver::ist_lokal($miniservers{$msno});
    say_v("Miniserver $msno: per Cloud DNS angebunden - wird nicht gemeldet");
    delete $miniservers{$msno};
}

my @ms_records;

my $ident_cache = ref($state->{ms_ident}) eq 'HASH' ? $state->{ms_ident} : {};
my $fehlt_cache = ref($state->{ms_fehlt}) eq 'HASH' ? $state->{ms_fehlt} : {};

if (!@$ms_metrics && !$want_inventory) {
    say_v('Miniserver-Telemetrie und Inventar sind fuer diesen Standort abgeschaltet.');
}
else {
    for my $msno (sort { $a <=> $b } keys %miniservers) {
        my ($rec, $missing) = FM::Collect::miniserver_record(
            $miniservers{$msno}, $msno, $ms_metrics, $ident_cache, $now,
            inventory => $want_inventory, devicetree => $want_devicetree,
            devicetree_interval => $interval, devicetree_every => $devtree_every,
            fehlt => $fehlt_cache, sagen => \&say_deb);
        push @ms_records, $rec;
        say_v("Miniserver $msno: " . scalar(keys %{ $rec->{v} }) . " Werte, "
              . "erreichbar=$rec->{reachable}"
              . (exists $rec->{devtree} ? ', Geraetebaum aktualisiert' : '')
              . (@$missing ? ', fehlend: ' . join(',', @$missing) : ''));
    }
}

$state->{ms_ident} = $ident_cache if !$dry;
$state->{ms_fehlt} = $fehlt_cache if !$dry;

my $ms_messages_seen = ref($state->{ms_messages}) eq 'HASH' ? $state->{ms_messages} : {};
for my $msno (sort { $a <=> $b } keys %miniservers) {
    my $mc_uuid = $ident_cache->{$msno} ? $ident_cache->{$msno}{message_center_uuid} : undef;
    next if !defined $mc_uuid || $mc_uuid eq '';

    my @entries = FM::Miniserver::messages($miniservers{$msno}, $mc_uuid, \&say_deb);
    my $seen_vorher = ref($ms_messages_seen->{$msno}) eq 'HASH' ? $ms_messages_seen->{$msno} : {};
    my $rooms = $ident_cache->{$msno} ? $ident_cache->{$msno}{rooms} : {};
    my ($events, $seen_nachher) = FM::Collect::ms_message_events(\@entries, $seen_vorher, $rooms);
    $ms_messages_seen->{$msno} = $seen_nachher;

    for my $ev (@$events) {
        my %opt = (msno => $msno);
        $opt{room}   = $ev->{room}   if defined $ev->{room};
        $opt{detail} = $ev->{detail} if defined $ev->{detail};
        FM::Events::add($rt, $ev->{sev}, $ev->{src}, $ev->{msg}, %opt);
    }
    say_v("Miniserver $msno: " . scalar(@entries) . " Systemmeldung(en), "
          . scalar(@$events) . " davon gemeldet/behoben") if @entries || @$events;
}
$state->{ms_messages} = $ms_messages_seen if !$dry;

if (!$dry) {
    FM::Spool::append($rt, FM::Collect::build_record(
        int($now), $lb_values, \@ms_records, $lbfriendlyname->(), $lbversion->(), lb_id_lesen()));
    FM::State::save($rt, $state);
    say_v('Spool: ' . FM::Spool::size($rt) . ' Byte');
}
else {
    say_v('Testlauf (--dry-run): nichts wurde in den Spool gelegt oder gespeichert.');
}
FM::Loxlog::ok($log, 'Sammellauf abgeschlossen');
FM::Loxlog::ende($log);
exit 0;

