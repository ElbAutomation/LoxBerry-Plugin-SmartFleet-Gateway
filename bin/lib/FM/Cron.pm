# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Cron;

use strict;
use warnings;

use constant MAX_NACHHOLEN => 86400 * 2;

sub _feld {
    my ($spec, $min, $max) = @_;
    my %treffer;
    for my $teil (split /,/, $spec) {
        my ($bereich, $schritt) = split m{/}, $teil, 2;
        $schritt = defined $schritt ? $schritt : 1;
        return undef if $schritt !~ /\A[0-9]+\z/ || $schritt < 1;

        my ($von, $bis);
        if ($bereich eq '*') {
            ($von, $bis) = ($min, $max);
        } elsif ($bereich =~ /\A([0-9]+)-([0-9]+)\z/) {
            ($von, $bis) = ($1 + 0, $2 + 0);
        } elsif ($bereich =~ /\A[0-9]+\z/) {
            ($von, $bis) = ($bereich + 0, $bereich + 0);
        } else {
            return undef;
        }
        return undef if $von < $min || $bis > $max || $von > $bis;

        for (my $v = $von; $v <= $bis; $v += $schritt) { $treffer{$v} = 1; }
    }
    return \%treffer;
}

sub _parse {
    my ($ausdruck) = @_;
    return undef if !defined $ausdruck;
    $ausdruck =~ s/\A\s+|\s+\z//g;
    my @f = split /\s+/, $ausdruck;
    return undef if scalar(@f) != 5;

    my $min  = _feld($f[0], 0, 59);
    my $std  = _feld($f[1], 0, 23);
    my $tag  = _feld($f[2], 1, 31);
    my $mon  = _feld($f[3], 1, 12);
    my $wtag = _feld($f[4], 0, 7);
    return undef if !$min || !$std || !$tag || !$mon || !$wtag;

    $wtag->{0} = 1 if $wtag->{7};
    return { min => $min, std => $std, tag => $tag, mon => $mon, wtag => $wtag };
}

sub _passt {
    my ($p, $zeit) = @_;
    my @g = localtime($zeit);
    return 0 if !$p->{min}{ $g[1] };
    return 0 if !$p->{std}{ $g[2] };
    return 0 if !$p->{mon}{ $g[4] + 1 };
    return 0 if !$p->{tag}{ $g[3] };
    return 0 if !$p->{wtag}{ $g[6] };
    return 1;
}

sub due {
    my ($ausdruck, $jetzt, $zuletzt) = @_;
    my $p = _parse($ausdruck);
    return 0 if !$p;
    return 0 if !defined $jetzt;

    return 0 if !defined $zuletzt;
    return 0 if $zuletzt >= $jetzt;

    my $von = $jetzt - $zuletzt > MAX_NACHHOLEN
            ? $jetzt - MAX_NACHHOLEN
            : $zuletzt;

    for (my $t = int($von / 60) * 60 + 60; $t <= $jetzt; $t += 60) {
        return 1 if _passt($p, $t);
    }
    return 0;
}

1;

