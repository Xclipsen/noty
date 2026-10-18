# Bibliotheksbackup und getrennte Bereiche – Build 11

Implementiert, unter Linux geprüft, für arm64 gebaut/signiert und am 17.10.2026 als Update installiert. Sechs Hefte/32 App-Dateien beim Update unverändert. UI- und Dateianbieter-Abnahme noch offen gemäß [BATCH-TEST-11.md](BATCH-TEST-11.md).

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
