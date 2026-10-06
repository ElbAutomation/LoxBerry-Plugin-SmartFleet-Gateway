#!/usr/bin/perl
# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

use strict;
use warnings;

use CGI;
$CGI::POST_MAX = 20 * 1024 * 1024;
use LoxBerry::System;
use LoxBerry::Web;
use LoxBerry::Storage;
use HTML::Template;

use lib "$LoxBerry::System::lbpbindir/lib";

use JSON::PP ();
use File::Spec;
use File::Path ();
use File::Temp ();
use POSIX ();
use FM::B64;
use FM::Backup::Keep;
use FM::Paths;
use FM::Config;
use FM::Pin;
use FM::Restore;
use FM::Settings;
use FM::State;
use FM::TunnelPw;
use FM::Vault;
use FM::Tunnel;

my $cgi     = CGI->new;
my $POST    = $cgi->Vars;
my $version = LoxBerry::System::pluginversion();
my %L;

my $configdir = $lbpconfigdir;

my $rt = FM::Paths::laufzeit($configdir);
my $cfg       = FM::Config::load($configdir);

my $stg = {
    backup_store     => FM::Settings::get($configdir, 'backup_store',     $cfg),
    tunnel_erlaubt   => FM::Settings::get($configdir, 'tunnel_erlaubt',   $cfg),
};

my $backup_store_anzeige = $stg->{backup_store}
    || File::Spec->catdir($lbpdatadir, 'backups');

my %SEITEN = (
    status   => 'index.html',
    settings => 'settings.html',
    logs     => 'logs.html',
);
my $form = defined $POST->{form} ? $POST->{form} : '';
$form = $cgi->param('form') || '' if $form eq '';
$form = 'status' if !exists $SEITEN{$form};

my $template = LoxBerry::System::read_file("$lbptemplatedir/$SEITEN{$form}");
my $out = HTML::Template->new_scalar_ref(
    \$template,
    global_vars       => 1,
    loop_context_vars => 1,
    die_on_bad_params => 0,
);
%L = LoxBerry::System::readlanguage($out, 'language.ini');

LoxBerry::System::readlanguage($out, undef, 1);

my $now = time();

sub esc {
    my ($s) = @_;
    return '' if !defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

sub alter_text {
    my ($sekunden) = @_;
    return $L{'FM.NIE'} if !defined $sekunden;
    $sekunden = 0 if $sekunden < 0;
    return sprintf($L{'FM.VOR_SEK'},  $sekunden)                   if $sekunden < 90;
    return sprintf($L{'FM.VOR_MIN'},  int($sekunden / 60 + 0.5))   if $sekunden < 5400;
    return sprintf($L{'FM.VOR_STD'},  int($sekunden / 3600 + 0.5)) if $sekunden < 172800;
    return sprintf($L{'FM.VOR_TAGE'}, int($sekunden / 86400 + 0.5));
}

sub zeitpunkt_text {
    my ($ts) = @_;
    return '-' if !defined $ts;
    my @l = localtime($ts);
    my $zone = POSIX::strftime("%Z", @l);
    return sprintf('%04d-%02d-%02d %02d:%02d%s',
                   $l[5] + 1900, $l[4] + 1, $l[3], $l[2], $l[1],
                   (defined $zone && $zone ne '' ? " $zone" : ''));
}

sub enroll_fehlertext {
    my ($roh) = @_;
    $roh = '' if !defined $roh;

    my @faelle = (
        [ qr/beginnt nicht mit FM1-|leerer Bereitstellungscode|kein gueltiges base64url|kein gueltiges JSON|unvollstaendig/,
          'CODE_KAPUTT' ],
        [ qr/nur https ist zulaessig/,          'CODE_HTTP'    ],
        [ qr/Fingerprint der Partner-CA/,       'CODE_ANDERER_SERVER' ],
        [ qr/Serverkette ist ungueltig/,        'SERVER_UNBEKANNT' ],
        [ qr/fremden Schluessel|Zertifikat ist ungueltig/, 'SERVER_UNBEKANNT' ],
        [ qr/hello antwortet mit HTTP 4\d\d/,   'ADRESSE_FALSCH' ],
        [ qr/"error"\s*:\s*"standortgrenze_erreicht"/, 'STANDORTGRENZE'    ],
        [ qr/"error"\s*:\s*"lizenz_abgelaufen"/,       'LIZENZ_ABGELAUFEN' ],
        [ qr/"error"\s*:\s*"lizenz_unlesbar"/,         'LIZENZ_UNLESBAR'   ],
        [ qr/"error"\s*:\s*"enroll_denied"|Server meldet Zustand/, 'CODE_VERBRAUCHT' ],
        [ qr/antwortet mit HTTP 599/,           'KEIN_NETZ'    ],
        [ qr/antwortet mit HTTP 5\d\d/,         'SERVER_FEHLER' ],
        [ qr/IO::Socket::SSL fehlt/,            'KEIN_SSL'     ],
        [ qr/Verbindung|timeout|Timeout|resolve|refused|Netz/i, 'KEIN_NETZ' ],
    );

    for my $f (@faelle) {
        next if $roh !~ $f->[0];
        return $L{'FM.ENROLL_' . $f->[1]};
    }

    my $kurz = $roh;
    $kurz =~ s/\b(fm_enroll|FM::[A-Za-z:]+)\s*:\s*//g;
    $kurz =~ s/\s+/ /g;
    $kurz =~ s/^\s+|\s+$//g;
    $kurz = substr($kurz, 0, 300) if length($kurz) > 300;
    return $L{'FM.ENROLL_UNBEKANNT'} . ($kurz ne '' ? " ($kurz)" : '');
}

my $angemeldet = ($cfg->{site} && $cfg->{server}) ? 1 : 0;

my $aktion = $cgi->param('aktion');
$aktion = '' if !defined $aktion;
my %BRAUCHT_ANMELDUNG = (setzen => 1, pruefen => 1, abmelden => 1);

my $ajax = $POST->{ajax} || $cgi->param('ajax') || '';

if ($ajax eq 'pin') {
    my $antwort = { ok => 0 };
    my $fehler  = LoxBerry::System::check_securepin($cgi->param('secpin'));
    if (!defined $fehler) {
        my $schein = eval { FM::Pin::ausstellen($rt) };
        $antwort = defined $schein ? { ok => 1, schein => $schein } : { ok => 0 };
    }
    elsif (int($fehler) == 3) {
        $antwort = { ok => 0, gesperrt => 1 };
    }
    print "Content-Type: application/json; charset=utf-8\n";
    print "Cache-Control: no-store\n\n";
    print JSON::PP->new->encode($antwort);
    exit 0;
}

my $freigegeben = FM::Pin::gueltig($rt,
                      ($POST->{schein} || $cgi->param('schein') || ''));

if ($ajax eq 'pruefen') {
    print "Content-Type: text/plain; charset=utf-8\n";
    print "Cache-Control: no-store\n\n";
    $| = 1;

    if (!$freigegeben) {
        print $L{'FM.PIN_FEHLT'}, "\n";
        exit 0;
    }
    if (!$angemeldet) {
        print $L{'FM.MELDUNG_ERST_ANMELDEN'}, "\n";
        exit 0;
    }

    my $collect_pl = File::Spec->catfile($lbpbindir, 'fm_collect.pl');
    my $sync_pl    = File::Spec->catfile($lbpbindir, 'fm_sync.pl');

    my $auffaellig = 0;
    my $rc_gesamt  = 0;
    for my $lauf (
        [$collect_pl, ['--dir', $configdir, '--verbose', '--dry-run']],
        [$sync_pl,    ['--dir', $configdir, '--verbose', '--log']],
    ) {
        my ($prog, $arg) = @$lauf;
        my $pid = open(my $ph, '-|');
        if (defined $pid && $pid == 0) {
            open(STDERR, '>&', \*STDOUT);
            exec($^X, $prog, @$arg);
            exit 127;
        }
        if (!$pid) {
            print $L{'FM.PRUEFUNG_NICHT_STARTBAR'}, "\n";
            next;
        }
        while (my $z = <$ph>) {
            print $z;
            $auffaellig = 1 if $z =~ /HTTP [45][0-9][0-9]|fehlgeschlagen|nicht erreichbar|abgelehnt/i;
        }
        close $ph;
        $rc_gesamt = $? >> 8 if ($? >> 8) != 0;
    }
    print "
";
    if ($rc_gesamt != 0) {
        print sprintf($L{'FM.PRUEFUNG_EXITCODE'}, $rc_gesamt), "
";
    }
    elsif ($auffaellig) {
        print $L{'FM.PRUEFUNG_NICHT_OK'}, "
";
    }
    else {
        print $L{'FM.PRUEFUNG_OK'}, "
";
    }
    exit 0;
}

my %MELDUNG_ORT = (
    enroll             => 'verbindung',
    abmelden           => 'trennen',
    tunnel_erlaubt_ein => 'fernwartung',
    tunnel_erlaubt_aus => 'fernwartung',
    vault_optin        => 'tresor',
    vault_widerruf     => 'tresor',
    vault_pin_zuruecksetzen => 'tresor',
    vorschlag          => 'passwort',
    setzen             => 'passwort',
    einstellungen      => 'sicherungen',
    wiederherstellung  => 'wiederherstellung',
    messwerte          => 'messwerte',
    pruefen            => 'testen',
);

my $meldung;
sub melde {
    my ($ok, $text, $wo) = @_;
    $meldung = { ok => $ok, text => $text, wo => ($wo || 'verbindung') };
    return;
}

my $ort = $MELDUNG_ORT{$aktion} || 'verbindung';
my $aktion_kam = ($aktion ne '') ? 1 : 0;
my $aktion_gemerkt = $aktion;

if ($aktion ne '' && !$freigegeben) {
    melde(0, $L{'FM.PIN_FEHLT'}, $ort);
    $aktion = '';
}

if ($aktion ne '' && $BRAUCHT_ANMELDUNG{$aktion} && !$angemeldet) {
    melde(0, $L{'FM.MELDUNG_ERST_ANMELDEN'}, $ort);
    $aktion = '';   # keiner der Bloecke unten greift mehr
}

if ($aktion eq 'enroll' && !$angemeldet) {
    my $code = defined $POST->{code} ? $POST->{code} : '';
    $code =~ s/\A\s+|\s+\z//g;

    if ($code eq '') {
        melde(0, $L{'FM.MELDUNG_CODE_LEER'}, $ort);
    }
    else {
        my $enroll_pl = File::Spec->catfile($lbpbindir, 'fm_enroll.pl');
        my @ausgabe;
        my $pid = open(my $eh, '-|');
        if (defined $pid && $pid == 0) {
            open(STDERR, '>&', \*STDOUT);
            exec($^X, $enroll_pl, '--dir', $configdir, '--code', $code);
            exit 127;
        }
        if ($pid) {
            while (my $z = <$eh>) { chomp $z; push @ausgabe, $z; }
            close $eh;
        }
        my $rc = $? >> 8;

        $cfg        = FM::Config::load($configdir);
        $angemeldet = ($cfg->{site} && $cfg->{server}) ? 1 : 0;

        if ($angemeldet) {
            if (!$stg->{backup_store}) {
                $stg->{backup_store} = File::Spec->catdir($lbpdatadir, 'backups');
                eval { FM::Settings::save($configdir, $stg); 1 };
            }

            eval { File::Path::make_path($stg->{backup_store}); 1 };
            melde(1, $L{'FM.MELDUNG_ENROLL_OK'}, $ort);
        }
        else {
            my $roh = @ausgabe ? join(' ', @ausgabe) : '';
            melde(0, enroll_fehlertext($roh), $ort);
        }
    }
}

if ($aktion eq 'abmelden') {
    my $ok = eval {
        unlink(FM::Config::keyfile($configdir));
        FM::Config::save($configdir, {});
        1;
    };
    $cfg        = FM::Config::load($configdir);
    $angemeldet = ($cfg->{site} && $cfg->{server}) ? 1 : 0;
    ($ok && !$angemeldet) ? melde(1, $L{'FM.MELDUNG_ABGEMELDET'}, $ort)
                          : melde(0, $L{'FM.MELDUNG_ABMELDEN_FEHLER'}, $ort);
}

if ($aktion eq 'einstellungen' || $aktion eq 'messwerte') {
    my $store = defined $POST->{store} ? $POST->{store} : '';
    $store =~ s/\A\s+|\s+\z//g;

    if (exists $POST->{store} && $store ne '' && $store !~ m{\A/}) {
        melde(0, $L{'FM.MELDUNG_STORE_RELATIV'}, $ort);
    }
    else {
        $stg->{backup_store} = $store if exists $POST->{store};

        if ($stg->{backup_store}) {
            eval { File::Path::make_path($stg->{backup_store}); 1 };
        }

        if (!$meldung) {
            eval { FM::Settings::save($configdir, $stg); 1 }
                ? melde(1, $L{'FM.MELDUNG_EINSTELLUNGEN_OK'}, $ort)
                : melde(0, $L{'FM.MELDUNG_SPEICHERN_FEHLER'}, $ort);
        }
    }
}

if ($aktion eq 'wiederherstellung') {
    my $cgi_fehler = $cgi->cgi_error();
    my $upload_fh = $cgi_fehler ? undef : $cgi->upload('wiederherstellung_datei');
    if ($cgi_fehler) {
        melde(0, $L{'FM.MELDUNG_WIEDERHERSTELLUNG_ZU_GROSS'}, $ort);
    }
    elsif (!$upload_fh) {
        melde(0, $L{'FM.MELDUNG_WIEDERHERSTELLUNG_KEINE_DATEI'}, $ort);
    }
    else {
        my $tmp_verzeichnis = eval { File::Temp::tempdir(CLEANUP => 1) };
        my $tmp_archiv = $tmp_verzeichnis
            ? File::Spec->catfile($tmp_verzeichnis, 'hochgeladen.7z') : undef;
        my $kopiert = $tmp_archiv && eval {
            open my $ausgabe, '>:raw', $tmp_archiv or die;
            binmode $upload_fh;
            my $puffer;
            while (read($upload_fh, $puffer, 65536)) { print {$ausgabe} $puffer; }
            close $ausgabe;
            1;
        };
        if (!$kopiert) {
            melde(0, $L{'FM.MELDUNG_WIEDERHERSTELLUNG_UPLOAD_FEHLER'}, $ort);
        }
        else {
            my $wh_pw = defined $POST->{wiederherstellung_passwort}
                ? $POST->{wiederherstellung_passwort} : '';
            my $ergebnis = eval { FM::Restore::einspielen($configdir, $rt, $tmp_archiv, $wh_pw) };
            if ($ergebnis && $ergebnis->{ok}) {
                melde(1, $L{'FM.MELDUNG_WIEDERHERSTELLUNG_OK'}, $ort);
            }
            else {
                my $grund = $ergebnis ? $ergebnis->{grund} : '';
                my %TEXT_JE_GRUND = (
                    kein_7z                  => $L{'FM.MELDUNG_WIEDERHERSTELLUNG_KEIN_7Z'},
                    entpacken_fehlgeschlagen => $L{'FM.MELDUNG_WIEDERHERSTELLUNG_KAPUTT'},
                    kein_manifest            => $L{'FM.MELDUNG_WIEDERHERSTELLUNG_KEIN_MANIFEST'},
                    falscher_typ             => $L{'FM.MELDUNG_WIEDERHERSTELLUNG_KEIN_MANIFEST'},
                    kopieren_fehlgeschlagen  => $L{'FM.MELDUNG_WIEDERHERSTELLUNG_KOPIEREN_FEHLGESCHLAGEN'},
                );
                melde(0, $TEXT_JE_GRUND{$grund} || $L{'FM.MELDUNG_WIEDERHERSTELLUNG_FEHLER'}, $ort);
            }
        }
    }
}

my $tunnel_vorschlag;
if ($aktion eq 'vorschlag') {
    $tunnel_vorschlag = eval { FM::TunnelPw::erzeugen() };
    if (!defined $tunnel_vorschlag) {
        melde(0, $L{'FM.MELDUNG_VORSCHLAG_FEHLER'}, $ort);
    }
}
elsif ($aktion eq 'setzen') {
    my $pw = defined $POST->{pw} ? $POST->{pw} : '';
    $pw = '' if $pw =~ /\A\*+\z/;
    my $pruefung = eval { FM::TunnelPw::pruefen($pw) };
    if (!$pruefung) {
        melde(0, $L{'FM.MELDUNG_PRUEFUNG_FEHLER'}, $ort);
    }
    elsif (!$pruefung->{ok}) {
        melde(0, $L{'FM.MELDUNG_ZU_SCHWACH'}, $ort);
        $tunnel_vorschlag = $pw;
    }
    else {
        my $abgelegt = eval {
            my $K = FM::TunnelPw::ableiten($pw, $cfg->{site});
            FM::TunnelPw::speichern($configdir, $K);
            1;
        };
        if ($abgelegt) {
            my $tresor = FM::Vault::tunnel_einreihen($configdir, $pw);
            my $text = $L{'FM.MELDUNG_GESETZT'};
            $text .= ' ' . $L{'FM.NICHT_UEBERTRAGEN'} if $tresor eq 'nicht_uebertragen';
            $text .= ' ' . $L{'FM.TRESOR_WARTET'} if $tresor eq 'wartet';
            melde(1, $text, $ort);
            $tunnel_vorschlag = $pw;
        }
        else {
            melde(0, $L{'FM.MELDUNG_ABLEGEN_FEHLER'}, $ort);
        }
    }
}
my $tunnel_gesetzt = (eval { defined FM::TunnelPw::laden($configdir) } ? 1 : 0);

if ($aktion eq 'tunnel_erlaubt_ein') {
    $stg->{tunnel_erlaubt} = 1;
    eval { FM::Settings::save($configdir, $stg); 1 }
        or melde(0, $L{'FM.MELDUNG_SPEICHERN_FEHLER'}, $ort);
}
elsif ($aktion eq 'tunnel_erlaubt_aus') {
    $stg->{tunnel_erlaubt} = 0;
    eval { FM::Settings::save($configdir, $stg); 1 }
        or melde(0, $L{'FM.MELDUNG_SPEICHERN_FEHLER'}, $ort);
}
if ($aktion =~ /\Avault_(?:optin|widerruf|pin_zuruecksetzen)\z/) {
    my $erg = FM::Vault::optin_aktion($configdir, $aktion,
                  scalar $cgi->param('vault_haken'),
                  scalar $cgi->param('vault_textversion'));
    my %TEXT = (
        vault_optin             => 'FM.VAULT_MELDUNG_OPTIN',
        vault_widerruf          => 'FM.VAULT_MELDUNG_WIDERRUF',
        vault_pin_zuruecksetzen => 'FM.VAULT_MELDUNG_PIN',
    );
    if ($erg eq 'ok') {
        my $text = $L{$TEXT{$aktion}};
        $text .= ' ' . $L{'FM.VAULT_MELDUNG_OPTIN_HINWEIS'} if $aktion eq 'vault_optin';
        melde(1, $text, $ort);
    }
    elsif ($erg eq 'haken_fehlt') { melde(0, $L{'FM.VAULT_MELDUNG_HAKEN'}, $ort); }
    else                          { melde(0, $L{'FM.VAULT_MELDUNG_FEHLER'}, $ort); }
}
my $tunnel_erlaubt = $stg->{tunnel_erlaubt} ? 1 : 0;

my ($tunnel_offen, $tunnel_ablauf, $tunnel_seit);
if ($angemeldet) {
    my $tunnel_pl = File::Spec->catfile($lbpbindir, 'fm_tunnel.pl');
    if (open(my $sfh, '-|', $^X, $tunnel_pl, '--dir', $configdir, '--status')) {
        while (my $zeile = <$sfh>) {
            chomp $zeile;
            $tunnel_offen  = 1  if $zeile =~ /^url=/;
            $tunnel_ablauf = $1 if $zeile =~ /^ablauf=([0-9]+)\z/;
            $tunnel_seit   = $1 if $zeile =~ /^seit=([0-9]+)\z/;
        }
        close $sfh;
    }
}

my $server_interval = 300;
{
    my $state = FM::State::load($rt);
    my $d = ref($state->{desired}) eq 'HASH' ? $state->{desired} : {};
    my $t = ref($d->{telemetry}) eq 'HASH' ? $d->{telemetry} : {};
    $server_interval = $t->{interval} if $t->{interval} && $t->{interval} >= 60;
}

my $poll_alter;
my $sync_fehler;
{
    my $st = eval { FM::State::load($rt) } || {};
    $poll_alter  = $st->{sync_ok_at} ? ($now - $st->{sync_ok_at}) : undef;
    $sync_fehler = $st->{sync_fehler};
}

my $verbunden = ($angemeldet && defined $poll_alter && $poll_alter <= 600) ? 1 : 0;

my $backup_alter;
if ($stg->{backup_store} && -d $stg->{backup_store}) {
    my $bester_ts;
    if (opendir(my $sh, $stg->{backup_store})) {
        for my $msdir (readdir $sh) {
            next if $msdir !~ /\Ams[0-9]+\z/;
            my $msd = File::Spec->catdir($stg->{backup_store}, $msdir);
            next if !opendir(my $gh, $msd);
            for my $stamp (readdir $gh) {
                next if $stamp !~ /\A[0-9]{14}\z/;
                my $gd   = File::Spec->catdir($msd, $stamp);
                my $meta = File::Spec->catfile($gd, 'meta.json');
                next if !defined FM::Backup::Keep::archiv_datei($gd);
                next if !-f $meta;
                open(my $fh, '<:raw', $meta) or next;
                local $/;
                my $raw = <$fh>;
                close $fh;
                my $m = eval { JSON::PP->new->decode($raw) };
                next if !$m || !defined $m->{ts};
                $bester_ts = $m->{ts} if !defined $bester_ts || $m->{ts} > $bester_ts;
            }
            closedir $gh;
        }
        closedir $sh;
    }
    $backup_alter = defined $bester_ts ? ($now - $bester_ts) : undef;
}

if (($ENV{REQUEST_METHOD} || '') eq 'POST'
    && !($ENV{HTTP_X_FM_FETCH} || '')
    && $aktion_kam
    && $aktion_gemerkt ne 'setzen') {

    my $ziel = 'index.cgi?form=' . $form;
    if ($meldung) {
        $ziel .= '&mo=' . $meldung->{wo}
              .  '&mk=' . ($meldung->{ok} ? 1 : 0)
              .  '&ms=' . FM::B64::b64u_encode($meldung->{text});
    }
    print "Status: 303 See Other
";
    print "Location: $ziel

";
    exit 0;
}

if (($ENV{HTTP_X_FM_FETCH} || '') && $aktion_kam
    && ($aktion_gemerkt eq 'enroll' || $aktion_gemerkt eq 'abmelden')) {
    print "Content-Type: application/json; charset=utf-8\n";
    print "Cache-Control: no-store\n\n";
    print JSON::PP->new->encode({
        mo => ($meldung ? $meldung->{wo}                       : ''),
        mk => ($meldung ? ($meldung->{ok} ? 1 : 0)              : 0),
        ms => ($meldung ? FM::B64::b64u_encode($meldung->{text}) : ''),
    });
    exit 0;
}

our %navbar;
$navbar{10}{Name}   = $L{'FM.NAV_STATUS'};
$navbar{10}{URL}    = 'index.cgi';
$navbar{10}{active} = 1 if $form eq 'status';

$navbar{20}{Name}   = $L{'FM.NAV_SETTINGS'};
$navbar{20}{URL}    = 'index.cgi?form=settings';
$navbar{20}{active} = 1 if $form eq 'settings';

$navbar{30}{Name}   = $L{'FM.NAV_LOGS'};
$navbar{30}{URL}    = 'index.cgi?form=logs';
$navbar{30}{active} = 1 if $form eq 'logs';

$out->param(FORM => $form);

if ($form eq 'settings') {
    my $auswahl = eval {
        LoxBerry::Storage::get_storage_html(
            formid        => 'store',
            label         => $L{'FM.LABEL_BACKUP_STORE'},
            currentpath   => $backup_store_anzeige,
            type_all      => 1,
            custom_folder => 1,
            readwriteonly => 1,
            show_browse   => 1,
            data_mini     => 1,
        );
    };
    $out->param(
        STORE_AUSWAHL    => (defined $auswahl ? $auswahl : ''),
        STORE_AUSWAHL_DA => ((defined $auswahl && $auswahl ne '') ? 1 : 0),
    );
}

if ($form eq 'logs') {
    my $liste = eval { LoxBerry::Web::loglist_html(PACKAGE => $lbpplugindir) };
    $out->param(
        LOGLIST    => (defined $liste ? $liste : ''),
        LOGLIST_DA => ((defined $liste && $liste ne '') ? 1 : 0),
    );
}

$out->param(
    ANGEMELDET  => $angemeldet,
    FREIGEGEBEN => ($freigegeben ? 1 : 0),
    SCHEIN      => ($freigegeben ? ($POST->{schein} || $cgi->param('schein') || '') : ''),
);

$out->param(
    ZUSTAND_TEXT   => (!$angemeldet ? $L{'FM.TAG_GETRENNT'}
                     : $verbunden   ? $L{'FM.TAG_VERBUNDEN'}
                     :                $L{'FM.TAG_KEIN_KONTAKT'}),
    ZUSTAND_KLASSE => ($verbunden ? 'fm-tag-ok' : 'fm-tag-weg'),
    SYNC_FEHLER    => (defined $sync_fehler ? $sync_fehler : ''),
    SYNC_FEHLER_DA => (($angemeldet && !$verbunden && defined $sync_fehler) ? 1 : 0),
);

$out->param(NUR_MIT_SERVER => ($angemeldet ? '' : 'disabled'));

$out->param(
    NUR_MIT_TUNNEL => ($tunnel_erlaubt ? '' : 'disabled'),
    NUR_MIT_BEIDEM => (($angemeldet && $tunnel_erlaubt) ? '' : 'disabled'),
);

my $vault_zeit = FM::Vault::optin_zeit($configdir);
$out->param(
    VAULT_AKTIV     => (defined $vault_zeit ? 1 : 0),
    VAULT_SEIT      => (defined $vault_zeit ? zeitpunkt_text($vault_zeit) : ''),
    VAULT_TEXTVERSION => FM::Vault::TEXT_VERSION,
);
$out->param(
    TUNNEL_ERLAUBT => $tunnel_erlaubt,
    TUNNEL_GESETZT => $tunnel_gesetzt,
    SITE_NAME      => ($cfg->{name} || $cfg->{site} || ''),
    PARTNER_NAME   => ($cfg->{partner_name} || $cfg->{partner} || ''),
);

$out->param(
    BACKUP_STORE     => $backup_store_anzeige,
    SERVER_INTERVAL  => $server_interval,
    PW_VORSCHLAG     => (defined $tunnel_vorschlag ? $tunnel_vorschlag
                        : ($tunnel_gesetzt ? '*********' : '')),
) if $freigegeben;

if (!$meldung && ($cgi->param('mo') || '')) {
    my $wo = $cgi->param('mo');
    my %ORTE = map { $_ => 1 } qw(verbindung fernwartung tresor passwort sicherungen wiederherstellung messwerte testen trennen);
    if ($ORTE{$wo}) {
        my $text = eval { FM::B64::b64u_decode($cgi->param('ms') || '') };
        $meldung = {
            wo   => $wo,
            ok   => (($cgi->param('mk') || '') eq '1') ? 1 : 0,
            text => (defined $text && $text ne '' ? $text : ''),
        } if defined $text && $text ne '';
    }
}

if ($meldung) {
    my $gross = uc($meldung->{wo});
    $out->param(
        "MELDUNG_${gross}_DA"   => 1,
        "MELDUNG_${gross}_OK"   => $meldung->{ok},
        "MELDUNG_${gross}_TEXT" => $meldung->{text},
    );
}

if ($angemeldet) {
    my $server = $cfg->{server};
    $server =~ s{/+\z}{};

    $out->param(
        SITE_NAME      => ($cfg->{name} || $cfg->{site}),
        PARTNER_NAME   => ($cfg->{partner_name} || $cfg->{partner} || ''),
        SERVER         => $cfg->{server},
        SERVER_URL     => $server . '/ui/index.php',
        HAT_ENROLLED   => ($cfg->{enrolled_at} ? 1 : 0),
        ENROLLED_AT    => zeitpunkt_text($cfg->{enrolled_at}),
        POLL_ALTER     => alter_text($poll_alter),
        BACKUP_ALTER   => alter_text($backup_alter),
        TUNNEL_OFFEN   => ($tunnel_offen ? 1 : 0),
    );

    if ($tunnel_offen) {
        my $dauerhaft = defined $tunnel_ablauf && $tunnel_ablauf == 0;
        $out->param(TUNNEL_DAUERHAFT => ($dauerhaft ? 1 : 0));
        $out->param(TUNNEL_ABLAUF_BEKANNT => (defined $tunnel_ablauf ? 1 : 0));
        my $seit = defined $tunnel_seit ? $tunnel_seit
                 : (defined $tunnel_ablauf && !$dauerhaft) ? $tunnel_ablauf - FM::Tunnel::ABLAUF_SEK() : undef;
        $out->param(TUNNEL_SEIT => zeitpunkt_text($seit)) if defined $seit;
        if (defined $tunnel_ablauf && !$dauerhaft) {
            my $verbleibend = $tunnel_ablauf - $now;
            $verbleibend = 0 if $verbleibend < 0;
            $out->param(TUNNEL_VERBLEIBEND => int($verbleibend / 60 + 0.5));
        }
    }

}

LoxBerry::Web::lbheader($L{'FM.PLUGINTITLE'} . " V$version", 'https://wiki.loxberry.de', '', 'nojqm');
print $out->output();
LoxBerry::Web::lbfooter();

exit 0;

