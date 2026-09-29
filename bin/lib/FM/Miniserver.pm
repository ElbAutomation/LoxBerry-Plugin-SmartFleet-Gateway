# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Miniserver;

use strict;
use warnings;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);
use JSON::PP;

my $UA;

sub _ua {
    return $UA if $UA;
    $UA = HTTP::Tiny->new(
        agent      => 'fm-agent/1.0',
        timeout    => 10,
        verify_SSL => 0,
    );
    return $UA;
}

sub base_url {
    my ($ms) = @_;
    my $transport = $ms->{Transport} || 'http';
    my $port = ($ms->{PreferHttps} && $ms->{PortHttps})
        ? $ms->{PortHttps}
        : ($ms->{Port} || ($transport eq 'https' ? 443 : 80));
    return $transport . '://' . $ms->{IPAddress} . ':' . $port;
}

my %WAHR = map { $_ => 1 } qw(true yes on enabled enable 1 check checked select selected);

sub ist_lokal {
    my ($ms) = @_;
    my $v = $ms->{UseCloudDNS};
    return 1 if !defined $v || $v eq '';
    $v =~ s/^\s+|\s+$//g;
    return $WAHR{lc $v} ? 0 : 1;
}

sub backup_passwort {
    my ($ms) = @_;
    my $cred = $ms->{Credentials_RAW};
    return undef if !defined $cred || $cred eq '';
    my ($user, $pass) = split(/:/, $cred, 2);
    return (defined $pass && $pass ne '') ? $pass : undef;
}

sub ip {
    my ($ms, $sagen) = @_;
    my ($ok, $body) = get(base_url($ms), $ms->{Credentials_RAW}, '/jdev/cfg/ip', $sagen);
    return undef if !$ok;
    my $v = ll_value($body);
    return (defined $v && $v ne '') ? $v : undef;
}

sub firmware_version {
    my ($ms, $sagen) = @_;
    my ($ok, $body) = get(base_url($ms), $ms->{Credentials_RAW}, '/jdev/cfg/version', $sagen);
    return undef if !$ok;
    my $v = ll_value($body);
    return (defined $v && $v ne '') ? $v : undef;
}

sub loxname {
    my ($ip, $version, $now) = @_;
    return undef if !defined $ip || $ip eq '';
    return undef if !defined $version
        || $version !~ /\A([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\z/;
    my $versionKompakt = sprintf('%02d%02d%02d%02d', $1, $2, $3, $4);

    my @l = localtime($now);
    my $lokal = sprintf('%04d%02d%02d%02d%02d%02d',
                        $l[5] + 1900, $l[4] + 1, $l[3], $l[2], $l[1], $l[0]);

    return "Backup_${ip}_${lokal}_${versionKompakt}";
}

sub ll_value {
    my ($raw) = @_;
    return undef if !defined $raw || $raw eq '';
    return $1 if $raw =~ /"value"\s*:\s*"([^"]*)"/;
    return $1 if $raw =~ /"value"\s*:\s*([0-9.eE+-]+)/;
    return undef;
}

sub parse_value {
    my ($pick, $raw) = @_;
    return undef if !defined $pick || !defined $raw;

    if ($pick eq 'number') {
        return $raw =~ /(-?[0-9]+(?:\.[0-9]+)?)/ ? $1 + 0 : undef;
    }
    if ($pick eq 'heapused') {
        return $raw =~ m{^\s*(-?[0-9]+(?:\.[0-9]+)?)\s*/} ? $1 + 0 : undef;
    }
    if ($pick eq 'heaptotal') {
        return $raw =~ m{/\s*(-?[0-9]+(?:\.[0-9]+)?)} ? $1 + 0 : undef;
    }
    if ($pick eq 'spsfreq') {
        return $raw =~ m{([0-9]+(?:\.[0-9]+)?)\s*/\s*sec} ? $1 + 0 : undef;
    }
    if ($pick eq 'tempcpu') {
        return $raw =~ /(?<!STM32 )Cpu Temperature:\s*(-?[0-9]+(?:\.[0-9]+)?)/ ? $1 + 0 : undef;
    }
    if ($pick eq 'tempstm32') {
        return $raw =~ /STM32\s*Cpu Temperature:\s*(-?[0-9]+(?:\.[0-9]+)?)/ ? $1 + 0 : undef;
    }
    return undef;
}

sub get {
    my ($base, $cred, $path, $sagen) = @_;
    $sagen ||= sub { };
    my %headers;
    if (defined $cred && $cred ne '') {
        my $b = encode_base64($cred, '');
        $headers{Authorization} = "Basic $b";
    }
    $sagen->("-> GET $base$path" . ($headers{Authorization} ? ' (Basic-Auth)' : ''));
    my $r = _ua()->get($base . $path, { headers => \%headers });
    $sagen->('<- ' . $r->{status} . ($r->{success} && defined $r->{content} ? "\n$r->{content}" : ''));
    return (0, undef, $r->{status}) if !$r->{success};
    return (1, $r->{content}, $r->{status});
}

sub ist_gen1 {
    my ($mstype) = @_;
    return (defined $mstype && $mstype =~ /\A[01]\z/) ? 1 : 0;
}

sub collect {
    my ($ms, $metrics, %opt) = @_;
    my $base  = base_url($ms);
    my $cred  = $ms->{Credentials_RAW};
    my $dm    = $opt{device_monitor_uuid};
    my $sagen = $opt{sagen} || sub { };
    my $skip = ref($opt{skip}) eq 'HASH' ? $opt{skip} : {};

    my (%values, @missing, @neu_fehlend);
    my $antworten = 0;
    my %antwort;

    for my $m (@$metrics) {
        next if $skip->{ $m->{key} };
        my $path = $m->{path};
        if ($path eq 'DEVICEMONITOR') {
            if (!$dm) { push @missing, $m->{key}; next; }
            $path = "/jdev/sps/io/$dm/all";
        }
        if (!$antwort{$path}) {
            my ($ok, $body, $status) = get($base, $cred, $path, $sagen);
            $antwort{$path} = [ $ok, $body, $status ];
            $antworten++ if $ok;
        }
        my ($ok, $body, $status) = @{ $antwort{$path} };
        if (!$ok) {
            push @missing, $m->{key};
            push @neu_fehlend, $m->{key} if defined $status && ($status == 404 || $status == 400);
            next;
        }
        my $will_roh = ($m->{pick} eq 'tempcpu' || $m->{pick} eq 'tempstm32');
        my $v = parse_value($m->{pick}, $will_roh ? $body : ll_value($body));
        if (defined $v) { $values{ $m->{key} } = $v; }
        else {
            push @missing, $m->{key};
            push @neu_fehlend, $m->{key};
        }
    }

    return (\%values, \@missing, ($antworten > 0 ? 1 : 0), \@neu_fehlend);
}

sub identity {
    my ($ms, $app_version, $sagen) = @_;
    my $base = base_url($ms);
    my $cred = $ms->{Credentials_RAW};

    my ($ok, $body) = get($base, $cred, '/data/LoxAPP3.json', $sagen);
    return { ok => 0, app_version => $app_version } if !$ok;

    my $d = eval { JSON::PP->new->utf8->decode($body) };
    return { ok => 0, app_version => $app_version } if !$d || ref($d->{msInfo}) ne 'HASH';

    my $i = $d->{msInfo};
    my $firmware = firmware_version($ms, $sagen);
    return {
        ok                  => 1,
        app_version         => $app_version,
        serial              => $i->{serialNr},
        mstype              => $i->{miniserverType},
        firmware            => $firmware,
        name                => $i->{msName},
        project             => $i->{projectName},
        device_monitor_uuid => $i->{deviceMonitor},
        controls            => (ref $d->{controls} eq 'HASH' ? scalar(keys %{ $d->{controls} }) : 0),
        location            => $i->{location},
        latitude            => $i->{latitude},
        longitude           => $i->{longitude},
        message_center_uuid => (ref $d->{messageCenter} eq 'HASH')
            ? (sort keys %{ $d->{messageCenter} })[0] : undef,
        rooms => (ref $d->{rooms} eq 'HASH')
            ? { map { $_ => $d->{rooms}{$_}{name} } keys %{ $d->{rooms} } }
            : {},
    };
}

sub messages {
    my ($ms, $mc_uuid, $sagen) = @_;
    return () if !defined $mc_uuid || $mc_uuid eq '';

    my ($ok, $body) = get(base_url($ms), $ms->{Credentials_RAW},
        "/jdev/sps/io/$mc_uuid/getEntries/2", $sagen);
    return () if !$ok;

    my $outer = eval { JSON::PP->new->utf8->decode($body) };
    return () if !$outer || ref($outer->{LL}) ne 'HASH';
    my $value = $outer->{LL}{value};
    return () if !defined $value || $value eq '';

    my $inner = eval { JSON::PP->new->decode($value) };
    return () if !$inner || ref($inner->{entries}) ne 'ARRAY';

    return grep { !$_->{isHistoric} } @{ $inner->{entries} };
}

sub _xml_node {
    my ($el) = @_;
    my %attrs;
    for my $a ($el->attributes) {
        $attrs{$a->nodeName} = $a->value;
    }
    my @children;
    for my $c ($el->childNodes) {
        next if !$c->isa('XML::LibXML::Element');
        push @children, _xml_node($c);
    }
    return { tag => $el->nodeName, attrs => \%attrs, children => \@children };
}

sub parse_status_xml {
    my ($raw) = @_;
    return undef if !defined $raw || $raw eq '';
    my $doc = eval { XML::LibXML->load_xml(string => $raw) };
    return undef if !$doc;
    return _xml_node($doc->documentElement);
}

sub devicetree {
    my ($ms, $sagen) = @_;
    $sagen ||= sub { };
    my $have = eval { require XML::LibXML; 1 };
    if (!$have) {
        $sagen->('XML::LibXML fehlt - Geraetebaum wird uebersprungen');
        return { ok => 0 };
    }
    my ($ok, $body) = get(base_url($ms), $ms->{Credentials_RAW}, '/data/status', $sagen);
    if (!$ok) {
        ($ok, $body) = get(base_url($ms), $ms->{Credentials_RAW}, '/status', $sagen);
    }
    return { ok => 0 } if !$ok;
    my $baum = parse_status_xml($body);
    return { ok => 0 } if !$baum;
    return { ok => 1, tag => $baum->{tag}, attrs => $baum->{attrs}, children => $baum->{children} };
}

1;

