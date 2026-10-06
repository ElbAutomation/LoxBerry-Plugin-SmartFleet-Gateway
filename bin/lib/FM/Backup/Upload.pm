# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Upload;

use strict;
use warnings;
use File::Spec;
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use FM::Sig;
use FM::Http;
use FM::Backup::Keep;

use constant CHUNK => 1048576;

sub chunk_count {
    my ($size) = @_;
    return 0 if !$size || $size < 1;
    return int(($size + CHUNK() - 1) / CHUNK());
}

sub read_chunk {
    my ($datei, $n) = @_;
    my $sz = -s $datei;
    return undef if !$sz;
    my $off = $n * CHUNK();
    return undef if $off >= $sz;

    open my $fh, '<:raw', $datei or return undef;
    seek $fh, $off, 0;
    my $buf = '';
    read $fh, $buf, CHUNK();
    close $fh;
    return $buf;
}

sub _meta {
    my ($gen_dir) = @_;
    my $f = File::Spec->catfile($gen_dir, 'meta.json');
    return undef if !-f $f;
    return eval {
        open my $fh, '<', $f or die;
        local $/;
        JSON::PP->new->decode(scalar <$fh>);
    };
}

sub _write_meta {
    my ($gen_dir, $meta) = @_;
    my $f = File::Spec->catfile($gen_dir, 'meta.json');
    open my $fh, '>', $f or return 0;
    print {$fh} JSON::PP->new->canonical->encode($meta);
    close $fh;
    return 1;
}

sub pending {
    my ($store, $msno) = @_;
    my $gens = FM::Backup::Keep::generations($store, $msno);
    for my $g (reverse @$gens) {
        my $m = _meta($g->{dir});
        next if !$m;
        next if $m->{uploaded};
        return { dir => $g->{dir}, meta => $m };
    }
    return undef;
}

sub _post {
    my ($cfg, $keyfile, $pfad, $daten, $roh) = @_;
    $roh ||= sub { };
    my $body = JSON::PP->new->canonical->encode($daten);
    my $sig_path = ($cfg->{path_prefix} || '') . $pfad;
    my $headers  = FM::Sig::headers($keyfile, $cfg->{site}, 'POST', $sig_path, $body);

    my $vorschau = $daten;
    if ($pfad =~ m{/chunk\.php\z} && ref($daten) eq 'HASH' && exists $daten->{data}) {
        $vorschau = { %$daten, data => '<' . length($daten->{data}) . ' Byte Base64, nicht protokolliert>' };
    }
    $roh->('-> POST ' . $cfg->{server} . $pfad . "\n"
         . JSON::PP->new->canonical->encode($vorschau));

    my ($st, $resp) = FM::Http::post_json("$cfg->{server}$pfad", $body, $headers);
    $roh->("<- $st" . (defined $resp && $resp ne '' ? "\n$resp" : ''));

    my $ans = eval { JSON::PP->new->decode($resp) };
    return ($st, ref($ans) eq 'HASH' ? $ans : {});
}

sub send_one {
    my ($cfg, $keyfile, $store, $msno, $sagen, $roh) = @_;
    $sagen ||= sub { };
    $roh   ||= sub { };

    my $offen = pending($store, $msno);
    return ('idle', 'nichts offen') if !$offen;

    my $meta = $offen->{meta};
    my $zip = FM::Backup::Keep::archiv_datei($offen->{dir});
    return ('error', 'kein Archiv in der Generation gefunden') if !defined $zip;

    my $initDaten = {
        msno => $meta->{msno}, ts => $meta->{ts},
        scope => _scope_string($meta->{scope}),
        fingerprint => $meta->{fingerprint},
        sha256 => $meta->{sha256},
        size => $meta->{size}, files => $meta->{files},
    };
    $initDaten->{loxname} = $meta->{loxname} if defined $meta->{loxname} && $meta->{loxname} ne '';

    my ($st, $ans) = _post($cfg, $keyfile, '/api/backup/init.php', $initDaten, $roh);

    if ($st != 200) {
        return ('error', "init: HTTP $st");
    }

    if ($ans->{known}) {
        $meta->{uploaded} = 1;
        _write_meta($offen->{dir}, $meta);
        $sagen->('Backup war dem Server schon bekannt');
        return ('done', 'schon bekannt');
    }

    my $n = defined $ans->{next} ? $ans->{next} + 0 : 0;
    my $gesamt = chunk_count($meta->{size});

    if ($n >= $gesamt) {
        my ($cs, $ca) = _post($cfg, $keyfile, '/api/backup/complete.php',
                              { upload => $ans->{upload} }, $roh);
        if ($cs == 200) {
            $meta->{uploaded} = 1;
            _write_meta($offen->{dir}, $meta);
            return ('done', 'vollstaendig');
        }
        return ('error', "complete: HTTP $cs");
    }

    my $stueck = read_chunk($zip, $n);
    return ('error', "Stueck $n nicht lesbar") if !defined $stueck;

    my $srv_chunk = defined $ans->{chunk} && $ans->{chunk} =~ /\A[0-9]+\z/
                  ? $ans->{chunk} + 0 : undef;
    if (defined $srv_chunk && $srv_chunk > 0 && $srv_chunk < length($stueck)) {
        $stueck = substr($stueck, 0, $srv_chunk);
    }

    my ($ps, $pa) = _post($cfg, $keyfile, '/api/backup/chunk.php', {
        upload => $ans->{upload}, n => $n,
        data => encode_base64($stueck, ''),
    }, $roh);

    if ($ps == 409 && defined $pa->{next}) {
        $sagen->("Stueck $n war schon da - der Server steht bei $pa->{next}");
        return ('partial', 'nachgezogen');
    }
    return ('error', "chunk $n: HTTP $ps") if $ps != 200;

    $sagen->(sprintf('Backup Miniserver %d: Stueck %d von %d',
                     $meta->{msno}, $n + 1, $gesamt));
    return ('partial', 'ein Stueck');
}

sub send_all {
    my ($cfg, $keyfile, $store, $msno, $sagen, $roh) = @_;
    my ($lage, $meldung) = ('idle', 'nichts offen');
    my $stuecke = 0;
    while (1) {
        ($lage, $meldung) = send_one($cfg, $keyfile, $store, $msno, $sagen, $roh);
        last if $lage ne 'partial';
        $stuecke++;
    }
    return ($lage, $meldung, $stuecke);
}

sub _scope_string {
    my ($scope) = @_;
    return 'system' if ref($scope) ne 'HASH';
    my @t = ('system');
    push @t, 'stats' if $scope->{stats};
    push @t, 'logs'  if $scope->{logs};
    return join '+', @t;
}

sub msnos {
    my ($store) = @_;
    return [] if !defined $store || !-d $store;
    opendir my $dh, $store or return [];
    my @n = map { /\Ams([0-9]+)\z/ ? $1 + 0 : () } readdir $dh;
    closedir $dh;
    my @s = sort { $a <=> $b } @n;
    return \@s;
}

1;

