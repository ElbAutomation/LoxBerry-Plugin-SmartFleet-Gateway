# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Tunnel;

use strict;
use warnings;
use Digest::SHA qw(hmac_sha256_hex);

use constant FENSTER_SEK => 300;
use constant ZWECK       => 'tunnel_open';
use constant PIDFILE     => '/dev/shm/smartfleet-tunnel.pid';
use constant LOGFILE     => '/dev/shm/smartfleet-tunnel.log';
use constant WARTEZEIT   => 60;
use constant ABLAUF_SEK  => 21600;

use constant EVENT_SRC_URL    => 'tunnel_url';
use constant EVENT_SRC_CLOSED => 'tunnel_closed';
use constant EVENT_SRC_ERROR  => 'tunnel_error';

sub riegel_offen {
    my ($cfg) = @_;
    return 0 if ref($cfg) ne 'HASH';
    return $cfg->{tunnel_erlaubt} ? 1 : 0;
}

sub zeitfenster_ok {
    my ($ts, $jetzt) = @_;
    return 0 if !defined $ts || $ts !~ /\A[0-9]+\z/;
    $jetzt = time() if !defined $jetzt;
    my $alter = $jetzt - $ts;
    return 0 if $alter > FENSTER_SEK;
    return 1;
}

sub _konstante_gleichheit {
    my ($a, $b) = @_;
    return 0 if !defined $a || !defined $b;
    my $la = length($a);
    my $lb = length($b);
    my $n  = $la > $lb ? $la : $lb;
    my $diff = ($la == $lb) ? 0 : 1;
    for my $i (0 .. $n - 1) {
        my $ca = $i < $la ? ord(substr($a, $i, 1)) : 0;
        my $cb = $i < $lb ? ord(substr($b, $i, 1)) : 0;
        $diff |= ($ca ^ $cb);
    }
    return $diff == 0 ? 1 : 0;
}

sub antwort_stimmt {
    my ($K_hex, $nonce, $site_id, $zweck, $ts, $antwort) = @_;
    return 0 if !defined $K_hex || $K_hex !~ /\A[0-9a-fA-F]{64}\z/;
    return 0 if !defined $nonce   || $nonce eq '';
    return 0 if !defined $site_id || $site_id eq '';
    return 0 if !defined $zweck   || $zweck eq '';
    return 0 if !defined $ts      || "$ts" eq '';
    return 0 if !defined $antwort || $antwort eq '';

    my $K = pack('H*', $K_hex);
    my $nachricht = join("\n", $nonce, $site_id, $zweck, $ts);
    my $erwartet = hmac_sha256_hex($nachricht, $K);
    return _konstante_gleichheit(lc($erwartet), lc($antwort));
}

sub cloudflared_suchen {
    my (@zusatzpfade) = @_;
    for my $bin ('/usr/bin/cloudflared', '/usr/local/bin/cloudflared', @zusatzpfade) {
        return $bin if defined $bin && $bin ne '' && -x $bin;
    }
    my $gefunden = `command -v cloudflared 2>/dev/null`;
    return undef if !defined $gefunden;
    $gefunden =~ s/[\r\n]+\z//;
    return ($gefunden ne '' && -x $gefunden) ? $gefunden : undef;
}

sub url_aus_log {
    my ($logfile) = @_;
    $logfile = LOGFILE if !defined $logfile;
    return undef if !-e $logfile;
    open my $fh, '<', $logfile or return undef;
    local $/;
    my $inhalt = <$fh>;
    close $fh;
    return undef if !defined $inhalt;
    return ($inhalt =~ m{(https://[a-z0-9-]+\.trycloudflare\.com)}) ? $1 : undef;
}

sub pid_verfolgt {
    my ($pidfile) = @_;
    $pidfile = PIDFILE if !defined $pidfile;
    return undef if !-e $pidfile;
    open my $fh, '<', $pidfile or return undef;
    my $pid = <$fh>;
    close $fh;
    return undef if !defined $pid;
    $pid =~ s/\s+//g;
    return undef if $pid !~ /\A[0-9]+\z/;
    return undef if !-d "/proc/$pid";
    my $exe = readlink("/proc/$pid/exe");
    return undef if !defined $exe || $exe !~ m{(^|/)cloudflared\z};
    return $pid;
}

sub start_lesen {
    my ($pidfile) = @_;
    $pidfile = PIDFILE if !defined $pidfile;
    open my $fh, '<', $pidfile or return undef;
    my @zeilen = <$fh>;
    close $fh;
    return undef if @zeilen < 3 || !defined $zeilen[2];
    (my $t = $zeilen[2]) =~ s/\s+//g;
    return $t =~ /\A[0-9]+\z/ ? $t + 0 : undef;
}

sub ablauf_lesen {
    my ($pidfile) = @_;
    $pidfile = PIDFILE if !defined $pidfile;
    return undef if !-e $pidfile;
    open my $fh, '<', $pidfile or return undef;
    my @zeilen = <$fh>;
    close $fh;
    return undef if @zeilen < 2;
    my $ablauf = $zeilen[1];
    return undef if !defined $ablauf;
    $ablauf =~ s/\s+//g;
    return undef if $ablauf !~ /\A[0-9]+\z/;
    return $ablauf + 0;
}

sub stop {
    my ($pidfile, $logfile) = @_;
    $pidfile = PIDFILE if !defined $pidfile;
    $logfile = LOGFILE if !defined $logfile;
    my $pid = pid_verfolgt($pidfile);
    if ($pid) {
        kill('TERM', $pid);
        for (1 .. 6) {
            last if !-d "/proc/$pid";
            select(undef, undef, undef, 0.5);
        }
        kill('KILL', $pid) if -d "/proc/$pid";
    }
    unlink($pidfile);
    unlink($logfile);
    return 1;
}

sub start {
    my (%arg) = @_;
    my $bin        = $arg{bin};
    my $ziel_url   = $arg{ziel_url};
    my $pidfile    = defined $arg{pidfile}    ? $arg{pidfile}    : PIDFILE;
    my $logfile    = defined $arg{logfile}    ? $arg{logfile}    : LOGFILE;
    my $wartezeit  = defined $arg{wartezeit}  ? $arg{wartezeit}  : WARTEZEIT;
    my $ablauf_sek = defined $arg{ablauf_sek} ? $arg{ablauf_sek} : ABLAUF_SEK;

    return (0, 'cloudflared_fehlt') if !defined $bin || !-x $bin;
    return (0, 'kein_zielpunkt') if !defined $ziel_url || $ziel_url eq '';

    stop($pidfile, $logfile);

    my $start_zeit = time();

    my $kommando = sprintf(
        q{sh -c 'echo $$ > %s; exec %s --url %s > %s 2>&1' &},
        $pidfile, $bin, $ziel_url, $logfile
    );
    my $exitcode = system($kommando);
    if ($exitcode != 0) {
        stop($pidfile, $logfile);
        return (0, 'start_fehlgeschlagen');
    }

    my $url;
    for (1 .. $wartezeit) {
        $url = url_aus_log($logfile);
        last if $url;
        sleep(1);
    }
    if (!$url) {
        stop($pidfile, $logfile);
        return (0, 'keine_url');
    }

    if (open my $efh, '>>', $pidfile) {
        my $ablauf = $ablauf_sek > 0 ? $start_zeit + $ablauf_sek : 0;
        print {$efh} "$ablauf\n$start_zeit\n";
        close $efh;
    }

    return (1, $url);
}

sub durchsetzen {
    my (%arg) = @_;
    my $pidfile = defined $arg{pidfile} ? $arg{pidfile} : PIDFILE;
    my $jetzt   = defined $arg{jetzt}   ? $arg{jetzt}   : time();
    my $riegel  = exists $arg{riegel} ? $arg{riegel} : 1;

    return { status => 'kein_tunnel' } if !-e $pidfile;

    if (!$riegel) {
        stop($pidfile);
        return { status => 'geschlossen', grund => 'riegel_geschlossen' };
    }

    my $pid    = pid_verfolgt($pidfile);
    my $ablauf = ablauf_lesen($pidfile);

    if (!$pid || !defined($ablauf) || ($ablauf > 0 && $ablauf <= $jetzt)) {
        stop($pidfile);
        return {
            status => 'geschlossen',
            grund  => !$pid             ? 'nicht_mehr_aktiv'
                    : !defined($ablauf) ? 'kein_zeitstempel'
                    :                     'zeitlimit',
        };
    }

    return { status => 'offen', ablauf => $ablauf, verbleibend => ($ablauf > 0 ? $ablauf - $jetzt : undef) };
}

sub oeffnen {
    my (%arg) = @_;
    my $cfg     = $arg{cfg};
    my $jetzt   = defined $arg{jetzt} ? $arg{jetzt} : time();
    my $site_id = (ref($cfg) eq 'HASH') ? $cfg->{site} : undef;

    return (0, 'riegel_geschlossen') if !riegel_offen($cfg);

    return (0, 'zeitfenster_abgelaufen') if !zeitfenster_ok($arg{ts}, $jetzt);

    return (0, 'kein_tunnelpasswort') if !defined $arg{K};
    return (0, 'hmac_falsch')
        if !defined $site_id || $site_id eq ''
        || !antwort_stimmt($arg{K}, $arg{nonce}, $site_id, ZWECK, $arg{ts}, $arg{antwort});

    my $bin = defined $arg{bin} ? $arg{bin} : cloudflared_suchen(@{ $arg{zusatzpfade} || [] });
    return (0, 'cloudflared_fehlt') if !defined $bin || !-x $bin;

    return start(
        bin        => $bin,
        ziel_url   => $arg{ziel_url},
        pidfile    => $arg{pidfile},
        logfile    => $arg{logfile},
        wartezeit  => $arg{wartezeit},
        ablauf_sek => ($arg{dauerhaft} ? 0 : undef),
    );
}

1;

