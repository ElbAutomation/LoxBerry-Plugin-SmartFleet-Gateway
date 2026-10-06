# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Keys;

use strict;
use warnings;
use File::Temp;
use File::Spec;
use MIME::Base64 qw(encode_base64);

use constant SPKI_PREFIX => pack('H*', '302a300506032b6570032100');

my $_openssl_checked = 0;

sub require_openssl3 {
    return if $_openssl_checked;
    my $v = `openssl version 2>&1`;
    $v = '' if !defined $v;
    if ($v !~ /^OpenSSL\s+([3-9]|\d{2,})\./) {
        die "FM::Keys: OpenSSL 3.0 oder neuer wird gebraucht, gefunden: $v";
    }
    $_openssl_checked = 1;
    return;
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "FM::Keys: $path nicht lesbar: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub _spew {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "FM::Keys: $path nicht schreibbar: $!";
    print {$fh} $data;
    close $fh or die "FM::Keys: $path nicht geschlossen: $!";
    return;
}

sub _run {
    my (@cmd) = @_;
    return system(@cmd) == 0 ? 1 : 0;
}

sub generate {
    my ($keyfile) = @_;
    require_openssl3();
    _run('openssl', 'genpkey', '-algorithm', 'ed25519', '-out', $keyfile)
        or die "FM::Keys: Schluesselerzeugung fehlgeschlagen\n";
    chmod(0600, $keyfile) == 1
        or die "FM::Keys: Rechte 0600 konnten nicht gesetzt werden\n";
    return 1;
}

sub public_raw {
    my ($keyfile) = @_;
    require_openssl3();
    my $tmp = File::Temp->new(SUFFIX => '.der');
    my $der = $tmp->filename;
    close $tmp;
    _run('openssl', 'pkey', '-in', $keyfile, '-pubout', '-outform', 'DER', '-out', $der)
        or die "FM::Keys: Pubkey konnte nicht abgeleitet werden\n";
    my $bytes = _slurp($der);
    die "FM::Keys: unerwartete DER-Laenge " . length($bytes) . " (erwartet 44)\n" if length($bytes) != 44;
    return substr($bytes, -32);
}

sub raw_to_pem {
    my ($pub32) = @_;
    die "FM::Keys: Pubkey muss 32 Byte haben\n" if length($pub32) != 32;
    my $b64  = encode_base64(SPKI_PREFIX . $pub32, '');
    my $body = join("\n", ($b64 =~ /(.{1,64})/g));
    return "-----BEGIN PUBLIC KEY-----\n$body\n-----END PUBLIC KEY-----\n";
}

sub sign {
    my ($keyfile, $message) = @_;
    require_openssl3();
    my $mtmp = File::Temp->new();
    my $mfile = $mtmp->filename;
    close $mtmp;
    my $stmp = File::Temp->new();
    my $sfile = $stmp->filename;
    close $stmp;
    _spew($mfile, $message);
    _run('openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', $keyfile,
         '-in', $mfile, '-out', $sfile)
        or die "FM::Keys: Signieren fehlgeschlagen\n";
    my $sig = _slurp($sfile);
    die "FM::Keys: Signatur hat " . length($sig) . " statt 64 Byte\n" if length($sig) != 64;
    return $sig;
}

sub verify_raw {
    my ($pub32, $message, $sig64) = @_;
    return 0 if !defined $pub32 || length($pub32) != 32;
    return 0 if !defined $sig64 || length($sig64) != 64;
    require_openssl3();
    my $ptmp = File::Temp->new(SUFFIX => '.pem');
    my $pfile = $ptmp->filename;
    close $ptmp;
    my $mtmp = File::Temp->new();
    my $mfile = $mtmp->filename;
    close $mtmp;
    my $stmp = File::Temp->new();
    my $sfile = $stmp->filename;
    close $stmp;
    _spew($pfile, raw_to_pem($pub32));
    _spew($mfile, $message);
    _spew($sfile, $sig64);
    open my $olderr, '>&', \*STDERR or die "FM::Keys: STDERR nicht sicherbar\n";
    open STDERR, '>', File::Spec->devnull or die "FM::Keys: devnull nicht offen\n";
    my $ok = _run('openssl', 'pkeyutl', '-verify', '-rawin', '-pubin',
                  '-inkey', $pfile, '-in', $mfile, '-sigfile', $sfile);
    open STDERR, '>&', $olderr or die "FM::Keys: STDERR nicht zurueckgesetzt\n";
    return $ok ? 1 : 0;
}

1;

