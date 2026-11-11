# Plan: Backups einfacher wiederherstellen (noty dev)

Stand 08.11.2026 abends: **Phasen 1–4 und Phase 5 Stufe 1 implementiert** (Core-Tests, Host-Roundtrip, iPad-Build erfolgreich; **nicht installiert, am iPad ungeprüft**). Phase 5 Stufe 2 (Abgleich in beide Richtungen) folgt erst mit einem zweiten Gerät. Entscheidungen des Nutzers stehen am Ende. Anlass: Der Nutzer ist mit der heutigen Wiederherstellung unzufrieden und hat Goodnotes zum Vergleich genannt. Bezug: Vermerk vom 08.11.2026 in [SCOPE](SCOPE.md) (Bereiche fallen in der finalen Version voraussichtlich weg; Backup oder Sync ist noch offen).

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

**Stand 08.11.2026 auf `feat/wiederherstellen`: implementiert, Core-Tests, Host-Roundtrip und SDK-Build erfolgreich; nicht installiert, am iPad ungeprüft.** Details: [LIBRARY-BACKUP](LIBRARY-BACKUP.md), Ergänzung vom 08.11.2026. Abweichung vom Plan: Eine Vorschau der ersten Seite gibt es noch nicht (Ordnerpfad und Seitenzahl ja).

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

**Stand 08.11.2026 auf `feat/wiederherstellen-2`: implementiert, iPad-Build erfolgreich; nicht installiert, am iPad ungeprüft.** Umsetzung:
- **Einstellungen › Wiederherstellen** (Gruppe „Daten“, eigene Seite neben „Backup“): „Ein Heft auf einen früheren Stand bringen“ (Heft wählen → Zeitleiste), „Automatische Backups“, „iCloud-Ablage“ (wenn an), „Bibliotheksbackup-Datei öffnen …“, Papierkorb und – solange es welche gibt – „Wiederhergestellte Kopien (alt)“ mit „In Bibliothek übernehmen“ (macht aus der alten Kopie ein normales Heft, die Kopie kommt in den Papierkorb). Die Einstellungssuche kennt die neuen Einträge.
- **Zeitleiste eines Hefts** (`NotebookTimelineView`): lokale Stände (nur lesend aus dem geschlossenen Paket, `LocalStates`, kein zweiter Schreiber), die automatischen Backups dieses iPads, die einen Stand des Hefts enthalten (aus den Zusammenfassungen der Phase 3, gleiche Stände nur einmal), und die Stände der iCloud-Ablage, nach Datum. Je Stand „Als Kopie zurückholen“ („Titel (Stand 08.11.2026, 10:00)“, im Ordner des heutigen Hefts) oder „Ersetzen …“ (heutiger Stand in den Papierkorb). Alles über den geprüften `.noty`-Import (`LibraryModel.importBackup`).
- **Aus dem Heft:** „…“ › „Älteren Stand wiederherstellen …“ (auch in der Befehlspalette) schließt das Heft und zeigt danach in der Bibliothek seine Zeitleiste. Das gibt es nur im normalen Editor der Bibliothek (`EditorWorkspace`); eine Kalendernotiz neben dem Termin oder vergrößert behält das alte „Lokale Wiederherstellungspunkte“.
- Neue lokale Stände landen nicht mehr unter „Wiederhergestellte Kopien“.
- **Ersetzen und der Kalender:** Vor dem Ersetzen gibt der Kalender seine Notiz neben dem Termin frei; hält danach noch jemand das Heftpaket (Editor, nicht gespeicherte Kalendernotiz), wird das Ersetzen abgelehnt und nichts verändert. Der zurückgeholte Stand bekommt eine neue Kennung, behält aber seine Seiten-IDs; Terminnotizen und das Lernfeld zeigen danach auf ihn (`CalendarState.notebookReplaced`). Scheitert das Speichern des Kalenders, zeigen sie auf den bisherigen Stand im Papierkorb und der Kalender meldet es.
- **Wo die Fenster erscheinen:** Die Zeitleiste aus dem Heft und eine aus Dateien geöffnete Bibliotheksbackup-Datei zeigt die Bibliothek erst, wenn dort nichts anderes offen ist (`RestoreRouter`); eine Anfrage aus dem Heft verfällt nach einer Minute. Einstellungen und Bereichsliste zeigen ihre Inhaltsansicht selbst. „Öffnen“ nach dem Zurückholen gibt es nur in der Zeitleiste der Bibliothek (sie schließt sich zuerst). Die Zeitleiste fragt die Backup-Liste vorher neu ab und zeigt nur Backups, die es am Ziel noch gibt.

- Ein Eintrag **in den Einstellungen** (Entscheidung des Nutzers) mit einer **Zeitleiste**: lokale Wiederherstellungspunkte (pro Heft) und externe Backups (ganze Bibliothek) in einer Liste, nach Datum sortiert und mit Quelle gekennzeichnet („auf dem iPad“, „iCloud Drive“, „WebDAV“).
- Aus einem geöffneten Heft führt „Älteren Stand wiederherstellen …“ direkt zur Zeitleiste dieses Hefts. Sie zeigt lokale Stände **und** die externen Backups, in denen das Heft vorkommt.
- Lokale Stände kommen ebenfalls als normale Kopie in die Bibliothek bzw. ersetzen das Heft. „Wiederhergestellte Kopien“ (`Restores/`) entfällt als eigene Ablage. Vorhandene Kopien bleiben lesbar und lassen sich einmalig in die Bibliothek übernehmen.
- Papierkorb und Seitenpapierkorb bleiben, wo sie sind. Die Zeitleiste verweist aber auf sie („Gelöscht? Zuerst im Papierkorb nachsehen“).

### Phase 3: Backup-Liste verständlich machen und sinnvoller aufbewahren

**Stand 08.11.2026: implementiert, Core-Tests grün; am iPad ungeprüft.** Nach jedem erfolgreichen automatischen Backup schreibt noty eine Zusammenfassung lokal (`Library/Application Support/BackupSummaries/<Reihe>.json`, `BackupSummaryIndex`: je Heft Kennung, Titel und Prüfsumme des Archivteils, dazu geändert/entfernt seit dem vorigen Backup; höchstens 120, Einträge verschwinden mit ihrem Archiv). Die Backup-Liste zeigt „42 Hefte · 3 geändert (Bio, Mathe, Deutsch)“. Aufbewahrung gestaffelt (`ExternalBackupPolicy.obsolete`): die neuesten N wie bisher (Einstellung 3–30) **plus** je das neueste Backup der letzten 7 Tage, 4 Wochen und 6 Monate; neue optionale Felder `keepWeeks`/`keepMonths` (ältere Builds lesen die Richtlinie weiter). Das neueste geprüfte Backup und noch nicht hochgeladene Backups bleiben wie bisher. Bei ausgeschaltetem Backup bleiben die Zusammenfassungen liegen. Die optionale Erweiterung der lokalen Historie (gestern/letzte Woche) ist nicht umgesetzt.

- Bei jedem erfolgreichen Backup schreibt noty eine kleine Zusammenfassung **lokal** in den App-Container: Datei, Datum, Anzahl der Hefte, seit dem letzten Backup geänderte Hefte. Die Liste kann dann „7. Nov., 18:02 · 42 Hefte · 3 geändert (Bio, Mathe, Deutsch)“ anzeigen, ohne vorher Archive aus iCloud zu laden. Fehlt die Zusammenfassung, z. B. bei alten Backups, zeigt die Liste nur das Datum wie heute. Die Zusammenfassung ist abgeleitet, also kein Teil des Archivs und kein Formatwechsel.
- Gestaffelt aufbewahren statt nur die letzten 7 Tage (vom Nutzer bestätigt): 7 tägliche, 4 wöchentliche und 6 monatliche Stände (`ExternalBackupPolicy.obsolete`). Ein versehentlich gelöschtes Heft lässt sich dann auch nach Wochen noch zurückholen. Optionale neue Felder in der Richtlinie, sodass ältere Builds sie weiter lesen können. Das neueste geprüfte Backup bleibt immer erhalten (wie heute).
- Optional nach Entscheidung des Nutzers: Unter den lokalen Wiederherstellungspunkten zusätzlich je einen Stand von gestern und von letzter Woche behalten, damit die lokale Historie nicht nur aus Ständen von heute besteht. Grenze weiterhin 300 MB.

### Phase 4: „Alles zurücksetzen“ ohne Bereich (Notfall) und Bereiche ausblenden

**Stand 08.11.2026: implementiert, iPad-Build erfolgreich; am iPad ungeprüft.** Abweichend von der Reihenfolge unten vor dem Gerätetest der Phasen 1 und 2 gebaut (Auftrag des Nutzers „den Plan zu Ende stellen“).
- In der Inhaltsansicht eines **eigenen automatischen Backups** unter „…“: **„Ganze Bibliothek auf diesen Stand bringen …“** (`LibraryBackupBrowser.wholeRestorePlan`): geänderte Hefte an ihrer Stelle (heutiger Stand in den Papierkorb), gelöschte bzw. im Papierkorb liegende kommen unter ihrem Namen zurück, fehlende Ordner werden nach den Titeln des Backups angelegt (ein vorhandener gleichnamiger Ordner derselben Ebene wird verwendet), seitdem neue Hefte kommen in den Papierkorb. Vorher Bestätigung mit Zahlen.
  - Nicht für fremde Dateien und Bereiche: Dort würde alles, was die Datei nicht enthält, in den Papierkorb wandern.
  - Gesperrt, wenn ein heutiges Heft nicht lesbar ist (eingeschränkter Vergleich: sonst gälte jedes Heft als geändert), und nach einem Lauf in derselben Ansicht.
  - Kommt nicht jedes Heft zurück, bleiben die seitdem neuen Hefte in der Bibliothek; die Bibliothek hat danach nie weniger als vorher.
  - Bekannte Grenze: Ersetzte Hefte haben danach neue Kennungen. Wer dasselbe Backup später noch einmal ganz anwendet, bekommt sie noch einmal als Kopie zurück und die gerade zurückgeholten wandern in den Papierkorb. Es geht nichts verloren, aber es ist unnötig.
- **Bibliotheksbackup-Datei** (aus Dateien oder den Einstellungen) öffnet die Inhaltsansicht statt eines neuen Bereichs; in den Test-Apps steht „Als neuen Bereich“ weiter zur Wahl.
- **Bereiche:** In der normalen noty erscheinen sie nur, wenn welche existieren (wie bisher, `DeveloperAccess.showsAreas`). Neu: „Hefte in Meine Bibliothek übernehmen …“ (lange drücken/wischen in der Bereichsliste, nur aus „Meine Bibliothek“) liest den Bereich (die Bereichsliste ist währenddessen gesperrt) und öffnet ihn als Backup mit allem ausgewählt; „Als Kopie zurückholen“ bringt die Hefte herüber, der Bereich bleibt, bis er entfernt wird. „Ganze Bibliothek als eigenen Bereich öffnen“ in der Backup-Liste nur noch in den Test-Apps.

- „Ganze Bibliothek auf diesen Stand bringen …“: Hefte aus dem Backup, die heute fehlen oder anders sind, kommen zurück. Heutige Hefte, die es im Backup nicht gab oder die sich geändert haben, landen **im Papierkorb**. Nichts wird endgültig gelöscht, und auch das lässt sich wieder rückgängig machen. Ordner werden nach dem Backup wiederhergestellt. Vorher erscheint eine Bestätigung mit Zahlen („12 zurückholen, 3 in den Papierkorb“).
- Danach braucht die normale noty keine Bereiche mehr zum Wiederherstellen. Umsetzung des SCOPE-Vermerks:
  - In der **normalen noty** gibt es keine Bereichsauswahl. Vorhandene Bereiche (alte Wiederherstellungen, Testbereiche) bekommen eine einmalige Aktion „Hefte in Meine Bibliothek übernehmen …“ und lassen sich danach wie heute entfernen.
  - In **noty dev, noty AI und noty calendar** bleibt der gespiegelte Bereich „noty“ für den App-Abgleich ([APP-SYNC](APP-SYNC.md)), da er dort ein Entwicklerwerkzeug ist. Die Einbahnstraße bleibt unverändert.
- Erst umsetzen, wenn Phasen 1 und 2 am iPad bestätigt sind.

### Phase 5: Sync

**Stand 08.11.2026: Stufe 1 als iCloud-Ablage implementiert** (jedes Heft einzeln mit Ständen im iCloud-Container der App, Zurückholen als Kopie oder Ersetzen), Build 141 auf `feat/wiederherstellen`, nicht installiert, am iPad ungeprüft. Details: [ICLOUD](ICLOUD.md). Nutzerentscheidung: iCloud statt eigener Server; iCloud-Dokumente (Dateien) statt CloudKit, weil die Hefte schon als geprüfte Dateien vorliegen. Stufe 2 (Abgleich in beide Richtungen) folgt, wenn ein zweites Gerät da ist.

Eine PDF-Kopie im Backupziel ist **nicht** gewünscht, das Backup bleibt im noty-Format.

**Warum nicht iCloud wie bei Goodnotes:** Ein CloudKit-Sync oder ein Sync über den iCloud-Container braucht die iCloud-Berechtigung. xtool 1.24.0 kennt sie nicht (`XKit/Model/Entitlements/EntitlementTypes.swift`). Schlimmer noch: `DeveloperServicesAddAppOperation` gleicht bei jedem signierten Build die Fähigkeiten der App-ID ab und **löscht alle, die es nicht kennt** (Ausnahme: In-App-Kauf). Ein von Hand im Apple-Entwicklerportal eingeschaltetes iCloud wäre nach dem nächsten Build wieder weg, und das Profil enthielte es nicht. Gehen würde es nur mit einem eigenen xtool-Fork, der die Fähigkeit samt Container-Zuordnung kennt. Das ist aufwendig, ungeprüft und müsste bei jedem xtool-Update nachgezogen werden. **Nicht empfohlen.**

**Ergebnis vom 08.11.2026: iCloud mit xtool funktioniert auf dem iPad** (Test-App, nicht noty)

- **Getestet:** Die Test-App `~/workspace/icloud-probe` (App-ID `XTL-BAFXLQ964V.de.la.noty.icloudprobe`, Container `iCloud.de.la.noty.probe`) wurde unter Linux mit dem gepatchten xtool signiert, per Link installiert und auf dem iPad ausgeführt. Ergebnis des Nutzers: Profil mit iCloud-Diensten, CloudKit- und Dokumente-Container, CloudKit-Konto verfügbar, CloudKit-Datensatz geschrieben, zurückgelesen und gelöscht, Datei im iCloud-Dokumentordner geschrieben und gelesen: **alles OK.**
- **Ablauf:** Der Nutzer legt den Container einmal im Apple-Entwicklerportal an und ordnet ihn der App-ID zu (CloudKit, „Xcode 6“). In den ersten ~15 Minuten danach meldete CloudKit `CKError 10 „Invalid bundle ID for container“`, dann ging es (bekannte Verzögerung bei Apple). iCloud-Dokumente gingen sofort.
- **gepatchtes xtool** `xtool-noty` (`~/workspace/xtool-noty`, Zweig `noty/icloud`, Version `1.24.0-noty.4`, Anleitung `NOTY.md`): schaltet iCloud für Apps mit `com.apple.developer.icloud-services` selbst ein, ändert vorhandene Fähigkeiten nie und protokolliert mit `XTOOL_TRACE_CAPABILITIES=1`, was an Apple geht. Das normale `xtool` 1.24.0 bleibt unverändert und baut alle noty-Apps wie bisher.
- **Korrektur der Annahme unten:** Laut Protokoll liefert Apples Schnittstelle die Typen vorhandener Fähigkeiten nicht mit (`capabilityType: null`). Das normale xtool erreicht seinen Lösch-Zweig deshalb nie und **löscht iCloud nicht**. Mit iCloud und Container im Portal erzeugte auch das normale xtool 1.24.0 ein vollständiges Profil (`ota_check.py` ohne Probleme, am iPad nicht installiert). Es kann iCloud nur nicht selbst einschalten und schickt seine bekannten Fähigkeiten bei jedem Build erneut als CREATE.
- **Bei Updates:** Ein künftiges xtool, das die Typen korrekt liest, könnte iCloud wieder löschen. Deshalb nach jedem xtool-Update zuerst die Test-App signieren und das Profil prüfen, erst dann eine noty-App mit iCloud.
- **Noch offen:** Container für noty, noty dev und noty AI (je ein eigener, Einbahnstraße), die Wahl zwischen CloudKit und iCloud-Dokumenten für den Sync und der Sync selbst. An noty selbst ist nichts geändert.

**Vorab-Untersuchung vom 08.11.2026** (vor dem Test, teilweise durch das Ergebnis oben überholt)

- *Was fehlt:* xtool 1.24.0 und der aktuelle Stand von `xtool-org/xtool` (`origin/main`, geprüft am 08.11.2026) kennen die iCloud-Einträge nicht (`com.apple.developer.icloud-services`, `…icloud-container-identifiers`, `…ubiquity-container-identifiers`, `…icloud-container-environment`). Apples Schnittstelle kennt die Fähigkeit aber (`ICLOUD` mit Einstellung `ICLOUD_VERSION` = `XCODE_6` in `DeveloperAPI/Generated/Types.swift`).
- *Signatur:* Bei bezahlten Teams lässt xtool unbekannte Einträge in der Signatur stehen (nur bei kostenlosen Teams werden sie gefiltert). Das Problem ist allein `DeveloperServicesAddAppOperation`: Es löscht an der App-ID jede Fähigkeit, die es nicht kennt. Dann fehlt iCloud im neu erzeugten Profil.
- *Kleiner Patch:* die iCloud-Einträge als bekannte Fähigkeit `ICLOUD`/`XCODE_6` eintragen, so wie es xtool schon für „Mit Apple anmelden“ macht (`EntitlementTypes.swift` und `DeveloperServicesCapability.swift`, zusammen etwa 50–100 Zeilen). Den **Container** legt der Nutzer einmal je App im Apple-Entwicklerportal an und ordnet ihn zu. Ein automatisches Anlegen wie bei App Groups bräuchte Xcodes interne Container-Aufrufe. Davon ist nur `/_cloudContainer/listCloudContainers.action` öffentlich belegt (Apple-Forum), Anlegen und Zuordnen nicht, deshalb **nicht empfohlen**.
- *Eigenes xtool bauen:* Die Swift-Abhängigkeiten ließen sich hier testweise bauen. Am Host fehlen nur die Header von libimobiledevice. Der vorgesehene Weg ist der offizielle Docker-Build von xtool (`Dockerfile` baut libplist 2.6.0, libimobiledevice-glue 1.3.1 und libimobiledevice selbst, `Linux/build.sh` erzeugt das AppImage). Docker ist vorhanden. Ein Wrapper-Wechsel wie beim Schritt 1.22.2 → 1.24.0, das alte AppImage bleibt daneben. Noch nicht ausgeführt.
- *Absicherung:* `ota_check.py` verlangt die iCloud-Einträge in Signatur **und** Profil, sonst keine Veröffentlichung. `publish_ota.sh` prüft, dass das gepatchte xtool läuft. Erst mit noty dev oder noty AI testen.
- *Getrennte Container:* `iCloud.de.la.noty` für die normale noty und eigene Container für noty dev und noty AI, sonst würden Testdaten die echten Hefte erreichen (Einbahnstraße aus [APP-SYNC](APP-SYNC.md)).
- *Aufwand:* Patch, Build, Absicherung und Probe auf dem iPad (ein CloudKit-Datensatz schreiben und lesen) etwa 2–3 Arbeitstage. **Der Sync selbst in noty ist der deutlich größere Teil** (Konfliktregeln, PDFs und Bilder, iCloud-Speicherplatz des Nutzers, Abgleich im Hintergrund, Tests mit zwei Geräten) und kommt unabhängig vom Weg dazu.
- *Bei jedem xtool-Update:* Den Patch auf die neue Version übertragen, mit Docker neu bauen, zuerst mit noty dev signieren und das Profil prüfen. Bei einem Patch in zwei Dateien meist ohne Konflikte. **Nie das offizielle xtool für eine noty-App benutzen:** Es würde iCloud wieder von der App-ID löschen, und der Container müsste im Portal neu zugeordnet werden. Die Hefte auf dem iPad sind davon nicht betroffen, nur der Abgleich fällt aus, bis wieder mit dem gepatchten xtool signiert wird. Ohne diese Pflege geht es nur, wenn der Patch bei xtool selbst aufgenommen wird (Pull Request an das öffentliche Projekt, nur mit Zustimmung des Nutzers).

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
