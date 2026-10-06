# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Spool;

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Path qw(make_path);
use Fcntl qw(:flock);

use constant MAX_BYTES => 512 * 1024;

sub _file { my ($dir) = @_; return File::Spec->catfile($dir, 'spool.jsonl'); }

sub _lockfile { my ($dir) = @_; return File::Spec->catfile($dir, 'spool.lock'); }

sub _lock {
    my ($dir, $mode) = @_;
    make_path($dir) if !-d $dir;
    my $lf = _lockfile($dir);
    open my $fh, '>>', $lf or die "FM::Spool: $lf nicht sperrbar: $!\n";
    flock($fh, $mode) or die "FM::Spool: $lf nicht sperrbar: $!\n";
    return $fh;
}

sub size {
    my ($dir) = @_;
    my $s = -s _file($dir);
    return $s ? $s : 0;
}

sub append {
    my ($dir, $rec) = @_;
    make_path($dir) if !-d $dir;
    my $f = _file($dir);

    my $line = JSON::PP->new->canonical->utf8->encode($rec) . "\n";

    my $lock = _lock($dir, LOCK_EX);

    open my $fh, '>>:raw', $f or die "FM::Spool: $f nicht schreibbar: $!\n";
    print {$fh} $line;
    close $fh;

    _enforce_limit($dir);

    close $lock;
    return 1;
}

sub _enforce_limit {
    my ($dir) = @_;
    my $f = _file($dir);
    my $s = -s $f;
    return if !$s || $s <= MAX_BYTES;

    open my $fh, '<:raw', $f or return;
    local $/;
    my $all = <$fh>;
    close $fh;
    return if !defined $all;

    my $ziel = int(MAX_BYTES * 0.75);
    my $weg  = length($all) - $ziel;
    $weg = 0 if $weg < 0;
    my $nl = index($all, "\n", $weg);
    my $rest = ($nl >= 0) ? substr($all, $nl + 1) : '';

    _write_atomic($f, $rest);
    return;
}

sub _write_atomic {
    my ($f, $content) = @_;
    my $tmp = "$f.new.$$";
    open my $out, '>:raw', $tmp or die "FM::Spool: $tmp nicht schreibbar: $!\n";
    if (!print {$out} $content) {
        my $e = $!;
        close $out;
        unlink $tmp;
        die "FM::Spool: $tmp nicht beschreibbar: $e\n";
    }
    if (!close $out) {
        my $e = $!;
        unlink $tmp;
        die "FM::Spool: $tmp nicht geschlossen: $e\n";
    }
    if (!rename $tmp, $f) {
        my $e = $!;
        unlink $tmp;
        die "FM::Spool: $tmp nicht nach $f verschiebbar: $e\n";
    }
    return;
}

sub read {
    my ($dir, $max_recs) = @_;
    my $f = _file($dir);
    return ([], 0) if !-e $f;

    my $lock = _lock($dir, LOCK_SH);

    open my $fh, '<:raw', $f or do { close $lock; return ([], 0); };
    local $/;
    my $all = <$fh>;
    close $fh;
    close $lock;
    return ([], 0) if !defined $all || $all eq '';

    my $last_nl = rindex($all, "\n");
    return ([], 0) if $last_nl < 0;
    my $usable = substr($all, 0, $last_nl + 1);

    my @recs;
    my @offsets;
    my $offset = 0;
    my $j = JSON::PP->new->utf8;
    for my $line (split /\n/, $usable) {
        $offset += length($line) + 1;

        if ($line =~ /\S/) {
            my $r = eval { $j->decode($line) };
            if ($r && ref($r) eq 'HASH') {
                push @recs, $r;
                push @offsets, $offset;
            }
        }

        if ($max_recs && $max_recs > 0 && scalar(@recs) >= $max_recs) {
            last;
        }
    }
    return (\@recs, $offset, \@offsets);
}

sub truncate_to {
    my ($dir, $offset) = @_;
    my $f = _file($dir);
    return 1 if !-e $f || !$offset || $offset <= 0;

    my $lock = _lock($dir, LOCK_EX);

    open my $fh, '<:raw', $f or do { close $lock; return 1; };
    local $/;
    my $all = <$fh>;
    close $fh;

    if (!defined $all) {
        close $lock;
        return 1;
    }

    my $len = length($all);

    if ($offset > $len || ($offset < $len && substr($all, $offset - 1, 1) ne "\n")) {
        close $lock;
        return 0;
    }

    my $rest = ($offset == $len) ? '' : substr($all, $offset);
    _write_atomic($f, $rest);
    close $lock;
    return 1;
}

1;

