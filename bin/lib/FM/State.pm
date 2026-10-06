# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::State;

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Path qw(make_path);
use Fcntl qw(:flock O_RDWR O_CREAT);

sub _file { my ($dir) = @_; return File::Spec->catfile($dir, 'state.json'); }

sub load {
    my ($dir) = @_;
    my $default = { seq => 0, pending_acks => [], desired => {} };
    my $f = _file($dir);
    return $default if !-e $f;
    open my $fh, '<:raw', $f or return $default;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $s = eval { JSON::PP->new->utf8->decode($raw) };
    return $default if !$s || ref($s) ne 'HASH';
    $s->{seq} = 0
        if ref($s->{seq}) ne '' || !defined($s->{seq}) || $s->{seq} !~ /\A[0-9]+\z/;
    $s->{pending_acks} = [] if ref($s->{pending_acks}) ne 'ARRAY';
    $s->{desired}      = {} if ref($s->{desired})      ne 'HASH';
    return $s;
}

sub save {
    my ($dir, $state) = @_;
    make_path($dir) if !-d $dir;
    my $f   = _file($dir);
    my $tmp = "$f.new.$$";
    open my $fh, '>:raw', $tmp or die "FM::State: $tmp nicht schreibbar: $!\n";
    print {$fh} JSON::PP->new->canonical->utf8->encode($state);
    close $fh or die "FM::State: $tmp nicht geschlossen: $!\n";
    chmod 0600, $tmp;
    rename $tmp, $f or die "FM::State: $tmp nicht nach $f verschiebbar: $!\n";
    return 1;
}

sub lock {
    my ($dir, $name) = @_;
    $name = 'sync' if !defined $name || $name !~ /\A[a-z]+\z/;
    make_path($dir) if !-d $dir;
    my $lf = File::Spec->catfile($dir, "$name.lock");
    open my $fh, '>>', $lf or return undef;
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        close $fh;
        return undef;
    }
    return $fh;
}

1;

