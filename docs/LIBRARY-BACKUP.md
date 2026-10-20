# Bibliotheksbackup und getrennte Bereiche – Build 11

## Ergänzung 20.10.2026 · Streaming, externe Ziele, Öffnen aus Dateien

Implementiert, Core-Tests, Host-Roundtrip und SDK-Build erfolgreich; nicht installiert, auf dem iPad ungeprüft. Überholt unten „Höchstens 200.000.000 Bytes“, „mehrere vollständige Snapshots im Speicher“ und „kein Streaming großer Archive“.

- **Format 1 unverändert.** Das Manifest wird vor den Blöcken mit maximaler Ziffernbreite reserviert und zuletzt geschrieben; der Rest ist mit Leerzeichen aufgefüllt (gültiges JSON, das Längenfeld schließt sie ein). Blöcke mit sortierten JSON-Schlüsseln; CRCs immer über die tatsächlich geschriebenen Bytes. Archive älterer Builds bleiben les- und wiederherstellbar; ältere Builds lesen neue Archive bis zu ihrer alten 200-MB-Grenze.
- **Grenzen:** Archiv ≤ 4.000.000.000 Bytes, Heftblock ≤ 200 MB (= größte Revision), Manifest ≤ 2 MB, Index ≤ 4 MB/10.000 Einträge, Werkzeuge ≤ 64 KB. Verstöße melden das betroffene Heft bzw. die Gesamtgröße.
- **Schreiben:** `LibraryStore.backupPlan` erfasst auf dem Bibliotheksactor nur Index (inkl. Papierkorb/Ordner), Präferenzen und Paketpfade. `LibraryArchive.write` liest danach außerhalb jedes Actors je Heft die bestätigte Revision (bei gleichzeitigem Commit bis zu drei frische Leseversuche; nur ältere gerettete Revision → Abbruch), prüft PDF (CoreGraphics), PencilKit und Bilder, kodiert, bildet CRC, hängt an und gibt frei. Danach liest ein Streaming-Durchlauf die fertige Datei vollständig zurück (CRC, Struktur, jedes Heft). Speicherbedarf ≈ ein Heft. Temporäre Archive nur in `tmp/NotyBackupArchives`, nie im Bibliotheksbaum; Reste > 1 Tag beim Start entfernt.
- **Offene Editoren** werden nur für Flush/Commit pausiert und arbeiten danach weiter; spätere Commits fehlen im Archiv. Endgültiges Löschen wartet auf ein laufendes Backup.
- **Restore:** Datei blockweise nach `Staging/<UUID>/input.notylibrary` kopieren, Streaming-Prüfung inkl. Apple-Prüfung je Heft; Abbruch oder fehlgeschlagene Vorbereitung entfernt dieses unveröffentlichte Stage. Commit: Größe+CRC der Stagingdatei, zweiter Streaming-Durchlauf schreibt jedes Heft einzeln in sein neues Paket und liest es zurück; der frische Store wird je Heft per kanonischer Neukodierung (Größe+CRC) mit dem Archivinhalt verglichen. Index zuletzt, Veröffentlichung unverändert.
- **Unabhängige Prüfung:** `verify_library_backup.py` liest blockweise, gleiche Grenzen, explizite Prüfungen statt `assert`, Exitcode 1 bei Fehler; gibt Gesamtgröße und Datei-CRC aus.

### Automatisches externes Backup

Ablauf: lokale Vorbedingung → Editor-/Werkzeug-Commit (sonst „verschoben“, kein Fehler, neuer Versuch nach einer Minute) → Zielprüfung (Ordner: Bookmark auflösbar, Ordner vorhanden – Schreibrechte zeigt erst der echte Schreibversuch; WebDAV: authentifiziertes `PROPFIND` Depth 0) → Archiv bauen → übertragen → zurücklesen → bereinigen. Fehlversuche verlängern den Abstand: 15 min, 1 h, 4 h, danach 12 h; Erfolg setzt zurück, „Jetzt sichern“ ignoriert den Abstand. Ergebnis, kurzer Grund und Fehlerzähler stehen optional in der Richtlinie (ältere gespeicherte Richtlinien bleiben lesbar).

- **Ordner/iCloud Drive:** alle Zugriffe über `NSFileCoordinator`. Kopie als `<name>.partial`, Rücklesen per Größe+CRC, Umbenennen, finales Rücklesen; Fehler entfernen den eigenen Teilstand, eine nicht bestätigte Enddatei wird entfernt (sonst in `.failed` umbenannt). `.<name>.icloud`-Platzhalter zählen für die Aufbewahrung, werden nie als beschädigt gewertet und ohne Download gelöscht; Wiederherstellen lädt sie per koordiniertem Lesen. Eigene `.partial`/`.failed` älter als 1 Tag werden beim nächsten Erfolg entfernt. Fremde Dateien nie.
- **WebDAV:** `PUT` direkt aus der Datei, `.partial` per Download und Größe+CRC prüfen, `MOVE` ohne Überschreiben, Enddatei erneut prüfen. Nach Fehlern best effort `DELETE` des eigenen Teil- bzw. unbestätigten Stands; alte eigene `.partial` beim nächsten Erfolg. Leeres Passwortfeld behält das gespeicherte Passwort; „Zugangsdaten entfernen“ löscht den Schlüsselbundeintrag nur ausdrücklich.
- **Status:** verschoben / nicht erreichbar / fehlgeschlagen mit Grund / Erfolg mit Datum. Automatische Fehler erzeugen keinen Alert, nur Plakette und Einstellungen; manuelles Sichern meldet per Alert. Mehr als drei Tage ohne Erfolg (oder seit Einrichtung): „Seit N Tagen kein Backup“. Weiterhin kein Beleg eines abgeschlossenen Cloud-Uploads.
- **Aus Dateien öffnen:** `CFBundleDocumentTypes` (Owner) für `.notylibrary`/`.notybackup`. Datei wird zuerst koordiniert ins App-`tmp` kopiert und vollständig geprüft, dann mit Zusammenfassung bestätigt: Bibliothek immer als neuer Bereich, Heft als getrennte Kopie (bei geöffnetem Notizbuch erst nach dem Schließen). Abbrechen verwirft das Stage.
- **Signierung:** Ablaufdatum aus dem eigenen `embedded.mobileprovision` (`SigningProfile`, Core-Test), Anzeige „Signatur gültig bis …“; mit eingeschalteter Erinnerung plant jeder Start die eine Mitteilung (feste Kennung) 24 h vor Ablauf neu, ohne beim Start nach Erlaubnis zu fragen.

Implementiert, unter Linux geprüft, für arm64 gebaut/signiert und am 17.10.2026 als Update installiert. Sechs Hefte/32 App-Dateien beim Update unverändert. UI- und Dateianbieter-Abnahme noch offen gemäß [BATCH-TEST-11.md](history/BATCH-TEST-11.md).

## Bereiche und Eigentümer

„Meine Bibliothek“ bleibt `Documents/Noty/`. Neue Test- und Restore-Bereiche liegen unter `Documents/NotyWorkspaces/Areas/<neue Bereichs-UUID>/Data/`. Jeder Bereich hat eigenen LibraryStore, Heftpakete und `toolbar.json`. Die Bereiche sind logische Instanzen derselben App; keine zweite Signierungsidentität oder zusätzlicher kostenloser App-Platz. Alle liegen im selben Container und sind kein Schutz gegen Deinstallation/Geräteverlust.

Die App startet weiterhin in „Meine Bibliothek“. Wechsel nur aus der geschlossenen Heftbibliothek über „Bereiche“. Ein neuer Testbereich enthält zwei Demoordner und ein neues Testheft mit neuen IDs, ohne Kopie persönlicher Notizen. Bereichsname ist sichtbar. Ein wiederhergestelltes Bibliotheksarchiv behält Dokument-/Seiten-/Ordner-IDs innerhalb des neuen Bereichs; dessen neue Bereichs-UUID trennt den Namensraum. Gemerkte Seiten und Exportstatus sind nach Speicherpfad getrennt, Werkzeugeinstellungen im jeweiligen Bereich. Die alten Seitenschlüssel werden nur im ursprünglichen Noty-Baum als Fallback gelesen.

Genau ein aktiver LibraryModel-/ToolbarSettingsModel-Eigentümer pro Bereich. Vor Dokumentwechsel Note-Commit abwarten und alten Editor stilllegen; vor Bereichswechsel ausstehende Werkzeugpräferenzen flushen. Kein paralleles Schreiben zweier Hefteditoren an demselben Paket. Bereits unlesbare Werkzeugeinstellungen werden beim Bereichswechsel nicht durch Defaults überschrieben.

## Archivformat `.notylibrary`, Version 1

Unverschlüsselt, unkomprimiert, keine externe Abhängigkeit. Höchstens 200.000.000 Bytes. Es enthält den vollständigen **aktuellen** Bibliotheksstand einschließlich Papierkorb und Werkzeugeinstellungen. Keine Revisionshistorie, alten Importarchive, anderen Bereiche oder Zugangsdaten. `.notybackup` bleibt das separate Einzelheftformat, PDF-Export eine eigene Ausgabe.

| Abschnitt | Inhalt |
| --- | --- |
| 0–7 | ASCII `NOTYLIB` + LF |
| 8–11 | JSON-Manifestlänge als UInt32 Big Endian |
| danach | JSON-Manifest, höchstens 2 MB |
| danach | genau die angegebenen Payloadblöcke in Manifestreihenfolge |

Manifest: `libraryBackupVersion=1`, `checksumAlgorithm=crc32-iso-hdlc`, `createdAt` ISO-8601, `entries`. Erster Block `kind=index` ohne ID, zweiter `kind=toolbar` ohne ID; weitere Blöcke `kind=notebook` mit Dokument-UUID. Jeder Block hat `byteCount` und `crc32`. Kein Block enthält einen Dateipfad; beim Restore werden alle Zielpfade selbst aus geprüften UUIDs erzeugt. Index höchstens 4 MB/10.000 Einträge, Präferenzen höchstens 64 KB/12 Lieblingsstifte. Archiv ohne zusätzlichen Anhang oder fehlende Blöcke.

Export nur aus der Bibliothek bei geschlossenen Editoren. LibraryModel sperrt weitere UI-Mutationen, LibraryStore erfasst Index und alle Heftstände ohne Actor-Suspension. Auch gelöschte Hefte werden gelesen. Unlesbare, fehlende oder nur aus älterer Revision gerettete Hefte brechen den Export ab; keine stille Teilsicherung. Bibliotheksnamen werden für den Export in die Snapshot-Titel übernommen, ohne die Originalpakete zu verändern. Apple-PDF-/PencilKit-Inhalte werden zusätzlich auf dem MainActor geprüft; Serialisierung/CRC und I/O außerhalb der Stifteingabe.

Validierung: Formatversionen, Länge/CRC aller Blöcke, exakte Menge eindeutiger Dokument-IDs, gültige Eltern ohne Zyklus, Heftnamen passend zum Index, gültige Seiten-IDs/Geometrien und Werkzeugeinstellungen. Vollständig kodierte Exportbytes werden erneut dekodiert und verglichen. CRC schützt gegen zufällige Beschädigung, nicht Manipulation/Authentizität. Die unabhängige Python-Prüfung in `scripts/verify_library_backup.py` verwendet zlib statt den Swift-CRC-Code und extrahiert keine Archivpfade.

„Exportiert“ erst nach erfolgreichem Systemdialog. Keine Aussage zum abgeschlossenen entfernten iCloud-Upload. Noch keine WebDAV-Zielverwaltung, automatischer Tagesversuch oder Live-Synchronisierung.

## Restore mit Veröffentlichung am Ende

WorkspaceStore liest begrenzt, prüft das vollständige Archiv und schreibt dessen genaue Bytes unter `NotyWorkspaces/Staging/<neue UUID>/input.notylibrary`. Der Rückgabewert ist an CRC und den vollständigen dekodierten Snapshot gebunden. Apple-Framework-Inhalte werden vor Commit durch die UI geprüft; beim Commit werden Stagingbytes, CRC und Bundle nochmals geprüft. Symbolische Links im Stage werden abgelehnt.

Alle Hefte werden in einem vorher nicht vorhandenen `Data/Library/Documents/<Dokument-ID>/` mit dem bestehenden Revisionscommit gespeichert und neu gelesen. Portable Indexkopie verweist ausschließlich auf diese lokalen Pakete; Reihenfolge, Ordner, Favoriten, Daten und Papierkorbmarker bleiben erhalten. Präferenzen separat schreiben, Index zuletzt committen. Frischer LibraryStore liest den vollständigen Stand einschließlich aller Hefte nochmals.

Danach `workspace.json` (Version 1, neue UUID, Titel, Art, Datum) schreiben und das ganze Stage-Verzeichnis per Rename unter `Areas/<UUID>` veröffentlichen. Bestehendes Ziel niemals ersetzen. Unvollständige Stages erscheinen nicht in der Bereichsliste. Bei Fehler Original und Stage erhalten; erneuter Import verwendet einen neuen Bereich. Der geprüfte Archiveingang bleibt im veröffentlichten Bereich als Herkunftsdatei, wird beim nächsten Backup nicht rekursiv aufgenommen.

## Prüfungen und offene Grenzen

92 Core-Tests erfolgreich: zusätzlich 15 Bibliotheksarchiv-/Bereichstests und vier Präferenztests, darunter Vollständigkeit/Identität, Papierkorb, unabhängige Bearbeitung nach Restore, leere Bibliothek, beschädigte Archive, manipuliertes Staging, Replay, fehlschlagende Veröffentlichung, Symlinks, unbekannte Formate und echte Präferenz-Schreibfehler. Kein simulierter physischer Stromausfall oder volles iPad.

Separater synthetischer End-to-End-Lauf mit echter vierseitiger Test-PDF: zwei Hefte, zwei Ordner, Papierkorb und Lieblingsstift exportiert/restauriert; Kopie bearbeitet und Quellbundle unverändert. Python bestätigt alle CRCs, lehnt beschädigte Kopie ab. Keine persönlichen iPad-Dateien für diesen Lauf verwendet. Nachweise in TESTING.md.

Noch keine effiziente Quelldeduplizierung/Streaming großer Archive, kein gemessener großer Bestand. Serialisierung hat mehrere vollständige Snapshots im Speicher. Begrenzung 200 MB ist kein Leistungsnachweis. Fehlgeschlagene Stages, gespeicherte Archiveingänge und Testbereiche werden noch nicht automatisch bereinigt; nicht unbegrenzt neue Bereiche anlegen. Keine endgültige Löschfunktion in diesem Paket. Tests auf dem iPad und externer Restore aus echter Geräteausgabe stehen aus.
