# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Keep;

use strict;
use warnings;
use File::Spec;
use File::Path qw(remove_tree);
use JSON::PP;

sub ms_dir {
    my ($store, $msno) = @_;
    return File::Spec->catdir($store, 'ms' . ($msno + 0));
}

sub gen_dir {
    my ($store, $msno, $stamp) = @_;
    return File::Spec->catdir(ms_dir($store, $msno), $stamp);
}

sub archiv_datei {
    my ($gendir) = @_;
    for my $name (qw(backup.7z backup.zip)) {
        my $p = File::Spec->catfile($gendir, $name);
        return $p if -f $p;
    }
    return undef;
}

sub generations {
    my ($store, $msno) = @_;
    my $d = ms_dir($store, $msno);
    return [] if !-d $d;

    opendir my $dh, $d or return [];
    my @stamps = grep { /\A[0-9]{14}\z/ } readdir $dh;
    closedir $dh;

    my @out;
    for my $s (sort { $b cmp $a } @stamps) {
        my $gd = File::Spec->catdir($d, $s);
        next if !defined archiv_datei($gd);
        push @out, { dir => $gd, stamp => $s };
    }
    return \@out;
}

sub prune {
    my ($store, $msno) = @_;

    my $g = generations($store, $msno);
    return 0 if scalar(@$g) <= 1;

    my $weg = 0;
    for my $alt (@{$g}[1 .. $#$g]) {
        my $meta = eval {
            open my $fh, '<', File::Spec->catfile($alt->{dir}, 'meta.json') or die;
            local $/;
            JSON::PP->new->decode(scalar <$fh>);
        };
        next if !$meta || !$meta->{uploaded};
        remove_tree($alt->{dir});
        $weg++ if !-d $alt->{dir};
    }
    return $weg;
}

1;

