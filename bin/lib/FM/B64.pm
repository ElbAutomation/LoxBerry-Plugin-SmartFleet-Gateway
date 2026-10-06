# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::B64;

use strict;
use warnings;
use MIME::Base64 qw(encode_base64 decode_base64);
use Exporter 'import';

our @EXPORT_OK = qw(b64u_encode b64u_decode);

sub b64u_encode {
    my ($bytes) = @_;
    my $s = encode_base64($bytes, '');
    $s =~ tr{+/}{-_};
    $s =~ s/=+\z//;
    return $s;
}

sub b64u_decode {
    my ($s) = @_;
    die "b64u_decode: undefinierte Eingabe\n" if !defined $s;
    die "b64u_decode: unerlaubte Zeichen\n"   if $s =~ m{[^A-Za-z0-9_-]};
    my $t = $s;
    $t =~ tr{-_}{+/};
    my $rest = length($t) % 4;
    die "b64u_decode: unmoegliche Laenge\n" if $rest == 1;
    $t .= '=' x ((4 - $rest) % 4);
    return decode_base64($t);
}

1;

