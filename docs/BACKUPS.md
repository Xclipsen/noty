# Heft-Backup und Wiederherstellung – Format 1

## Ergänzung 20.10.2026

`.notybackup` unverändert (≤ 200 MB, im Speicher geprüft). Neu: Öffnen aus der Dateien-App („In noty öffnen“) kopiert die Datei zuerst ins App-`tmp`, prüft sie und zeigt Titel/Seitenzahl zur Bestätigung; danach derselbe Staging-/Kopie-Weg wie beim Import, bei geöffnetem Notizbuch erst nach dem Schließen. Bibliotheksbackup jetzt gestreamt bis 4 GB, externe Ziele mit Zielprüfung, Backoff und Aufräumen eigener Teilstände: [LIBRARY-BACKUP.md](LIBRARY-BACKUP.md). Implementiert und gebaut, auf dem iPad ungeprüft.

## Ergänzung Build 21

Heft-/Bibliotheksarchive enthalten Schema-7-Umschlag/Papierstandard, gemischte Textformatierung und gesicherte Stände vor dem Leeren. Bibliotheksbackup enthält Werkzeugformat 4 einschließlich unterem Andocken, Autostift, Hover und Blättermodus. Containerformate unverändert; ältere unbekannte Notebook-/Werkzeugformate sperren. Unabhängiger Python-/Swift-Host-Roundtrip bestanden; externer Schema-7-Geräterestore noch ungeprüft. [Nachweise](UI-REBUILD.md). Aussagen zu fehlender WebDAV-/iCloud-Implementierung in den historischen Abschnitten unten wurden durch Build 20 überholt; dessen Geräteabnahme bleibt offen.

Stand: 17.10.2026. Build-7-Heftbackup implementiert, gebaut/installiert und vom iPad über PC zurück als Kopie wiederhergestellt; eindeutiger Text anschließend gespeichert/wieder geöffnet, beschädigtes Archiv auf dem iPad abgelehnt. Aktuell 73 Core-Tests; Nachweise in TESTING.md. Gilt für ein vollständiges aktuelles Heft, noch keine gesamte Bibliothek.

## Ergänzung für Build 11 (installiert, Gerätetest offen)

Eigenes `.notylibrary`-Format für die vollständige aktuelle Bibliothek einschließlich Ordnern, Papierkorb und Werkzeugpräferenzen implementiert und unter Linux geprüft. Restore öffnet einen neuen logischen Bereich und ersetzt die aktuelle Bibliothek nicht. Format, ausgeschlossene Historie und Grenzen: [LIBRARY-BACKUP.md](LIBRARY-BACKUP.md). Einzelheft-Format unten unverändert; auf dem Gerät inzwischen Build 11, Vorbestand nach Update vollständig erhalten. Der neue externe Geräte-Roundtrip steht aus. Aktuell 92 Core-Tests.

## Drei getrennte Funktionen

Ab Build 10 existiert eine Bibliothek mit Ordnern und mehreren Heften. Der bestehende Export bleibt ausdrücklich ein **Heft-Backup**; Index, Ordnerzuordnungen und andere Hefte sind nicht enthalten. Der vollständige Bibliotheksbackup/-restore ist in Build 11 vorbereitet; Geräte-Nachweis bleibt Voraussetzung für die Alltagsfreigabe. Aktuell 73 Core-Tests; neue Bibliotheksoberfläche noch nicht auf dem iPad abgenommen.

- **Automatisches lokales Speichern:** aktueller Arbeitsstand, erst nach Manifest-Commit „Lokal gespeichert“.
- **Lokale Wiederherstellung:** vorige konsistente Revisionen im App-Container, siehe STORAGE.md. Build 8 ergänzt einen Browser zum Öffnen älterer Stände als Kopie, Geräteprüfung noch offen. Kein Schutz gegen Deinstallation/Geräteverlust.
- **Exportiertes Heft-Backup:** eigenständige Datei mit Quelle und editierbaren Inhalten. Der Nutzer wählt den Ort im Dateien-Dialog. Erst ein Ort außerhalb des App-Containers oder eine unabhängig gesicherte PC-Kopie schützt gegen dessen Verlust. Ein PDF ist kein editierbares Backup.

Export-/Backupstatus ist von der lokalen Speichermeldung getrennt. Der letzte erfolgreiche Datei-Export wird lokal mit Datum gespeichert. Ein erfolgreicher Dateien-Dialog bestätigt die lokale Übergabe; kein Nachweis eines entfernten Cloud-Uploads. WebDAV-Zielverwaltung und tägliche automatische Sicherungsversuche fehlen noch.

## Offenes Dateiformat `.notybackup`

Keine Verschlüsselung, keine Kompression und keine ZIP-Abhängigkeit. Genau ein vollständiger Notebook-Snapshot:

| Abschnitt | Format |
| --- | --- |
| 0–7 | ASCII `NOTYBKP` gefolgt von LF |
| 8–11 | Manifestlänge, unsigned 32 Bit, Big Endian |
| danach | JSON-Manifest, UTF-8, maximal 64000 Bytes |
| danach | vollständiges Notebook-JSON, exakt angegebene Bytezahl, kein Anhang |

Manifest: `backupFormatVersion=1`, `checksumAlgorithm="crc32-iso-hdlc"`, `payloadName="notebook.json"`, `payloadByteCount`, `payloadCRC32`, `documentID`, `notebookSchemaVersion`, `createdAt` (ISO-8601). Gesamte Datei höchstens 200000000 Bytes.

Payload: unveränderte Original-PDF-Bytes, alle geordneten Seiten samt stabilen IDs/Geometrie, PencilKit-Daten und vollständiger Tastaturtext sowie Dokument-ID/Titel/Schemaversion. Aktuelle Revision exportieren, keine temporären Importpfade, Vorschaubilder oder Zugangsdaten. Die Bibliothek enthält ab Build 10 Ordner und mehrere Hefte; diese Struktur fehlt im bisherigen Einzelheft-Archiv. Bilder/Formobjekte folgen noch; das Bibliotheksformat muss sie später ebenfalls ergänzen. Importarchive und separat wiederhergestellte Hefte werden nicht pauschal in diesen einzelnen Heftexport aufgenommen.

Länge, CRC und Identität/Schemaversion werden geprüft. Neuere unbekannte Versionen abbrechen. CRC erkennt zufällige Beschädigung, keine Authentizität. Es werden keine vom Archiv bestimmten Dateipfade entpackt; `payloadName` muss exakt dem festen Namen entsprechen. Frühere reine Notebook-JSON-Exporte bleiben importierbar und werden als Altformat ohne Prüfsumme gekennzeichnet.

## Konsistenter Export

UI erfasst einen vollständigen Wert-Snapshot. Serialisierung und Prüfung auf dem Repository-Actor, Editor während der Vorbereitung gesperrt. Fertige Archivbytes vor Öffnen des Dialogs erneut vollständig validieren. Abgeschlossene Eingaben sind enthalten; laufende noch nicht abgeschlossene Stiftbewegungen nicht zugesichert. Fehler/Abbruch erzeugt keine Erfolgsmarkierung und verändert keine älteren Backupdateien.

## Restore als getrennte Kopie

1. Quelle mit aktivem Dateien-Zugriff in begrenzten Blöcken lesen; nicht erst unbegrenzt laden und danach Größe prüfen.
2. Version, Grenzen, Länge, CRC und Notebook prüfen, anschließend unveränderte Archivbytes in `Noty/BackupStaging/<UUID>/input.notybackup` atomar schreiben und erneut lesen/prüfen.
3. Kandidaten auf dem UI-Actor mit PDFKit/PencilKit und gemeinsamer Geometrie validieren. Noch kein Commit und kein Ersetzen des geöffneten Hefts.
4. Staging gegen vorbereiteten Snapshot erneut prüfen. Neue Dokument-ID und Titelzusatz „(Wiederhergestellt)“, Seiten-IDs/Inhalte bleiben innerhalb der Kopie erhalten.
5. In ein **neues leeres** `Noty/Restores/<neue Dokument-ID>/` mit regulärem Revisions-Commit schreiben und frisch zurücklesen. Vorhandene Ziele nie überschreiben.
6. Kopie separat öffnen und normal bearbeiten. Das ursprüngliche Heft bleibt geöffnet und unverändert. „Schließen“ kehrt zurück. Später über „Dateien → Wiederhergestellte Kopien“ wieder öffnen. Erfolgreiches Staging entfernen; fehlgeschlagene Stände erhalten.

Der Restore verändert weder Hauptmanifest noch Änderungszähler des ursprünglichen Hefts. Mehrere Imports erzeugen mehrere Kopien. Unlesbare Kopien werden gemeldet, nicht gelöscht. Das heutige Kopien-Menü ist noch kein vollständiger Explorer. Staging/Restore-Kopien haben noch keine automatische Speicherbereinigung. Ab Build 8 werden weitere Kopien auch bei Wiederherstellung aus einer Kopie in derselben gemeinsamen Sammlung angelegt.

## Unabhängige Prüfung auf dem PC

```bash
python3 scripts/verify_backup.py /pfad/zum/heft.notybackup
# Optional: vollständiger Vergleich mit dem zugehörigen lokalen Notebook-Snapshot
python3 scripts/verify_backup.py /pfad/zum/heft.notybackup --compare /pfad/zur/revision.json
```

Standardbibliothek, zlib-CRC unabhängig von Swift, keine Extraktion und keine Ausgabe von Notiztext. Prüft Struktur, Grenzen, CRC, Dokument-/Seitenidentitäten und Base64-Schichten; ersetzt keine Apple-Framework- oder Geräteprüfung. Alle tatsächlichen PC-Sicherungen unter `/home/la/Backups/`.

## Noch offen

Belegt: tatsächlicher Geräteexport, externe PC-Kopie, unabhängige Prüfung, Rücktransfer, Restore in leeren Kopiebereich, alle Ebenen sichtbar und eindeutiger Tastaturtext weiterbearbeitet/gespeichert/wieder geöffnet. Hauptheft beim gezielten Kopientest unverändert; beschädigtes Archiv auf dem iPad abgelehnt. Neu hinzugefügte Ink in der Kopie und lokale Historie noch separat prüfen. Danach: gesamter Bibliotheksbestand, iCloud/WebDAV-Ziele, tägliche Versuche/Retention, effiziente Assets und große Dokumente. Keine abgeschlossene V1-Backup-Abnahme.
