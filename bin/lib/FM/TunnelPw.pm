# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::TunnelPw;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp;

use constant SCHWELLE_BIT => 45;

my @WORTLISTE;

sub _moduldir {
    return dirname(__FILE__);
}

sub _wortliste {
    return @WORTLISTE if @WORTLISTE;
    my $datei = File::Spec->catfile(_moduldir(), 'wortliste.txt');
    open my $fh, '<:raw', $datei
        or die "FM::TunnelPw: Wortliste nicht lesbar: $datei ($!)\n";
    while (my $zeile = <$fh>) {
        $zeile =~ s/[\r\n]+\z//;
        push @WORTLISTE, $zeile if length $zeile;
    }
    close $fh;
    die "FM::TunnelPw: Wortliste ist leer\n" if !@WORTLISTE;
    return @WORTLISTE;
}

sub _zufallsindex {
    my ($n) = @_;
    die "FM::TunnelPw: n muss eine Zweierpotenz > 0 sein\n"
        if $n <= 0 || ($n & ($n - 1)) != 0;
    my $bytes;
    if (open my $fh, '<:raw', '/dev/urandom') {
        read $fh, $bytes, 2;
        close $fh;
    }
    if (!defined $bytes || length($bytes) != 2) {
        die "FM::TunnelPw: /dev/urandom nicht lesbar - kein sicheres Passwort erzeugbar\n"
            if $^O !~ /MSWin32|msys|cygwin/;
        $bytes = pack('n', int(rand(65536)));
    }
    my $val = unpack('n', $bytes);
    return $val % $n;
}

sub erzeugen {
    my @liste = _wortliste();
    my $n = scalar @liste;
    my @gewaehlt = map { $liste[_zufallsindex($n)] } (1 .. 6);
    return join('-', @gewaehlt);
}

sub pruefen {
    my ($pw) = @_;
    $pw = '' if !defined $pw;

    my $r = eval {
        require Data::Password::zxcvbn;
        Data::Password::zxcvbn::password_strength($pw);
    };
    if (!defined $r || ref($r) ne 'HASH' || !defined $r->{guesses_log10}) {
        return {
            ok      => 0,
            bits    => undef,
            meldung => 'Passwortpruefung nicht verfuegbar (Data::Password::zxcvbn fehlt) - Passwort abgelehnt',
        };
    }

    my $bits = $r->{guesses_log10} * (log(10) / log(2));
    my $ok = ($bits >= SCHWELLE_BIT) ? 1 : 0;
    return {
        ok      => $ok,
        bits    => $bits,
        meldung => $ok
            ? sprintf('Passwort angenommen (%.1f Bit)', $bits)
            : sprintf('Passwort zu schwach (%.1f von %d Bit noetig)', $bits, SCHWELLE_BIT),
    };
}

sub _slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "FM::TunnelPw: $path nicht lesbar: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub ableiten {
    my ($pw, $site_id) = @_;
    die "FM::TunnelPw: Passwort fehlt\n" if !defined $pw || $pw eq '';
    die "FM::TunnelPw: SiteId fehlt\n" if !defined $site_id || $site_id eq '';

    my $otmp = File::Temp->new();
    my $ofile = $otmp->filename;
    close $otmp;

    my $ok = system(
        'openssl', 'kdf', '-keylen', '32',
        '-kdfopt', "digest:SHA256",
        '-kdfopt', "pass:$pw",
        '-kdfopt', "salt:$site_id",
        '-kdfopt', 'iter:600000',
        '-binary', '-out', $ofile,
        'PBKDF2',
    ) == 0;
    die "FM::TunnelPw: openssl kdf fehlgeschlagen\n" if !$ok;

    my $raw = _slurp_raw($ofile);
    die "FM::TunnelPw: K hat " . length($raw) . " statt 32 Byte\n" if length($raw) != 32;
    return unpack('H*', $raw);
}

sub speichern {
    my ($dir, $K) = @_;
    die "FM::TunnelPw: Verzeichnis fehlt\n" if !defined $dir || $dir eq '';
    die "FM::TunnelPw: K muss 64-stelliges Hex sein\n" if !defined $K || $K !~ /^[0-9a-fA-F]{64}\z/;

    my $datei = File::Spec->catfile($dir, 'tunnel.key');

    my $altumask = umask(0077);
    my $ok = eval {
        open my $fh, '>', $datei or die "FM::TunnelPw: $datei nicht schreibbar: $!\n";
        print {$fh} $K;
        close $fh or die "FM::TunnelPw: $datei nicht geschlossen: $!\n";
        1;
    };
    my $fehler = $@;
    umask($altumask);
    die $fehler if !$ok;

    chmod(0600, $datei) == 1
        or die "FM::TunnelPw: Rechte 0600 an $datei konnten nicht gesetzt werden\n";
    return 1;
}

sub laden {
    my ($dir) = @_;
    die "FM::TunnelPw: Verzeichnis fehlt\n" if !defined $dir || $dir eq '';
    my $datei = File::Spec->catfile($dir, 'tunnel.key');
    return undef if !-e $datei;
    open my $fh, '<', $datei or die "FM::TunnelPw: $datei nicht lesbar: $!\n";
    my $K = <$fh>;
    close $fh;
    return undef if !defined $K;
    $K =~ s/[\r\n]+\z//;
    return undef if $K !~ /^[0-9a-fA-F]{64}\z/;
    return $K;
}

1;

