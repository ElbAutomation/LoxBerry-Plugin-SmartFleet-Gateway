# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Collect;

use strict;
use warnings;
use Time::HiRes ();
use FM::Miniserver;

use constant IDENT_RETRY => 3600;

use constant FEHLT_PRUEFUNG => 86400;

my %NIE_MERKEN = map { $_ => 1 } qw(sys_cpu sys_heap_used sys_heap_total);

use constant DEVTREE_GEN1_MIN => 3600;

sub due {
    my ($state, $now, $interval) = @_;
    $interval = 300 if !$interval || $interval < 1;
    my $next = $state->{collect_next};
    return 1 if !defined $next;
    return 1 if $next > $now + $interval * 5;
    return $next <= $now ? 1 : 0;
}

sub ident_cache {
    my ($state, $site) = @_;
    return {} if ref($state) ne 'HASH' || ref($state->{ms_ident}) ne 'HASH';
    return {} if !defined $site || !defined $state->{ms_ident_site} || $state->{ms_ident_site} ne $site;
    return $state->{ms_ident};
}

sub identity_due {
    my ($cached, $app_version, $now) = @_;
    return 0 if !defined $app_version || $app_version eq '';
    if (defined $now && ref($cached) eq 'HASH'
        && defined $cached->{ident_retry_at}
        && $cached->{ident_retry_at} =~ /\A[0-9]+\z/) {
        my $bis = $cached->{ident_retry_at} + 0;
        return 0 if $now < $bis && $bis <= $now + IDENT_RETRY * 5;
    }
    return 1 if !$cached || ref($cached) ne 'HASH' || !%$cached;
    return 1 if !defined $cached->{app_version};
    for my $feld (qw(message_center_uuid rooms firmware)) {
        return 1 if !exists $cached->{$feld};
    }
    return $cached->{app_version} ne $app_version ? 1 : 0;
}

sub remember_identity {
    my ($cache, $msno, $ident, $now) = @_;
    if (ref($ident) eq 'HASH' && $ident->{ok}) {
        my %e = %$ident;
        delete $e{ok};
        $cache->{$msno} = \%e;
        return 1;
    }
    my $e = ref($cache->{$msno}) eq 'HASH' ? $cache->{$msno} : {};
    $e->{ident_retry_at} = int($now) + IDENT_RETRY;
    $cache->{$msno} = $e;
    return 0;
}

sub devicetree_due {
    my ($cached, $now, $interval, $every) = @_;
    $interval = 300 if !$interval || $interval < 1;
    $every    = 3   if !$every    || $every < 1;
    my $next = ref($cached) eq 'HASH' ? $cached->{devtree_next} : undef;
    return 1 if !defined $next;
    return 1 if $next > $now + $interval * $every * 5;
    return $next <= $now ? 1 : 0;
}

sub remember_devicetree {
    my ($cache, $msno, $now, $interval, $every) = @_;
    $interval = 300 if !$interval || $interval < 1;
    $every    = 3   if !$every    || $every < 1;
    my $e = ref($cache->{$msno}) eq 'HASH' ? $cache->{$msno} : {};
    $e->{devtree_next} = int($now) + $interval * $every;
    $cache->{$msno} = $e;
    return;
}

sub miniserver_record {
    my ($ms, $msno, $metrics, $cache, $now, %opt) = @_;
    my $will_inventar = exists $opt{inventory} ? ($opt{inventory} ? 1 : 0) : 1;
    my $sagen = $opt{sagen} || sub { };
    $cache = {} if ref($cache) ne 'HASH';

    my $cached = ref($cache->{$msno}) eq 'HASH' ? $cache->{$msno} : {};
    my %rec = (msno => $msno + 0, v => {});
    my @missing;
    my $reachable;

    my $fehlt_alle = ref($opt{fehlt}) eq 'HASH' ? $opt{fehlt} : undef;
    my $fehlt = $fehlt_alle && ref($fehlt_alle->{$msno}) eq 'HASH' ? $fehlt_alle->{$msno} : {};
    my %skip = map { $_ => 1 } grep { $fehlt->{$_} > $now } keys %$fehlt;

    if ($metrics && @$metrics) {
        my $t0 = Time::HiRes::time();
        my ($values, $miss, $ok, $neu) = FM::Miniserver::collect(
            $ms, $metrics, device_monitor_uuid => $cached->{device_monitor_uuid},
            skip => \%skip, sagen => $sagen);
        $rec{rt_ms} = int((Time::HiRes::time() - $t0) * 1000);
        $rec{v}     = $values;
        @missing    = @$miss;
        $reachable  = $ok;

        if ($fehlt_alle) {
            my %neu = map { $_ => 1 } grep { !$NIE_MERKEN{$_} } @{ $neu || [] };
            for my $k (keys %$values) { delete $fehlt->{$k}; }
            for my $k (keys %neu)     { $fehlt->{$k} = int($now) + FEHLT_PRUEFUNG; }
            for my $k (keys %$fehlt)  { delete $fehlt->{$k} if $fehlt->{$k} <= $now && !$neu{$k}; }
            if (%$fehlt) { $fehlt_alle->{$msno} = $fehlt; }
            else         { delete $fehlt_alle->{$msno}; }
        }
    }

    if ($will_inventar) {
        my ($vok, $vbody) = FM::Miniserver::get(
            FM::Miniserver::base_url($ms), $ms->{Credentials_RAW},
            '/jdev/sps/LoxAPPversion3', $sagen);
        my $app_version = $vok ? FM::Miniserver::ll_value($vbody) : undef;
        $reachable = ($vok ? 1 : 0) if !defined $reachable;

        if (identity_due($cached, $app_version, $now)) {
            my $ident = FM::Miniserver::identity($ms, $app_version, $sagen);
            remember_identity($cache, $msno, $ident, $now);
            $cached = ref($cache->{$msno}) eq 'HASH' ? $cache->{$msno} : {};
        }
    }

    my $will_devtree = $opt{devicetree} ? 1 : 0;
    my $devtree_every = $opt{devicetree_every};
    if (FM::Miniserver::ist_gen1($cached->{mstype})) {
        my $iv = ($opt{devicetree_interval} && $opt{devicetree_interval} >= 1) ? $opt{devicetree_interval} : 300;
        my $min_every = int((DEVTREE_GEN1_MIN + $iv - 1) / $iv);
        $devtree_every = $min_every if !$devtree_every || $devtree_every < $min_every;
    }
    if ($will_devtree && devicetree_due($cached, $now, $opt{devicetree_interval}, $devtree_every)) {
        my $baum = FM::Miniserver::devicetree($ms, $sagen);
        remember_devicetree($cache, $msno, $now, $opt{devicetree_interval}, $devtree_every);
        if ($baum && $baum->{ok}) {
            $rec{devtree} = { tag => $baum->{tag}, attrs => $baum->{attrs}, children => $baum->{children} };
        }
    }

    $rec{reachable} = defined $reachable ? $reachable : 0;
    $rec{ident} = {
        name      => $cached->{name},
        serial    => $cached->{serial},
        mstype    => $cached->{mstype},
        firmware  => $cached->{firmware},
        project   => $cached->{project},
        controls  => $cached->{controls},
        location  => $cached->{location},
        latitude  => $cached->{latitude},
        longitude => $cached->{longitude},
    };
    return (\%rec, \@missing);
}

sub ms_message_sev {
    my ($severity) = @_;
    my $n = (defined $severity && $severity =~ /\A-?[0-9]+\z/) ? $severity + 0 : 0;
    return 'error' if $n >= 3;
    return 'warn'  if $n == 2;
    return 'info';
}

sub ms_message_text {
    my ($entry) = @_;
    my $title    = $entry->{title};
    my $affected = $entry->{affectedName};
    if (defined $title && $title ne '') {
        return (defined $affected && $affected ne '') ? "$title: $affected" : $title;
    }
    my $desc = $entry->{desc};
    return (defined $desc && $desc ne '') ? $desc : 'Systemmeldung ohne Titel';
}

use constant SRC_NOK => 'ms_message';
use constant SRC_OK  => 'ms_message_ok';

sub ms_message_events {
    my ($entries, $seen, $rooms) = @_;
    $entries = [] if ref($entries) ne 'ARRAY';
    $seen    = {}  if ref($seen)    ne 'HASH';
    $rooms   = {}  if ref($rooms)  ne 'HASH';

    my @events;
    my %neu;
    for my $e (@$entries) {
        next if ref($e) ne 'HASH';
        my $uuid = $e->{entryUuid};
        next if !defined $uuid || $uuid eq '';
        my $titel = ms_message_text($e);
        $neu{$uuid} = { titel => $titel };
        my $room_uuid = $e->{roomUuid};
        my $room = (defined $room_uuid && exists $rooms->{$room_uuid}) ? $rooms->{$room_uuid} : undef;
        my $detail = (defined $e->{desc} && $e->{desc} ne '') ? $e->{desc} : undef;
        push @events, { src => SRC_NOK, sev => ms_message_sev($e->{severity}), msg => $titel,
                         room => $room, detail => $detail };
    }

    for my $uuid (sort keys %$seen) {
        next if exists $neu{$uuid};
        my $titel = (ref($seen->{$uuid}) eq 'HASH') ? $seen->{$uuid}{titel} : undef;
        my $msg = (defined $titel && $titel ne '') ? $titel : ms_message_text({});
        push @events, { src => SRC_OK, sev => 'info', msg => $msg, room => undef, detail => undef };
    }

    return (\@events, \%neu);
}

sub build_record {
    my ($now, $lb, $ms, $lb_name, $lb_version, $lb_id) = @_;
    my %rec = (
        ts => $now + 0,
        lb => ($lb && ref($lb) eq 'HASH' ? $lb : {}),
    );
    $rec{ms} = $ms if ref($ms) eq 'ARRAY';
    $rec{lb_name}    = $lb_name    if defined $lb_name    && $lb_name    ne '';
    $rec{lb_version} = $lb_version if defined $lb_version && $lb_version ne '';
    $rec{lb_id}      = substr($lb_id, 0, 12) if defined $lb_id && $lb_id ne '';
    return \%rec;
}

1;

