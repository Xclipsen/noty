# Plan: Backups einfacher wiederherstellen (noty dev)

Stand 08.11.2026, **nur Plan, nichts umgesetzt.** Entscheidungen des Nutzers vom selben Tag stehen am Ende. Anlass: Der Nutzer ist mit der heutigen Wiederherstellung unzufrieden und hat Goodnotes zum Vergleich genannt. Bezug: Vermerk vom 08.11.2026 in [SCOPE](SCOPE.md) (Bereiche fallen in der finalen Version voraussichtlich weg; Backup oder Sync ist noch offen).

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

- Ein Eintrag **in den Einstellungen** (Entscheidung des Nutzers) mit einer **Zeitleiste**: lokale Wiederherstellungspunkte (pro Heft) und externe Backups (ganze Bibliothek) in einer Liste, nach Datum sortiert und mit Quelle gekennzeichnet („auf dem iPad“, „iCloud Drive“, „WebDAV“).
- Aus einem geöffneten Heft führt „Älteren Stand wiederherstellen …“ direkt zur Zeitleiste dieses Hefts. Sie zeigt lokale Stände **und** die externen Backups, in denen das Heft vorkommt.
- Lokale Stände kommen ebenfalls als normale Kopie in die Bibliothek bzw. ersetzen das Heft. „Wiederhergestellte Kopien“ (`Restores/`) entfällt als eigene Ablage. Vorhandene Kopien bleiben lesbar und lassen sich einmalig in die Bibliothek übernehmen.
- Papierkorb und Seitenpapierkorb bleiben, wo sie sind. Die Zeitleiste verweist aber auf sie („Gelöscht? Zuerst im Papierkorb nachsehen“).

### Phase 3: Backup-Liste verständlich machen und sinnvoller aufbewahren

- Bei jedem erfolgreichen Backup schreibt noty eine kleine Zusammenfassung **lokal** in den App-Container: Datei, Datum, Anzahl der Hefte, seit dem letzten Backup geänderte Hefte. Die Liste kann dann „7. Nov., 18:02 · 42 Hefte · 3 geändert (Bio, Mathe, Deutsch)“ anzeigen, ohne vorher Archive aus iCloud zu laden. Fehlt die Zusammenfassung, z. B. bei alten Backups, zeigt die Liste nur das Datum wie heute. Die Zusammenfassung ist abgeleitet, also kein Teil des Archivs und kein Formatwechsel.
- Gestaffelt aufbewahren statt nur die letzten 7 Tage (vom Nutzer bestätigt): 7 tägliche, 4 wöchentliche und 6 monatliche Stände (`ExternalBackupPolicy.obsolete`). Ein versehentlich gelöschtes Heft lässt sich dann auch nach Wochen noch zurückholen. Optionale neue Felder in der Richtlinie, sodass ältere Builds sie weiter lesen können. Das neueste geprüfte Backup bleibt immer erhalten (wie heute).
- Optional nach Entscheidung des Nutzers: Unter den lokalen Wiederherstellungspunkten zusätzlich je einen Stand von gestern und von letzter Woche behalten, damit die lokale Historie nicht nur aus Ständen von heute besteht. Grenze weiterhin 300 MB.

### Phase 4: „Alles zurücksetzen“ ohne Bereich (Notfall) und Bereiche ausblenden

- „Ganze Bibliothek auf diesen Stand bringen …“: Hefte aus dem Backup, die heute fehlen oder anders sind, kommen zurück. Heutige Hefte, die es im Backup nicht gab oder die sich geändert haben, landen **im Papierkorb**. Nichts wird endgültig gelöscht, und auch das lässt sich wieder rückgängig machen. Ordner werden nach dem Backup wiederhergestellt. Vorher erscheint eine Bestätigung mit Zahlen („12 zurückholen, 3 in den Papierkorb“).
- Danach braucht die normale noty keine Bereiche mehr zum Wiederherstellen. Umsetzung des SCOPE-Vermerks:
  - In der **normalen noty** gibt es keine Bereichsauswahl. Vorhandene Bereiche (alte Wiederherstellungen, Testbereiche) bekommen eine einmalige Aktion „Hefte in Meine Bibliothek übernehmen …“ und lassen sich danach wie heute entfernen.
  - In **noty dev, noty AI und noty calendar** bleibt der gespiegelte Bereich „noty“ für den App-Abgleich ([APP-SYNC](APP-SYNC.md)), da er dort ein Entwicklerwerkzeug ist. Die Einbahnstraße bleibt unverändert.
- Erst umsetzen, wenn Phasen 1 und 2 am iPad bestätigt sind.

### Phase 5 (offen): Sync

Eine PDF-Kopie im Backupziel ist **nicht** gewünscht, das Backup bleibt im noty-Format.

**Warum nicht iCloud wie bei Goodnotes:** Ein CloudKit-Sync oder ein Sync über den iCloud-Container braucht die iCloud-Berechtigung. xtool 1.24.0 kennt sie nicht (`XKit/Model/Entitlements/EntitlementTypes.swift`). Schlimmer noch: `DeveloperServicesAddAppOperation` gleicht bei jedem signierten Build die Fähigkeiten der App-ID ab und **löscht alle, die es nicht kennt** (Ausnahme: In-App-Kauf). Ein von Hand im Apple-Entwicklerportal eingeschaltetes iCloud wäre nach dem nächsten Build wieder weg, und das Profil enthielte es nicht. Gehen würde es nur mit einem eigenen xtool-Fork, der die Fähigkeit samt Container-Zuordnung kennt. Das ist aufwendig, ungeprüft und müsste bei jedem xtool-Update nachgezogen werden. **Nicht empfohlen.**

**Wege ohne Apple-Berechtigung:**

| Weg | Wie | Dafür | Dagegen |
| --- | --- | --- | --- |
| **A. Eigener Server** (IONOS, `noty.xclipsen.de`) | Jedes Heft wird als unveränderliche Revision hochgeladen, so wie `RevisionStore` sie ohnehin schreibt. Bilder und PDFs werden nach SHA-256 gespeichert, also nur einmal übertragen. Der Server führt je Heft den „aktuellen Stand“ und nimmt einen Upload nur an, wenn das Gerät vom aktuellen Stand ausgegangen ist (Vergleich mit der Basisrevision). Wurde auf zwei Geräten geändert, bleiben **beide** erhalten: Der zweite Stand wird als Kopie „Titel (Konflikt …)“ angelegt, nichts wird überschrieben. Änderungen werden über einen Cursor abgefragt, wie beim Abgleich der Gesetzesmarkierungen. | Volle Kontrolle, kein Apple-Entitlement. Konto, HTTPS-Backend und das Cursor-Prinzip sind vom Gesetzes-Sync schon da (`LawPersonalStore`). Später könnte die Website die Hefte am PC anzeigen. | Speicher und Betrieb auf dem eigenen Server. Schulunterlagen liegen dort, also wäre Verschlüsselung zu überlegen. Größter Bauaufwand: Server **und** App. |
| **B. Ordner-Sync** über einen iCloud-Drive-Ordner oder WebDAV/Nextcloud (wie das jetzige Backupziel) | Dasselbe Revisionsmodell, aber als Dateien in einem Ordner. Jedes Gerät schreibt **nur eigene Dateien** (eigene Revisionen und eine eigene Kopfdatei je Gerät) und liest die der anderen. So entstehen keine Schreibkonflikte, auch nicht bei iCloud Drive, das keine sicheren Vergleichs-Schreibvorgänge kennt. Bei WebDAV ginge zusätzlich `If-Match` mit ETag. | Kein Server-Code, nutzt die vorhandenen Zugriffe auf Ordner und WebDAV. | iCloud lädt verzögert, Dateien sind oft erst Platzhalter, und es gibt keinen Hintergrundabgleich. Wann ein Upload wirklich fertig ist, lässt sich nicht nachweisen (wie heute beim Backup). Konfliktregeln wie bei A. |
| C. CloudKit | siehe oben | wie Goodnotes | nur mit xtool-Fork |

**Empfehlung:** Den Sync erst bauen, wenn ein zweites Gerät oder Zugriff am PC tatsächlich gebraucht wird. Mit einem iPad bringt er nichts, was Backup und Wiederherstellung (Phasen 1–4) nicht schon leisten. Wenn es so weit ist, **Weg A in zwei Stufen:**
1. **Nur hochladen, Heft für Heft:** Geänderte Hefte gehen als Revisionen auf den Server. Das ist gleichzeitig ein schrittweises Offsite-Backup mit Versionen (nur Geändertes wird übertragen, anders als das heutige Komplettarchiv) und kommt deiner Idee „Backup und Sync zusammenlegen“ am nächsten. Die Wiederherstellung aus Phase 1 und 2 bekommt dann den Server als weitere Quelle in der Zeitleiste.
2. **Abgleich in beide Richtungen,** sobald ein zweites Gerät da ist: Herunterladen per Cursor und Konfliktkopien statt Überschreiben.

Das tägliche Komplettbackup in iCloud Drive oder WebDAV bleibt in beiden Stufen als unabhängiges Sicherheitsnetz, denn ein Sync verteilt Fehler und Löschungen mit. Kein Sync-Erfolg allein aus lokalem Schreiben ableiten (AGENTS.md). Der App-Abgleich zwischen noty, noty dev und noty AI bleibt davon getrennt.

## Reihenfolge und Arbeitsweise

1. Zweig `feat/wiederherstellen` von `dev` mit eigenem Worktree. Builds gehen an **noty dev** (eigene Daten, eigenes Backupziel zum Testen).
2. Phase 1 → noty dev → Nutzer testet → Phase 2 → … Jede Phase ist für sich nutzbar.
3. Merge nach `dev`, die normale noty nur nach ausdrücklicher Freigabe (AGENTS.md).
4. Nach jeder Phase README, [BACKUPS](BACKUPS.md), [LIBRARY-BACKUP](LIBRARY-BACKUP.md) und TESTING mit den tatsächlichen Nachweisen aktualisieren.

## Entscheidungen des Nutzers (08.11.2026)

1. Beim Zurückholen ist **„Als Kopie“** vorausgewählt.
2. „Wiederherstellen“ liegt **in den Einstellungen**.
3. Gestaffelte Aufbewahrung **7 Tage / 4 Wochen / 6 Monate**: ja.
4. **Keine PDF-Kopie**, das Backup bleibt im noty-Format.
5. Sync: Wege prüfen (Phase 5). Noch keine Entscheidung zur Umsetzung.
