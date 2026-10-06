# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Settings;
use strict;
use warnings;
use File::Spec;
use JSON::PP;

our @FELDER = qw(backup_store tunnel_erlaubt);

sub _file { my ($dir) = @_; return File::Spec->catfile($dir, 'plugin.json'); }

sub load {
    my ($dir) = @_;
    my $f = _file($dir);
    my $out = {};

    if (-e $f && open(my $fh, '<:raw', $f)) {
        local $/;
        my $roh = <$fh>;
        close $fh;
        my $j = eval { JSON::PP->new->decode($roh) };
        $out = $j if ref($j) eq 'HASH';
    }

    return $out;
}

our %NUR_LOKAL = (backup_store => 1);

sub get {
    my ($dir, $feld, $agentcfg) = @_;
    my $s = load($dir);
    return $s->{$feld} if exists $s->{$feld};
    return undef if $NUR_LOKAL{$feld};
    return $agentcfg->{$feld} if ref($agentcfg) eq 'HASH' && exists $agentcfg->{$feld};
    return undef;
}

sub save {
    my ($dir, $werte) = @_;
    my $f    = _file($dir);
    my $tmp  = "$f.tmp.$$";

    my %rein;
    for my $k (@FELDER) {
        $rein{$k} = $werte->{$k} if exists $werte->{$k} && defined $werte->{$k};
    }

    my $json = JSON::PP->new->canonical->pretty->encode(\%rein);
    open(my $fh, '>:raw', $tmp) or die "FM::Settings: $tmp: $!\n";
    print {$fh} $json           or die "FM::Settings: Schreiben nach $tmp: $!\n";
    close($fh)                  or die "FM::Settings: Schliessen von $tmp: $!\n";
    rename($tmp, $f)            or die "FM::Settings: Umbenennen nach $f: $!\n";
    return 1;
}

1;

