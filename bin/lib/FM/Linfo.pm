# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Linfo;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;

my $UA;

sub _ua {
    return $UA if $UA;
    $UA = HTTP::Tiny->new(agent => 'fm-agent/1.0', timeout => 15);
    return $UA;
}

sub pluck {
    my ($data, $path) = @_;
    return undef if !defined $data || ref($path) ne 'ARRAY';
    my $cur = $data;
    for my $step (@$path) {
        return undef if ref($cur) ne 'HASH';
        return undef if !exists $cur->{$step};
        $cur = $cur->{$step};
    }
    return $cur;
}

sub _num {
    my ($v) = @_;
    return undef if !defined $v || ref $v;
    return $v =~ /(-?[0-9]+(?:\.[0-9]+)?)/ ? $1 + 0 : undef;
}

sub _pct {
    my ($total, $free) = @_;
    $total = _num($total);
    $free  = _num($free);
    return undef if !defined $total || !defined $free || $total <= 0;
    my $p = ($total - $free) / $total * 100;
    return undef if $p < 0 || $p > 100;
    return sprintf('%.2f', $p) + 0;
}

sub parse_value {
    my ($pick, $data, $path) = @_;
    return undef if !defined $pick;

    if ($pick eq 'number') {
        return _num(pluck($data, $path));
    }
    if ($pick eq 'usedpct') {
        my $r = pluck($data, $path);
        return undef if ref($r) ne 'HASH';
        return _pct($r->{total}, $r->{free});
    }
    if ($pick eq 'swappct') {
        my $r = pluck($data, $path);
        return undef if ref($r) ne 'HASH';
        return _pct($r->{swapTotal}, $r->{swapFree});
    }
    if ($pick eq 'mountpct') {
        my $wanted = (ref($path) eq 'ARRAY' && @$path) ? $path->[0] : '/';
        my $mounts = pluck($data, ['Mounts']);
        return undef if ref($mounts) ne 'ARRAY';
        for my $m (@$mounts) {
            next if ref($m) ne 'HASH';
            my $mp = $m->{mount} // $m->{mountpoint} // $m->{path};
            next if !defined $mp || $mp ne $wanted;
            return _num($m->{used_percent}) if defined $m->{used_percent};
            return _pct($m->{size}, $m->{free});
        }
        return undef;
    }
    if ($pick eq 'firsttemp') {
        my $liste = pluck($data, $path);
        return undef if ref($liste) ne 'ARRAY' || !@$liste;
        my $erster = $liste->[0];
        return undef if ref($erster) ne 'HASH';
        return _num($erster->{temp});
    }
    return undef;
}

sub from_data {
    my ($data, $metrics) = @_;
    my (%values, @missing);
    for my $m (@$metrics) {
        my $v = parse_value($m->{pick}, $data, $m->{path});
        if (defined $v) { $values{ $m->{key} } = $v; }
        else            { push @missing, $m->{key}; }
    }
    return (\%values, \@missing);
}

sub collect {
    my ($url, $metrics) = @_;
    my $r = _ua()->get($url);
    return ({}, [ map { $_->{key} } @$metrics ], "HTTP $r->{status}")
        if !$r->{success};
    my $data = eval { JSON::PP->new->decode($r->{content}) };
    return ({}, [ map { $_->{key} } @$metrics ], 'Antwort ist kein gueltiges JSON')
        if !$data;
    my ($v, $miss) = from_data($data, $metrics);
    return ($v, $miss, undef);
}

1;

