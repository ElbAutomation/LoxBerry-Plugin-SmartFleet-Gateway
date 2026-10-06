# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Jobs;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(run_jobs);

sub run_jobs {
    my ($jobs, $handlers, $say_v) = @_;
    $say_v ||= sub { };
    $handlers ||= {};
    my @acks;
    for my $job (@{ ref($jobs) eq 'ARRAY' ? $jobs : [] }) {
        my $type = $job->{type} || '';
        my $h    = $handlers->{$type};
        if (!$h) {
            $say_v->("Unbekannter Auftragstyp '$type' - wird abgelehnt.");
            push @acks, { job => $job->{id}, status => 'failed', result => 'unbekannter Auftragstyp' };
            next;
        }
        my ($ok, $result) = eval { $h->($job) };
        if ($@) {
            ($ok, $result) = (0, "Ausnahme: $@");
        }
        push @acks, { job => $job->{id}, status => ($ok ? 'ok' : 'failed'), result => "$result" };
        $say_v->("Auftrag $job->{id} ($type): " . ($ok ? 'ok' : 'fehlgeschlagen'));
    }
    return \@acks;
}

1;

