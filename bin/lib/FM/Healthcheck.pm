# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Healthcheck;

use strict;
use warnings;
use JSON::PP;

my %SEV = ( 3 => 'error', 4 => 'warn' );

sub events {
    my ($json_text) = @_;
    my $checks = eval { JSON::PP->new->decode($json_text) };
    return () if !$checks || ref($checks) ne 'ARRAY';

    my @out;
    for my $c (@$checks) {
        next if ref($c) ne 'HASH';
        my $status = $c->{status};
        next if !defined $status;
        my $sev = $SEV{$status};
        next if !$sev;

        my $titel = (defined $c->{title} && $c->{title} ne '')
            ? $c->{title} : (defined $c->{sub} && $c->{sub} ne '' ? $c->{sub} : 'Pruefung');
        my $ergebnis = (defined $c->{result} && $c->{result} ne '')
            ? $c->{result} : '(kein Ergebnistext)';
        push @out, { sev => $sev, msg => "$titel: $ergebnis" };
    }
    return @out;
}

1;

