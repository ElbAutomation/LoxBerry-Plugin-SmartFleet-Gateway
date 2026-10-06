# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Pin;
use strict;
use warnings;
use File::Spec;

use constant GUELTIG_SEK => 900;

sub _datei { my ($dir) = @_; return File::Spec->catfile($dir, 'pin.session'); }

sub ausstellen {
    my ($dir) = @_;

    my $roh;
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $roh, 24);
        close $fh;
    }
    return undef if !defined $roh || length($roh) != 24;
    my $schein = unpack('H*', $roh);

    my $f   = _datei($dir);
    my $tmp = "$f.tmp.$$";
    my $bis = time() + GUELTIG_SEK;

    my $alt = umask(0077);
    my $ok = eval {
        open(my $fh, '>', $tmp) or die "FM::Pin: $tmp: $!\n";
        print {$fh} "$schein\n$bis\n" or die "FM::Pin: Schreiben: $!\n";
        close($fh) or die "FM::Pin: Schliessen: $!\n";
        rename($tmp, $f) or die "FM::Pin: Umbenennen: $!\n";
        1;
    };
    my $fehler = $@;
    umask($alt);
    die $fehler if !$ok;

    return $schein;
}

sub gueltig {
    my ($dir, $schein) = @_;
    return 0 if !defined $schein || $schein !~ /\A[0-9a-f]{48}\z/;

    my $f = _datei($dir);
    return 0 if !-e $f;
    open(my $fh, '<', $f) or return 0;
    my $gespeichert = <$fh>;
    my $bis         = <$fh>;
    close $fh;
    return 0 if !defined $gespeichert || !defined $bis;
    chomp($gespeichert, $bis);

    return 0 if $bis !~ /\A[0-9]+\z/ || time() > $bis;

    return 0 if length($gespeichert) != length($schein);
    my $diff = 0;
    for my $i (0 .. length($schein) - 1) {
        $diff |= ord(substr($gespeichert, $i, 1)) ^ ord(substr($schein, $i, 1));
    }
    return $diff == 0 ? 1 : 0;
}

sub einziehen {
    my ($dir) = @_;
    unlink(_datei($dir));
    return 1;
}

1;

