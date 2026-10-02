#!/usr/bin/perl
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use Getopt::Long;
use JSON::PP;
use Digest::SHA qw(sha256);
use FM::B64 qw(b64u_encode b64u_decode);
use FM::Config;
use FM::Loxlog;
use FM::Keys;
use FM::Cert;
use FM::Http;
use FM::Roots;

sub _sitename {
    my ($cfg) = @_;
    return $cfg->{name} if $cfg->{name};
    my $name = eval {
        require LoxBerry::System;
        LoxBerry::System->import(qw(lbhostname));
        return lbhostname();
    };
    if (!defined $name || $name eq '') {
        $name = `hostname`;
        chomp $name if defined $name;
    }
    return (defined $name && $name ne '') ? $name : 'LoxBerry';
}

my ($dir, $code, $force);
GetOptions('dir=s' => \$dir, 'code=s' => \$code, 'force' => \$force)
    or die "Aufruf: fm_enroll.pl --dir <konfigdir> --code <bereitstellungscode> [--force]\n";
die "fm_enroll: --dir fehlt\n"  if !$dir;
die "fm_enroll: --code fehlt\n" if !$code;

my $log = FM::Loxlog::start(
    'connect', 'Verbindung zum Server wird aufgebaut',
    force_debug => 1,
);
sub sag {
    my $text = "@_";
    print "$text\n";
    FM::Loxlog::inf($log, $text);
}
sub diag {
    FM::Loxlog::deb($log, "@_");
}

sub stirb {
    my ($text) = @_;
    FM::Loxlog::err($log, $text);
    FM::Loxlog::ende($log);
    die "$text\n";
}

sub kurz {
    my ($geheimnis) = @_;
    return '(leer)' if !defined $geheimnis || $geheimnis eq '';
    return length($geheimnis) <= 12
        ? substr($geheimnis, 0, 4) . '...'
        : substr($geheimnis, 0, 8) . '...(' . length($geheimnis) . ' Zeichen)';
}

sub versuchen {
    my ($code) = @_;
    my @erg = eval { $code->() };
    if ($@) {
        (my $grund = $@) =~ s/\s+\z//;
        stirb($grund);
    }
    return wantarray ? @erg : $erg[0];
}

my $cfg = FM::Config::load($dir);
diag("Konfigurationsverzeichnis: $dir");
if ($cfg->{site} && !$force) {
    stirb("fm_enroll: dieser Standort ist bereits angemeldet ($cfg->{site}).\n"
      . "Mit --force wird die Anmeldung ersetzt - der alte Standort bleibt auf dem\n"
      . "Server bestehen und muss dort geloescht werden.");
}

my $p = eval { FM::Config::parse_code($code) };
if (!$p) {
    (my $grund = $@) =~ s/\s+\z//;
    stirb($grund);
}
diag("Code entschluesselt - Serveradresse: $p->{url}, Fingerprint: " . kurz($p->{fp})
     . ", Token: " . kurz($p->{token}));
sag("Server: $p->{url}");
FM::Http::verify_ssl(!$p->{lb});
sag("Server laeuft auf einem LoxBerry (Testinstallation) - Zertifikat wird nicht geprueft.") if $p->{lb};

my $keyfile = FM::Config::keyfile($dir);
if (-s $keyfile && !$force && eval { FM::Keys::public_raw($keyfile); 1 }) {
    sag("Vorhandenen Schluessel wiederverwenden.");
} else {
    versuchen(sub { FM::Keys::generate($keyfile) });
    sag("Neues Schluesselpaar erzeugt.");
}
my $pub = FM::Keys::public_raw($keyfile);
diag("Oeffentlicher Schluessel (b64u): " . b64u_encode($pub));

diag("GET $p->{url}/api/hello.php");
my ($st, $body) = FM::Http::get("$p->{url}/api/hello.php");
diag("hello: HTTP $st, " . length($body // '') . " Bytes Antwort");
stirb("fm_enroll: hello antwortet mit HTTP $st") if $st != 200;
my $hello = eval { JSON::PP->new->decode($body) };
stirb("fm_enroll: hello liefert kein gueltiges JSON") if !$hello;

my $srv_leaf = eval {
    FM::Cert::verify_chain($hello->{chain}, expect_typ => 'srv', roots => FM::Roots::roots());
};
stirb("fm_enroll: die Serverkette ist ungueltig: $@") if !$srv_leaf;
diag("Serverkette gueltig - Blatt: $srv_leaf->{sub}");

my ($srv_cert, $ca_cert) = split /~/, $hello->{chain}, 2;
my $ca_payload = FM::Cert::decode($ca_cert);
my $fp = b64u_encode(sha256(b64u_decode($ca_payload->{pub})));
diag("Partner-CA aus hello: $ca_payload->{sub}, Fingerprint " . kurz($fp));
if ($fp ne $p->{fp}) {
    stirb("fm_enroll: der Fingerprint der Partner-CA passt nicht zum Bereitstellungscode.\n"
      . "  erwartet: $p->{fp}\n  gefunden: $fp\n"
      . "Abbruch, ohne dass der Token gesendet wurde.");
}
sag("Server geprueft: $srv_leaf->{sub} unter $ca_payload->{sub}");

my $pub_b64 = b64u_encode($pub);
my $ts      = time();
my $selfsig = b64u_encode(versuchen(sub {
    FM::Keys::sign($keyfile, "enroll\n$p->{token}\n$pub_b64\n$ts")
}));

my $name = _sitename($cfg);
diag("Standortname: $name, Zeitstempel: $ts");

my $req = JSON::PP->new->canonical->encode({
    v => 1, token => $p->{token}, pub => $pub_b64,
    name => $name, ts => $ts, selfsig => $selfsig,
});
diag("POST $p->{url}/api/enroll.php (token im Log gekuerzt: " . kurz($p->{token}) . ")");
my ($st2, $body2) = FM::Http::post_json("$p->{url}/api/enroll.php", $req);
diag("enroll: HTTP $st2, Antwort: " . (defined $body2 ? substr($body2, 0, 500) : '(leer)'));
stirb("fm_enroll: enroll antwortet mit HTTP $st2: $body2") if $st2 != 200;
my $ans = eval { JSON::PP->new->decode($body2) };
stirb("fm_enroll: enroll liefert kein gueltiges JSON") if !$ans;
stirb("fm_enroll: Server meldet Zustand '$ans->{status}'") if ($ans->{status} || '') ne 'issued';

my $leaf = eval {
    FM::Cert::verify_chain($ans->{chain}, expect_typ => 'site',
                           expect_sub => $ans->{site}, roots => FM::Roots::roots());
};
stirb("fm_enroll: das ausgestellte Zertifikat ist ungueltig: $@") if !$leaf;
diag("Ausgestelltes Zertifikat gueltig - Standort: $ans->{site}, gueltig bis "
     . scalar(gmtime($leaf->{exp})) . " UTC");
stirb("fm_enroll: das Zertifikat traegt einen fremden Schluessel - Abbruch")
    if b64u_decode($leaf->{pub}) ne $pub;

$name = $ans->{name} if defined $ans->{name} && $ans->{name} ne '';

my $partner_name = (defined $ans->{partner_name} && $ans->{partner_name} ne '')
    ? $ans->{partner_name} : $ca_payload->{sub};

my %alt = %$cfg;
delete $alt{lb_server};
versuchen(sub { FM::Config::save($dir, {
    %alt,
    ($p->{lb} ? (lb_server => 1) : ()),
    site        => $ans->{site},
    name        => $name,
    server      => $p->{url},
    path_prefix => FM::Config::path_prefix($p->{url}),
    chain       => $ans->{chain},
    srv_pub     => $srv_leaf->{pub},
    partner     => $ca_payload->{sub},
    partner_name => $partner_name,
    enrolled_at => time(),
}) });

sag("Angemeldet als $ans->{site}");
sag("Gueltig bis " . scalar(gmtime($leaf->{exp})) . " UTC");
FM::Loxlog::ok($log, 'Verbindung hergestellt');
FM::Loxlog::ende($log);
exit 0;

