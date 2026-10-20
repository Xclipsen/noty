# Bibliothek – Format 1, Build 10

## Nachtrag Build 45

Seitenleiste ohne `List` neu aufgebaut (Ziehen ging dort nicht mehr), Einfügelinien in Baum, Angeheftet und Hauptbereich, Angeheftet zweispaltig mit eigener Reihenfolge (UserDefaults, nicht im Bibliotheksbackup). Details und Grenzen: [EDITOR-FEEDBACK-35](EDITOR-FEEDBACK-35.md). Der folgende Abschnitt zu „Ziehen und Ablegen“ beschreibt den älteren Stand.

## Ergänzung Bibliothek im Dateien-Stil (19.10.2026, nach Build 41)

Startseite mit Begrüßung/Regalen entfällt (ebenso das lokale Profil in Einstellungen › Allgemein; gespeicherte Werte bleiben unangetastet). `LibraryView` ist ein `NavigationSplitView` wie die Dateien-App: links „Angeheftet“, „Alle Unterlagen“, „Zuletzt verwendet“ und der Baum aller aktiven Ordner **und** Notizbücher; Ordner antippen zeigt ihren Inhalt rechts (Raster/Liste), Notizbuch antippen öffnet es. Werkzeugleiste: Inhaltssuche, Darstellung, „Neu“ (Notizbuch, Ordner, PDF-/Backup-Import, wiederhergestellte Kopien), Einstellungen; Backup-Hinweis nur bei Handlungsbedarf (Stand UI-Feinschliff, [UI-POLISH](UI-POLISH.md)). Kontextmenü: Anheften/Lösen, Umbenennen, Verschieben, Duplizieren (nur Notizbücher), „Im Ordner zeigen“ (in Angeheftet/Zuletzt/Suche), Papierkorb.

- **Anheften** verwendet das vorhandene Index-Feld `favorite` (kein Formatwechsel, Teil von Bibliotheksbackups). Gelöschte/entfernte Einträge erscheinen nicht.
- **Aufgeklappte Ordner** im Seitenleistenbaum: UserDefaults `noty.v2.libraryExpanded.<Bereichspfad>` (UUID-Liste je Bereich), bleiben bis zum Zuklappen erhalten; Einträge, die im Index nicht mehr existieren, werden beim Neuladen entfernt. Ein rechts geöffneter Ordner klappt nur seine Vorfahren auf.
- **Duplizieren** (`LibraryStore.duplicateDocument`): neueste bestätigte Revision als neues Paket `Library/Documents/<neue UUID>/` mit neuer Dokument-ID, Titel „… Kopie“, direkt hinter dem Original; Seiten/Papierkorb/PDF-/Bildoriginale unverändert, keine lokale Historie, Seiten-/Objekt-IDs dokumentintern wie bei Restore-Kopien. Paket wird vor dem Indexcommit geschrieben und zurückgelesen; eine aus älterer Revision wiederhergestellte (`recovered`) Quelle wird abgelehnt. Nachweis: `LibraryStoreTests.testDuplicate…`.
- **Ziehen und Ablegen** in der Seitenleiste (und Listenansicht rechts) zeigt eine Einfügelinie zwischen Zeilen bzw. hebt einen Zielordner hervor (Zeilenmitte = hinein, oberes/unteres Viertel = davor/dahinter; unter einem aufgeklappten Ordner = an dessen Anfang). Ablegen über `LibraryStore.place(_:in:before:)`: Ordnerwechsel und Position unter den Geschwistern in **einem** Indexcommit, gleiche Zyklusregeln wie `move`. Positionen nur bei „Eigene Reihenfolge“; bei Sortierung nach Name/Datum nur in Ordner hinein. Nachweis: `LibraryStoreTests.testPlace…`.
- **Rückkehr aus dem Editor** lädt still im Hintergrund neu (`refresh(quiet:)`): keine Deaktivierung/Abdunklung, kein Fortschrittsbalken, nur geänderte Werte werden veröffentlicht; nur die Vorschau des bearbeiteten Hefts wird neu gerendert (altes Bild bleibt bis dahin). Automatische Backups verhalten sich ebenso. Nutzeraktionen warten kurz auf diese Hintergrundarbeit statt verworfen zu werden.

Implementiert, Core-Tests/Host-Roundtrip und SDK-Build erfolgreich; nicht installiert, auf dem iPad ungeprüft.

## Ergänzung Einstellungen, Startseite und endgültiges Löschen (19.10.2026)

Zentrale Einstellungen (`SettingsView`, Zahnrad in der Bibliothek, für den Editor mit denselben Bereichsmodellen aufrufbar): Allgemein (lokales Profil nur für die Begrüßung, kein Konto/Server), Editor, Stift & Werkzeuge (inkl. Werkzeugleiste anpassen), Papier-Standards, Backup & Daten (externes Backup, Bibliotheksdatei, Bereiche), Papierkorb, Über (Version/Build, Datenablage, Signierung, Abschnitt Diagnose mit Hänger-Diagnose, wirkt nach Neustart; seit dem UI-Feinschliff keine eigene Seite mehr). Bereichsbezogen sind `toolbar.json`-Werte, Backupziel und Papierkorb; Profil, Darstellung/Sortierung, Schreibscrollen und Seitenleiste gelten app-weit (UserDefaults). Bereichsbezogene UserDefaults (Backupziel, Exportdatum, zuletzt geöffnetes Heft, letzte Seite je Heft) verwenden containerunabhängige Schlüssel `noty.v2.<name>.<Pfad relativ zu Documents>`; ältere Schlüssel mit absolutem Containerpfad werden beim Laden einmalig kopiert und bleiben erhalten. Papier-Standard als optionales `defaultAppearance` in Werkzeugformat 7; ältere Builds ignorieren den Schlüssel, Swift-Validierung und `verify_library_backup.py` prüfen ihn. Startseite „Start“: Begrüßung, Backup-Status-Plakette (öffnet Backup & Daten), Zuletzt verwendet, Favoriten, oberste Ebene; Raster/Liste und Sortierung (eigene Reihenfolge, Name, zuletzt geöffnet) ändern nur die Anzeige, nie den Index. Der Papierkorb ist aus der Seitenleiste in die Einstellungen gewandert (Kurzzugriff mit Anzahl unten in der Seitenleiste).

Endgültiges Löschen (`LibraryStore.purge(ids:)`, `emptyTrash()`) nur auf ausdrückliche Bestätigung; noty leert den Papierkorb nie automatisch. Nur Einträge im Papierkorb (direkt oder über einen gelöschten Ordner); sonst wird der ganze Aufruf abgelehnt. Ein Ordner nimmt alle Nachfahren mit. Ablauf: Paketpfade prüfen (keine Symlinks, nur unterhalb des Bibliotheksroots) → neuen Index wie jede Änderung atomar committen → zweiter Commit, damit auch `index-previous.json` keine entfernten Pakete referenziert (scheitert er, bleiben die Pakete erhalten) → Pakete nach `Library/Purging/` umbenennen und entfernen. Fehler danach hinterlassen verwaiste Dateien, nie einen beschädigten Index; die nächste Inventur nimmt verbliebene Pakete als aktive Einträge wieder auf. `legacyMain` liegt direkt im Root und wird nicht endgültig gelöscht (bleibt wiederherstellbar). Ältere Backups enthalten gelöschte Einträge weiterhin. Nachweis: `LibraryPurgeTests` (Core, Linux). **Implementiert, SDK-Build erfolgreich; nicht installiert, auf dem iPad ungeprüft.**

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
