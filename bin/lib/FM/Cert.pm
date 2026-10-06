# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Cert;

use strict;
use warnings;
use JSON::PP;
use FM::B64 qw(b64u_encode b64u_decode);
use FM::Keys;

my @REQUIRED = qw(v typ sub pub iss nbf exp);
my %VALID_TYP = map { $_ => 1 } qw(ca srv site);
my @STRING_FIELDS = qw(typ sub pub iss);
my @NUMBER_FIELDS = qw(v nbf exp);

sub _json { return JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(0); }

sub _is_json_number {
    my ($v) = @_;
    return 0 if ref($v) ne '';
    return 0 if JSON::PP::is_bool($v);
    return $v =~ /\A-?[0-9]+\z/ ? 1 : 0;
}

sub _is_json_string {
    my ($v) = @_;
    return 0 if ref($v) ne '';
    return 0 if JSON::PP::is_bool($v);
    return _is_json_number($v) ? 0 : 1;
}

sub encode {
    my ($payload, $signer_keyfile) = @_;
    die "FM::Cert: Payload muss ein Hashref sein\n" if ref($payload) ne 'HASH';
    for my $f (@REQUIRED) {
        die "FM::Cert: Pflichtfeld fehlt: $f\n" if !defined $payload->{$f};
    }
    die "FM::Cert: unbekannter typ: $payload->{typ}\n" if !$VALID_TYP{ $payload->{typ} };
    die "FM::Cert: nur Formatversion 1\n" if $payload->{v} != 1;

    $payload->{$_} += 0 for qw(v nbf exp);

    my $b64payload = b64u_encode(_json()->encode($payload));
    my $sig        = FM::Keys::sign($signer_keyfile, $b64payload);
    return $b64payload . '.' . b64u_encode($sig);
}

sub decode {
    my ($cert) = @_;
    die "FM::Cert: leeres Zertifikat\n" if !defined $cert || $cert eq '';
    my @parts = split /\./, $cert, -1;
    die "FM::Cert: erwartet genau zwei durch Punkt getrennte Teile\n" if @parts != 2;
    my $payload = eval { _json()->decode(b64u_decode($parts[0])) };
    die "FM::Cert: Payload nicht lesbar: $@" if !$payload;
    die "FM::Cert: Payload ist kein Objekt\n" if ref($payload) ne 'HASH';
    for my $f (@REQUIRED) {
        die "FM::Cert: Pflichtfeld fehlt: $f\n" if !defined $payload->{$f};
    }
    for my $f (@STRING_FIELDS) {
        die "FM::Cert: Feld '$f' muss ein String sein\n" if !_is_json_string($payload->{$f});
    }
    for my $f (@NUMBER_FIELDS) {
        die "FM::Cert: Feld '$f' muss eine Zahl sein\n" if !_is_json_number($payload->{$f});
    }
    if (defined $payload->{tier}) {
        die "FM::Cert: Feld 'tier' muss ein String sein\n" if !_is_json_string($payload->{tier});
    }
    if (defined $payload->{max_standorte}) {
        die "FM::Cert: Feld 'max_standorte' muss eine Zahl sein\n"
            if !_is_json_number($payload->{max_standorte});
    }
    if (defined $payload->{upd}) {
        die "FM::Cert: Feld 'upd' muss eine Zahl sein\n"
            if !_is_json_number($payload->{upd});
    }
    die "FM::Cert: unbekannter typ\n"   if !$VALID_TYP{ $payload->{typ} };
    die "FM::Cert: nur Formatversion 1\n" if $payload->{v} != 1;
    return $payload;
}

sub verify_one {
    my ($cert, $issuer_pub32) = @_;
    return 0 if !defined $cert || !defined $issuer_pub32;
    my @parts = split /\./, $cert, -1;
    return 0 if @parts != 2;
    my $sig = eval { b64u_decode($parts[1]) };
    return 0 if !defined $sig;
    return FM::Keys::verify_raw($issuer_pub32, $parts[0], $sig);
}

sub verify_chain {
    my ($chain, %opt) = @_;

    my $expect_typ = $opt{expect_typ} or die "FM::Cert: expect_typ ist Pflicht\n";
    my $now        = defined $opt{now} ? $opt{now} : time();
    my $roots      = $opt{roots};
    if (!$roots) {
        require FM::Roots;
        $roots = FM::Roots::roots();
    }
    die "FM::Cert: keine Vertrauenswurzel bekannt\n" if !%$roots;

    die "FM::Cert: leere Kette\n" if !defined $chain || $chain eq '';
    my @parts = split /~/, $chain, -1;
    die "FM::Cert: Kette muss genau zwei Glieder haben, hat " . scalar(@parts) . "\n"
        if @parts != 2;

    my $leaf = decode($parts[0]);
    my $ca   = decode($parts[1]);

    die "FM::Cert: zweites Glied hat typ '$ca->{typ}', erwartet 'ca'\n" if $ca->{typ} ne 'ca';
    die "FM::Cert: Blatt hat typ '$leaf->{typ}', erwartet '$expect_typ'\n"
        if $leaf->{typ} ne $expect_typ;

    die "FM::Cert: Blatt nennt als Aussteller '$leaf->{iss}', die CA heisst '$ca->{sub}'\n"
        if $leaf->{iss} ne $ca->{sub};

    my $root_pub = $roots->{ $ca->{iss} };
    die "FM::Cert: unbekannte Wurzel '$ca->{iss}'\n" if !$root_pub;

    die "FM::Cert: Signatur der CA ist ungueltig\n"
        if !verify_one($parts[1], $root_pub);
    my $ca_pub = b64u_decode($ca->{pub});
    die "FM::Cert: Signatur des Blatts ist ungueltig\n"
        if !verify_one($parts[0], $ca_pub);

    for my $c ([ 'CA', $ca ], [ 'Blatt', $leaf ]) {
        my ($what, $p) = @$c;
        die "FM::Cert: $what ist noch nicht gueltig (nbf $p->{nbf} > $now)\n" if $now < $p->{nbf};
        die "FM::Cert: $what ist abgelaufen (exp $p->{exp} < $now)\n"          if $now > $p->{exp};
    }

    if (defined $opt{expect_sub}) {
        die "FM::Cert: Blatt-Inhaber '$leaf->{sub}' stimmt nicht mit erwartetem '$opt{expect_sub}' ueberein\n"
            if $leaf->{sub} ne $opt{expect_sub};
    }

    return $leaf;
}

1;

