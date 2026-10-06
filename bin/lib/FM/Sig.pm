# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Sig;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use FM::B64 qw(b64u_encode);
use FM::Keys;
use Exporter 'import';

our @EXPORT_OK = qw(signing_string new_nonce headers verify_response);

sub signing_string {
    my ($method, $path, $time, $nonce, $body) = @_;
    $body = '' if !defined $body;
    return join("\n", $method, $path, $time, $nonce, sha256_hex($body));
}

sub new_nonce {
    my $bytes;
    if (open my $fh, '<:raw', '/dev/urandom') {
        read $fh, $bytes, 16;
        close $fh;
    }
    if (!defined $bytes || length($bytes) != 16) {
        $bytes = join '', map { chr(int(rand(256))) } 1 .. 16;
    }
    return b64u_encode($bytes);
}

sub headers {
    my ($keyfile, $site_id, $method, $path, $body, $time, $nonce) = @_;
    $time  = time()       if !defined $time;
    $nonce = new_nonce()  if !defined $nonce;
    my $sig = FM::Keys::sign($keyfile, signing_string($method, $path, $time, $nonce, $body));
    return {
        'X-FM-Site'  => $site_id,
        'X-FM-Time'  => "$time",
        'X-FM-Nonce' => $nonce,
        'X-FM-Sig'   => b64u_encode($sig),
    };
}

sub verify_response {
    my ($body, $sig_b64u, $srv_pub32) = @_;
    return 0 if !defined $sig_b64u || $sig_b64u eq '';
    require FM::B64;
    my $sig = eval { FM::B64::b64u_decode($sig_b64u) };
    return 0 if !defined $sig;
    return FM::Keys::verify_raw($srv_pub32, $body, $sig);
}

1;

