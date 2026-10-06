# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Loxlog;
use strict;
use warnings;
use File::Spec;

my $verfuegbar;

sub _loglevel {
    my $daten = eval { LoxBerry::System::plugindata($LoxBerry::System::lbpplugindir) };
    return 6 if !$daten || !defined $daten->{PLUGINDB_LOGLEVEL};
    my $stufe = $daten->{PLUGINDB_LOGLEVEL};
    return 6 if $stufe !~ /\A[0-7]\z/;   # unbekannter Wert: lieber melden als schweigen
    return $stufe + 0;
}

sub _laden {
    return $verfuegbar if defined $verfuegbar;
    $verfuegbar = eval {
        require LoxBerry::System;
        require LoxBerry::Log;
        die "LoxBerry::Log->new fehlt\n" if !defined &LoxBerry::Log::new;
        1;
    } ? 1 : 0;
    return $verfuegbar;
}

sub start {
    my ($name, $ueber, %opts) = @_;
    return undef if !_laden();

    local $SIG{__WARN__} = sub { };

    my $stderr_alt;
    my $umgeleitet = open($stderr_alt, '>&', \*STDERR)
                     && open(STDERR, '>', File::Spec->devnull);

    my $log = eval {
        LoxBerry::Log->new(
            name    => $name,
            loglevel => $opts{force_debug} ? 7 : _loglevel(),
            package => $LoxBerry::System::lbpplugindir,
            addtime => 1,
        );
    };

    if ($umgeleitet) {
        open(STDERR, '>&', $stderr_alt);
        close($stderr_alt);
    }

    return undef if !$log;

    eval { $log->LOGSTART($ueber) } if defined $ueber;

    return $log;
}

sub inf  { my ($l, $t) = @_; $l->INF($t)  if $l; return; }
sub ok   { my ($l, $t) = @_; $l->OK($t)   if $l; return; }
sub warn { my ($l, $t) = @_; $l->WARN($t) if $l; return; }
sub err  { my ($l, $t) = @_; $l->ERR($t)  if $l; return; }
sub deb  { my ($l, $t) = @_; $l->DEB($t)  if $l; return; }

sub ende {
    my ($l) = @_;
    return if !$l;
    $l->LOGEND('');
    return;
}

1;

