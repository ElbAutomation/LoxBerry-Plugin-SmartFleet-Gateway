# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Chart;

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Temp qw(tempfile);
use File::Copy qw(move);

use constant INTERVALL   => 300;
use constant AUSFALL_MAX => 3;

sub zahl_mit_einheit {
    my ($s) = @_;
    return () if !defined $s || ref($s) ne '';
    return () if $s !~ /\A\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s*([^\s\d]\D{0,11})?\s*\z/;
    my ($z, $e) = ($1, defined $2 ? $2 : '');
    $e =~ s/\s+\z//;
    return ($z + 0, $e);
}

sub ist_zahl {
    my ($v) = @_;
    return 0 if !defined $v || ref($v) ne '';
    return $v =~ /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/ ? 1 : 0;
}

sub _nr { my ($k) = @_; return $k =~ /(\d+)\z/ ? $1 + 0 : 0; }

sub parse_all {
    my ($body) = @_;
    return undef if !defined $body;
    my $d = eval { JSON::PP->new->utf8->decode($body) };
    return undef if ref($d) ne 'HASH' || ref($d->{LL}) ne 'HASH';
    my $ll = $d->{LL};
    return undef if !defined $ll->{Code} || $ll->{Code} ne '200';
    my @aus;
    for my $k (sort { _nr($a) <=> _nr($b) } grep { /\Aoutput\d+\z/ } keys %$ll) {
        my $o = $ll->{$k};
        next if ref($o) ne 'HASH' || !defined $o->{name} || $o->{name} !~ /\A[\p{L}\p{M}\p{N}\p{S}_]{1,32}\z/;
        my $v = $o->{value};
        next if !defined $v || ref($v) ne '';
        next if !ist_zahl($v);
        push @aus, [ $o->{name}, $v + 0, '' ];
    }
    return \@aus if @aus;
    my ($z, $e) = zahl_mit_einheit($ll->{value});
    return defined $z ? [ [ 'value', $z, $e ] ] : [];
}

sub werte_lesen {
    my ($auswahl, $abruf, %opt) = @_;
    my $deadline = $opt{deadline};
    my %je;
    push @{ $je{ $_->{b} } }, $_->{o} for @$auswahl;
    my @bloecke = sort keys %je;
    my $anzahl  = scalar @bloecke;
    my $start   = ($anzahl && defined $opt{start}) ? ($opt{start} % $anzahl) : 0;
    my (@werte, $fehlt, $consec);
    my $vollstaendig = 1;
    $fehlt  = 0;
    $consec = 0;
    my $gelaufen = 0;
    for my $i (0 .. $anzahl - 1) {
        my $b = $bloecke[ ($start + $i) % $anzahl ];
        if (defined $deadline && time() > $deadline) { $vollstaendig = 0; last; }
        $gelaufen++;
        my ($ok, $body) = $abruf->($b);
        my $aus = $ok ? parse_all($body) : undef;
        if (!$aus) {
            $fehlt += scalar @{ $je{$b} };
            if (++$consec >= AUSFALL_MAX) { $vollstaendig = 0; last; }
            next;
        }
        $consec = 0;
        my %wert = map { $_->[0] => [ $_->[1], $_->[2] ] } @$aus;
        for my $o (@{ $je{$b} }) {
            if (exists $wert{$o}) {
                my $w = { b => $b, o => $o, v => $wert{$o}[0] };
                $w->{e} = $wert{$o}[1] if defined $wert{$o}[1] && $wert{$o}[1] ne '';
                push @werte, $w;
            }
            else { $fehlt++; }
        }
    }
    my $naechster = $anzahl ? (($start + $gelaufen) % $anzahl) : 0;
    return (\@werte, $fehlt, $vollstaendig, $naechster);
}

sub due {
    my ($state, $now) = @_;
    my $next = $state->{chart_next};
    return 1 if !defined $next;
    return 1 if $next > $now + INTERVALL * 5;
    return $next <= $now ? 1 : 0;
}

sub naechster {
    my ($now, $ok) = @_;
    return $now + ($ok ? INTERVALL : 60);
}

sub _auswahldatei { my ($dir) = @_; return File::Spec->catfile($dir, 'chart_auswahl.json'); }

sub auswahl_laden {
    my ($dir) = @_;
    my $f = _auswahldatei($dir);
    return [] if !-f $f;
    open my $fh, '<:raw', $f or return [];
    local $/;
    my $j = <$fh>;
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($j) };
    return ref($d) eq 'ARRAY' ? $d : [];
}

sub auswahl_speichern {
    my ($dir, $liste) = @_;
    return 0 if ref($liste) ne 'ARRAY';
    my @sauber;
    for my $e (@$liste) {
        next if ref($e) ne 'HASH' || !defined $e->{msno} || $e->{msno} !~ /\A[0-9]+\z/
             || !defined $e->{b} || $e->{b} !~ /\A[0-9A-Za-z-]{1,64}\z/
             || !defined $e->{o} || $e->{o} !~ /\A[\p{L}\p{M}\p{N}\p{S}_]{1,32}\z/;
        push @sauber, { msno => $e->{msno} + 0, b => $e->{b}, o => $e->{o} };
    }
    my $json = JSON::PP->new->canonical->utf8->encode(\@sauber);
    my $f = _auswahldatei($dir);
    if (-f $f && open(my $in, '<:raw', $f)) {
        local $/;
        my $alt = <$in>;
        close $in;
        return 1 if defined $alt && $alt eq $json;
    }
    my ($fh, $tmp) = tempfile('chart_auswahl.XXXXXX', DIR => $dir, UNLINK => 0);
    binmode $fh, ':raw';
    print {$fh} $json;
    close $fh or return 0;
    chmod 0600, $tmp;
    return move($tmp, $f) ? 1 : 0;
}

sub _anforderungsdatei { my ($rt) = @_; return File::Spec->catfile($rt, 'chart_anforderungen.json'); }

sub anforderungen_laden {
    my ($rt) = @_;
    my $f = _anforderungsdatei($rt);
    return [] if !-f $f;
    open my $fh, '<:raw', $f or return [];
    local $/;
    my $j = <$fh>;
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($j) };
    return ref($d) eq 'ARRAY' ? $d : [];
}

sub anforderungen_speichern {
    my ($rt, $liste) = @_;
    return 0 if ref($liste) ne 'ARRAY';
    my @sauber;
    for my $e (@$liste) {
        next if ref($e) ne 'HASH' || !defined $e->{msno} || $e->{msno} !~ /\A[0-9]+\z/
             || !defined $e->{b} || $e->{b} !~ /\A[0-9A-Za-z-]{1,64}\z/
             || !defined $e->{o} || $e->{o} !~ /\A[\p{L}\p{M}\p{N}\p{S}_]{1,32}\z/;
        push @sauber, { msno => $e->{msno} + 0, b => $e->{b}, o => $e->{o} };
    }
    my $json = JSON::PP->new->canonical->utf8->encode(\@sauber);
    my $f = _anforderungsdatei($rt);
    if (-f $f && open(my $in, '<:raw', $f)) {
        local $/;
        my $alt = <$in>;
        close $in;
        return 1 if defined $alt && $alt eq $json;
    }
    my ($fh, $tmp) = tempfile('chart_anf.XXXXXX', DIR => $rt, UNLINK => 0);
    binmode $fh, ':raw';
    print {$fh} $json;
    if (!close $fh) { unlink $tmp; return 0; }
    if (!move($tmp, $f)) { unlink $tmp; return 0; }
    return 1;
}

sub anforderungen_lesen {
    my ($liste, $abruf, %opt) = @_;
    my $deadline = $opt{deadline};
    my %je;
    push @{ $je{ $_->{b} } }, $_ for @$liste;
    my (@cr, @rest);
    for my $b (sort keys %je) {
        if ($b !~ /\A[0-9A-Za-z-]{1,64}\z/) {
            push @cr, { b => $b, o => $_->{o}, v => undef } for @{ $je{$b} };
            next;
        }
        if (defined $deadline && time() > $deadline) {
            push @rest, @{ $je{$b} };
            next;
        }
        my ($ok, $body) = $abruf->($b);
        my $aus = $ok ? parse_all($body) : undef;
        my %wert = $aus ? (map { $_->[0] => [ $_->[1], $_->[2] ] } @$aus) : ();
        for my $e (@{ $je{$b} }) {
            my $c = { b => $b, o => $e->{o}, v => undef };
            if (exists $wert{ $e->{o} }) {
                $c->{v} = $wert{ $e->{o} }[0];
                $c->{e} = $wert{ $e->{o} }[1] if defined $wert{ $e->{o} }[1] && $wert{ $e->{o} }[1] ne '';
            }
            push @cr, $c;
        }
    }
    return (\@cr, \@rest);
}

sub gruppen_der_auswahl {
    my ($liste) = @_;
    my %g;
    push @{ $g{ $_->{msno} } }, { b => $_->{b}, o => $_->{o} } for grep { ref($_) eq 'HASH' } @$liste;
    return \%g;
}

1;

