# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Element;

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Temp qw(tempfile);
use File::Copy qw(move);
use FM::Chart;

use constant LAUF_MAX    => 50;
use constant LISTE_MAX   => 500;
use constant AUSGAENGE_MAX => 64;
use constant PAUSE_MS    => 100;

sub _datei { my ($rt) = @_; return File::Spec->catfile($rt, 'element_pruefung.json'); }

sub _gueltig {
    my ($e) = @_;
    return 0 if ref($e) ne 'HASH';
    return 0 if !defined $e->{msno} || ref($e->{msno}) ne '' || $e->{msno} !~ /\A[0-9]+\z/;
    return 0 if !defined $e->{b}    || ref($e->{b}) ne ''    || $e->{b} !~ /\A[0-9A-Za-z-]{1,64}\z/;
    return 0 if !defined $e->{typ}  || ref($e->{typ}) ne ''  || $e->{typ} !~ /\A[A-Za-z0-9_ ]{1,80}\z/;
    return 1;
}

sub pruefung_roh {
    my ($rt) = @_;
    my $f = _datei($rt);
    return undef if !-f $f;
    open my $fh, '<:raw', $f or return undef;
    local $/;
    my $j = <$fh>;
    close $fh;
    return $j;
}

sub pruefung_rest_speichern {
    my ($rt, $rest, $roh_vorher) = @_;
    my $jetzt = pruefung_roh($rt);
    return 0 if (defined $jetzt ? $jetzt : '') ne (defined $roh_vorher ? $roh_vorher : '');
    return pruefung_speichern($rt, $rest);
}

sub pruefung_laden {
    my ($rt) = @_;
    my $f = _datei($rt);
    return [] if !-f $f;
    open my $fh, '<:raw', $f or return [];
    local $/;
    my $j = <$fh>;
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($j) };
    return [] if ref($d) ne 'ARRAY';
    return [ grep { _gueltig($_) } @$d ];
}

sub pruefung_speichern {
    my ($rt, $liste) = @_;
    return 0 if ref($liste) ne 'ARRAY';
    my @sauber;
    for my $e (@$liste) {
        next if !_gueltig($e);
        push @sauber, { msno => $e->{msno} + 0, b => $e->{b}, typ => $e->{typ} };
        last if @sauber >= LISTE_MAX;
    }
    my $json = JSON::PP->new->canonical->utf8->encode(\@sauber);
    my $f = _datei($rt);
    if (-f $f && open(my $in, '<:raw', $f)) {
        local $/;
        my $alt = <$in>;
        close $in;
        return 1 if defined $alt && $alt eq $json;
    }
    my ($fh, $tmp) = tempfile('element_pr.XXXXXX', DIR => $rt, UNLINK => 0);
    binmode $fh, ':raw';
    print {$fh} $json;
    if (!close $fh) { unlink $tmp; return 0; }
    chmod 0600, $tmp;
    if (!move($tmp, $f)) { unlink $tmp; return 0; }
    return 1;
}

sub klassifizieren {
    my ($body) = @_;
    return undef if !defined $body;
    my $d = eval { JSON::PP->new->utf8->decode($body) };
    return undef if ref($d) ne 'HASH' || ref($d->{LL}) ne 'HASH';
    my $ll = $d->{LL};
    return undef if !defined $ll->{Code} || $ll->{Code} ne '200';
    my %aus;
    my $n = 0;
    for my $k (sort { _nr($a) <=> _nr($b) } grep { /\Aoutput\d+\z/ } keys %$ll) {
        my $o = $ll->{$k};
        next if ref($o) ne 'HASH' || !defined $o->{name} || ref($o->{name}) ne ''
             || $o->{name} !~ /\A[\p{L}\p{M}\p{N}\p{S}_]{1,32}\z/;
        next if exists $aus{ $o->{name} };
        last if $n >= AUSGAENGE_MAX;
        $aus{ $o->{name} } = FM::Chart::ist_zahl($o->{value}) ? 'zahl' : 'text';
        $n++;
    }
    return \%aus if %aus;
    return { value => _art_einfach($ll->{value}) } if defined $ll->{value} && ref($ll->{value}) eq '';
    return {};
}

sub _nr { my ($k) = @_; return $k =~ /(\d+)\z/ ? $1 + 0 : 0; }

sub _art_einfach {
    my ($v) = @_;
    my ($z) = FM::Chart::zahl_mit_einheit($v);
    return defined $z ? 'zahl' : 'text';
}

sub _pause {
    my ($ms) = @_;
    select(undef, undef, undef, $ms / 1000) if $ms > 0;
}

sub abrufen {
    my ($liste, $abruf, %opt) = @_;
    my $deadline = $opt{deadline};
    my $pause_ms = defined $opt{pause_ms} ? $opt{pause_ms} : PAUSE_MS;
    my $pause    = ref($opt{pause}) eq 'CODE' ? $opt{pause} : \&_pause;
    my (@ep, @rest);
    my $bearbeitet = 0;
    my $abgerufen  = 0;
    for my $e (@$liste) {
        if ($bearbeitet >= LAUF_MAX || (defined $deadline && time() > $deadline)) {
            push @rest, $e;
            next;
        }
        $bearbeitet++;
        my %r = (msno => $e->{msno} + 0, b => $e->{b}, typ => $e->{typ}, ok => 0 + 0, ausgaenge => {});
        if ($e->{typ} =~ /text/i) {
            $r{ok} = 1 + 0;
            push @ep, \%r;
            next;
        }
        $pause->($pause_ms) if $abgerufen++;
        my ($ok, $body) = $abruf->($e->{msno} + 0, $e->{b});
        my $aus = $ok ? klassifizieren($body) : undef;
        if ($aus) {
            $r{ok} = 1 + 0;
            $r{ausgaenge} = $aus;
        }
        push @ep, \%r;
    }
    return (\@ep, \@rest);
}

1;

