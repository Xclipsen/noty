# Heft-Backup und Wiederherstellung – Format 1

## Ergänzung 22.10.2026 · Textdokumente in `.noty` und Bibliotheksbackup

Kein neues Archivformat: `.noty`/`.notybackup` Format 2 und `.notylibrary` Format 2 tragen Textdokumente als Notebook-Datensatz mit `notebookSchemaVersion` 15 und `kind: "textDocument"`. Der Import legt sie als Textdokument an (Index-Hinweis aus der Datei), der Bibliotheks-Restore übernimmt die Art aus den Dokumenten, auch wenn das archivierte Index-`kind` fehlt. Ältere Builds lehnen solche Dateien als „Dokumentformat 15“ ab. `verify_backup.py` gibt zusätzlich `kind` aus, `verify_library_backup.py` zählt `textDocuments`. Host-Roundtrip und Prüfer-Negativtests bestanden; am iPad ungeprüft.

## Ergänzung 22.10.2026 · `.noty`-Datei

Stand: **implementiert und erfolgreich gebaut (`xtool dev build`), nicht installiert, auf dem iPad ungeprüft.** Spezifikation: [TEXT-REBUILD-62](TEXT-REBUILD-62.md) Abschnitt 5. Überholt unten „Titelzusatz (Wiederhergestellt)“ und für Heftdateien „Restore als getrennte Kopie unter `Restores/`“ sowie in [LIBRARY-BACKUP](LIBRARY-BACKUP.md) „Heft als getrennte Kopie“.

- **Format unverändert:** Heft-Backups werden als `<Titel>.noty` geschrieben; der Inhalt ist exakt `.notybackup` Format 2 (kein Schema-, Kopf- oder Datensatzwechsel). Neuer exportierter UTType `de.la.noty.document` (Endung `noty`, `public.data`), Dokumenttyp „noty-Datei“ (Owner) für `.noty` und `.notybackup`. `.notybackup` (`de.la.noty.backup`) bleibt deklariert und importierbar, `.notylibrary` unverändert. `verify_backup.py` prüft unabhängig von der Endung (Negativtest mit `.noty` in `check_verifiers.sh`, Host-Roundtrip schreibt `heft.noty`).
- **Aufräumen fehlgeschlagener Importe:** Ein Stage bleibt zur Analyse liegen und wird beim nächsten Bibliotheksstart nach 24 Stunden entfernt (nur UUID-Ordner direkt in `BackupStaging/`). Per AirDrop, Mail oder „Kopieren nach noty“ gelieferte Dateien in `Documents/Inbox` werden nach der Bearbeitung entfernt, Reste nach 24 Stunden.
- **Import** (Dateien-App „In noty öffnen“, Bibliothek „Neu › Heft importieren (.noty) …“): derselbe gestufte, geprüfte Weg wie bisher (Stage, Streaming-Prüfung, Apple-Prüfung, erneute Stage-Prüfung, frisch zurückgelesen). Das Paket entsteht aber als normales Bibliotheksheft `Library/Documents/<neue ID>` (`source = library`), nicht unter `Restores/`, keine Kennzeichnung „wiederhergestellte Kopie“, nicht in „Wiederhergestellte Kopien“. Immer neue Dokument-ID; Seiten-/Objekt-IDs bleiben innerhalb des Hefts. Titel exakt aus der Datei; Steuerzeichen werden Leerzeichen, > 120 Zeichen gekürzt, leer → „Unbenanntes Heft“. Paket vor Indexeintrag; ein Abbruch dazwischen hinterlässt ein auffindbares Heft, nie einen Indexeintrag ohne Paket. Abbrechen der Nachfrage entfernt das unveröffentlichte Stage.
- **Gleiche Dokument-ID schon aktiv in der Bibliothek:** Nachfrage „Vorhandenes ersetzen“ oder „Beide behalten“ (oder Abbrechen). *Ersetzen:* in **einem** Indexcommit kommt das vorhandene Heft mit seinem letzten bestätigten Stand in den Bibliothekspapierkorb (Paket unberührt, wiederherstellbar) und das importierte Heft an dieselbe Stelle (gleicher Ordner, gleiche Reihenfolge, Anheftung). Das Importheft erhält trotzdem eine **neue** Identität: der Papierkorbeintrag braucht seine ID, und ein Überschreiben des bestehenden Pakets wäre ein zweiter Writer auf ein vorhandenes Heft. Import nur bei geschlossenem Notizbuch, daher ist der bestätigte Stand der aktuelle. *Beide behalten:* normaler Import mit „Titel (n)“. Papierkorbeinträge mit gleicher ID lösen keine Nachfrage aus.
- **Namensgleichheit:** „Titel (1)“, „Titel (2)“ … (erste freie Nummer) statt „(Wiederhergestellt)“, beim Import und bei Kopien aus der lokalen Historie (diese bleiben wiederhergestellte Kopien unter `Restores/`). Reine Core-Funktion `NotebookTitles.unique`. Vergleichsbereich: alle **aktiven Hefte des Bibliotheksbereichs** (alle Ordner, ohne Papierkorb, ohne Ordnernamen), Groß-/Kleinschreibung und Unicode-Normalform egal. Begründung: Suche, Angeheftet und Zuletzt zeigen Hefte ordnerübergreifend; Papierkorbeinträge sind unsichtbar und dürfen beim Ersetzen den Titel nicht auf „(1)“ schieben. „Bio (1)“ setzt eine bestehende Reihe fort („Bio (2)“), „Klasse (10)“ ohne „Klasse“ wird „Klasse (10) (1)“. Historienkopien berücksichtigen zusätzlich noch nicht indizierte Kopien derselben Editor-Sitzung.
- **Teilen als .noty:** im Heftmenü (Teilen und exportieren) und im Kontextmenü der Bibliothek. Erzeugt die geprüfte Datei `<Titel>.noty` (Dateiname: `/ \ : ? * " < > |` → „-“, Steuerzeichen → Leerzeichen, ohne führende Punkte, ≤ 200 UTF-8-Bytes, leer → „Heft“) in einem eigenen Ordner unter `tmp/NotyBackupArchives` und öffnet das Teilen-Menü; nach dessen Ende entfernt, Reste > 1 Tag beim Start. Editor: aktueller Wert-Snapshot wie beim Backup; Bibliothek: letzter bestätigter Stand mit Bibliothekstitel, eine beschädigte neueste Revision wird abgelehnt statt still einen älteren Stand zu teilen. Der Export-Dialog („Vollständiges Backup …“) schreibt ebenfalls `.noty` mit dem Titel als Vorschlag. PDF-Teilen bleibt getrennt. Ein abgeschlossenes Teilen ist kein Nachweis eines Empfangs oder Cloud-Uploads.
- **Nachweise:** Core-Tests `NotyFileTests` (Namensvergabe, Bereich, Dateinamen, Import als normales Heft ohne Restored-Kennzeichnung, ID-Kollision Ersetzen/Beide behalten, Abbruch, Historienkopien), alle Core-Tests, Host-Roundtrip, Prüfer-Negativtests, `xtool dev build` mit beiden UTTypes in der gebauten `Info.plist`. **Auf dem iPad ungeprüft:** „In noty öffnen“ für `.noty`/`.notybackup`, Teilen-Menü (AirDrop/Dateien/Nachrichten) und Dateiname, Nachfrage bei ID-Kollision, Ersetzen samt Papierkorb und Position, Historienkopie mit „(n)“.

## Ergänzung 21.10.2026 · Format 2 (Datensatzstrom mit Bild-Assets)

Stand: **implementiert und erfolgreich gebaut, nicht installiert, am iPad ungeprüft.** Überholt „≤ 200 MB, im Speicher geprüft“ unten.

- **Schreiben:** Die App schreibt nur noch `.notybackup` Format 2: Magic, Kopf (`backupFormatVersion: 2`, `checksumAlgorithm`, `assetHashAlgorithm: "sha256"`, `documentID`, `notebookSchemaVersion`, `createdAt`, sortierte Schlüssel), dann genau ein Heft-Datensatz (CRC-32), danach jedes eindeutige Bildoriginal genau einmal als Asset-Datensatz (SHA-256 statt CRC), zuletzt ein Abschlussdatensatz mit Anzahl und Nutzlastbytes. Geschrieben wird gestreamt in eine Datei unter `tmp/NotyBackupArchives` (4-MB-Blöcke), danach vollständig zurückgelesen und geprüft; der Export übergibt die Datei, ohne sie in den Speicher zu laden. Nicht gespeicherte neue Bilder (Pending) sind enthalten.
- **Grenzen:** Datei ≤ 800 MB (Heft-JSON ≤ 200 MB ohne Bildoriginale, Bildoriginale ≤ 500 MB, Asset ≤ 20 MB). Unbekannte Version ≥ 3 → „Backupformat 3 benötigt eine neuere noty-Version“.
- **Lesen und Restore:** Format 1 und Prototyp-JSON bleiben lesbar (im Speicher, ≤ 200 MB). Eine Wiederherstellung kopiert die Datei blockweise ins Stage, prüft sie streamend (jedes Asset per SHA-256) und schreibt die Originale nach `BackupStaging/<id>/Assets/`; Dateinamen stammen nur aus geprüften Hashes. Vor dem Commit werden Größe und CRC der Stage-Datei und die SHA-256 jedes Originals erneut geprüft. Die Kopie entsteht als neues Paket mit Schema 12 und eigenen Assets (Assets zuerst, Manifest zuletzt), wird frisch zurückgelesen und erst dann das Stage entfernt. Auch Format-1-Backups mit eingebetteten Bildern werden so zu Schema-12-Kopien; das bestehende Heft bleibt unberührt.
- **Rückspielbarkeit:** Builds ≤ 53 lehnen Format 2 ab („Backupformat 2 benötigt eine neuere noty-Version“); ein Backup aus diesem Stand lässt sich dort **nicht** wiederherstellen. Vor einer Rückkehr zu einem älteren Build gibt es keinen Rückweg außer einem früher erstellten Format-1-Backup.
- **Prüfer:** `python3 -B scripts/verify_backup.py ARCHIV [--compare REVISION.json]` liest Format 1 und 2, prüft jedes Asset per `hashlib.sha256` in 1-MB-Blöcken, verlangt genau die referenzierten Assets ohne Doppelte, Zusätze oder Anhang und gibt zusätzlich `formatVersion`, `assets`, `assetBytes` aus. CRC und SHA-256 erkennen Beschädigung, schützen aber nicht vor Manipulation.

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
