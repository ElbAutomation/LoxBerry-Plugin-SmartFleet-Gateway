# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Backup::Fetch;

use strict;
use warnings;
use MIME::Base64 qw(encode_base64);
use HTTP::Tiny;
use FM::Backup::Catalog;

use constant MAX_TIEFE => 8;

my $UA;
sub _ua {
    return $UA if $UA;
    $UA = HTTP::Tiny->new(agent => 'fm-agent/1.0', timeout => 30,
                          verify_SSL => 0);
    return $UA;
}

sub _get {
    my ($base, $cred, $pfad, $sagen) = @_;
    $sagen ||= sub { };
    my %h;
    $h{Authorization} = 'Basic ' . encode_base64($cred, '')
        if defined $cred && $cred ne '';
    $sagen->('-> GET ' . $base . $pfad . ($h{Authorization} ? ' (Basic-Auth)' : ''));
    my $r = _ua()->get($base . $pfad, { headers => \%h });
    $sagen->('<- ' . $r->{status} . ($r->{success} && defined $r->{content} ? "\n$r->{content}" : ''));
    return (0, undef) if !$r->{success};
    return (1, $r->{content});
}

sub parse_list {
    my ($text) = @_;
    my @out;
    return \@out if !defined $text || $text eq '';

    for my $z (split /\r?\n/, $text) {
        $z =~ s/\s+$//;
        next if $z !~ /\S/;
        my ($typ, $size, $datum, $name) =
            $z =~ /^(\S+)\s+(\d+)\s+(\w{3}\s+\d+\s+[\d:]+)\s+(.+)$/;
        next if !defined $name;
        $datum =~ s/\s+/ /g;
        next if $name eq '.' || $name eq '..';
        push @out, { name => $name, size => $size + 0, datum => $datum,
                     dir => ($typ eq 'd' ? 1 : 0) };
    }
    return \@out;
}

sub walk {
    my ($base, $cred, $dirs, $grenze, $sagen) = @_;
    $grenze = 512 * 1024 * 1024 if !$grenze || $grenze < 1;
    $sagen ||= sub { };

    my (@dateien, @fehler);
    my $summe = 0;
    my $voll_abbruch = 0;

    my $rein;
    $rein = sub {
        my ($pfad, $tiefe) = @_;
        return if $tiefe > MAX_TIEFE;
        return if $voll_abbruch;

        $sagen->("Verzeichnis $pfad");
        my ($ok, $body) = _get($base, $cred, "/dev/fslist$pfad", $sagen);
        if (!$ok) {
            push @fehler, "Auflisten fehlgeschlagen: $pfad";
            return;
        }

        for my $e (@{ parse_list($body) }) {
            my $voll = $pfad . '/' . $e->{name};
            next if FM::Backup::Catalog::excluded($voll);

            if ($e->{dir}) {
                $rein->($voll, $tiefe + 1);
                return if $voll_abbruch;
            } else {
                $summe += $e->{size};
                if ($summe > $grenze) {
                    push @fehler, sprintf(
                        'Groessengrenze ueberschritten: %d von %d Byte',
                        $summe, $grenze);
                    $voll_abbruch = 1;
                    return;
                }
                push @dateien, { path => $voll, size => $e->{size}, datum => $e->{datum} };
            }
        }
    };

    $rein->($_, 0) for @$dirs;
    return (\@dateien, \@fehler);
}

sub get_to_file {
    my ($base, $cred, $pfad, $ziel, $sagen) = @_;
    $sagen ||= sub { };
    my %h;
    $h{Authorization} = 'Basic ' . encode_base64($cred, '')
        if defined $cred && $cred ne '';

    $sagen->('-> GET ' . $base . '/dev/fsget' . $pfad . ($h{Authorization} ? ' (Basic-Auth)' : ''));
    open my $fh, '>:raw', $ziel or return (0, 0);
    my $bytes = 0;
    my $r = _ua()->request('GET', $base . '/dev/fsget' . $pfad, {
        headers   => \%h,
        data_callback => sub {
            my ($stueck) = @_;
            print {$fh} $stueck;
            $bytes += length $stueck;
        },
    });
    close $fh;
    $sagen->("<- $r->{status} ($bytes Byte, nicht protokolliert)");

    if (!$r->{success}) {
        unlink $ziel;
        return (0, 0);
    }
    return (1, $bytes);
}

1;

