# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Http;

use strict;
use warnings;
use HTTP::Tiny;

my $UA;
my $VERIFY = 1;

sub verify_ssl {
    my ($an) = @_;
    my $neu = $an ? 1 : 0;
    undef $UA if $neu != $VERIFY;
    $VERIFY = $neu;
    return $VERIFY;
}

sub verify_an { return $VERIFY }

sub _ua {
    return $UA if $UA;
    if (!eval { require IO::Socket::SSL; 1 }) {
        die "FM::Http: IO::Socket::SSL fehlt - https ist damit nicht moeglich\n";
    }
    $UA = HTTP::Tiny->new(
        agent           => 'fm-agent/1.0',
        timeout         => 30,
        verify_SSL      => $VERIFY,
        default_headers => { 'Accept' => 'application/json' },
    );
    return $UA;
}

sub get {
    my ($url, $sagen) = @_;
    $sagen ||= sub { };
    $sagen->("-> GET $url");
    my $r = _ua()->get($url);
    $sagen->('<- ' . $r->{status} . ($r->{content} ? "\n$r->{content}" : ''));
    return ($r->{status}, $r->{content}, $r->{headers});
}

sub post_json {
    my ($url, $body, $headers, $sagen) = @_;
    $sagen ||= sub { };
    my %h = ( 'Content-Type' => 'application/json', %{ $headers || {} } );
    $sagen->("-> POST $url\n" . (defined $body ? $body : ''));
    my $r = _ua()->request('POST', $url, { content => $body, headers => \%h });
    $sagen->('<- ' . $r->{status} . ($r->{content} ? "\n$r->{content}" : ''));
    return ($r->{status}, $r->{content}, $r->{headers});
}

1;

