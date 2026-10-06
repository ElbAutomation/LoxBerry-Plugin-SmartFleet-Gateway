# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Loxplan;

use strict;
use warnings;
use Compress::Zlib qw(crc32);
use File::Spec;
use FM::Backup::Pack;

use constant MAGIC => 0xaabbccee;

use constant LOXONE_EPOCH => 1230768000;

sub unpack_loxcc {
    my ($quelldatei, $zieldatei) = @_;

    open my $in, '<:raw', $quelldatei or return (0, "Quelle nicht lesbar: $!");
    local $/;
    my $raw = <$in>;
    close $in;

    return (0, 'Datei zu kurz fuer einen LoxCC-Kopf') if length($raw) < 16;

    my ($header, $compressedSize, $uncompressedSize, $checksum) =
        unpack('V4', substr($raw, 0, 16));
    return (0, 'falsches Format (Magic-Wort stimmt nicht)') if $header != MAGIC;

    my $data  = substr($raw, 16, $compressedSize);
    my $len   = length($data);
    my $index = 0;
    my $result = '';

    while ($index < $len) {
        my $byte = ord(substr($data, $index, 1));
        $index++;

        my $copyBytes = $byte >> 4;
        $byte &= 0xf;
        if ($copyBytes == 15) {
            while (1) {
                return (0, 'Datenstrom endet mitten in einer Laengenangabe') if $index >= $len;
                my $addByte = ord(substr($data, $index, 1));
                $copyBytes += $addByte;
                $index++;
                last if $addByte != 0xff;
            }
        }
        if ($copyBytes > 0) {
            $result .= substr($data, $index, $copyBytes);
            $index += $copyBytes;
        }
        last if $index >= $len;

        my $bytesBack = unpack('v', substr($data, $index, 2));
        $index += 2;

        my $bytesBackCopied = 4 + $byte;
        if ($byte == 15) {
            while (1) {
                return (0, 'Datenstrom endet mitten in einer Laengenangabe') if $index >= $len;
                my $val = ord(substr($data, $index, 1));
                $bytesBackCopied += $val;
                $index++;
                last if $val != 0xff;
            }
        }

        while ($bytesBackCopied > 0) {
            if (-$bytesBack + 1 == 0) {
                $result .= substr($result, -$bytesBack);
            } else {
                $result .= substr($result, -$bytesBack, 1);
            }
            $bytesBackCopied--;
        }
    }

    my $crc = crc32($result);
    return (0, sprintf('Pruefsumme falsch (%u statt %u)', $crc, $checksum))
        if $crc != $checksum;
    return (0, sprintf('Groesse falsch (%d statt %d Byte)', length($result), $uncompressedSize))
        if length($result) != $uncompressedSize;

    open my $out, '>:raw', $zieldatei or return (0, "Ziel nicht schreibbar: $!");
    print {$out} $result;
    close $out;
    return (1, undef);
}

sub waehle_projektdatei {
    my ($dateien) = @_;
    return undef if ref($dateien) ne 'ARRAY';

    my @kandidaten = grep {
        ref($_) eq 'HASH' && !$_->{dir}
            && defined $_->{name}
            && $_->{name} =~ /\Asps_/i
            && $_->{name} !~ /\Asps_old/i
            && $_->{name} =~ /\.(?:zip|loxcc)\z/i
    } @$dateien;
    return undef if !@kandidaten;

    my @sortiert = sort { lc($b->{name}) cmp lc($a->{name}) } @kandidaten;
    return $sortiert[0]{name};
}

sub app_version_geaendert {
    my ($bekannt, $neu) = @_;
    return 1 if !defined $bekannt || $bekannt eq '';
    return (!defined $neu || $bekannt ne $neu) ? 1 : 0;
}

sub entpacke {
    my ($rohdatei, $arbeitsverzeichnis) = @_;
    my $ziel = File::Spec->catfile($arbeitsverzeichnis, 'programm.Loxone');

    my ($ext) = $rohdatei =~ /\.([^.\/\\]+)\z/;
    $ext = defined $ext ? lc($ext) : '';

    if ($ext eq 'loxcc') {
        my ($ok, $fehler) = unpack_loxcc($rohdatei, $ziel);
        return $ok ? (1, $ziel) : (0, $fehler);
    }

    if ($ext ne 'zip') {
        return (0, "unbekannte Dateiendung: $rohdatei");
    }

    return (0, '7z fehlt') if !FM::Backup::Pack::have_7z();

    my $entpackt = File::Spec->catdir($arbeitsverzeichnis, 'entpackt');
    require File::Path;
    File::Path::make_path($entpackt);
    my $rc = system('7z', 'x', '-y', "-o$entpackt", $rohdatei, '-bso0', '-bsp0');
    return (0, "7z meldete $rc") if $rc != 0;

    my $roh_loxone = File::Spec->catfile($entpackt, 'sps0.Loxone');
    if (-f $roh_loxone) {
        require File::Copy;
        return (0, "konnte $roh_loxone nicht uebernehmen")
            if !File::Copy::copy($roh_loxone, $ziel);
        return (1, $ziel);
    }

    my $roh_loxcc = File::Spec->catfile($entpackt, 'sps0.LoxCC');
    if (-f $roh_loxcc) {
        my ($ok, $fehler) = unpack_loxcc($roh_loxcc, $ziel);
        return $ok ? (1, $ziel) : (0, $fehler);
    }

    return (0, 'weder sps0.Loxone noch sps0.LoxCC im Archiv gefunden');
}

sub metadaten {
    my ($pfad) = @_;
    my %leer = (config_version => undef, creator => undef, cust => undef, config_ts => undef);

    open my $fh, '<:raw', $pfad or return { %leer };
    my $praefix = '';
    read $fh, $praefix, 8192;
    close $fh;

    return { %leer } if $praefix !~ /<C\s+Type="Document"([^>]*)>/;
    my $attrs = $1;

    my %werte;
    while ($attrs =~ /(\w+)="([^"]*)"/g) {
        $werte{$1} = _xml_entdekodieren($2);
    }

    my $config_ts;
    if (defined $werte{DateS} && $werte{DateS} =~ /\A\d+\z/) {
        $config_ts = LOXONE_EPOCH + $werte{DateS};
    }

    return {
        config_version => _firmware_formatieren($werte{ConfigVersion}),
        creator        => $werte{Creator},
        cust           => $werte{Cust},
        config_ts      => $config_ts,
    };
}

sub _firmware_formatieren {
    my ($s) = @_;
    return $s if !defined $s || $s !~ /\A\d{8}\z/;
    return join('.', map { $_ + 0 } $s =~ /(\d{2})/g);
}

sub _xml_entdekodieren {
    my ($s) = @_;
    return $s if !defined $s || $s eq '';
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&apos;/'/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

use constant PROJEKT_NEU_MAX_ALTER => 3600;

sub projekt_neu_plan {
    my ($mtime, $now, $cfg_ok, $msnos, $erledigt) = @_;
    return ({}, 0) if !defined $mtime;
    return ({}, 1) if !$cfg_ok || !@$msnos || $now - $mtime > PROJEKT_NEU_MAX_ALTER;
    my %ez;
    for my $m (@$msnos) {
        my $ts = $erledigt->{$m};
        $ez{$m} = 1 if !defined $ts || $ts < $mtime;
    }
    return (\%ez, 0);
}

sub projekt_neu_erledigt {
    my ($mtime, $msnos, $erledigt) = @_;
    return 0 if !defined $mtime;
    for my $m (@$msnos) {
        my $ts = $erledigt->{$m};
        return 0 if !defined $ts || $ts < $mtime;
    }
    return 1;
}

1;

