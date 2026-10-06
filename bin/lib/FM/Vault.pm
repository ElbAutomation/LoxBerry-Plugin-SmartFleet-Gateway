# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Vault;
use strict;
use warnings;
use File::Temp ();
use IPC::Open3 ();
use Encode ();
use JSON::PP ();
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64);
use FM::B64;
use FM::Keys;

use constant INFO        => 'smartfleet-vault-v1';
use constant SPKI_X25519 => "\x30\x2a\x30\x05\x06\x03\x2b\x65\x6e\x03\x21\x00";

sub _slurp { my ($p) = @_; open my $f, '<:raw', $p or die "FM::Vault: $p: $!\n"; local $/; my $d = <$f>; close $f; return $d; }
sub _spew  { my ($p, $d) = @_; open my $f, '>:raw', $p or die "FM::Vault: $p: $!\n"; print {$f} $d; close $f or die "FM::Vault: $p: $!\n"; return 1; }
sub _run   { my (@c) = @_; return system(@c) == 0 ? 1 : 0; }

sub _run_pipe {
    my ($eingabe, @c) = @_;
    my $aus;
    my $ok = eval {
        my $pid = IPC::Open3::open3(my $in, my $out, '>&STDERR', @c);
        binmode $in;
        binmode $out;
        print {$in} $eingabe if defined $eingabe && length $eingabe;
        close $in;
        local $/;
        $aus = <$out>;
        close $out;
        waitpid($pid, 0);
        $? == 0;
    };
    return $ok ? (defined $aus ? $aus : '') : undef;
}

sub _zufall {
    my ($n) = @_;
    open my $f, '<:raw', '/dev/urandom' or die "FM::Vault: kein Zufall verfuegbar\n";
    my $got = read($f, my $buf, $n);
    close $f;
    die "FM::Vault: Zufall zu kurz\n" if !defined $got || $got != $n;
    return $buf;
}

sub hkdf {
    my ($ikm, $salt, $info, $len) = @_;
    $salt = '' if !defined $salt;
    my $prk = hmac_sha256($ikm, $salt);
    my ($t, $okm) = ('', '');
    my $i = 1;
    while (length($okm) < $len) {
        $t = hmac_sha256($t . $info . chr($i), $prk);
        $okm .= $t;
        $i++;
    }
    return substr($okm, 0, $len);
}

sub _pem_x25519_pub {
    my ($pub32) = @_;
    my $b64 = encode_base64(SPKI_X25519 . $pub32, '');
    return "-----BEGIN PUBLIC KEY-----\n" . join("\n", ($b64 =~ /(.{1,64})/g)) . "\n-----END PUBLIC KEY-----\n";
}

sub versiegeln {
    my ($enc_pub32, $klartext) = @_;
    die "FM::Vault: Empfaengerschluessel muss 32 Byte haben\n" if !defined $enc_pub32 || length($enc_pub32) != 32;
    FM::Keys::require_openssl3();
    my $tmp = File::Temp->newdir();
    my $d = $tmp->dirname;
    _run('openssl', 'genpkey', '-algorithm', 'X25519', '-out', "$d/e.pem") or die "FM::Vault: Ephemeralschluessel\n";
    _run('openssl', 'pkey', '-in', "$d/e.pem", '-pubout', '-outform', 'DER', '-out', "$d/e.der") or die "FM::Vault: Ephemeral-Pub\n";
    my $eph_pub = substr(_slurp("$d/e.der"), -32);
    _spew("$d/p.pem", _pem_x25519_pub($enc_pub32));
    my $shared = _run_pipe(undef, 'openssl', 'pkeyutl', '-derive', '-inkey', "$d/e.pem", '-peerkey', "$d/p.pem");
    die "FM::Vault: Schluesselableitung\n" if !defined $shared;
    die "FM::Vault: gemeinsames Geheimnis hat falsche Laenge\n" if length($shared) != 32;
    my $okm = hkdf($shared, '', INFO, 64);
    my ($ek, $mk) = (substr($okm, 0, 32), substr($okm, 32, 32));
    my $iv = _zufall(16);
    my $ct = _run_pipe($klartext, 'openssl', 'enc', '-aes-256-ctr', '-K', unpack('H*', $ek), '-iv', unpack('H*', $iv));
    die "FM::Vault: Verschluesselung\n" if !defined $ct || length($ct) != length($klartext);
    my $kopf = chr(1) . $eph_pub . $iv . $ct;
    return FM::B64::b64u_encode($kopf . hmac_sha256($kopf, $mk));
}

sub enc_nachricht {
    my ($site, $version, $enc_pub_b64u) = @_;
    return join("\n", 'smartfleet-vault-enc-v1', $site, $version, $enc_pub_b64u);
}

sub enc_key_pruefen {
    my ($ident_pub32, $site, $version, $enc_pub_b64u, $sig_b64u) = @_;
    return 0 if !defined $ident_pub32 || !defined $sig_b64u || !defined $enc_pub_b64u;
    my $sig = eval { FM::B64::b64u_decode($sig_b64u) };
    return 0 if !defined $sig;
    return FM::Keys::verify_raw($ident_pub32, enc_nachricht($site, $version, $enc_pub_b64u), $sig) ? 1 : 0;
}

use constant TEXT_VERSION => 1;

sub _pfad { my ($dir, $name) = @_; return "$dir/$name"; }

sub _laden {
    my ($pfad) = @_;
    return ('fehlt', undef) if !-e $pfad;
    my $roh = eval { _slurp($pfad) };
    return ('defekt', undef) if !defined $roh || !length($roh);
    my $d = eval { JSON::PP::decode_json($roh) };
    return ref($d) eq 'HASH' ? ('ok', $d) : ('defekt', undef);
}

sub _sperre {
    my ($dir) = @_;
    my $lf = _pfad($dir, 'vault.lock');
    my $alt = umask(0077);
    my $ok = open(my $fh, '>>', $lf);
    umask($alt);
    die "FM::Vault: $lf nicht sperrbar: $!\n" if !$ok;
    flock($fh, 2) or die "FM::Vault: $lf nicht sperrbar: $!\n";
    return $fh;
}

sub _speichern {
    my ($pfad, $daten) = @_;
    my $alt = umask(0077);
    my $tmp = "$pfad.tmp";
    my $ok = eval {
        _spew($tmp, JSON::PP->new->ascii->canonical->encode($daten));
        chmod(0600, $tmp) == 1 or die "FM::Vault: chmod $tmp: $!\n";
        rename($tmp, $pfad) or die "FM::Vault: rename $pfad: $!\n";
        1;
    };
    my $fehler = $@;
    umask($alt);
    if (!$ok) { unlink $tmp; die $fehler; }
    return 1;
}

sub _korb {
    my ($dir, $reparieren) = @_;
    my $pfad = _pfad($dir, 'vault_korb.json');
    my ($st, $k) = _laden($pfad);
    if ($st eq 'defekt' && $reparieren) {
        rename($pfad, "$pfad.defekt");
        chmod(0600, "$pfad.defekt");
    }
    $k = {} if $st ne 'ok';
    $k->{eintraege} = {} if ref($k->{eintraege}) ne 'HASH';
    $k->{hashes}    = {} if ref($k->{hashes}) ne 'HASH' || !defined $k->{v} || $k->{v} !~ /^\d+$/ || $k->{v} < 2;
    $k->{widerruf}  = $k->{widerruf} ? 1 : 0;
    return $k;
}

sub _korb_speichern { my ($dir, $k) = @_; $k->{v} = 2; return _speichern(_pfad($dir, 'vault_korb.json'), $k); }

sub _korb_leeren {
    my ($dir) = @_;
    return 1 if !-e _pfad($dir, 'vault_korb.json');   # nichts da, nichts zu leeren (und keine Datei ohne Not anlegen)
    my $k = _korb($dir, 1);
    $k->{eintraege} = {};
    $k->{hashes} = {};
    return _korb_speichern($dir, $k);
}

sub info_pruefen {
    my ($dir, $site, $info) = @_;
    return 'keiner' if ref($info) ne 'HASH' || !length($info->{ident_pub} // '');
    return 'signatur_ungueltig' if ($info->{key_version} // '') !~ /^\d+$/;
    my $ident = eval { FM::B64::b64u_decode($info->{ident_pub}) };
    my $ok = defined $ident
        && enc_key_pruefen($ident, $site, $info->{key_version}, $info->{enc_pub}, $info->{enc_sig});
    return 'signatur_ungueltig' if !$ok;
    my $lock = _sperre($dir);
    my ($st, $pin) = _laden(_pfad($dir, 'vault.json'));
    return 'pin_defekt' if $st eq 'defekt';
    if ($st eq 'fehlt' || !length($pin->{ident_pub} // '')) {
        _speichern(_pfad($dir, 'vault.json'), {
            ident_pub => $info->{ident_pub}, version => $info->{key_version} + 0,
            enc_pub => $info->{enc_pub}, site => $site });
        _korb_leeren($dir);
        return 'gepinnt';
    }
    return 'identitaet_geaendert' if $pin->{ident_pub} ne $info->{ident_pub};
    return 'signatur_ungueltig' if defined $pin->{version} && $pin->{version} =~ /^\d+$/
        && $info->{key_version} + 0 < $pin->{version} + 0;
    $pin->{version} = $info->{key_version} + 0;
    $pin->{enc_pub} = $info->{enc_pub};
    _speichern(_pfad($dir, 'vault.json'), $pin);
    return 'ok';
}

sub pin_loeschen {
    my ($dir) = @_;
    my $lock = _sperre($dir);
    my $p = _pfad($dir, 'vault.json');
    unlink $p if -e $p;
    _korb_leeren($dir);
    return 1;
}

sub optin_setzen {
    my ($dir) = @_;
    return _speichern(_pfad($dir, 'vault_optin.json'), { textversion => TEXT_VERSION, at => time() });
}

sub optin_gueltig {
    my ($dir) = @_;
    my ($st, $o) = _laden(_pfad($dir, 'vault_optin.json'));
    return 0 if $st ne 'ok';
    return (defined $o->{textversion} && $o->{textversion} =~ /^\d+$/ && $o->{textversion} == TEXT_VERSION) ? 1 : 0;
}

sub optin_widerrufen {
    my ($dir) = @_;
    my $lock = _sperre($dir);
    my $k = _korb($dir, 1);
    $k->{eintraege} = {};
    $k->{hashes} = {};
    $k->{widerruf} = 1;
    _korb_speichern($dir, $k);
    my $p = _pfad($dir, 'vault_optin.json');
    unlink $p if -e $p;
    return 1;
}

sub optin_zeit {
    my ($dir) = @_;
    return undef if !optin_gueltig($dir);
    my ($st, $o) = _laden(_pfad($dir, 'vault_optin.json'));
    return (defined $o->{at} && $o->{at} =~ /^\d+$/) ? $o->{at} + 0 : undef;
}

sub optin_aktion {
    my ($dir, $aktion, $haken, $textversion) = @_;
    $aktion = '' if !defined $aktion;
    if ($aktion eq 'vault_optin') {
        return 'haken_fehlt' if !defined $haken || $haken ne '1';
        return 'haken_fehlt' if !defined $textversion || $textversion !~ /\A\d+\z/ || $textversion != TEXT_VERSION;
        return eval { optin_setzen($dir); 1 } ? 'ok' : 'fehler';
    }
    if ($aktion eq 'vault_widerruf') {
        return eval { optin_widerrufen($dir); 1 } ? 'ok' : 'fehler';
    }
    if ($aktion eq 'vault_pin_zuruecksetzen') {
        return eval { pin_loeschen($dir); 1 } ? 'ok' : 'fehler';
    }
    return 'unbekannt';
}

sub tunnel_json {
    my ($pw) = @_;
    return undef if !defined $pw;
    my $zeichen = $pw;
    if (!utf8::is_utf8($zeichen)) {
        $zeichen = eval { Encode::decode('UTF-8', $pw, Encode::FB_CROAK() | Encode::LEAVE_SRC()) };
        return undef if !defined $zeichen;
    }
    return JSON::PP->new->utf8->canonical->encode({ typ => 'tunnel', pass => $zeichen });
}

sub _pw_zeichen {
    my ($pw) = @_;
    return undef if !defined $pw;
    return $pw if utf8::is_utf8($pw);
    return eval { Encode::decode('UTF-8', $pw, Encode::FB_CROAK() | Encode::LEAVE_SRC()) };
}

sub tunnel_pw_speichern {
    my ($dir, $pw) = @_;
    my $z = _pw_zeichen($pw);
    return 0 if !defined $z || $z eq '';
    return eval { my $lock = _sperre($dir); _speichern(_pfad($dir, 'tunnel_pw.json'), { pw => $z }); 1 } ? 1 : 0;
}

sub tunnel_pw_laden {
    my ($dir) = @_;
    my ($st, $d) = _laden(_pfad($dir, 'tunnel_pw.json'));
    return undef if $st ne 'ok';
    my $p = $d->{pw};
    return (defined $p && !ref($p) && length($p)) ? $p : undef;
}

sub tunnel_einreihen {
    my ($dir, $pw) = @_;
    my $abgelegt = tunnel_pw_speichern($dir, $pw);
    return 'kein_optin' if !optin_gueltig($dir);
    return 'nicht_uebertragen' if !$abgelegt;
    my $sitekey = eval { _slurp(_pfad($dir, 'site.key')) };
    return 'wartet' if !defined $sitekey || !length($sitekey);
    return tunnel_einreihen_gespeichert($dir, $sitekey) ? 'uebertragen' : 'wartet';
}

sub tunnel_einreihen_gespeichert {
    my ($dir, $sitekey) = @_;
    return 0 if !defined $sitekey || !length($sitekey);
    return eval {
        my $pw = tunnel_pw_laden($dir);
        return 0 if !defined $pw;
        utf8::upgrade($pw);
        my $json = tunnel_json($pw);
        return 0 if !defined $json;
        my $hash = ms_hash($sitekey, $json);
        return 0 if !hash_geaendert($dir, 'tunnel', $hash);
        return 0 if hash_ausstehend($dir, 'tunnel', $hash);
        return 0 if !einreihen($dir, 'tunnel', $json, $hash);
        1;
    } ? 1 : 0;
}

sub neu_anfordern {
    my ($dir, $neu) = @_;
    return 'kein_optin' if !optin_gueltig($dir);
    return eval {
        if ($neu) {
            pin_loeschen($dir);
        } else {
            my $lock = _sperre($dir);
            my $k = _korb($dir, 1);
            $k->{hashes} = {};
            _korb_speichern($dir, $k);
        }
        'ok';
    } || 'kein_optin';
}

sub widerruf_offen { my ($dir) = @_; return _korb($dir, 0)->{widerruf} ? 1 : 0; }

sub widerruf_quittiert {
    my ($dir) = @_;
    my $lock = _sperre($dir);
    my $k = _korb($dir, 1);
    $k->{widerruf} = 0;
    return _korb_speichern($dir, $k);
}

sub einreihen {
    my ($dir, $key, $klartext, $hash) = @_;
    my ($st, $pin) = _laden(_pfad($dir, 'vault.json'));
    return 0 if $st ne 'ok' || !length($pin->{enc_pub} // '') || !defined $klartext || !length($key // '');
    my $enc = eval { FM::B64::b64u_decode($pin->{enc_pub}) };
    return 0 if !defined $enc || length($enc) != 32;
    my $cipher = eval { versiegeln($enc, $klartext) };
    return 0 if !defined $cipher;
    my $lock = _sperre($dir);
    my $k = _korb($dir, 1);
    $k->{eintraege}{$key} = { cipher => $cipher, version => ($pin->{version} // 0) + 0, (defined $hash ? (hash => $hash) : ()) };
    _korb_speichern($dir, $k);
    return 1;
}

sub ausstehend {
    my ($dir) = @_;
    my $e = _korb($dir, 0)->{eintraege};
    return [ map { { entry_key => $_, key_version => $e->{$_}{version}, cipher => $e->{$_}{cipher} } } sort keys %$e ];
}

sub bestaetigt {
    my ($dir, $keys, $gesendet) = @_;
    my $lock = _sperre($dir);
    my $k = _korb($dir, 1);
    for my $key (@{ $keys || [] }) {
        if (ref($gesendet) eq 'HASH') {
            my $e = $k->{eintraege}{$key};
            next if ref($e) eq 'HASH' && (!defined $gesendet->{$key} || ($e->{cipher} // '') ne $gesendet->{$key});
        }
        my $e = $k->{eintraege}{$key};
        $k->{hashes}{$key} = $e->{hash} if ref($e) eq 'HASH' && defined $e->{hash} && length $e->{hash};
        delete $k->{eintraege}{$key};
    }
    return _korb_speichern($dir, $k);
}

sub hash_geaendert {
    my ($dir, $hkey, $hex) = @_;
    my $alt = _korb($dir, 0)->{hashes}{$hkey};
    return (defined $alt && $alt eq $hex) ? 0 : 1;
}

sub namen_speichern {
    my ($dir, $roh) = @_;
    return 0 if ref($roh) ne 'HASH';
    my %neu;
    for my $k (keys %$roh) {
        next if $k !~ /^ms[0-9]{1,3}\z/;
        my $v = $roh->{$k};
        next if !defined $v || ref($v) || $v eq '';
        $neu{$k} = substr($v, 0, 190);
    }
    my $pfad = _pfad($dir, 'vault_namen.json');
    my ($st, $alt) = _laden($pfad);
    my $json = JSON::PP->new->ascii->canonical;
    return 1 if $st eq 'ok' && $json->encode($alt) eq $json->encode(\%neu);
    my $lock = _sperre($dir);
    _speichern($pfad, \%neu);
    return 1;
}

sub namen_bekannt {
    my ($dir) = @_;
    my ($st) = _laden(_pfad($dir, 'vault_namen.json'));
    return $st eq 'ok' ? 1 : 0;
}

sub server_name {
    my ($dir, $msno) = @_;
    my ($st, $n) = _laden(_pfad($dir, 'vault_namen.json'));
    return undef if $st ne 'ok';
    my $v = $n->{"ms$msno"};
    return (defined $v && !ref($v) && length $v) ? $v : undef;
}

sub hash_ausstehend {
    my ($dir, $hkey, $hex) = @_;
    my $e = _korb($dir, 0)->{eintraege}{$hkey};
    return (ref($e) eq 'HASH' && defined $e->{hash} && $e->{hash} eq $hex) ? 1 : 0;
}

sub hash_merken {
    my ($dir, $hkey, $hex) = @_;
    my $lock = _sperre($dir);
    my $k = _korb($dir, 1);
    $k->{hashes}{$hkey} = $hex;
    return _korb_speichern($dir, $k);
}

sub zeichen {
    my ($s) = @_;
    return $s if !defined $s || $s =~ /[^\x00-\xff]/;
    my $d = eval { Encode::decode('UTF-8', Encode::encode('ISO-8859-1', $s), Encode::FB_CROAK() | Encode::LEAVE_SRC()) };
    return defined $d ? $d : $s;
}

sub ms_klartext {
    my ($msno, $name, $user, $pass) = @_;
    return JSON::PP->new->canonical->utf8->encode({
        typ => 'ms', msno => $msno + 0, name => $name // '', user => $user // '', pass => $pass,
        note => "Miniserver Nr. $msno",
    });
}

sub ms_hash {
    my ($sitekey, $klartext) = @_;
    return Digest::SHA::hmac_sha256_hex($klartext, $sitekey);
}

sub ms_einreihen {
    my ($dir, $sitekey, $msno, $name, $user, $pass) = @_;
    return 0 if !defined $sitekey || !length($sitekey) || !defined $pass || !defined $msno;
    my $ok = eval {
        $user = zeichen($user);
        $pass = zeichen($pass);
        my $hkey = "ms$msno";
        my $klar = ms_klartext($msno, $name, $user, $pass);
        my $hash = ms_hash($sitekey, $klar);
        return 0 if !hash_geaendert($dir, $hkey, $hash);
        return 0 if hash_ausstehend($dir, $hkey, $hash);
        return 0 if !einreihen($dir, $hkey, $klar, $hash);
        1;
    };
    return $ok ? 1 : 0;
}

sub rumpf_erweitern {
    my ($dir, $body) = @_;
    eval {
        if (optin_gueltig($dir)) {
            my $liste = ausstehend($dir);
            $body->{vault} = $liste if @$liste;
        }
        $body->{vault_widerruf} = 1 if widerruf_offen($dir);
        1;
    };
    return;
}

sub antwort_verarbeiten {
    my ($dir, $site, $ans, $body) = @_;
    my @ev;
    return @ev if ref($ans) ne 'HASH';
    eval {
        if (ref($ans->{vault}) eq 'HASH' && optin_gueltig($dir)) {
            my $vs = info_pruefen($dir, $site, $ans->{vault});
            if ($vs eq 'identitaet_geaendert' || $vs eq 'signatur_ungueltig') {
                push @ev, ['vault_' . $vs, 'Der Tresorschluessel des Servers wurde abgelehnt.'];
            } elsif ($vs eq 'pin_defekt') {
                push @ev, ['vault_pin_defekt', 'Die lokale Tresor-Pinndatei ist unlesbar - es wird nichts gesendet.'];
            }
        }
        1;
    };
    eval {
        if (ref($ans->{vault_ok}) eq 'ARRAY') {
            my $gesendet;
            if (ref($body) eq 'HASH') {
                $gesendet = {};
                if (ref($body->{vault}) eq 'ARRAY') {
                    for my $e (@{ $body->{vault} }) { $gesendet->{ $e->{entry_key} } = $e->{cipher} if ref($e) eq 'HASH'; }
                }
            }
            bestaetigt($dir, $ans->{vault_ok}, $gesendet);
        }
        1;
    };
    eval { widerruf_quittiert($dir) if $ans->{vault_widerruf_ok}; 1 };
    eval { namen_speichern($dir, $ans->{vault_namen}) if ref($ans->{vault_namen}) eq 'HASH' && optin_gueltig($dir); 1 };
    return @ev;
}

1;

