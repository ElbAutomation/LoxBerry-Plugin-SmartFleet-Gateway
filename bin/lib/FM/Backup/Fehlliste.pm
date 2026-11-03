# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Fehlliste;
use strict;
use warnings;
use utf8;
use FM::Meldung;

use constant TEXT_MAX   => 170;
use constant DETAIL_MAX => 1500;
my @STUFEN = (48, 36, 24, 20);

sub kurz {
    my ($p, $max) = @_;
    $p //= '';
    my $z = length $p;
    return $p if $z <= $max || $max < 8;
    my $vorn = int(($max - 1) * 45 / 100);
    my $hinten = $max - 1 - $vorn;
    my $name = $p =~ m{/([^/]*)\z} ? length $1 : 0;
    if ($name > $hinten) {
        $hinten = $name < $max - 6 ? $name : $max - 6;
        $vorn = $max - 1 - $hinten;
    }
    return substr($p, 0, $vorn) . "\x{2026}" . substr($p, $z - $hinten);
}

sub grund {
    my ($e) = @_;
    my $st = $e->{status} // 0;
    $st = 0 if $st == 599;
    return $st ? FM::Meldung->new('grund_datei_http', $st) : FM::Meldung->new('grund_datei_keine_antwort');
}

sub _bauen {
    my ($wer, $l, $fehlend, $gesamt, $max) = @_;
    my @d1 = (kurz($l->[0]{pfad}, $max), grund($l->[0]));
    if (@$l == 1 || $fehlend <= 1) {
        return FM::Meldung->new('backup_unvollstaendig_1', $wer, $fehlend, $gesamt, @d1) if $fehlend <= 1;
        return FM::Meldung->new('backup_unvollstaendig_1_mehr', $wer, $fehlend, $gesamt, @d1, $fehlend - 1);
    }
    my @d2 = (kurz($l->[1]{pfad}, $max), grund($l->[1]));
    return FM::Meldung->new('backup_unvollstaendig_2', $wer, $fehlend, $gesamt, @d1, @d2) if $fehlend == 2;
    return FM::Meldung->new('backup_unvollstaendig_2_mehr', $wer, $fehlend, $gesamt, @d1, @d2, $fehlend - 2);
}

sub meldung {
    my ($wer, $l, $fehlend, $gesamt) = @_;
    $l ||= [];
    return FM::Meldung->new('backup_unvollstaendig', $wer, $fehlend, $gesamt) if !@$l || !$fehlend;
    my $m;
    for my $max (@STUFEN) {
        $m = _bauen($wer, $l, $fehlend, $gesamt, $max);
        my $text = "$m";
        $text =~ s/\A\Q$wer\E: //;
        last if length($text) <= TEXT_MAX;
    }
    return $m;
}

sub detail {
    my ($l, $fehlend) = @_;
    $l ||= [];
    my ($out, $gezeigt) = ('', 0);
    for my $e (@$l) {
        my $z = ($out eq '' ? '' : "\n") . ($e->{pfad} // '') . ' (' . grund($e) . ')';
        last if length($out) + length($z) + 24 >= DETAIL_MAX;
        $out .= $z;
        $gezeigt++;
    }
    $out .= ($out eq '' ? '' : "\n") . 'und ' . ($fehlend - $gezeigt) . ' weitere' if ($fehlend // 0) > $gezeigt;
    return $out;
}

1;

