# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Jobs;

use strict;
use warnings;
use Exporter 'import';
use FM::Meldung;

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
            push @acks, _ack($job->{id}, 0, FM::Meldung->new('job_unbekannt'));
            next;
        }
        my ($ok, $result) = eval { $h->($job) };
        if ($@) {
            my $e = "$@";
            $e =~ s/\s+\z//;
            ($ok, $result) = (0, FM::Meldung->new('job_ausnahme', $e));
        }
        push @acks, _ack($job->{id}, $ok, $result);
        $say_v->("Auftrag $job->{id} ($type): " . ($ok ? 'ok' : 'fehlgeschlagen'));
    }
    return \@acks;
}

sub _ack {
    my ($id, $ok, $result) = @_;
    my $a = { job => $id, status => ($ok ? 'ok' : 'failed'), result => (defined $result ? "$result" : '') };
    if (FM::Meldung::ist($result)) {
        $a->{code} = $result->code;
        my $args = $result->args_json;
        $a->{args} = $args if @$args;
    }
    return $a;
}

1;

