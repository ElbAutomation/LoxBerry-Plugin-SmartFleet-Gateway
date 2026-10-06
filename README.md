# LoxBerry SmartFleet Gateway

LoxBerry-Plugin, das eine Loxone-Installation an einen
[SmartFleet](https://smartfleetmanager.de)-Server anbindet. Es läuft beim
Kunden auf dem LoxBerry und erledigt dort die Arbeit vor Ort: Kennzahlen der
Miniserver und des LoxBerry erfassen, Konfigurations-Backups ziehen, Aufträge
des Partners ausführen und auf dessen Anforderung eine zeitlich begrenzte
Fernwartung öffnen.

Eine Installation lässt sich auf zwei Wegen an den Server anbinden:

| | |
|---|---|
| **SmartFleet Gateway** | das eigene Hutschienengerät — der Regelweg |
| **LoxBerry SmartFleet Gateway** | dieses Plugin — wenn in der Installation bereits ein LoxBerry läuft |

Der Server läuft beim Systemintegrator und ist nicht Teil dieses
Repositories.

## Was das Gateway tut

| | |
|---|---|
| **Telemetrie** | Alle fünf Minuten Kennzahlen von den Miniservern und vom LoxBerry, im Minutentakt zum Server |
| **Statistikwerte** | Die Bausteinausgänge, die der Partner auf dem Server auswählt, alle fünf Minuten — Grundlage für Charts, Dashboards und Alarme |
| **Backups** | Nach Zeitplan die Konfiguration der Miniserver über `fslist`/`fsget`, als ZIP (auf Wunsch AES-256), stückweise zum Server; dazu ein Eigenbackup des Plugins |
| **Projektdatei** | Die Loxone-Projektdatei der Miniserver, aus der der Server den Katalog der Bausteine aufbaut |
| **Passwort-Tresor** | Nur nach Zustimmung des Betreibers: die Passwörter der Miniserver und das Fernwartungs-Passwort, verschlüsselt an den Tresor des Partners |
| **Aufträge** | Das Gateway fragt beim Poll, ob etwas anliegt — es nimmt keine Verbindung von außen an |
| **Fernwartung** | Auf Anforderung des Partners, zeitlich begrenzt, nur nach Prüfung eines Passworts, das der Betreiber selbst vergibt |

## Das Gateway baut keine Verbindung von außen auf

Es gibt keinen offenen Port und keinen Dienst, der auf Anfragen wartet. Das
Gateway fragt im Minutentakt beim Server nach, ob etwas zu tun ist, und
entscheidet dann selbst.

Für eine Fernwartung müssen **drei** Bedingungen gleichzeitig erfüllt sein:

1. Zugang zum Server — ohne ihn entsteht gar kein Auftrag
2. das Fernwartungs-Passwort — das Gateway prüft es gegen sein lokal
   abgelegtes Geheimnis; der Server kennt das Passwort **nie**
3. der Signaturschlüssel des Servers — das Gateway verwirft jeden
   unsignierten Auftrag

Das Fernwartungs-Passwort vergibt der Betreiber des LoxBerry selbst, in der
Plugin-Oberfläche. Dort kann er die Fernwartung auch ganz sperren.

## Voraussetzungen

- **LoxBerry 4.0.0.15 oder neuer, empfohlen 4.0.0.16.** Ältere Versionen
  als 4.0.0.16 beenden beim „Remote-Support beenden" *alle*
  `cloudflared`-Prozesse, also auch die Fernwartung dieses Plugins. Das ist
  kein Sicherheitsproblem — der Tunnel geht zu, nicht auf —, aber die
  Verbindung bräche ohne erkennbaren Grund ab.
- Das Paket `libdata-password-zxcvbn-perl` wird bei der Installation
  automatisch nachgezogen.

## Installation

Über die Plugin-Verwaltung des LoxBerry, mit dem ZIP-Archiv von der Seite
[Download](https://smartfleetmanager.de/download/) oder aus den
[Releases](../../releases). In der Plugin-Verwaltung erscheint das Plugin
als „SmartFleet Gateway".

Nach der Installation trägt man in der Plugin-Oberfläche den
Bereitstellungscode ein, den der Partner erzeugt hat. Danach meldet sich der
Standort selbstständig an und arbeitet im Minutentakt.

Ausführlich im Handbuch:
[Plugin installieren](https://smartfleetmanager.de/docs/plugin/installieren/),
[Standort koppeln](https://smartfleetmanager.de/docs/plugin/standort-koppeln/).

## Lizenz

Quelloffen einsehbar, aber nicht frei: Der Quelltext ist veröffentlicht, damit
nachvollziehbar ist, was auf dem eigenen LoxBerry läuft. Der Betrieb auf
eigenen und betreuten Installationen ist unentgeltlich erlaubt; Weitergabe,
Veränderung und die Übernahme von Quelltext sind es nicht. Einzelheiten in
[LICENSE](LICENSE).

Anfragen zu abweichenden Nutzungsrechten: info@smartfleetmanager.de
