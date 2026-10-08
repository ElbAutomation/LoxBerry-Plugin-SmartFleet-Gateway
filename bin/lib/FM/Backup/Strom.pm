# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Strom;
use strict;
use warnings;
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha256_hex);
use FM::Sig;
use FM::Http;
use FM::Backup::Pack;
use FM::Backup::Strom7z;

use constant CHUNK    => 1048576;
use constant LESEN    => 65536;

sub list_fp {
    my ($dateien) = @_;
    my @z = map { join("\0", $_->{path}, $_->{size} + 0, $_->{datum} // '') . "\n" } @$dateien;
    return sha256_hex(join '', sort @z);
}

sub size_max {
    my ($summe) = @_;
    return $summe + int($summe / 1000) + 65536;
}

sub scope_string {
    my ($scope) = @_;
    return 'system' if ref($scope) ne 'HASH';
    my @t = ('system');
    push @t, 'stats' if $scope->{stats};
    push @t, 'logs'  if $scope->{logs};
    return join '+', @t;
}

sub _post {
    my ($cfg, $keyfile, $pfad, $daten, $roh) = @_;
    my $body = JSON::PP->new->canonical->encode($daten);
    my $sig_path = ($cfg->{path_prefix} || '') . $pfad;
    my $headers  = FM::Sig::headers($keyfile, $cfg->{site}, 'POST', $sig_path, $body);
    my $vorschau = exists $daten->{data}
        ? { %$daten, data => '<' . length($daten->{data}) . ' Byte Base64, nicht protokolliert>' } : $daten;
    $roh->('-> POST ' . $cfg->{server} . $pfad . "\n" . JSON::PP->new->canonical->encode($vorschau));
    my ($st, $resp) = FM::Http::post_json("$cfg->{server}$pfad", $body, $headers);
    $roh->("<- $st" . (defined $resp && $resp ne '' ? "\n$resp" : ''));
    my $ans = eval { JSON::PP->new->decode($resp) };
    return ($st, ref($ans) eq 'HASH' ? $ans : {});
}

sub senden {
    my (%a) = @_;
    my $sagen = $a{sagen} || sub { };
    my $roh   = $a{roh}   || sub { };
    my $pause = $a{pause} || sub { sleep $_[0] };
    my $post  = $a{post}  || sub { _post($a{cfg}, $a{keyfile}, $_[0], $_[1], $roh) };
    my @d = @{ $a{dateien} || [] };
    my $fehler = sub { return { lage => 'error', meldung => $_[0], files => 0, fehlend => [], stuecke => $_[1] || 0 } };

    return $fehler->('keine Dateien') if !@d;
    return $fehler->('kein Passwort - Verschluesselung nicht moeglich')
        if !defined $a{passwort} || $a{passwort} eq '';
    my $summe = 0;
    $summe += $_->{size} for @d;
    my $max = size_max($summe);

    my $mit_wdh = sub {
        my ($pfad, $daten) = @_;
        my ($st, $ans);
        for my $v (0 .. 3) {
            $pause->(2 << $v) if $v;
            ($st, $ans) = $post->($pfad, $daten);
            last if $st && ($st < 500 || $st == 507);
        }
        return ($st || 0, $ans || {});
    };

    my $init = { stream => 1, msno => $a{msno} + 0, ts => $a{ts} + 0, scope => $a{scope} // 'system',
                 list_fp => list_fp([ map { { path => '/' . $_->{name}, size => $_->{size}, datum => $_->{datum} } }
                                     grep { !$_->{ohne_fp} } @d ]),
                 size_max => $max };
    $init->{loxname} = $a{loxname} if defined $a{loxname} && $a{loxname} ne '';
    my ($st, $ans) = $mit_wdh->('/api/backup/init.php', $init);
    if ($st == 409 && ($ans->{error} // '') eq 'ms_konflikt') {
        return { lage => 'abgelehnt', meldung => 'der Miniserver wird von einem anderen Gateway uebertragen',
                 files => 0, fehlend => [], stuecke => 0 };
    }
    if ($st == 507) {
        return { lage => 'voll', meldung => 'Speicherplatz des Standorts erschoepft', files => 0, fehlend => [], stuecke => 0 };
    }
    return $fehler->("init: HTTP $st" . (defined $ans->{message} ? " - $ans->{message}" : '')) if $st != 200;
    if ($ans->{known}) {
        return { lage => 'known', meldung => 'Liste bekannt', files => 0, fehlend => [], stuecke => 0 };
    }
    my $upload = $ans->{upload} // '';
    my $chunk  = (defined $ans->{chunk} && $ans->{chunk} =~ /\A[0-9]+\z/ && $ans->{chunk} > 0) ? $ans->{chunk} + 0 : CHUNK;

    my ($puf, $nr, $gesamt, $grund, $voll) = ('', 0, 0, undef, 0);
    my $tail = Digest::SHA->new(256);
    my $stueck_senden = sub {
        return if $puf eq '';
        my ($cs, $ca) = $mit_wdh->('/api/backup/chunk.php',
                                   { upload => $upload, n => $nr, data => encode_base64($puf, '') });
        if ($cs == 507) {
            $voll  = 1;
            $grund = "Speicherplatz des Standorts erschoepft (nach $nr Stueck(en))";
            die "$grund\n";
        }
        if (!($cs == 200 || ($cs == 409 && defined $ca->{next} && $ca->{next} == $nr + 1))) {
            $grund = "Uebertragung fehlgeschlagen (Stueck $nr, HTTP $cs)";
            die "$grund\n";
        }
        $nr++;
        $puf = '';
        $sagen->("Stueck $nr hochgeladen");
    };
    my $aus = sub {
        my ($p) = @_;
        my $ab = $gesamt >= 32 ? 0 : 32 - $gesamt;
        $tail->add(substr($p, $ab)) if $ab < length $p;
        $gesamt += length $p;
        $puf .= $p;
        while (length($puf) >= $chunk) {
            my $rest = substr($puf, $chunk);
            $puf = substr($puf, 0, $chunk);
            $stueck_senden->();
            $puf = $rest;
        }
    };

    my (@erfasst, @fehlend, $offen);
    my $ergebnis = eval {
        my $z = FM::Backup::Strom7z->new(FM::Backup::Strom7z::schluessel($a{passwort}), $aus);
        for my $e (@d) {
            my $q = $e->{holen}->();
            if (!defined $q) {
                push @fehlend, '/' . $e->{name};
                $sagen->("/$e->{name} nicht holbar");
                next;
            }
            $z->datei($e->{name}, $e->{modus});
            if (ref $q) {
                $z->daten($$q);
            } else {
                $offen = $q if $e->{weg};
                open my $fh, '<:raw', $q or die "$q nicht lesbar: $!\n";
                my $b;
                while (read($fh, $b, LESEN)) { $z->daten($b); }
                close $fh;
                unlink $q if $e->{weg};
                $offen = undef;
            }
            my ($sha, $g) = $z->datei_ende;
            push @erfasst, { path => $e->{fp_pfad} // '/' . $e->{name}, size => $g, sha256 => $sha } if !$e->{ohne_fp};
        }
        die "keine einzige Datei holbar\n" if !@erfasst;
        my ($kopf, $groesse) = $z->ende;
        $stueck_senden->();
        my ($cs, $ca) = $mit_wdh->('/api/backup/complete.php', {
            upload => $upload, head => encode_base64($kopf, ''), size => $groesse,
            sha256_tail => $tail->hexdigest, fingerprint => FM::Backup::Pack::fingerprint(\@erfasst, 1),
            files => scalar(@erfasst), vollstaendig => (@fehlend ? 0 : 1),
        });
        die "Abschluss abgelehnt (HTTP $cs)\n" if $cs != 200;
        +{ lage => ($ca->{known} ? 'known' : 'done'), meldung => ($ca->{known} ? 'Inhalt bekannt' : 'hochgeladen'),
          files => scalar(@erfasst), fehlend => \@fehlend, size => $groesse, stuecke => $nr };
    };
    if (!$ergebnis) {
        unlink $offen if defined $offen;
        my $m = $grund // $@ // 'unbekannter Fehler';
        $m =~ s/\s+\z//;
        my $r = $fehler->($m, $nr);
        $r->{lage} = 'voll' if $voll;
        $r->{fehlend} = \@fehlend;
        return $r;
    }
    return $ergebnis;
}

1;

