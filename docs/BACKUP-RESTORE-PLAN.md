# Plan: Backups einfacher wiederherstellen (noty dev)

Stand 08.11.2026, **nur Plan, nichts umgesetzt.** Anlass: Der Nutzer ist mit der heutigen Wiederherstellung unzufrieden und hat Goodnotes zum Vergleich genannt. Bezug: Vermerk vom 08.11.2026 in [SCOPE](SCOPE.md) (Bereiche fallen in der finalen Version voraussichtlich weg; Backup oder Sync ist noch offen).

## Was heute stört (Ist-Stand im Code auf `dev`)

Zum Wiederherstellen gibt es fünf getrennte Stellen, und keine davon holt **ein einzelnes Heft aus einem Backup** zurück:

| Wo | Was passiert | Problem |
| --- | --- | --- |
| Einstellungen › Backup & Daten › Ältere Backups (`ExternalBackupView`) | Die Liste zeigt nur Datum und Uhrzeit. Die einzige Aktion ist „Als neuen Bereich wiederherstellen“ (`WorkspaceAppModel.restoreLibrary`). | Man sieht nicht, was in einem Backup steckt. Es kommt immer die ganze Bibliothek als zusätzlicher Bereich zurück, und ein Heft lässt sich von dort nicht in „Meine Bibliothek“ übernehmen (nur über den Umweg „Als .noty teilen“ und wieder importieren). |
| Heft › Lokale Wiederherstellungspunkte (`LocalHistoryView`) | Bis zu 8 ältere Stände des Hefts (die 3 jüngsten plus 5 im Abstand von ≥ 10 min, höchstens 300 MB). „Als neue Kopie öffnen“. | Die Kopie landet unter „Wiederhergestellte Kopien“ (`Restores/`), also außerhalb der normalen Bibliothek. Schon nach kurzem Arbeiten sind alle Stände nur noch von heute. |
| Bibliothek › Wiederhergestellte Kopien (`RestoredCopiesView`) | eigene Liste der Kopien | eine weitere Ablage neben der Bibliothek |
| Papierkorb der Bibliothek, Seitenpapierkorb | gelöschte Hefte bzw. Seiten | funktioniert, gehört aber gedanklich ebenfalls zum Zurückholen |
| Datei öffnen (`.notylibrary`, `.noty`) | Bibliothek als neuer Bereich, ein Heft mit „Vorhandenes ersetzen / Beide behalten“ | Nur beim `.noty`-Import gibt es schon die Wahl, die man eigentlich überall möchte. |

Die Technik darunter (geprüfte Archive, Staging, erneute Prüfung, Commit mit Zurücklesen, unabhängiger Python-Prüfer) ist solide und soll bleiben. Neu gebaut werden soll die **Bedienung**.

## Ziel

Ein Ort **„Wiederherstellen“**, an dem man einen Zeitpunkt wählt, sieht, was sich seitdem geändert hat, und einzelne Hefte (oder bei Bedarf alles) zurückholt, und zwar **in die normale Bibliothek**, ohne Bereichswechsel.

## Bausteine, die schon da sind

- `LibraryArchive.verify(url, visit:)` liest ein Bibliotheksbackup als Datenstrom, Heft für Heft, und hat dabei höchstens ein Heft im Speicher. Damit lässt sich ein Inhaltsverzeichnis erzeugen und ein einzelnes Heft herausholen, ohne die ganze Bibliothek wiederherzustellen.
- Der `.noty`-Import (`NotyFile`, `PreparedRestore`, `commit`): neue Dokument-ID, eindeutige Titel nach dem Muster „Titel (1)“, „Vorhandenes ersetzen“ (das aktuelle Heft kommt in **einem** Indexcommit in den Papierkorb), „Beide behalten“, Paket vor Indexeintrag. Das ist genau die Logik, die beim Zurückholen aus einem Backup gebraucht wird.
- `ExternalBackupModel.retrieve` holt ein Archiv vom Ziel (auch iCloud-Platzhalter) in einen Zwischenordner.
- Lokale Historie über `RevisionStore` und `checkpoints.json`.

## Phasen

### Phase 1: Einzelne Hefte aus einem Backup zurückholen (größter Gewinn)

- In „Ältere Backups“ öffnet ein Tipp auf einen Eintrag eine Detailansicht. Sie holt das Archiv, prüft es vollständig und zeigt:
  - die Hefte mit Ordnerpfad, Seitenzahl und Vorschau der ersten Seite,
  - einen Vergleich mit heute: **gelöscht seitdem**, **geändert seitdem**, **unverändert**, **nur heute vorhanden** (Vergleich über Dokument-ID und Revisions-Prüfsumme bzw. Inhalt),
  - einen Filter „Nur Unterschiede“, der standardmäßig an ist.
- Aktionen je Heft, auch für mehrere ausgewählte Hefte:
  - **„Als Kopie zurückholen“** (Standard): ein neues Heft in der Bibliothek, Titel „Titel (Stand 07.11.)“. Es kommt in seinen alten Ordner, falls der noch existiert, sonst in die oberste Ebene.
  - **„Aktuellen Stand ersetzen“**: Das heutige Heft kommt in den Papierkorb, der Backup-Stand nimmt seinen Platz ein (gleicher Ordner und gleiche Position, angeheftet bleibt angeheftet). Das ist dieselbe Semantik wie beim `.noty`-Import „Vorhandenes ersetzen“.
  - Ein Heft, das heute fehlt, wird einfach wiederhergestellt.
- Kein neues Archiv- oder Heftformat und kein neuer Bereich. Die bisherige Aktion „Als neuen Bereich wiederherstellen“ wandert vorerst hinter „Mehr …“ (siehe Phase 4).
- Nachweise: Core-Tests (Inhaltsverzeichnis aus Format 1 und 2, Vergleich, Zurückholen als Kopie bzw. Ersetzen, Abbruch- und Fehlerfälle, unbeteiligte Hefte bytegleich), Host-Roundtrip, SDK-Build. Am iPad: ein Testheft löschen bzw. ändern, aus dem iCloud-Backup zurückholen, beide Varianten.

### Phase 2: Ein gemeinsamer Ort „Wiederherstellen“

- Ein Eintrag in der Seitenleiste bzw. in den Einstellungen mit einer **Zeitleiste**: lokale Wiederherstellungspunkte (pro Heft) und externe Backups (ganze Bibliothek) in einer Liste, nach Datum sortiert und mit Quelle gekennzeichnet („auf dem iPad“, „iCloud Drive“, „WebDAV“).
- Aus einem geöffneten Heft führt „Älteren Stand wiederherstellen …“ direkt zur Zeitleiste dieses Hefts. Sie zeigt lokale Stände **und** die externen Backups, in denen das Heft vorkommt.
- Lokale Stände kommen ebenfalls als normale Kopie in die Bibliothek bzw. ersetzen das Heft. „Wiederhergestellte Kopien“ (`Restores/`) entfällt als eigene Ablage. Vorhandene Kopien bleiben lesbar und lassen sich einmalig in die Bibliothek übernehmen.
- Papierkorb und Seitenpapierkorb bleiben, wo sie sind. Die Zeitleiste verweist aber auf sie („Gelöscht? Zuerst im Papierkorb nachsehen“).

### Phase 3: Backup-Liste verständlich machen und sinnvoller aufbewahren

- Bei jedem erfolgreichen Backup schreibt noty eine kleine Zusammenfassung **lokal** in den App-Container: Datei, Datum, Anzahl der Hefte, seit dem letzten Backup geänderte Hefte. Die Liste kann dann „7. Nov., 18:02 · 42 Hefte · 3 geändert (Bio, Mathe, Deutsch)“ anzeigen, ohne vorher Archive aus iCloud zu laden. Fehlt die Zusammenfassung, z. B. bei alten Backups, zeigt die Liste nur das Datum wie heute. Die Zusammenfassung ist abgeleitet, also kein Teil des Archivs und kein Formatwechsel.
- Gestaffelt aufbewahren statt nur die letzten 7 Tage: 7 tägliche, 4 wöchentliche und 6 monatliche Stände (`ExternalBackupPolicy.obsolete`). Ein versehentlich gelöschtes Heft lässt sich dann auch nach Wochen noch zurückholen. Optionale neue Felder in der Richtlinie, sodass ältere Builds sie weiter lesen können. Das neueste geprüfte Backup bleibt immer erhalten (wie heute).
- Optional nach Entscheidung des Nutzers: Unter den lokalen Wiederherstellungspunkten zusätzlich je einen Stand von gestern und von letzter Woche behalten, damit die lokale Historie nicht nur aus Ständen von heute besteht. Grenze weiterhin 300 MB.

### Phase 4: „Alles zurücksetzen“ ohne Bereich (Notfall) und Bereiche ausblenden

- „Ganze Bibliothek auf diesen Stand bringen …“: Hefte aus dem Backup, die heute fehlen oder anders sind, kommen zurück. Heutige Hefte, die es im Backup nicht gab oder die sich geändert haben, landen **im Papierkorb**. Nichts wird endgültig gelöscht, und auch das lässt sich wieder rückgängig machen. Ordner werden nach dem Backup wiederhergestellt. Vorher erscheint eine Bestätigung mit Zahlen („12 zurückholen, 3 in den Papierkorb“).
- Danach braucht die normale noty keine Bereiche mehr zum Wiederherstellen. Umsetzung des SCOPE-Vermerks:
  - In der **normalen noty** gibt es keine Bereichsauswahl. Vorhandene Bereiche (alte Wiederherstellungen, Testbereiche) bekommen eine einmalige Aktion „Hefte in Meine Bibliothek übernehmen …“ und lassen sich danach wie heute entfernen.
  - In **noty dev, noty AI und noty calendar** bleibt der gespiegelte Bereich „noty“ für den App-Abgleich ([APP-SYNC](APP-SYNC.md)), da er dort ein Entwicklerwerkzeug ist. Die Einbahnstraße bleibt unverändert.
- Erst umsetzen, wenn Phasen 1 und 2 am iPad bestätigt sind.

### Phase 5 (offen, Entscheidung des Nutzers): Sync bzw. PDF-Kopie

- **Ein echter iCloud-Sync wie bei Goodnotes (CloudKit oder iCloud-Container) ist mit der jetzigen Toolchain nicht möglich.** xtool 1.24.0 kennt keine iCloud-Berechtigung: In `XKit/Model/Entitlements/EntitlementTypes.swift` und `DeveloperServicesCapability.swift` stehen u. a. App Groups, Sign in with Apple, Associated Domains, HealthKit und HomeKit, aber kein iCloud. Geprüft am Quellstand 1.24.0 von xtool. Ob sich die Fähigkeit im Apple-Entwicklerportal von Hand einschalten lässt und xtool sie dann im Profil stehen lässt, ist **ungeprüft**.
- Möglich wäre ein Sync über eine Datei in einem gewählten iCloud-Drive- bzw. WebDAV-Ordner (wie das jetzige Backupziel). Das bringt aber eigene Konfliktregeln und ist mit nur einem iPad kaum nützlich. Empfehlung: erst angehen, wenn ein zweites Gerät tatsächlich gebraucht wird. Bis dahin bleibt Live-Synchronisierung außerhalb der ersten vollständigen Version (SCOPE).
- Kleinere Alternative nach dem Vorbild von Goodnotes: Optional legt jedes Backup zusätzlich je Heft eine **PDF-Kopie** in einen Unterordner des Ziels, damit die Unterlagen am PC ohne noty lesbar sind. Getrennt vom editierbaren Backup und nur für geänderte Hefte.

## Reihenfolge und Arbeitsweise

1. Zweig `feat/wiederherstellen` von `dev` mit eigenem Worktree. Builds gehen an **noty dev** (eigene Daten, eigenes Backupziel zum Testen).
2. Phase 1 → noty dev → Nutzer testet → Phase 2 → … Jede Phase ist für sich nutzbar.
3. Merge nach `dev`, die normale noty nur nach ausdrücklicher Freigabe (AGENTS.md).
4. Nach jeder Phase README, [BACKUPS](BACKUPS.md), [LIBRARY-BACKUP](LIBRARY-BACKUP.md) und TESTING mit den tatsächlichen Nachweisen aktualisieren.

## Offene Fragen an den Nutzer

1. Soll beim Zurückholen eines Hefts **„Als Kopie“** oder **„Ersetzen“** vorausgewählt sein?
2. Wo soll „Wiederherstellen“ liegen: in der Seitenleiste der Bibliothek, in den Einstellungen oder an beiden Stellen?
3. Passt die gestaffelte Aufbewahrung (7 Tage, 4 Wochen, 6 Monate) oder soll noch länger zurückgegangen werden?
4. Ist eine PDF-Kopie im Backupziel gewünscht?
