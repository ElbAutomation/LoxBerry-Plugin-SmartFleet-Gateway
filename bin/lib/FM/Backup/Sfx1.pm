# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Sfx1;
use strict;
use warnings;
use IPC::Open2 ();

sub verfuegbar {
    my ($helfer) = @_;
    return 0 if !defined $helfer || !-r $helfer;
    my $ok = eval {
        my $pid = fork();
        die "fork\n" if !defined $pid;
        if (!$pid) {
            open STDOUT, '>', '/dev/null';
            open STDERR, '>', '/dev/null';
            exec 'php', $helfer, '--pruefen';
            exit 127;
        }
        waitpid($pid, 0);
        $? == 0;
    };
    return $ok ? 1 : 0;
}

sub new {
    my ($class, $helfer, $segment) = @_;
    my ($aus, $ein);
    my $pid = eval { IPC::Open2::open2($aus, $ein, 'php', $helfer) };
    die "FM::Backup::Sfx1: Helfer nicht startbar\n" if !$pid;
    binmode $aus;
    binmode $ein;
    my $z = bless { pid => $pid, aus => $aus, ein => $ein, segment => $segment }, $class;
    $z->_schreiben(pack('N', $segment));
    $z->{kopf} = $z->_antwort;
    die "FM::Backup::Sfx1: Kopf ungueltig\n" if length($z->{kopf}) != 25 || substr($z->{kopf}, 0, 5) ne "SFX1\x01";
    return $z;
}

sub _schreiben {
    my ($z, $d) = @_;
    local $SIG{PIPE} = 'IGNORE';
    my $o = 0;
    while ($o < length $d) {
        my $w = syswrite($z->{ein}, $d, length($d) - $o, $o);
        die "FM::Backup::Sfx1: Helfer nimmt nichts an ($!)\n" if !defined $w || $w == 0;
        $o += $w;
    }
}

sub _genau {
    my ($z, $n) = @_;
    my $s = '';
    while (length($s) < $n) {
        my $r = sysread($z->{aus}, my $b, $n - length $s);
        die "FM::Backup::Sfx1: Helfer abgebrochen\n" if !$r;
        $s .= $b;
    }
    return $s;
}

sub _antwort {
    my ($z) = @_;
    my $n = unpack('N', $z->_genau(4));
    die "FM::Backup::Sfx1: Antwort zu lang\n" if $n > $z->{segment} + 1024;
    return $z->_genau($n);
}

sub _anfrage {
    my ($z, $typ, $daten) = @_;
    $z->_schreiben($typ . pack('N', length $daten) . $daten);
    return $z->_antwort;
}

sub kopf { return $_[0]{kopf} }

sub segment {
    my ($z, $klar, $ende) = @_;
    return $z->_anfrage($ende ? 'E' : 'S', $klar);
}

sub startkopf {
    my ($z, $k32) = @_;
    die "FM::Backup::Sfx1: Startkopf nicht 32 Byte\n" if length($k32) != 32;
    return $z->_anfrage('K', $k32);
}

sub siegel {
    my ($z, $pub) = @_;
    return $z->_anfrage('V', $pub);
}

sub ende {
    my ($z) = @_;
    return 1 if !$z->{pid};
    close $z->{ein};
    close $z->{aus};
    waitpid($z->{pid}, 0);
    my $ok = $? == 0;
    $z->{pid} = 0;
    return $ok ? 1 : 0;
}

sub DESTROY {
    my ($z) = @_;
    local $?;
    $z->ende if $z->{pid};
}

1;

