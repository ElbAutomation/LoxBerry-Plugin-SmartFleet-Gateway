# LoxBerry SmartFleet Gateway
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

package FM::Meldung;
use strict;
use warnings;
use utf8;
use Scalar::Util qw(blessed);
use overload '""' => \&text, 'eq' => sub { "$_[0]" eq "$_[1]" }, 'ne' => sub { "$_[0]" ne "$_[1]" },
    'bool' => sub { 1 }, fallback => 1;

our %TEXT = (
    ms                              => 'Miniserver {1}: {2}',
    kennung                         => '{1}: {2}',
    wer_ms                          => 'Miniserver {1}',
    wer_plugin                      => 'Plugin',

    backup_pakete_fehlen            => 'Paket libcryptx-perl oder libcompress-raw-lzma-perl fehlt - es wird NICHT unverschlüsselt gesichert',
    backup_fehlgeschlagen           => '{1}: Backup fehlgeschlagen - {2}',
    backup_erfolgreich              => '{1}: Backup erfolgreich hochgeladen',
    backup_unvollstaendig           => '{1}: {2} von {3} Dateien nicht gesichert',
    backup_plugin_kein_passwort     => 'Plugin: kein Miniserver-Passwort verfügbar - Verschlüsselung nicht möglich, kein Eigenbackup',
    nicht_hochgeladen               => '{1}: nicht hochgeladen - {2}',
    nicht_hochgeladen_abwaehlen     => '{1}: nicht hochgeladen - {2} (in den Einstellungen des Plugins abwählen)',

    grund_anderes_gateway           => 'der Miniserver wird von einem anderen Gateway übertragen',
    grund_speicher_voll             => 'Speicherplatz des Standorts erschöpft',
    grund_speicher_voll_stueck      => 'Speicherplatz des Standorts erschöpft (nach Stück {1})',
    grund_uebertragung_stueck       => 'Übertragung fehlgeschlagen (Stück {1}, HTTP {2})',
    grund_abschluss_abgelehnt       => 'Abschluss abgelehnt (HTTP {1})',
    grund_keine_dateien             => 'keine Dateien',
    grund_keine_datei_holbar        => 'keine einzige Datei holbar',
    grund_kein_passwort             => 'kein Passwort - Verschlüsselung nicht möglich',
    backup_kein_tresor              => 'Kein Passwort Tresor eingerichtet - keine Backups',
    backup_kein_php                 => 'PHP mit sodium fehlt - keine Backups',
    grund_kein_tresor               => 'beim Server ist kein Passwort Tresor eingerichtet',
    grund_tresor_ungueltig          => 'Schlüssel des Passwort Tresors unbrauchbar',
    grund_helfer                    => 'Verschlüsselung fehlgeschlagen: {1}',
    grund_kein_ms_passwort          => 'kein Miniserver-Passwort hinterlegt - Verschlüsselung nicht möglich',
    grund_auflisten                 => 'Auflisten fehlgeschlagen: {1}',
    grund_groesse                   => 'Größengrenze überschritten: {1} von {2} Byte',
    grund_unbekannt                 => 'unbekannter Fehler',
    grund_nicht_holbar              => '{1} nicht holbar',
    grund_entpacken                 => 'Entpacken fehlgeschlagen - {1}',
    grund_stueck_nicht_lesbar       => 'Stück {1} nicht lesbar',
    grund_version_unbekannt         => 'Server kennt die zwischengespeicherte Version nicht mehr - eine echte Datei wird gebraucht',

    projekt_verzeichnis             => 'Programmverzeichnis nicht auflistbar',
    projekt_kein_stand              => 'kein Programmstand gefunden',
    projekt_zu_gross                => 'Programmdatei zu groß ({1} MB, Grenze {2} MB)',
    projekt_uebertragung            => 'Übertragung fehlgeschlagen - {1}',
    projekt_aktualisiert            => 'Programm aktualisiert',

    chart_nicht_lesbar              => '{1} Chart-Werte nicht lesbar',
    chart_zeitbudget                => 'Zeitbudget erreicht, Chart-Werte unvollständig',

    healthcheck_nicht_verfuegbar    => 'LoxBerry-Healthcheck nicht verfügbar',
    healthcheck_nicht_gestartet     => 'LoxBerry-Healthcheck ließ sich nicht starten',
    healthcheck_fehlgeschlagen      => 'LoxBerry-Healthcheck fehlgeschlagen (Exitcode {1})',

    tresor_abgelehnt                => 'Der Tresorschlüssel des Servers wurde abgelehnt.',
    tresor_pin_defekt               => 'Die lokale Tresor-Pinndatei ist unlesbar - es wird nichts gesendet.',

    job_pong                        => 'Antwort erhalten',
    job_backup_gesichert            => 'Backup erstellt',
    job_backup_fehler               => 'Backup-Lauf mit Fehler beendet ({1})',
    job_plugin_daten                => 'Plugin-Daten nicht lesbar',
    job_update_keine_releasecfg     => 'Keine release.cfg gefunden',
    job_update_aktuell              => 'Bereits aktuell',
    job_update_archiv_http          => 'Archiv nicht ladbar (HTTP {1})',
    job_update_archiv_ablage        => 'Archiv nicht ablegbar',
    job_update_nicht_gestartet      => 'plugininstall.pl nicht gestartet',
    job_update_gestartet            => 'Update auf {1} gestartet',
    job_nicht_ablegbar              => 'Die Anforderung ließ sich auf dem Gateway nicht ablegen',
    job_projekt_neu                 => 'Projektdatei wird beim nächsten Lauf neu abgerufen',
    job_tresor_aus                  => 'Übermittlung an den Tresor ist auf dem Gateway nicht aktiviert',
    job_tresor_neu                  => 'Neuer Tresor: Schlüssel wird übernommen, Passwörter werden neu übertragen',
    job_tresor_erneut               => 'Passwörter werden neu übertragen',
    job_unvollstaendig              => 'Auftrag unvollständig',
    job_tunnel_gestartet            => 'Fernwartung gestartet',
    job_tunnel_nicht_gestartet      => 'Fernwartung nicht gestartet',
    job_tunnel_beendet              => 'Fernwartung beendet',
    job_tunnel_nicht_beendet        => 'Fernwartung nicht beendet',
    job_unbekannt                   => 'Das Gateway kennt diesen Auftrag nicht',
    job_ausnahme                    => 'Ausnahme: {1}',
);

sub new {
    my ($cls, $code, @args) = @_;
    die "FM::Meldung: unbekannter Code '$code'\n" if !defined $code || !exists $TEXT{$code};
    return bless { code => $code, args => \@args }, $cls;
}

sub code { return $_[0]{code}; }

sub ist { my ($v) = @_; return blessed($v) && $v->isa(__PACKAGE__) ? 1 : 0; }

sub text {
    my ($self) = @_;
    my $t = $TEXT{ $self->{code} };
    my @a = @{ $self->{args} };
    $t =~ s/\{([1-9])\}/_wert($a[$1 - 1])/ge;
    return $t;
}

sub _wert {
    my ($v) = @_;
    return '' if !defined $v;
    return $v->text if ist($v);
    my $s = "$v";
    $s =~ tr/./,/ if $s =~ /\A-?[0-9]+\.[0-9]+\z/;
    return $s;
}

sub args_json {
    my ($self) = @_;
    return [ map {
        ist($_) ? $_->json
        : !defined $_ ? ''
        : /\A-?(?:0|[1-9][0-9]{0,14})(?:\.[0-9]+)?\z/ ? 0 + $_
        : "$_"
    } @{ $self->{args} } ];
}

sub json {
    my ($self) = @_;
    my $h = { code => $self->{code} };
    my $a = $self->args_json;
    $h->{args} = $a if @$a;
    return $h;
}

1;

