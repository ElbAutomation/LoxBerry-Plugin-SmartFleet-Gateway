# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Selftest;

use strict;
use warnings;
use HTTP::Tiny;

sub allowed {
    my ($base, $url) = @_;
    return 0 if !defined $base || $base eq '';
    return 0 if !defined $url  || $url  eq '';
    return 0 if $url !~ m{\Ahttps?://}i;

    my $praefix = $base;
    $praefix =~ s{/+\z}{};
    $praefix .= '/';

    return 0 if index($url, $praefix) != 0;
    return 1;
}

sub _ua {
    require FM::Http;
    return HTTP::Tiny->new(agent => 'fm-agent/1.0', timeout => 15, verify_SSL => FM::Http::verify_an());
}

sub run {
    my ($base, $url) = @_;
    return undef if !allowed($base, $url);

    my $r  = _ua()->get($url);
    my $st = $r->{status};

    return undef if !defined $st || $st == 599;
    return $st + 0;
}

1;

