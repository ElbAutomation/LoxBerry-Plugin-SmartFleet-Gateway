# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Paths;
use strict;
use warnings;
use File::Spec;
use File::Path ();
use File::Copy ();

use constant SHM => '/dev/shm';

sub _ordner {
    my ($konfigdir) = @_;
    my @teile = File::Spec->splitdir($konfigdir);
    pop @teile while @teile && $teile[-1] eq '';
    return @teile ? $teile[-1] : 'smartfleet';
}

sub laufzeit {
    my ($konfigdir) = @_;
    return $konfigdir if !defined $konfigdir || $konfigdir eq '';

    my $ziel = File::Spec->catdir(SHM, _ordner($konfigdir));

    if (-d SHM && -w SHM) {
        if (!-d $ziel) {
            my $alt = umask(0077);
            eval { File::Path::make_path($ziel); 1 };
            umask($alt);
        }
        return $ziel if -d $ziel && -w $ziel;
    }

    return $konfigdir;
}

sub ist_ram {
    my ($konfigdir) = @_;
    return laufzeit($konfigdir) ne $konfigdir ? 1 : 0;
}

our @UMZUG = qw(state.json spool.jsonl events.jsonl);

sub uebernehmen {
    my ($konfigdir) = @_;
    my $ziel = laufzeit($konfigdir);
    return 0 if $ziel eq $konfigdir;

    my $n = 0;
    for my $name (@UMZUG) {
        my $alt = File::Spec->catfile($konfigdir, $name);
        my $neu = File::Spec->catfile($ziel, $name);
        next if !-e $alt;
        next if -e $neu;
        $n++ if File::Copy::move($alt, $neu);
    }

    for my $name (qw(sync.lock collect.lock backup.lock spool.lock events.lock vault.lock
                     pin.session)) {
        unlink(File::Spec->catfile($konfigdir, $name));
    }

    return $n;
}

1;

