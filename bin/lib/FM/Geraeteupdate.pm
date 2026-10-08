# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Geraeteupdate;
use strict;
use warnings;
use File::Spec;
use JSON::PP ();

sub soll_stufe {
    my ($desired) = @_;
    return undef if ref($desired) ne 'HASH' || ref($desired->{update}) ne 'HASH';
    return $desired->{update}{auto} ? 3 : 2;
}

sub release_cfg {
    my ($text) = @_;
    return undef if !defined $text || $text !~ /^\s*\[AUTOUPDATE\]/m;
    my ($v) = $text =~ /^\s*VERSION\s*=\s*(\S+)/m;
    my ($a) = $text =~ /^\s*ARCHIVEURL\s*=\s*(\S+)/m;
    return undef if !$v || !$a;
    return { version => $v, archiv => $a };
}

sub vergleich {
    my ($x, $y) = @_;
    my @a = map { /^(\d+)/ ? $1 : 0 } split /\./, (defined $x ? $x : '');
    my @b = map { /^(\d+)/ ? $1 : 0 } split /\./, (defined $y ? $y : '');
    for my $i (0 .. 2) {
        my $c = ($a[$i] || 0) <=> ($b[$i] || 0);
        return $c if $c;
    }
    return 0;
}

sub stufe_setzen {
    my (%a) = @_;
    my $soll = "$a{soll}";
    my $ok = eval { require LoxBerry::System::PluginDB; 1 };
    return (0, undef, $soll) if !$ok || !$a{md5};
    my %p = (md5 => $a{md5});
    $p{_dbfile} = $a{_dbfile} if $a{_dbfile};
    my $plugin = LoxBerry::System::PluginDB->plugin(%p);
    return (0, undef, $soll) if !$plugin;
    my $alt = $plugin->{autoupdate};
    return (0, $alt, $soll) if defined $alt && "$alt" eq $soll;
    $plugin->{autoupdate} = $soll;
    $plugin->save;
    return (1, $alt, $soll);
}

sub update_starten {
    my (%a) = @_;
    my $r = $a{release} or return (0, 'keine release.cfg');
    return (1, 'aktuell') if vergleich($r->{version}, $a{laufend}) <= 0;
    my ($st, $zip) = $a{holen}->($r->{archiv});
    return (0, 'Archiv nicht ladbar (HTTP ' . (defined $st ? $st : '-') . ')')
        if !defined $st || $st != 200 || !defined $zip || $zip eq '';
    my $datei = File::Spec->catfile($a{temp}, 'smartfleet-update.zip');
    open my $fh, '>:raw', $datei or return (0, 'Archiv nicht ablegbar');
    print {$fh} $zip;
    close $fh or return (0, 'Archiv nicht ablegbar');
    $a{starter}->($datei, $a{md5}) or return (0, 'plugininstall.pl nicht gestartet');
    return (1, "gestartet ($r->{version})");
}

sub eigene {
    my ($ordner) = @_;
    my $ok = eval { require LoxBerry::System; 1 };
    return undef if !$ok || !defined &LoxBerry::System::plugindata;
    no warnings 'once';
    $ordner = $LoxBerry::System::lbpplugindir if !defined $ordner;
    return undef if !defined $ordner;
    my $d = eval { LoxBerry::System::plugindata($ordner) };
    return undef if ref($d) ne 'HASH' || !$d->{PLUGINDB_MD5_CHECKSUM};
    return {
        md5        => $d->{PLUGINDB_MD5_CHECKSUM},
        version    => $d->{PLUGINDB_VERSION},
        stufe      => $d->{PLUGINDB_AUTOUPDATE},
        releasecfg => $d->{PLUGINDB_RELEASECFG},
    };
}

sub verfuegbar_pruefen {
    my ($rt, $now, $url, $holen) = @_;
    return undef if !defined $url || $url eq '';
    my $f = File::Spec->catfile($rt, 'release_check.json');
    my $stand = {};
    if (open my $fh, '<', $f) {
        local $/;
        $stand = eval { JSON::PP->new->decode(scalar <$fh>) } || {};
        close $fh;
    }
    return $stand->{version} if $stand->{zeit} && $now - $stand->{zeit} < 86400;
    my ($st, $text) = $holen->($url);
    my $r = (defined $st && $st == 200) ? release_cfg($text) : undef;
    $stand = { zeit => $now + 0, version => $r ? $r->{version} : $stand->{version} };
    if (open my $fh, '>', $f) {
        print {$fh} JSON::PP->new->encode($stand);
        close $fh;
    }
    return $stand->{version};
}

1;

