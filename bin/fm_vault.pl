#!/usr/bin/perl
# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;
use Getopt::Long;

use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";

use FM::Config;
use FM::Miniserver;
use FM::Settings;
use FM::Vault;

my ($dir, $verbose);
GetOptions('dir=s' => \$dir, 'verbose' => \$verbose)
    or die "Aufruf: fm_vault.pl --dir <konfigdir> [--verbose]\n";
die "fm_vault: --dir fehlt\n" if !$dir;

sub say_v { print "@_\n" if $verbose; }

if (!eval { FM::Vault::optin_gueltig($dir) }) {
    say_v('Kein gueltiges Opt-in - nichts zu tun.');
    exit 0;
}

my $sitekey = eval { FM::Vault::_slurp(FM::Config::keyfile($dir)) };
if (!defined $sitekey || !length($sitekey)) {
    say_v('Kein site.key - der Laeufer beendet sich.');
    exit 0;
}

my $t = FM::Vault::tunnel_einreihen_gespeichert($dir, $sitekey);
say_v('Tunnel-Passwort: ' . ($t ? 'eingereiht' : 'nichts einzureihen'));

my $ok_lb = eval {
    require LoxBerry::System;
    no strict 'refs';
    die "get_miniservers fehlt\n"
        if !defined &{"LoxBerry::System::get_miniservers"};
    1;
};
if (!$ok_lb) {
    say_v('LoxBerry::System ist hier nicht verfuegbar - der Laeufer beendet sich.');
    exit 0;
}

if (!FM::Vault::namen_bekannt($dir)) {
    say_v('Noch keine Anzeigenamen vom Server - der Laeufer beendet sich.');
    exit 0;
}

my %miniservers = LoxBerry::System::get_miniservers();
%miniservers = FM::Miniserver::auswahl(\%miniservers, FM::Settings::get($dir, 'ms_weglassen', {}));

for my $msno (sort { $a <=> $b } keys %miniservers) {
    my $ms = $miniservers{$msno};
    if (!FM::Miniserver::ist_lokal($ms)) {
        say_v("Miniserver $msno: per Cloud DNS angebunden - wird nicht eingereiht");
        next;
    }
    my $pw = FM::Miniserver::backup_passwort($ms);
    next if !defined $pw;
    my ($user) = split(/:/, ($ms->{Credentials_RAW} // ''), 2);
    my $name = FM::Vault::server_name($dir, $msno);
    $name = FM::Vault::zeichen($ms->{Name} // '') if !defined $name;   # dem Server noch unbekannt: Name vom LoxBerry
    my $r = FM::Vault::ms_einreihen($dir, $sitekey, $msno, $name, ($user // ''), $pw);
    say_v("Miniserver $msno: " . ($r ? 'eingereiht' : 'nichts einzureihen'));
}

exit 0;

