# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Catalog;

use strict;
use warnings;

my @MINISERVER = (
    { key => 'sys_cpu',          path => '/jdev/sys/cpu',         pick => 'number',    group => 'SYSTEM', hist => 1, default => 1 },
    { key => 'sys_heap_used',    path => '/jdev/sys/heap',        pick => 'heapused',  group => 'SYSTEM', hist => 1, default => 1 },
    { key => 'sys_heap_total',   path => '/jdev/sys/heap',        pick => 'heaptotal', group => 'SYSTEM', hist => 0, default => 1 },
    { key => 'sys_numtasks',     path => '/jdev/sys/numtasks',    pick => 'number',    group => 'SYSTEM', hist => 0, default => 0 },
    { key => 'sys_check',        path => '/jdev/sys/check',       pick => 'number',    group => 'SYSTEM', hist => 0, default => 0 },
    { key => 'sys_temperature',  path => '/jdev/sys/temperature', pick => 'tempcpu',   group => 'SYSTEM', hist => 1, default => 1 },
    { key => 'sys_temperature_stm32', path => '/jdev/sys/temperature', pick => 'tempstm32', group => 'SYSTEM', hist => 1, default => 1 },

    { key => 'sps_state',        path => '/jdev/sps/state',       pick => 'number',    group => 'SPS',    hist => 0, default => 0 },
    { key => 'sps_frequency',    path => '/jdev/sps/status',      pick => 'spsfreq',   group => 'SPS',    hist => 0, default => 0 },

    { key => 'bus_packetssent',     path => '/jdev/bus/packetssent',     pick => 'number', group => 'BUS', hist => 0, default => 0 },
    { key => 'bus_packetsreceived', path => '/jdev/bus/packetsreceived', pick => 'number', group => 'BUS', hist => 0, default => 0 },
    { key => 'bus_receiveerrors',   path => '/jdev/bus/receiveerrors',   pick => 'number', group => 'BUS', hist => 1, default => 1 },
    { key => 'bus_frameerrors',     path => '/jdev/bus/frameerrors',     pick => 'number', group => 'BUS', hist => 1, default => 1 },
    { key => 'bus_overruns',        path => '/jdev/bus/overruns',        pick => 'number', group => 'BUS', hist => 1, default => 1 },
    { key => 'bus_parityerrors',    path => '/jdev/bus/parityerrors',    pick => 'number', group => 'BUS', hist => 1, default => 1 },

    { key => 'lan_txp', path => '/jdev/lan/txp', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_txe', path => '/jdev/lan/txe', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_txc', path => '/jdev/lan/txc', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_exh', path => '/jdev/lan/exh', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_txu', path => '/jdev/lan/txu', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_rxp', path => '/jdev/lan/rxp', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_eof', path => '/jdev/lan/eof', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_rxo', path => '/jdev/lan/rxo', pick => 'number', group => 'LAN', hist => 0, default => 0 },
    { key => 'lan_nob', path => '/jdev/lan/nob', pick => 'number', group => 'LAN', hist => 0, default => 0 },

    { key => 'device_monitor', path => 'DEVICEMONITOR', pick => 'number', group => 'SYSTEM', hist => 1, default => 0 },
);

my @LOXBERRY = (
    { key => 'lb_load_1',            path => ['Load', 'now'],                              pick => 'number',  group => 'SYSTEM', hist => 1, default => 1 },
    { key => 'lb_load_5',            path => ['Load', '5min'],                             pick => 'number',  group => 'SYSTEM', hist => 0, default => 1 },
    { key => 'lb_load_15',           path => ['Load', '15min'],                            pick => 'number',  group => 'SYSTEM', hist => 0, default => 1 },
    { key => 'lb_cpu_usage',         path => ['cpuUsage'],                                 pick => 'number',  group => 'SYSTEM', hist => 1, default => 1 },
    { key => 'lb_booted',            path => ['UpTime', 'bootedTimestamp'],                pick => 'number',  group => 'SYSTEM', hist => 0, default => 1 },
    { key => 'lb_ram_total',         path => ['RAM', 'total'],                             pick => 'number',  group => 'RAM',    hist => 0, default => 0 },
    { key => 'lb_ram_free',          path => ['RAM', 'free'],                              pick => 'number',  group => 'RAM',    hist => 1, default => 1 },
    { key => 'lb_ram_used_percent',  path => ['RAM'],                                      pick => 'usedpct', group => 'RAM',    hist => 1, default => 1 },
    { key => 'lb_swap_used_percent', path => ['RAM'],                                      pick => 'swappct', group => 'RAM',    hist => 1, default => 1 },
    { key => 'lb_proc_total',        path => ['processStats', 'proc_total'],               pick => 'number',  group => 'PROC',   hist => 0, default => 1 },
    { key => 'lb_proc_zombie',       path => ['processStats', 'totals', 'zombie'],         pick => 'number',  group => 'PROC',   hist => 1, default => 1 },
    { key => 'lb_disk_root_percent', path => ['/'],                                        pick => 'mountpct',group => 'DISK',   hist => 1, default => 1 },
    { key => 'lb_temp_cpu',          path => ['Temps'],                                    pick => 'firsttemp', group => 'SYSTEM', hist => 1, default => 1 },
);

sub miniserver_all { return map { { %$_ } } @MINISERVER; }
sub loxberry_all {
    return map {
        my %e = %$_;
        $e{path} = [ @{ $_->{path} } ] if ref($_->{path}) eq 'ARRAY';
        \%e;
    } @LOXBERRY;
}

sub select {
    my ($all, $wanted) = @_;
    if (!defined $wanted || ref($wanted) ne 'ARRAY') {
        return [ grep { $_->{default} } @$all ];
    }
    return [] if !@$wanted;
    my %want = map { defined $_ ? ($_ => 1) : () } @$wanted;
    return [ grep { $want{ $_->{key} } } @$all ];
}

1;

