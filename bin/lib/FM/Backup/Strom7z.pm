# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Strom7z;
use strict;
use warnings;
use Digest::SHA ();
use Compress::Raw::Zlib ();
use Encode ();

use constant PUFFER => 65536;
use constant RUNDEN => 1 << 19;
use constant WOERTERBUCH => 8 << 20;
use constant WB_PROP     => 22;

sub verfuegbar {
    return eval { require Crypt::Mode::CBC; require Compress::Raw::Lzma; 1 } ? 1 : 0;
}

sub _zufall {
    my ($n) = @_;
    if (open my $fh, '<:raw', '/dev/urandom') {
        my $b = '';
        read($fh, $b, $n);
        close $fh;
        return $b if length($b) == $n;
    }
    die "FM::Backup::Strom7z: kein Zufall verfuegbar\n";
}

sub schluessel {
    my ($pw) = @_;
    return undef if !defined $pw || $pw eq '';
    my $t = utf8::is_utf8($pw) ? $pw : Encode::decode('UTF-8', $pw, sub { chr $_[0] });
    my $b = Encode::encode('UTF-16LE', $t);
    my $sha = Digest::SHA->new(256);
    $sha->add($b . pack('VV', $_, 0)) for 0 .. RUNDEN - 1;
    return $sha->digest;
}

sub _zahl {
    my ($v) = @_;
    my ($first, $mask, $i) = (0, 0x80, 0);
    for ($i = 0; $i < 8; $i++) {
        if ($v < 2 ** (7 * ($i + 1))) {
            $first |= int($v / 2 ** (8 * $i)) & 0xFF;
            last;
        }
        $first |= $mask;
        $mask >>= 1;
    }
    my $s = chr($first);
    $s .= chr(int($v / 2 ** (8 * $_)) & 0xFF) for 0 .. $i - 1;
    return $s;
}

sub _u64 { my ($v) = @_; return pack('VV', $v % 4294967296, int($v / 4294967296)); }

sub new {
    my ($class, $key, $aus) = @_;
    die "FM::Backup::Strom7z: Schluessel muss 32 Byte haben\n" if length($key // '') != 32;
    require Crypt::Mode::CBC;
    require Compress::Raw::Lzma;
    my $z = bless { key => $key, aus => $aus, d => [], offen => 0, strom => 0 }, $class;
    $aus->("\0" x 32);
    return $z;
}

sub _an_aes {
    my ($z, $p) = @_;
    return if $p eq '';
    $z->{gepackt} += length $p;
    $z->{puf} .= $p;
    if (length($z->{puf}) >= PUFFER) {
        my $n = length($z->{puf}) - length($z->{puf}) % 16;
        my $c = $z->{cbc}->add(substr($z->{puf}, 0, $n, ''));
        $z->{chiffre} += length $c;
        $z->{aus}->($c);
    }
}

sub _strom_beginn {
    my ($z) = @_;
    $z->{iv0} = _zufall(16);
    $z->{cbc} = Crypt::Mode::CBC->new('AES', 0);
    $z->{cbc}->start_encrypt($z->{key}, $z->{iv0});
    ($z->{roh}, $z->{gepackt}, $z->{chiffre}, $z->{puf}) = (0, 0, 0, '');
    my ($lz, $st) = Compress::Raw::Lzma::RawEncoder->new(
        Filter => [ Lzma::Filter::Lzma2(DictSize => WOERTERBUCH) ], AppendOutput => 0);
    die "FM::Backup::Strom7z: LZMA2 nicht startbar ($st)\n" if !$lz;
    $z->{lz} = $lz;
    $z->{strom} = 1;
}

sub _strom_daten {
    my ($z, $p) = @_;
    $z->{roh} += length $p;
    my $out;
    my $st = $z->{lz}->code($p, $out);
    die "FM::Backup::Strom7z: LZMA2 ($st)\n" if $st != Compress::Raw::Lzma::LZMA_OK();
    $z->_an_aes($out) if defined $out;
}

sub _strom_ende {
    my ($z) = @_;
    my $out;
    my $st = $z->{lz}->flush($out);
    die "FM::Backup::Strom7z: LZMA2 ($st)\n" if $st != Compress::Raw::Lzma::LZMA_STREAM_END();
    $z->_an_aes($out) if defined $out;
    my $rest = length($z->{puf}) % 16;
    $z->{puf} .= "\0" x (16 - $rest) if $rest;
    if ($z->{puf} ne '') {
        my $c = $z->{cbc}->add($z->{puf});
        $z->{puf} = '';
        $z->{chiffre} += length $c;
        $z->{aus}->($c);
    }
    $z->{cbc}->finish;
    delete $z->{lz};
    $z->{strom} = 0;
}

sub _ordner {
    my ($iv) = @_;
    return _zahl(2)
         . "\x21\x21\x01" . chr(WB_PROP)
         . "\x24\x06\xF1\x07\x01" . _zahl(18)
         . "\x53\x0F" . $iv          # 2^19 Runden, IV vorhanden, kein Salt
         . _zahl(0) . _zahl(1);
}

sub _strom_info {
    my ($packpos, $packsize, $iv, $roh, $gepackt, $crc) = @_;
    return "\x06" . _zahl($packpos) . _zahl(1) . "\x09" . _zahl($packsize) . "\x00"
         . "\x07\x0B" . _zahl(1) . "\x00" . _ordner($iv)
         . "\x0C" . _zahl($roh) . _zahl($gepackt)
         . (defined $crc ? "\x0A\x01" . pack('V', $crc) : '')
         . "\x00";
}

sub datei {
    my ($z, $name, $modus) = @_;
    die "FM::Backup::Strom7z: Datei noch offen\n" if $z->{offen};
    my $t = utf8::is_utf8($name) ? $name : Encode::decode('UTF-8', $name, sub { chr $_[0] });
    die "FM::Backup::Strom7z: leerer Name\n" if $t eq '';
    my $attr = defined $modus ? (0x20 | 0x8000 | ((0100000 | ($modus & 07777)) << 16)) : undef;
    push @{ $z->{d} }, { name16 => Encode::encode('UTF-16LE', $t) . "\0\0", groesse => 0, crc => 0, attr => $attr };
    $z->{offen} = 1;
    $z->{dgr} = 0;
    $z->{crc} = 0;
    $z->{sha} = Digest::SHA->new(256);
}

sub daten {
    my ($z, $p) = @_;
    die "FM::Backup::Strom7z: keine Datei offen\n" if !$z->{offen};
    return if !defined $p || $p eq '';
    $z->_strom_beginn if !$z->{strom};
    $z->{crc} = Compress::Raw::Zlib::crc32($p, $z->{crc});
    $z->{sha}->add($p);
    $z->{dgr} += length $p;
    $z->_strom_daten($p);
}

sub datei_ende {
    my ($z) = @_;
    die "FM::Backup::Strom7z: keine Datei offen\n" if !$z->{offen};
    my $e = $z->{d}[-1];
    $e->{groesse} = $z->{dgr};
    $e->{crc} = $z->{crc};
    $z->{offen} = 0;
    return ($z->{sha}->hexdigest, $z->{dgr});
}

sub datei_weg {
    my ($z) = @_;
    return 0 if !$z->{offen} || $z->{dgr};
    pop @{ $z->{d} };
    $z->{offen} = 0;
    return 1;
}

sub _bits {
    my (@b) = @_;
    my ($s, $c, $mask) = ('', 0, 0x80);
    for my $x (@b) {
        $c |= $mask if $x;
        $mask >>= 1;
        if (!$mask) { $s .= chr $c; ($c, $mask) = (0, 0x80); }
    }
    $s .= chr $c if $mask != 0x80;
    return $s;
}

sub ende {
    my ($z) = @_;
    die "FM::Backup::Strom7z: Datei noch offen\n" if $z->{offen};
    die "FM::Backup::Strom7z: keine Daten\n" if !$z->{strom};
    $z->_strom_ende;
    my ($h_roh, $h_gep, $h_pack, $h_iv) = @$z{qw(roh gepackt chiffre iv0)};
    my @d = @{ $z->{d} };
    my @voll = grep { $_->{groesse} } @d;
    my $leer = @d - @voll;

    my $h = "\x01\x04" . _strom_info(0, $h_pack, $h_iv, $h_roh, $h_gep, undef);
    $h .= "\x08\x0D" . _zahl(scalar @voll);
    if (@voll > 1) {
        $h .= "\x09";
        $h .= _zahl($voll[$_]{groesse}) for 0 .. $#voll - 1;
    }
    $h .= "\x0A\x01" . join('', map { pack('V', $_->{crc}) } @voll);
    $h .= "\x00\x00";
    $h .= "\x05" . _zahl(scalar @d);
    if ($leer) {
        my $v = _bits(map { $_->{groesse} ? 0 : 1 } @d);
        my $f = _bits((1) x $leer);
        $h .= "\x0E" . _zahl(length $v) . $v . "\x0F" . _zahl(length $f) . $f;
    }
    my $namen = join('', map { $_->{name16} } @d);
    $h .= "\x11" . _zahl(length($namen) + 1) . "\x00" . $namen;
    my @attr = grep { defined $_->{attr} } @d;
    if (@attr) {
        my $a = (@attr == @d ? "\x01" : "\x00" . _bits(map { defined $_->{attr} ? 1 : 0 } @d))
              . "\x00" . join('', map { pack('V', $_->{attr}) } @attr);
        $h .= "\x15" . _zahl(length $a) . $a;   # kAttributes, nicht extern
    }
    $h .= "\x00\x00";

    my $h_crc = Compress::Raw::Zlib::crc32($h);
    $z->_strom_beginn;
    $z->_strom_daten($h);
    $z->_strom_ende;
    my $e = "\x17" . _strom_info($h_pack, $z->{chiffre}, $z->{iv0}, length($h), $z->{gepackt}, $h_crc) . "\x00";
    $z->{aus}->($e);

    my $off = $h_pack + $z->{chiffre};
    my $rest = _u64($off) . _u64(length $e) . pack('V', Compress::Raw::Zlib::crc32($e));
    my $kopf = "7z\xBC\xAF\x27\x1C\x00\x04" . pack('V', Compress::Raw::Zlib::crc32($rest)) . $rest;
    $z->{key} = "\0" x 32;
    return ($kopf, 32 + $off + length $e);
}

1;

