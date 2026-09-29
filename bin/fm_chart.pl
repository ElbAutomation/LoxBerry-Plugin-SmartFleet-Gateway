#!/usr/bin/perl
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use Getopt::Long;
use File::Spec;
use JSON::PP;

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Paths;
use FM::Config;
use FM::State;
use FM::Loxlog;
use FM::Miniserver;
use FM::Events;
use FM::Spool;
use FM::Chart;
use FM::Element;

use constant LAUF_BUDGET    => 40;
use constant ANTWORT_TEIL   => 50;

my ($dir, $verbose);
GetOptions('dir=s' => \$dir, 'verbose' => \$verbose)
    or die "Aufruf: fm_chart.pl --dir <konfigdir> [--verbose]\n";
die "fm_chart: --dir fehlt\n" if !$dir;

my $rt = FM::Paths::laufzeit($dir);
FM::Paths::uebernehmen($dir);

my $cfg = FM::Config::load($dir);
exit 0 if !$cfg->{site} || !$cfg->{server};
my $keyfile = FM::Config::keyfile($dir);

my $log;
sub say_v  { print "$_[0]\n" if $verbose; FM::Loxlog::inf($log, $_[0]) if $log; }
sub say_deb { print "$_[0]\n" if $verbose; FM::Loxlog::deb($log, $_[0]) if $log; }

my $lock = FM::State::lock($rt, 'chart');
if (!$lock) {
    say_v('Ein Chart-Lauf laeuft bereits - die Sperre ist belegt.');
    exit 0;
}

my $ok_lb = eval {
    require LoxBerry::System;
    no strict 'refs';
    die "get_miniservers fehlt\n" if !defined &{"LoxBerry::System::get_miniservers"};
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
my $state = FM::State::load($rt);
$state->{chart} = {} if ref($state->{chart}) ne 'HASH';
my $now = time();
my $lauf_deadline = $now + LAUF_BUDGET;

my $auswahl     = FM::Chart::auswahl_laden($dir);
my $gruppen     = FM::Chart::gruppen_der_auswahl($auswahl);
my $erfassen    = (%miniservers && @$auswahl && FM::Chart::due($state, $now)) ? 1 : 0;

my $anf = FM::Chart::anforderungen_laden($rt);
my $pruef_roh = FM::Element::pruefung_roh($rt);
my $pruef = FM::Element::pruefung_laden($rt);
exit 0 if !@$anf && !$erfassen && !@$pruef;

my %anf_je_ms;
push @{ $anf_je_ms{ $_->{msno} } }, $_ for @$anf;
my (@antworten, @offen);
for my $msno (sort { $a <=> $b } keys %anf_je_ms) {
    my $ms = $miniservers{$msno};
    if (!$ms) {
        push @antworten, map { { msno => $msno + 0, b => $_->{b}, o => $_->{o}, v => undef } } @{ $anf_je_ms{$msno} };
        next;
    }
    my $base = FM::Miniserver::base_url($ms);
    my $cred = $ms->{Credentials_RAW};
    my $abruf = sub {
        my ($u) = @_;
        return FM::Miniserver::get($base, $cred, "/jdev/sps/io/$u/all");
    };
    my ($cr, $rest) = FM::Chart::anforderungen_lesen($anf_je_ms{$msno}, $abruf, deadline => $lauf_deadline);
    push @antworten, map {
        my $a = { msno => $msno + 0, b => $_->{b}, o => $_->{o}, v => $_->{v} };
        $a->{e} = $_->{e} if defined $_->{e} && $_->{e} ne '';
        $a;
    } @$cr;
    push @offen, map { { msno => $msno + 0, b => $_->{b}, o => $_->{o} } } @$rest;
    say_v("Miniserver $msno: " . scalar(@$cr) . ' Einzelanforderungen beantwortet, ' . scalar(@$rest) . ' offen');
}
while (@antworten) {
    FM::Spool::append($rt, { ts => $now, cr => [ splice(@antworten, 0, ANTWORT_TEIL) ] });
}
FM::Chart::anforderungen_speichern($rt, \@offen) if @$anf;

if (@$pruef) {
    my $abruf_e = sub {
        my ($msno, $u) = @_;
        my $ms = $miniservers{$msno} or return (0, undef);
        return FM::Miniserver::get(FM::Miniserver::base_url($ms), $ms->{Credentials_RAW}, "/jdev/sps/io/$u/all");
    };
    my ($ep, $ep_rest) = FM::Element::abrufen($pruef, $abruf_e, deadline => $lauf_deadline);
    while (@$ep) {
        FM::Spool::append($rt, { ts => $now, ep => [ splice(@$ep, 0, ANTWORT_TEIL) ] });
    }
    FM::Element::pruefung_rest_speichern($rt, $ep_rest, $pruef_roh);
    say_v('Elementpruefung: ' . (scalar(@$pruef) - scalar(@$ep_rest)) . ' bearbeitet, ' . scalar(@$ep_rest) . ' offen');
}

my @werte;
my $lesbar = 1;
for my $msno (sort { $a <=> $b } keys %miniservers) {
    my $ms   = $miniservers{$msno};
    my $base = FM::Miniserver::base_url($ms);
    my $cred = $ms->{Credentials_RAW};
    my $cs   = ($state->{chart}{$msno} ||= {});
    delete @$cs{qw(katalog_version katalog_retry_at version_next)};
    my $abruf = sub {
        my ($u) = @_;
        return FM::Miniserver::get($base, $cred, "/jdev/sps/io/$u/all");
    };

    next if !$erfassen || ref($gruppen->{$msno}) ne 'ARRAY' || !@{ $gruppen->{$msno} };
    my ($w, $fehlt, $voll, $next) = FM::Chart::werte_lesen($gruppen->{$msno}, $abruf,
        deadline => $lauf_deadline, start => $cs->{start} || 0);
    $cs->{start} = $next;
    push @werte, map { { msno => $msno + 0, b => $_->{b}, o => $_->{o}, v => $_->{v} } } @$w;
    $lesbar = 0 if !@$w;
    if ($fehlt && !$cs->{fehlt_gemeldet}) {
        FM::Events::add($rt, 'warn', 'chart', "Miniserver $msno: $fehlt Chart-Werte nicht lesbar", msno => 0);
        $cs->{fehlt_gemeldet} = 1;
    } elsif (!$fehlt) {
        delete $cs->{fehlt_gemeldet};
    }
    if (!$voll && !$cs->{budget_gemeldet}) {
        FM::Events::add($rt, 'warn', 'chart', "Miniserver $msno: Zeitbudget erreicht, Chart-Werte unvollstaendig", msno => 0);
        $cs->{budget_gemeldet} = 1;
    } elsif ($voll) {
        delete $cs->{budget_gemeldet};
    }
    say_v("Miniserver $msno: " . scalar(@$w) . " Werte gelesen, $fehlt nicht lesbar" . ($voll ? '' : ', Zeitbudget erreicht'));
}

FM::Spool::append($rt, { ts => $now, ch => \@werte }) if @werte;
$state->{chart_next} = FM::Chart::naechster($now, $lesbar) if $erfassen;
my $frisch = FM::State::load($rt);
for my $k (qw(chart chart_next)) {
    if (exists $state->{$k}) { $frisch->{$k} = $state->{$k}; }
    else                     { delete $frisch->{$k}; }
}
FM::State::save($rt, $frisch);
exit 0;

