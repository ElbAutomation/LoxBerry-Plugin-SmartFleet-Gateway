# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Config;

use strict;
use warnings;
use JSON::PP;
use File::Spec;
use File::Path qw(make_path);
use FM::B64 qw(b64u_decode);

sub _file { my ($dir) = @_; return File::Spec->catfile($dir, 'agent.json'); }
sub keyfile { my ($dir) = @_; return File::Spec->catfile($dir, 'site.key'); }

sub load {
    my ($dir) = @_;
    my $f = _file($dir);
    return {} if !-e $f;
    open my $fh, '<:raw', $f or die "FM::Config: $f nicht lesbar: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    return {} if !defined $raw || $raw eq '';
    my $c = eval { JSON::PP->new->decode($raw) };
    die "FM::Config: $f ist kein gueltiges JSON\n" if !$c;
    require FM::Http;
    FM::Http::verify_ssl(!$c->{lb_server});
    return $c;
}

sub save {
    my ($dir, $cfg) = @_;
    make_path($dir) if !-d $dir;
    my $f = _file($dir);
    my $tmp = "$f.new.$$";
    open my $fh, '>:raw', $tmp or die "FM::Config: $tmp nicht schreibbar: $!\n";
    print {$fh} JSON::PP->new->canonical->pretty->encode($cfg);
    close $fh or die "FM::Config: $tmp nicht geschlossen: $!\n";
    chmod(0600, $tmp) == 1 or die "FM::Config: Rechte von $tmp nicht setzbar: $!\n";
    rename $tmp, $f or die "FM::Config: $tmp nicht nach $f verschiebbar: $!\n";
    return 1;
}

sub parse_code {
    my ($code) = @_;
    die "FM::Config: leerer Bereitstellungscode\n" if !defined $code || $code eq '';
    $code =~ s/\s+//g;
    die "FM::Config: Bereitstellungscode beginnt nicht mit FM1-\n" if $code !~ s/^FM1-//;
    my $json = eval { b64u_decode($code) };
    die "FM::Config: Bereitstellungscode ist kein gueltiges base64url\n" if !defined $json;
    my $p = eval { JSON::PP->new->decode($json) };
    die "FM::Config: Bereitstellungscode enthaelt kein gueltiges JSON\n" if !$p;
    for my $f (qw(u t f)) {
        die "FM::Config: Bereitstellungscode ist unvollstaendig (Feld $f fehlt)\n"
            if !defined $p->{$f} || $p->{$f} eq '';
    }
    die "FM::Config: nur https ist zulaessig\n"
        if $p->{u} !~ m{^https://} && !$ENV{FM_ALLOW_HTTP};
    return { url => $p->{u}, token => $p->{t}, fp => $p->{f}, lb => ($p->{l} ? 1 : 0) };
}

sub path_prefix {
    my ($url) = @_;
    return '' if !defined $url || $url eq '';
    my ($path) = $url =~ m{^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+(/.*)?$};
    return '' if !defined $path || $path eq '';
    $path =~ s{/+$}{};
    return $path;
}

1;

