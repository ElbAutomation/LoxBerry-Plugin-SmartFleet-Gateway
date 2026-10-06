# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Sync;

use strict;
use warnings;
use FM::Spool;

use constant SYNC_MAX => 50;

use constant SYNC_MAX_VALUES => 4000;

sub count_values {
    my ($rec) = @_;
    return 0 if ref($rec) ne 'HASH';
    my $n = 0;
    $n += scalar(keys %{ $rec->{lb} }) if ref($rec->{lb}) eq 'HASH';
    if (ref($rec->{ms}) eq 'ARRAY') {
        for my $m (@{ $rec->{ms} }) {
            next if ref($m) ne 'HASH';
            $n++ if defined $m->{rt_ms};
            $n += scalar(keys %{ $m->{v} }) if ref($m->{v}) eq 'HASH';
        }
    }
    $n += scalar(@{ $rec->{ch} }) if ref($rec->{ch}) eq 'ARRAY';
    $n += scalar(@{ $rec->{cr} }) if ref($rec->{cr}) eq 'ARRAY';
    $n += scalar(@{ $rec->{ep} }) if ref($rec->{ep}) eq 'ARRAY';
    return $n;
}

sub take_samples {
    my ($dir) = @_;
    my ($recs, $offset, $offsets) = FM::Spool::read($dir, SYNC_MAX);
    return ([], 0) if !@$recs;

    my @batch;
    my $werte = 0;
    for my $i (0 .. $#$recs) {
        my $n = count_values($recs->[$i]);
        last if @batch && $werte + $n > SYNC_MAX_VALUES;
        push @batch, $recs->[$i];
        $werte += $n;
    }

    my $off = (scalar(@batch) == scalar(@$recs))
        ? $offset
        : $offsets->[ scalar(@batch) - 1 ];

    return (\@batch, $off);
}

sub may_truncate {
    my ($ans, $sent) = @_;
    return 1 if ref($ans) ne 'HASH';
    my $r = $ans->{records};
    return 1 if !defined $r || ref($r) ne '' || $r !~ /\A[0-9]+\z/;
    return ($r + 0) >= ($sent + 0) ? 1 : 0;
}

1;

