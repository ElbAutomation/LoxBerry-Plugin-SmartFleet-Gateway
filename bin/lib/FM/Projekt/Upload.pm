# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Projekt::Upload;

use strict;
use warnings;
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use FM::Sig;
use FM::Http;
use FM::Backup::Upload;

sub _post {
    my ($cfg, $keyfile, $pfad, $daten, $roh) = @_;
    $roh ||= sub { };
    my $body = JSON::PP->new->canonical->utf8->encode($daten);
    my $sig_path = ($cfg->{path_prefix} || '') . $pfad;
    my $headers  = FM::Sig::headers($keyfile, $cfg->{site}, 'POST', $sig_path, $body);

    my $vorschau = $daten;
    if ($pfad =~ m{/chunk\.php\z} && ref($daten) eq 'HASH' && exists $daten->{data}) {
        $vorschau = { %$vorschau, data => '<' . length($daten->{data}) . ' Byte Base64, nicht protokolliert>' };
    }
    if (ref($daten) eq 'HASH' && exists $daten->{loxapp3}) {
        $vorschau = { %$vorschau, loxapp3 => '<' . length($daten->{loxapp3}) . ' Byte Base64, nicht protokolliert>' };
    }
    $roh->('-> POST ' . $cfg->{server} . $pfad . "\n" . JSON::PP->new->canonical->encode($vorschau));

    my ($st, $resp) = FM::Http::post_json("$cfg->{server}$pfad", $body, $headers);
    $roh->("<- $st" . (defined $resp && $resp ne '' ? "\n$resp" : ''));

    my $ans = eval { JSON::PP->new->decode($resp) };
    return ($st, ref($ans) eq 'HASH' ? $ans : {});
}

sub hochladen {
    my ($cfg, $keyfile, $msno, $quelle_ts, $groesse, $sha256, $dateipfad, $metadaten, $loxapp3, $sagen, $roh) = @_;
    $sagen ||= sub { };
    $roh   ||= sub { };
    $metadaten = {} if ref($metadaten) ne 'HASH';

    my $initDaten = { msno => $msno, quelle_ts => $quelle_ts, sha256 => $sha256, size => $groesse };
    for my $feld (qw(config_version creator cust config_ts)) {
        $initDaten->{$feld} = $metadaten->{$feld}
            if defined $metadaten->{$feld} && $metadaten->{$feld} ne '';
    }
    if (defined $loxapp3 && $loxapp3 ne '') {
        $initDaten->{loxapp3} = encode_base64($loxapp3, '');
    }

    my ($st, $ans) = _post($cfg, $keyfile, '/api/projekt/init.php', $initDaten, $roh);
    return ('error', "init: HTTP $st") if $st != 200;
    return ('done', 'schon bekannt') if $ans->{known};

    if (!defined $dateipfad) {
        return ('retry', 'Server kennt die zwischengespeicherte Version nicht mehr - eine echte Datei wird gebraucht');
    }

    my $n      = defined $ans->{next} ? $ans->{next} + 0 : 0;
    my $gesamt = FM::Backup::Upload::chunk_count($groesse);

    while ($n < $gesamt) {
        my $stueck = FM::Backup::Upload::read_chunk($dateipfad, $n);
        return ('error', "Stueck $n nicht lesbar") if !defined $stueck;

        my $srv_chunk = defined $ans->{chunk} && $ans->{chunk} =~ /\A[0-9]+\z/
                      ? $ans->{chunk} + 0 : undef;
        if (defined $srv_chunk && $srv_chunk > 0 && $srv_chunk < length($stueck)) {
            $stueck = substr($stueck, 0, $srv_chunk);
        }

        my ($ps, $pa) = _post($cfg, $keyfile, '/api/projekt/chunk.php', {
            upload => $ans->{upload}, n => $n, data => encode_base64($stueck, ''),
        }, $roh);

        if ($ps == 409 && defined $pa->{next}) {
            $sagen->("Stueck $n war schon da - der Server steht bei $pa->{next}");
            $n = $pa->{next} + 0;
            next;
        }
        return ('error', "chunk $n: HTTP $ps") if $ps != 200;

        $sagen->(sprintf('Miniserver %d: Stueck %d von %d', $msno, $n + 1, $gesamt));
        $n++;
    }

    my ($cs, undef) = _post($cfg, $keyfile, '/api/projekt/complete.php', { upload => $ans->{upload} }, $roh);
    return ('error', "complete: HTTP $cs") if $cs != 200;
    return ('done', 'vollstaendig');
}

1;

