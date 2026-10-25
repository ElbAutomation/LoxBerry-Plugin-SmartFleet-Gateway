<?php
// Verschluesselt ein Backup im Datenstrom fuer den Passwort Tresor (Spec
// 2026-10-21-backup-tresor-design.md, Abschnitt 4.1): Format SFX1 wie
// FM\Chiffrat im SmartFleet Server, der Dateischluessel K versiegelt im
// Format 1 wie FM\Siegel und vault-krypto.js dort.
//
// Warum PHP: Perl hat kein XChaCha20 (CryptX 0.085 nur mit 12-Byte-Nonce,
// gemessen), das PHP von LoxBerry 4 hat sodium fest eingebaut (Debian-Paket
// libsodium23, siehe dpkg/apt).
//
// K entsteht hier und verlaesst diesen Prozess nie - weder als Argument
// (Prozessliste) noch auf stdout. FM::Backup::Sfx1 spricht mit dem Helfer
// im Wechsel ueber stdin/stdout, eine Anfrage, eine Antwort:
//
//   Start:   Segmentgroesse (uint32 BE)  -> Antwort: SFX1-Kopf (25 Byte)
//   'S'|'E': Laenge | Klartext            -> Antwort: Segment (E = letztes)
//   'K':     Laenge | 32 Byte Startkopf   -> Antwort: Nonce | Chiffretext
//   'V':     Laenge | enc_pub (32 Byte)   -> Antwort: Siegel (base64url)
//   Ende der Eingabe: Ende des Helfers.
//
// Jede Antwort ist Laenge (uint32 BE) | Daten. Ein Fehler geht nach stderr,
// der Helfer endet mit 1.
//
// --pruefen: endet mit 0, wenn alle noetigen Funktionen da sind.
declare(strict_types=1);

const MAGIC = "SFX1\x01";
const KOPF_AD = 'SFK1';
const INFO = 'smartfleet-vault-v1';

function sfx1_tauglich(): bool
{
    foreach (array('sodium_crypto_aead_xchacha20poly1305_ietf_encrypt', 'sodium_crypto_box_keypair', 'sodium_crypto_scalarmult',
                   'hash_hkdf', 'hash_hmac', 'random_bytes', 'openssl_encrypt', 'openssl_get_cipher_methods') as $f) {
        if (!function_exists($f)) {
            return false;
        }
    }
    return in_array('aes-256-ctr', openssl_get_cipher_methods(), true);
}

function sfx1_fehler(string $text): void
{
    fwrite(STDERR, 'fm_sfx1: ' . $text . "\n");
    exit(1);
}

function sfx1_lesen($in, int $n): string
{
    $s = '';
    while (strlen($s) < $n) {
        $t = fread($in, $n - strlen($s));
        if ($t === false || $t === '') {
            return $s;
        }
        $s .= $t;
    }
    return $s;
}

function sfx1_antwort($out, string $daten): void
{
    $s = pack('N', strlen($daten)) . $daten;
    $o = 0;
    while ($o < strlen($s)) {
        $w = fwrite($out, substr($s, $o));
        if ($w === false || $w === 0) {
            sfx1_fehler('stdout geschlossen');
        }
        $o += $w;
    }
    fflush($out);
}

function sfx1_b64u(string $b): string
{
    return rtrim(strtr(base64_encode($b), '+/', '-_'), '=');
}

/** Siegel Format 1: 0x01 | eph_pub | iv | AES-256-CTR | HMAC-SHA256 (wie FM\Siegel im SmartFleet Server). */
function sfx1_siegel(string $encPub, string $klartext): string
{
    if (strlen($encPub) !== SODIUM_CRYPTO_BOX_PUBLICKEYBYTES) {
        sfx1_fehler('enc_pub ungueltig');
    }
    $eph = sodium_crypto_box_keypair();
    $shared = sodium_crypto_scalarmult(sodium_crypto_box_secretkey($eph), $encPub);
    $okm = hash_hkdf('sha256', $shared, 64, INFO, '');
    $iv = random_bytes(16);
    $ct = openssl_encrypt($klartext, 'aes-256-ctr', substr($okm, 0, 32), OPENSSL_RAW_DATA, $iv);
    if ($ct === false) {
        sfx1_fehler('aes-256-ctr');
    }
    $kopf = "\x01" . sodium_crypto_box_publickey($eph) . $iv . $ct;
    return sfx1_b64u($kopf . hash_hmac('sha256', $kopf, substr($okm, 32, 32), true));
}

if (in_array('--pruefen', $argv, true)) {
    exit(sfx1_tauglich() ? 0 : 1);
}
if (!sfx1_tauglich()) {
    sfx1_fehler('sodium oder openssl fehlt');
}

$in = STDIN;
$out = STDOUT;
$s = sfx1_lesen($in, 4);
if (strlen($s) !== 4) {
    sfx1_fehler('keine Segmentgroesse');
}
$seg = unpack('N', $s)[1];
if ($seg < 1024 || $seg > 1048576) {
    sfx1_fehler('Segmentgroesse ausserhalb 1 KiB bis 1 MiB');
}
$k = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES);
$kopf = MAGIC . random_bytes(16) . pack('N', $seg);
sfx1_antwort($out, $kopf);

$nr = 0;
$ende = false;
while (true) {
    $typ = fread($in, 1);
    if ($typ === false || $typ === '') {
        break;
    }
    $l = sfx1_lesen($in, 4);
    if (strlen($l) !== 4) {
        sfx1_fehler('Laenge fehlt');
    }
    $n = unpack('N', $l)[1];
    if ($n > $seg) {
        sfx1_fehler('Anfrage zu lang');
    }
    $p = sfx1_lesen($in, $n);
    if (strlen($p) !== $n) {
        sfx1_fehler('Anfrage abgeschnitten');
    }
    if ($typ === 'S' || $typ === 'E') {
        if ($ende || $n === 0) {
            sfx1_fehler($ende ? 'Segment nach dem Ende' : 'leeres Segment');
        }
        $ende = $typ === 'E';
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $c = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt($p, $kopf . pack('N', $nr) . ($ende ? "\x01" : "\x00"), $nonce, $k);
        $nr++;
        sfx1_antwort($out, pack('N', strlen($c)) . $nonce . $c);
    } elseif ($typ === 'K') {
        if ($n !== 32) {
            sfx1_fehler('Startkopf nicht 32 Byte');
        }
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        sfx1_antwort($out, $nonce . sodium_crypto_aead_xchacha20poly1305_ietf_encrypt($p, KOPF_AD . $kopf, $nonce, $k));
    } elseif ($typ === 'V') {
        sfx1_antwort($out, sfx1_siegel($p, sfx1_b64u($k)));
    } else {
        sfx1_fehler('unbekannte Anfrage');
    }
}
if (function_exists('sodium_memzero')) {
    sodium_memzero($k);
}
exit(0);
