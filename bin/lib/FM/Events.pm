# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Events;

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Path qw(make_path);
use Fcntl qw(:flock);

use constant MAX_BYTES     => 256 * 1024;
use constant MAX_PER_POLL  => 50;
use constant THROTTLE_SECS => 3600;
use constant MAX_MSG_LEN   => 500;

my %VALID_SEV = map { $_ => 1 } qw(error warn info debug);

sub _file { my ($dir) = @_; return File::Spec->catfile($dir, 'events.jsonl'); }

sub _lockfile { my ($dir) = @_; return File::Spec->catfile($dir, 'events.lock'); }

sub _lock {
    my ($dir, $mode) = @_;
    make_path($dir) if !-d $dir;
    my $lf = _lockfile($dir);
    open my $fh, '>>', $lf or die "FM::Events: $lf nicht sperrbar: $!\n";
    flock($fh, $mode) or die "FM::Events: $lf nicht sperrbar: $!\n";
    return $fh;
}

sub _write_atomic {
    my ($f, $content) = @_;
    my $tmp = "$f.new.$$";
    open my $out, '>:raw', $tmp or die "FM::Events: $tmp nicht schreibbar: $!\n";
    if (!print {$out} $content) {
        my $e = $!;
        close $out;
        unlink $tmp;
        die "FM::Events: $tmp nicht beschreibbar: $e\n";
    }
    if (!close $out) {
        my $e = $!;
        unlink $tmp;
        die "FM::Events: $tmp nicht geschlossen: $e\n";
    }
    if (!rename $tmp, $f) {
        my $e = $!;
        unlink $tmp;
        die "FM::Events: $tmp nicht nach $f verschiebbar: $e\n";
    }
    return;
}

sub _read_raw_locked {
    my ($f) = @_;
    return [] if !-e $f;
    open my $fh, '<:raw', $f or return [];
    local $/;
    my $all = <$fh>;
    close $fh;
    return [] if !defined $all || $all eq '';
    my $last_nl = rindex($all, "\n");
    return [] if $last_nl < 0;
    my $usable = substr($all, 0, $last_nl + 1);
    my @lines = split /\n/, $usable;
    return \@lines;
}

sub add {
    my ($dir, $sev, $src, $msg, %opt) = @_;

    my $ok = eval {
        return 0 if !defined $dir  || $dir  eq '';
        return 0 if !defined $sev  || !$VALID_SEV{$sev};
        return 0 if !defined $src  || $src eq '';
        return 0 if !defined $msg  || $msg eq '';

        $msg = substr($msg, 0, MAX_MSG_LEN) if length($msg) > MAX_MSG_LEN;
        my $msno   = $opt{msno};
        my $room   = $opt{room};
        my $detail = $opt{detail};

        make_path($dir) if !-d $dir;
        my $f = _file($dir);

        my $lock = _lock($dir, LOCK_EX);

        my $lines = _read_raw_locked($f);
        my $j = JSON::PP->new->utf8;
        my $now = time();
        my $cutoff = $now - THROTTLE_SECS;

        my @out;
        my $throttled = 0;
        for my $line (@$lines) {
            if (!$throttled && $line =~ /\S/) {
                my $r = eval { $j->decode($line) };
                if ( $r && ref($r) eq 'HASH'
                    && defined($r->{sev}) && $r->{sev} eq $sev
                    && defined($r->{src}) && $r->{src} eq $src
                    && defined($r->{msg}) && $r->{msg} eq $msg
                    && ( (!defined $r->{msno} && !defined $msno)
                         || (defined $r->{msno} && defined $msno && $r->{msno} == $msno) )
                    && defined($r->{ts}) && $r->{ts} >= $cutoff )
                {
                    $r->{n} = ($r->{n} || 1) + 1;
                    push @out, JSON::PP->new->canonical->utf8->encode($r);
                    $throttled = 1;
                    next;
                }
            }
            push @out, $line;
        }

        if (!$throttled) {
            my $rec = {
                ts  => $now,
                sev => $sev,
                src => $src,
                msg => $msg,
                n   => 1,
            };
            $rec->{msno}   = $msno   if defined $msno;
            $rec->{room}   = $room   if defined $room;
            $rec->{detail} = $detail if defined $detail;
            push @out, JSON::PP->new->canonical->utf8->encode($rec);
        }

        my $content = join('', map { "$_\n" } @out);
        _write_atomic($f, $content);

        _enforce_limit($dir);

        close $lock;
        return 1;
    };

    return $ok ? 1 : 0;
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

sub take {
    my ($dir, $max) = @_;
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

    my @events;
    my $offset = 0;
    my $j = JSON::PP->new->utf8;
    for my $line (split /\n/, $usable) {
        $offset += length($line) + 1;

        if ($line =~ /\S/) {
            my $r = eval { $j->decode($line) };
            if ($r && ref($r) eq 'HASH') {
                push @events, $r;
            }
        }

        if ($max && $max > 0 && scalar(@events) >= $max) {
            last;
        }
    }
    return (\@events, $offset);
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

