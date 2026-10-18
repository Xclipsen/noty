# Bibliothek – Format 1, Build 10

## Ergänzung Build 21

Notizbuchraster mit gewähltem Umschlag oder tatsächlicher erster Seitenvorschau; Anordnen weiterhin über Bearbeiten/Listendarstellung. Erstellen-Dialog für Titel, Umschlag an/aus/Farbe und Papierart/-farbe/-format/-orientierung. Umschlag ist kein Seiteninhalt. Notebook-Schema 7 speichert die Vorgaben; Bibliotheksindex bleibt Format 1 und dupliziert sie nicht. Vorschaulesen seriell auf dem vorhandenen Bibliotheksactor, Rendern mit bestehendem begrenztem Thumbnailcache. Neue Papierseiten übernehmen die Notebook-Geometrie. 169 Core-Tests, Archivroundtrip und SDK-Build bestanden; neue Bibliotheksbedienung am Gerät ungeprüft. [Details](UI-REBUILD.md). Nachfolgende Abschnitte sind der frühere Build-10-Stand.

Implementiert und für das iPad gebaut; UI-Abnahme offen. Keine neue externe Abhängigkeit. Foundation-Kern unter Linux testbar, SwiftUI-Navigation und Drag-and-drop auf dem Gerät prüfen.

## Getrennte Eigentümer und Commit

`LibraryStore` ist der einzige Indexschreiber. `Noty/Library/index.json` enthält Formatversion 1, einen vollständigen JSON-Payload als Base64 und dessen CRC-32/ISO-HDLC. Payload ebenfalls versioniert; maximal 10.000 Einträge/4 MB Index. Zuerst den zuletzt gültigen Index atomar nach `index-previous.json`, zuletzt den neuen Index atomar nach `index.json` schreiben. Erst dann UI-Erfolg und In-Memory-Stand aktualisieren. Beschädigtes Original wird beim Lesen nicht durch eine leere Bibliothek ersetzt; gültiger vorheriger Index mit Warnung, unbekannte neuere Version sperrt Rückfall und Schreiben. CRC erkennt zufällige Beschädigung, keine absichtliche Manipulation.

Ein Eintrag besitzt feste UUID, Namen (1–120 Zeichen), optionale Elternordner-ID, Herkunft, Favorit, letztes Öffnungsdatum und optionales Papierkorbdatum. Herkunft fehlt bei Ordnern; bei Heften ausschließlich `legacyMain`, `restored` oder `library`. Keine frei gespeicherten Dateipfade. Eltern müssen existierende Ordner sein, UUIDs eindeutig, Zyklen verboten. Array-Reihenfolge definiert die manuelle Reihenfolge unter Geschwistern. Umordnung akzeptiert ausschließlich deren vollständige, eindeutige ID-Menge.

Heftpfade:

- `legacyMain`: bisheriges `Noty/`, Dokument-ID unverändert.
- `restored`: `Noty/Restores/<Dokument-UUID>/`.
- `library`: `Noty/Library/Documents/<Dokument-UUID>/`.

Das Einbinden liest bestehende Pakete, schreibt deren Dateien nicht um und verschiebt nichts. Neue Pakete zuerst über RevisionStore vollständig schreiben/zurücklesen, anschließend Index committen. Bei Abbruch dazwischen findet die nächste Inventur das verwaiste vollständige Paket wieder im Wurzelbereich. Eine verlorene noch nicht bestätigte Ordnerzuordnung kann dabei nicht rekonstruiert werden. Unlesbare unbekannte Pakete bleiben erhalten und werden gemeldet. Symbolische Links in Paketpfaden werden abgelehnt.

Umbenennen/Ordnerwechsel/Papierkorb betreffen nur den Index. Beim nächsten Öffnen übernimmt der exklusive Editor den Bibliotheksnamen in seine normale Heftrevision, damit Heft-Backups den neuen Namen tragen. Kein zweiter Schreiber am Heftpaket. Beim Schließen speichert der Editor und wartet auf Abschluss; bei Fehler bleibt er offen. Nach Erfolg keine weiteren Saves dieses Editors. Erst nach Schließen neue Instanz für dieselbe Dokument-ID öffnen. Noch keine zwei gleichzeitigen Ansichten.

## Papierkorb und Oberfläche

Ein gelöschter Ordner blendet seine Unterlagen rekursiv aus; Dateien unverändert. Einträge mit eigenem Löschdatum sind im Papierkorb wiederherstellbar. Ist der frühere Elternordner selbst im Papierkorb, wird der wiederhergestellte Eintrag an die Wurzel gesetzt. Separat gelöschte Kinder bleiben beim Restore des Ordners gelöscht. Es gibt in diesem Paket keine endgültige Löschfunktion.

Seitenleiste mit nativer Breitenanpassung, aufklappbarem Ordnerbaum und Filtern. Über „Bearbeiten“ die Geschwisterreihenfolge ändern; per Ziehen auf einen Ordner oder über „Verschieben“ das Ziel ändern. Namenssuche umfasst alle aktiven Ordner/Heftnamen; PDF-/Handschrift-/OCR-Inhaltssuche bleibt eigener späterer Schritt. „Kopien mit Textvorschau finden“ dient gezielt dem noch offenen Wiederfinden-Test; Seiten-UUIDs ermöglichen direkte Auswahl.

PDF-Import aus der Bibliothek erzeugt ein neues Heft und ersetzt den Altbestand nicht. Höchstens 20 MB/500 Seiten, Original-PDF-Bytes vollständig enthalten. Backupimport verwendet den vorhandenen Staging-/Validierungspfad und erzeugt eine Kopie. Der `.notybackup`-Export sichert genau ein Heft, **nicht** den Index, Ordner oder alle Hefte. Build 11 ergänzt dafür `.notylibrary`, siehe [LIBRARY-BACKUP.md](LIBRARY-BACKUP.md); der Geräte-Nachweis bleibt vor Alltagsfreigabe offen. Noch keine WebDAV-/iCloud-Zielverwaltung, keine Live-Synchronisierung.

## Nachweise und Grenzen

Zwölf Bibliotheks-Risikotests: bytegleiche Bestandsübernahme, Elternzyklen, Ordnung, rekursiver Papierkorb, Wiederherstellung bei gelöschtem Elternordner, echter Index-Schreibfehler mit verwaistem Paket, beschädigte/neue Formate, CRC, parallele Indexänderungen, später entdeckte Kopien und Symlinks. Insgesamt 73 Core-Tests erfolgreich.

Separater Linux-Lauf mit Kopie aller sechs echten iPad-Hefte: Übernahme, verschachteltes Verschieben, Umbenennen, Favorit/Zuletzt verwendet, neues Heft, Papierkorb/Restore, neuer Store/Neuladen erfolgreich; ursprüngliche sechs Notebook-Snapshots anschließend vollständig gleich. Das belegt keine UIKit-/SwiftUI-Bedienung. Keine Messung großer Bibliotheken; Restore-Vorschauen lesen derzeit alle Restore-Pakete. Quellen bleiben je Revision dupliziert. Geräteabnahme gebündelt in [BATCH-TEST-10.md](BATCH-TEST-10.md).
