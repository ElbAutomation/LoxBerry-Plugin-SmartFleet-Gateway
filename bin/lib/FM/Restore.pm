# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Restore;

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use FM::Backup::Pack;

sub einspielen {
    my ($configdir, $rt, $archiv_pfad, $passwort) = @_;
    $passwort = '' if !defined $passwort;

    return { ok => 0, grund => 'kein_7z' } if !FM::Backup::Pack::have_7z();
    return { ok => 0, grund => 'keine_datei' }
        if !defined $archiv_pfad || !-f $archiv_pfad;

    my $auspack = eval { tempdir(CLEANUP => 1) };
    return { ok => 0, grund => 'temp_fehlgeschlagen' } if !$auspack;

    my $rc = system('sh', '-c',
        'exec 7z x -o"$1" -p"$2" "$3" -bso0 -bsp0 -y < /dev/null',
        'sh', $auspack, $passwort, $archiv_pfad);
    return { ok => 0, grund => 'entpacken_fehlgeschlagen' } if $rc != 0;

    my $manifest_pfad = File::Spec->catfile($auspack, 'manifest.json');
    return { ok => 0, grund => 'kein_manifest' } if !-f $manifest_pfad;

    my $manifest = eval {
        open my $fh, '<', $manifest_pfad or die;
        local $/;
        my $m = JSON::PP->new->decode(scalar <$fh>);
        die "manifest.json ist kein Objekt\n" if ref($m) ne 'HASH';
        return $m;
    };
    return { ok => 0, grund => 'kein_manifest' } if !$manifest;
    return { ok => 0, grund => 'falscher_typ' }
        if !defined $manifest->{typ} || $manifest->{typ} ne FM::Backup::Pack::MANIFEST_TYP();

    my $nutzlast = 0;
    if (opendir(my $ph, $auspack)) {
        for my $name (readdir $ph) {
            next if $name eq '.' || $name eq '..' || $name eq 'manifest.json';
            $nutzlast++ if -f File::Spec->catfile($auspack, $name);
        }
        closedir $ph;
    }
    return { ok => 0, grund => 'kein_manifest' } if !$nutzlast;

    if (opendir(my $dh, $configdir)) {
        for my $name (readdir $dh) {
            next if $name eq '.' || $name eq '..';
            next if $name =~ /\.lock\z/ || $name eq 'pin.session';
            my $pfad = File::Spec->catfile($configdir, $name);
            unlink $pfad if -f $pfad;
        }
        closedir $dh;
    }

    my @kopierfehler;
    if (opendir(my $qh, $auspack)) {
        for my $name (readdir $qh) {
            next if $name eq '.' || $name eq '..';
            next if $name eq 'manifest.json';
            next if $name =~ /\.lock\z/ || $name eq 'pin.session';
            my $quelle = File::Spec->catfile($auspack, $name);
            next if !-f $quelle;
            my $crc = system('cp', '-p', $quelle, File::Spec->catfile($configdir, $name));
            push @kopierfehler, $name if $crc != 0;
        }
        closedir $qh;
    }
    if (@kopierfehler) {
        for my $datei (qw(state.json spool.jsonl events.jsonl)) {
            unlink File::Spec->catfile($rt, $datei);
        }
        return { ok => 0, grund => 'kopieren_fehlgeschlagen' };
    }

    for my $datei (qw(state.json spool.jsonl events.jsonl)) {
        unlink File::Spec->catfile($rt, $datei);
    }

    return { ok => 1 };
}

1;

