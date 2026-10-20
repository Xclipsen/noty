Status: Plan, freigegeben am 20.10.2026; Umsetzung auf feat/image-assets in Schritten C1–C8.

# Plan: Bild-Assets für noty (Notebook-Schema 12, Archivformat 2)

## 0. Kurzfassung und Empfehlung

- **Bildbytes kommen aus dem JSON heraus.** Jedes Bildoriginal wird eine unveränderliche Datei `Assets/<sha256>` im Heftpaket. `ImageObject` hält nur noch `asset: {sha256, byteCount}`.
- **Kein Byte-Ballast mehr im Laufzeitmodell.** Ein Asset-Store pro Heft (`NotebookAssets`, Core) liefert die Bytes: entweder als Datei-URL (ImageIO liest dann direkt von der Datei) oder, für frisch importierte und noch nicht gespeicherte Bilder, aus einem Pending-Bereich im Speicher.
- **Commit-Reihenfolge:** zuerst die Assets (Teildatei → fsync → Hash erneut prüfen → umbenennen), dann die Revision, das Manifest zuletzt. Manifestformat 1 bleibt Byte für Byte im Build-46-Format.
- **Migration beim Laden, Schreiben erst bei der ersten echten Änderung.** Schema 5–11 mit eingebetteten Bildern wird schon beim Laden im Speicher auf Schema 12 gehoben. Geschrieben wird erst mit der ersten echten Änderung. Davor sichert der Commit die exakten bestätigten Altbytes unter `Migrations/<UUID>/notebook-v11.json`.
- **Asset-GC nie während einer Editorsitzung.** Er läuft nur beim Öffnen (bevor Undo-Historie existiert) und beim Schließen, und nie während eines laufenden Backups.
  - Als Wurzeln gelten alle Dateien unter `Revisions/`, `Quarantine/`, `Migrations/` und `Archives/`.
  - Sie werden per Rohbyte-Suche nach 64-stelligen Hex-Hashes durchsucht. Das ist bewusst übervorsichtig, funktioniert auch bei beschädigten oder unbekannten Dateien und dekodiert kein großes JSON.
- **Beide Archive bekommen Version 2** als streambaren Datensatzstrom mit SHA-256 je Asset. Version 1 bleibt lesbar.
- **Empfehlung:** reine Referenz im Modell. Die Alternative „Data im Speicher behalten, nur die Serialisierung auslagern“ ist bei 500 MB wegen Speicher und Ladezeit nicht tragfähig (Abschnitt 2).

---

## 1. Ist-Zustand (Fundstellen)

**Format und Validierung**
- `ImageObject.data: Data` liegt in `Core/Sources/NotebookCore/ImageObject.swift:6`. `validate()` prüft in Zeile 27 die 20 MB je Original.
- `replaceImages` hebt auf Schema 5 (`ImageObject.swift:83-91`, Zeile 86).
- `Notebook.currentSchemaVersion = 11` steht in `Notebook.swift:25`. `decode` prüft vor jeder Validierung den Schema-Header (`Notebook.swift:37-44`). Die Summe der Bildoriginale je Objekt wird gegen 40 MB geprüft (`Notebook.swift:56-64`), die Bildregeln je Seite in `Notebook.swift:76-82`.
- `ImageLimits` steht in `ImageImportPolicy.swift:7` (20 MB) und `:11` (40 MB). `imageOriginalBytes` (`:101`) zählt Duplikate mehrfach, `imageInsertionProblem` steht in `:107-113`.

**Speichern**
- `RevisionStore.save` (`RevisionStore.swift:178-235`) kodiert das ganze Heft in Zeile 183 und dekodiert es zur Kontrolle in Zeile 185 vollständig neu.
- `writeRevision` (`:479-493`) schreibt die Revision und liest sie wieder (CRC). Bei jedem Autosave mit 40 MB Bildern werden also etwa 53 MB Base64 kodiert, dekodiert, zweimal per CRC geprüft, geschrieben und zurückgelesen.
- Die Migrationssicherung greift bei `old.schemaVersion < document.schemaVersion` (`:186-189`), umgesetzt in `archiveMigrationSource` (`:240-263`).
- Der Revisions-GC (`:338-352`) räumt nur `Revisions/` auf.

**Vergleiche über Megabytes**
- `ImageObject` hat ein synthetisiertes `==` über `data`. Betroffen sind: `EditorModel.updateImages` (`EditorModel.swift:312`), `ImageObjectLayer.shows` (`ImageObjectLayer.swift:173`), das Undo (`NotebookUndoHistory.swift:234, 246-250`), `replaceContents` (`CrossPageTransfer.swift:218`) und `RevisionStore.swift:180`.
- Der Suchindex hasht die ganzen Bildbytes je Seite (`ContentSearchIndex.swift:210`).

**Backups**
- `BackupArchive.maximumBytes = 200_000_000` (`BackupArchive.swift:40`). Das Heftbackup wird vollständig im Speicher gebaut (`encode` in `:44-66`) und als `Data` exportiert (`ExportFile`, `EditorModel.swift:763-773`, aufgerufen in `ContentView.swift:619`).
- Der Import liest ebenfalls komplett in den Speicher (`IncomingBackup.swift:25, 67`; `NotebookRepository.prepareRestore`, `NotebookRepository.swift:30-56`).
- `LibraryArchive` streamt bereits (Manifest reserviert, `LibraryArchive.swift:256-297`). Jedes Heft ist darin aber ein JSON-Block von höchstens 200 MB (`:190`).

**Wahrscheinliche Ursache des Ruckelns (Hypothese, am Gerät mit HangProbe und Editor-Traces messen)**
- Das Kodieren, Dekodieren und Prüfen von etwa 53 MB bei jedem Autosave nach dem Loslassen.
- Megabyte-Vergleiche über `==` beim Gestenende, in der Undo-Aufzeichnung und beim Neuaufbau des Layers.
- Das Hashen der Bildbytes im Suchindex.

---

## 2. Varianten im Vergleich

| | A: nur Referenz im Modell (empfohlen) | B: `Data` bleibt im Modell, nur die Serialisierung wird ausgelagert |
|---|---|---|
| RAM bei 500 MB | Nur dekodierte Darstellungen (bestehender Cache 160 MB, `ImageRendering.swift:125-128`). Originale per ImageIO direkt aus der Datei. | 500 MB Rohbytes je offenem Heft, dazu Undo-Kopien gelöschter Bilder und die Pending-Bytes. Bibliotheksbackup und Vorschau laden zusätzlich. Auf 4-GB-iPads besteht Jetsam-Gefahr. |
| Ladezeit | Nur `stat` (Größe) je Asset. Dekodiert und gehasht wird erst bei Bedarf. | 500 MB lesen, dazu SHA-Prüfung und heute noch `EditorModelValidation.validateContent` mit einer ImageIO-Dekodierung je Bild (`EditorModel.swift:744-752`): mehrere Sekunden. |
| `==` / Undo | 64 Zeichen plus `Int` | `memcmp` über Megabytes. Wäre nur mit einem eigenen `==` über gecachte Hashes vermeidbar. |
| Speichern | Kleines JSON, neue Assets einmalig | Kleines JSON, aber Hash-Cache je `Data`-Puffer nötig |
| Codebruch | `ImageObject.data` fällt weg. In der App sind nur etwa 8 direkte Stellen betroffen, fast alle in `ImageRendering.swift`. | Kaum Bruch |
| Plattenseite (Asset-GC, Archive, Migration) | gleich | gleich |

Der Aufwand auf der Plattenseite ist in beiden Varianten gleich. B spart nur den Laufzeitumbau, skaliert aber beim Speicher und beim Öffnen genau dort schlecht, wo der Nutzer hinwill. **Empfehlung A.** Der Bruch bleibt klein, weil fast alle Bytezugriffe schon über `ImageRendering` laufen.

---

## 3. Format

### 3.1 Paketlayout (zusätzlich zu STORAGE „Dateien und Identitäten“)

```text
<Paket>/Assets/<sha256>                       unveränderliches Bildoriginal, Name = 64 Hex-Zeichen klein, ohne Endung
<Paket>/Assets/<sha256>.partial-<UUID>        Rest eines abgebrochenen Asset-Schreibvorgangs (nur der GC entfernt ihn)
```

- Es gibt kein Sharding; ein flaches Verzeichnis reicht für einige tausend Dateien.
- `Assets/` darf kein Symlink sein. Das wird geprüft wie `validateRevisionDirectory` (`RevisionStore.swift:495-498`).
- Pakete sind getrennt. Auch das Hauptpaket `Documents/Noty/` bekommt sein eigenes `Assets/`. `Restores/*` und `Library/Documents/*` sind eigene Pakete; der GC des Hauptpakets fasst sie nie an.

### 3.2 Schema 12, Bildobjekt im JSON

```json
{"id":"…","asset":{"sha256":"<64 hex>","byteCount":4812331},"pixelWidth":4032,"pixelHeight":3024,
 "x":…,"y":…,"width":…,"height":…,"rotation":0,"crop":{…},"locked":false}
```

- Schema 12: `asset` ist Pflicht, `data` ist verboten.
- Schema 5–11: `data` ist Pflicht, `asset` ist verboten. Gemischte Formen sind ungültig.
- Ab 13 gesperrt: `unsupportedSchema`, ohne Rückfall.

### 3.3 Validierungsregeln und Limits (Swift und Python gemeinsam)

- `ImageLimits` (in `ImageImportPolicy.swift`):
  - `maximumFileBytes = 20_000_000` bleibt die Speichergrenze je Asset; bestehende Bilder bis 20 MB bleiben gültig.
  - neu `maximumImportBytes = 5_000_000`; `ImageCompression.importTargetBytes` (`ImageCompression.swift:21`) verwendet diesen Wert.
  - neu `legacyMaximumNotebookBytes = 40_000_000`: Summe je Objekt, nur für gespeichertes Schema ≤ 11.
  - `maximumNotebookBytes = 500_000_000`: **Summe der eindeutigen Assets** über aktive Seiten und Seitenpapierkorb. Duplikate zählen nicht doppelt.
- `sha256` passt auf `^[0-9a-f]{64}$`; `byteCount` liegt bei 1…20 MB.
- Objekte mit gleichem Hash müssen gleiche `byteCount`, `pixelWidth` und `pixelHeight` haben. So kann die Apple-Prüfung je Asset einmal laufen.
- Nicht leere `images` verlangen im Speicher Schema ≥ 12. `replaceImages` hebt also auf `max(12, …)` statt `max(5, …)` (`ImageObject.swift:86`).
- `imageOriginalBytes` wird zu `uniqueImageAssetBytes`. `imageInsertionProblem(adding ref:, pageID:)` rechnet für einen Hash, der schon im Heft liegt, 0 Bytes an.
- Meldungstexte anpassen: `ImageImportError.notebookFull` (`ImageRendering.swift:29-30`, „40 MB … duplizierter Seiten“) und `RevisionError.snapshotTooLarge` (`RevisionStore.swift:66`; betrifft künftig praktisch nur noch PDFs).

---

## 4. Laufzeitmodell

### 4.1 Neue Typen

**Core** (plattformunabhängig, ohne CryptoKit, keine neue Paketabhängigkeit; `Core/Package.swift` hat keine):
- `SHA256` (neue Datei `SHA256.swift`): streamend, `update(_:)`, `hexDigest`. Testvektoren nach FIPS 180-4.
- `ImageAssetReference: Codable, Hashable, Sendable {sha256: String, byteCount: Int}`.
- `ImageAssetPayload`: `.file(URL)` oder `.data(Data)`.
- `ImageAssetProviding` (Protokoll): `func payload(for: ImageAssetReference) throws -> ImageAssetPayload`.
- `NotebookAssets` (neue Datei `ImageAssets.swift`): `final class`, per Lock gesichert, `@unchecked Sendable`, eine Instanz je Paket.
  - `init(directory:readOnly:)`
  - `stage(_ data: Data) throws -> ImageAssetReference`: hasht, legt im Pending-Bereich im Speicher ab und prüft die Obergrenze `maximumPendingBytes ≈ 100 MB`.
  - `payload(for:)`: zuerst die Datei, dann Pending.
  - `verifiedPayload(for:)`: einmal je Sitzung streamender SHA-Vergleich.
  - `persist(_ refs:, from:)`: das Schreibprotokoll aus 5.1, nur für den Writer.
  - `presentOnDisk(_ refs:)`: `stat`, reguläre Datei, kein Symlink, Größe stimmt.
  - `collectGarbage(roots:…)`
  - `dropPending(_:)`
- `NotebookDecoding.decode(_ data:) -> DecodedNotebook {notebook, storedSchemaVersion, inlineImageBytes: [String: Data]}`. Ein Kontextobjekt über `userInfo` sammelt beim Dekodieren eingebettete Altbytes.
- `Notebook.decode(_:)` bleibt als Bequemlichkeitsfunktion für reine Prüfwege (`RevisionStore.swift:185`, `BackupArchive.swift:47`, `LibraryArchive.swift:17`).

**App** (`Sources/Noty`):
- `ImageAssetRegistry`: Inhaltsadressierung macht einen prozessweiten Resolver fachlich korrekt, weil gleicher Hash gleiche Bytes bedeutet.
  - Er hält schwache Referenzen auf registrierte `NotebookAssets`: vom Editor (Repository) und schreibgeschützte Instanzen für Vorschau und Export geschlossener Hefte.
- `ImageRendering`-Funktionen bekommen einen Parameter `assets: ImageAssetProviding = ImageAssetRegistry.shared`. Aufrufstellen in den UIKit-Ebenen bleiben unverändert; Hintergrundwege übergeben die Quelle ausdrücklich.

### 4.2 Wo `ImageObject.data` benutzt wird, und was dort stattdessen passiert

| Stelle | Heute | Neu |
|---|---|---|
| `ImageObject.swift:6, 21, 27` | Feld, Initialisierer, Größenprüfung | `asset`; `validate` prüft die Referenz |
| `Notebook.swift:64` | Summe je Objekt ≤ 40 MB | eindeutige Summe ≤ 500 MB plus Konsistenzregel (3.3); die Altregel prüft der Dekodierweg |
| `ImageImportPolicy.swift:101-113` | `imageOriginalBytes` | `uniqueImageAssetBytes` |
| `NotebookUndoHistory.swift:200, 322` | rechnet Bildbytes als Kosten | etwa 128 B je Referenz; die Grenze 80 MB begrenzt dann im Wesentlichen Ink |
| `ContentSearchIndex.swift:210` | `value.add(image.data)` | `value.add(image.asset.sha256)`; der abgeleitete Index baut sich einmal neu |
| `ImageRendering.swift:106` (`ImageImport.object`) | aus `Data` | aus der gestageten Referenz plus Maßen |
| `ImageRendering.swift:116-160` | Cache-Eintrag mit `bytes`, `sameBytes`, Schlüssel `id-limit` | Schlüssel `sha256-limit`, `Entry.bytes` und `sameBytes` entfallen; Duplikate teilen sich Darstellungen |
| `ImageRendering.swift:168, 184-186, 195` | `prepare`, `validate`, `decoded` aus `Data` | `CGImageSourceCreateWithURL` (Datei) bzw. `…WithData` (Pending); die SHA-Prüfung im Hintergrund in `prepare` |
| `ImageImportModel.swift:138-152` | Budget 40 MB, `Data` → Objekt | `room` aus der eindeutigen Summe; `try await Task.detached { assets.stage(data) }`, danach Grenzprüfung und `updateImages` |
| `EditorModel.swift:744-752` (`validateContent` beim Öffnen) | ImageIO-Dekodierung je Bild | beim Öffnen nur `presentOnDisk`; die volle Prüfung erfolgt beim ersten Rendern (vorhandener `rejected`-Weg in `ImageObjectLayer.swift:224-233`), bei Backup, Restore und PDF-Export |
| indirekt über `ImageRendering`: `ImageObjectLayer.swift:203-265, 487, 551` (auch Zuschnitt), `SelectionTransfer.swift:71, 91`, `PDFExporter.swift:72, 134`, `PageThumbnailCache.swift:80`, `ContentSearchView.swift:293`, `BackupSupport.swift:37` | — | unverändert über den Standard-Resolver; PDF-Export, Vorschau und Backupprüfung geschlossener Hefte übergeben ihre schreibgeschützten `NotebookAssets` |
| Synthetisiertes `Codable`/`==` | Megabytes | Referenz; `init(from:)` mit Altpfad |
| `scripts/PageWorkflowCheck.swift:73, 145` | `ImageObject(data:)` | `store.assets.stage(...)`; Prüfung gegen `Assets/<sha>` |
| Tests | `ImageObjectTests` (4), `CrossPageTransferTests` (2), `ContentSearchIndexTests` (1), `ImageImportPolicyTests` (1) und 6 `.data`-Zugriffe | Testhelfer `ImageObject.test(bytes:)` |

### 4.3 Der Pending-Bereich

- Er liegt im Speicher von `NotebookAssets`. Beim Import liegen die Bytes nach `ImageCompression` ohnehin im Speicher; Copy-on-Write sorgt dafür, dass keine Kopie entsteht.
- Der nächste Commit schreibt **alle** Pending-Assets, auch die gerade nicht referenzierten, damit Undo sie wieder einfügen kann. Danach gibt `dropPending` die Bytes frei; ab dann liest der Renderer die Datei.
- Wird die Obergrenze erreicht (Speichern scheitert wiederholt), werden weitere Importe mit einer klaren Meldung abgelehnt („Bitte erst erfolgreich speichern“).
- Alt-Hefte: Die eingebetteten Bytes (höchstens 40 MB) landen beim Laden im Pending-Bereich der Instanz.

---

## 5. Commit, Laden, Recovery

### 5.1 Commit in `RevisionStore.save` (`RevisionStore.swift:178-235`)

0. Die Kurzschlussprüfung „unverändert“ (Zeile 180) bleibt.
1. Kodieren, Größe prüfen, erneut dekodieren. Das geht jetzt schnell, weil das JSON klein ist.
2. Migrationssicherung, Bedingung neu: `(lastStoredSchema ?? old.schemaVersion) < document.schemaVersion`. Das ist wichtig, weil `lastDocument` nach dem Laden schon auf 12 gehoben ist. Wie bisher entsteht `notebook-v<alt>.json` (`:240-263`); scheitert das, gibt es keinen Commit.
3. **Assets zuerst:** `assets.persist(document.assetReferences ∪ pending, from: importing ?? pending)`. Für jeden fehlenden Hash:
   - schreiben nach `Assets/<sha>.partial-<UUID>`, dann `synchronize()`
   - streamend zurücklesen; SHA-256 und Größe müssen stimmen
   - `moveItem` auf `Assets/<sha>`; ein vorhandenes Ziel wird nie überschrieben
   - existiert das Ziel schon: Größe prüfen und die eigene Teildatei löschen
   - nur ein *nachweislich* falscher vorhandener Inhalt wird per `replaceItemAt` repariert; der Inhalt einer Adresse ist definiert, das ist also keine Überschreibung fremder Daten

   Scheitert dieser Schritt, wird abgebrochen, bevor eine Revision entsteht. Waisen sind harmlos. Wiederholte Versuche schreiben denselben Hash nicht erneut, die Platte füllt sich dadurch also nicht.
4. Revision, `checkpoints.json`, `manifest-previous.json`, `manifest.json` zuletzt: unverändert. Erst danach erscheint „Lokal gespeichert“.
5. Danach: `lastStoredSchema = document.schemaVersion`, `dropPending`, Revisions-GC wie bisher. **Kein** Asset-GC hier.

API:
- `RevisionStore.save(_:importingAssetsFrom: ImageAssetProviding? = nil)` für Kopien.
- `public let assets: NotebookAssets`
- interner Test-Haken `var commitFault: (CommitStage) throws -> Void` (analog zu `clock`, `:104`) mit `.assetsWritten`, `.revisionWritten`, `.checkpointsWritten`, `.previousWritten`.

### 5.2 Laden (`RevisionStore.load`, `:115-176`)

- Für jede Kandidatenrevision mit Schema 12 kommt nach CRC und Dekodierung `assets.presentOnDisk(refs)` hinzu. Fehlt ein Asset, gilt die Revision als unvollständig: Rückfall auf die ältere Revision bzw. `noCompleteRevision`, wie bei CRC-Fehlern. Nichts wird gelöscht.
- `unsupportedSchema` bleibt Sperre, ohne Rückfall.
- Die SHA-Prüfung erfolgt nicht beim Öffnen (500 MB wären zu teuer), sondern beim ersten Lesen bzw. in Backup und Export.

### 5.3 Absturz zwischen den Schritten

| Absturz nach … | Zustand beim Neustart | Behandlung |
|---|---|---|
| Teildatei teilweise geschrieben | `*.partial-*` | ignoriert; der GC entfernt sie nach mehr als 1 h |
| Assets fertig, noch keine Revision | verwaiste Assets | Manifest alt, Stand alt; der GC entfernt sie beim nächsten Öffnen |
| Revision geschrieben, Manifest nicht | unreferenzierte Revision plus Assets | bestehende Logik: gelöscht bzw. nach Rückfall in die Quarantäne; Assets bleiben, solange eine Datei unter `Revisions/` oder `Quarantine/` sie nennt |
| Manifest geschrieben | Commit vollständig | Aufräumen beim nächsten Mal |
| Asset später beschädigt (gleiche Größe) | Laden klappt | SHA-Fehler beim Lesen: Bild „defekt“ (vorhandene UI), Backup bricht mit Heftnamen ab, Python-Prüfer lehnt ab |
| Asset fehlt (externe Beschädigung) | Revision unvollständig | Rückfall bzw. Lesefehler, Dateien bleiben (Entscheidung 2) |

Grenze wie bisher dokumentiert: `.atomic` und `synchronize` garantieren keine physische Stromausfallsicherheit, und Verzeichnis-fsync gibt es in Foundation nicht.

---

## 6. Migration der Hefte mit Schema 5–11

1. `NotebookDecoding.decode` liest den Header-Schemawert. Ist er ≤ 11:
   - `ImageObject.init(from:)` verlangt `data`, hasht es und legt die Bytes in `inlineImageBytes`.
   - Die Altregeln gelten: je ≤ 20 MB, Summe je Objekt ≤ 40 MB.
   - Danach wird **im Speicher** `schemaVersion = 12` gesetzt und `validate()` aufgerufen.
   - Hefte ohne Bilder bleiben auf ihrem Schema.
2. `RevisionStore.load` übernimmt `inlineImageBytes` in den Pending-Bereich und merkt sich `lastStoredSchema` sowie die exakten `lastBytes`.
3. Der Editor (`EditorModel.swift:88-123`) ruft nach dem Laden `save()` auf. Wegen `lastDocument == document` entsteht kein Commit. Bloßes Öffnen schreibt also nichts, auch kein `Assets/`.
4. Erste echte Änderung: Sicherung `Migrations/<UUID>/notebook-v11.json` (exakte Bytes) → Assets → Revision mit Schema 12 → Manifest. Scheitert die Sicherung, gibt es keinen Commit. Ein wiederholter Versuch verwendet dasselbe Archiv (vorhandene Logik).
5. Kein Herabsetzen:
   - Undo stellt das Schema nie zurück (`NotebookUndoHistory.swift:213-221` nimmt bereits `max`). `PageStructureChange` mit `schemaVersion` je Seite per Test absichern.
   - `restoredCopy` (`NotebookRepository.swift:59-65`) nimmt `max`.
   - Es gibt keinen Kodierweg zurück zu `data`.
6. Ältere Builds (≤ 53) sperren Schema 12 mit „Dokumentformat 12 … nicht unterstützt“. Ein Rückfall ist nicht möglich, weil der Schema-Header vor der Validierung geprüft wird (`Notebook.swift:37-40`). Unbekannte Dateien unter `Assets/` stören sie nicht, ihr GC fasst nur `Revisions/` an.
7. Kopien (v1-Backup-Restore, Duplikat eines Alt-Hefts) entstehen direkt als Schema 12 mit Assets. Das ist zulässig, weil es neue Pakete sind und das Original bzw. die Archivdatei die Altbytes behält. Das wird dokumentiert.

---

## 7. Garbage Collection

**Wo:** `RevisionStore.collectAssetGarbage(isBlocked:)`, also nur beim einzigen Writer. Erreichbar über `NotebookRepository.collectAssetGarbage()`.

**Wann:**
- (a) im Editor nach erfolgreichem Laden und vor der ersten Änderung, gleicher Actor, also seriell vor jedem Save;
- (b) in `flushBeforeClosing` (`EditorModel.swift:569-584`) nach dem letzten erfolgreichen Commit.

Nie während einer Sitzung. Damit können Undo/Redo, `copiedPage` und das Ziehen über Seiten nie auf ein gelöschtes Asset zeigen; Pins sind unnötig.

**Sperre:** Läuft ein Bibliotheks- oder externes Backup (`LibraryModel.buildArchive`, `LibraryModel.swift:104-120`), wird der GC übersprungen und beim nächsten Mal nachgeholt. Dafür gibt es ein prozessweites Flag, analog zu „Endgültiges Löschen wartet auf ein laufendes Backup“.

**Wurzeln** (alles übervorsichtig):
- Rohbyte-Suche nach `"[0-9a-f]{64}"` (in Anführungszeichen) in **jeder** regulären Datei unter:
  - `Revisions/`: alle Dateien, nicht nur die referenzierten; deckt Manifest, vorige Fassung und Checkpoints ab, auch bei unlesbarer `checkpoints.json`;
  - `Quarantine/**`;
  - `Migrations/**`: wichtig für künftige 12→13-Sicherungen;
  - `Archives/**`.
- Dazu Pending und das aktuelle Dokument im Speicher.

Base64 enthält kein `"`. Fehltreffer halten also höchstens Müll fest, falsche Negative gibt es nicht. Die Suche funktioniert auch bei beschädigtem JSON, neueren Schemata und Python-Ausgaben mit Leerzeichen. Grenze: Unicode-Escapes in Hex-Strings erzeugt kein Encoder. Der Prüfer meldet sie.

**Löschen:**
- nur Dateien `^[0-9a-f]{64}$`, regulär, kein Symlink, nicht in den Wurzeln und älter als 15 min;
- `*.partial-<UUID>` älter als 1 h;
- fremde Namen, Verzeichnisse und Symlinks bleiben unangetastet (Philosophie wie `RevisionStore.swift:333-352`);
- jeder Lesefehler in den Wurzelverzeichnissen bricht den ganzen Lauf ab, ohne etwas zu löschen.

**Folge:** „Endgültig löschen“ im Seitenpapierkorb (`deleteTrashedPage`/`emptyPageTrash`, `PageOperations.swift:278-292`) gibt Platz erst frei, wenn keine behaltene Revision, kein Checkpoint und keine Quarantäne mehr darauf verweist, und frühestens beim nächsten Öffnen oder Schließen. Das wird in STORAGE und IMAGES dokumentiert. Bei PDFs ist es heute genauso.

**Optional in C7:** Das Checkpoint-Budget (`maximumCheckpointBytes`, `RevisionStore.swift:268`) zählt auch Asset-Bytes, die *nur* Checkpoints halten. Die Referenzen je Revision werden per Rohsuche ermittelt und nach Dateiname gecacht; Revisionen sind unveränderlich.

---

## 8. Backups und Archive

### 8.1 Gemeinsamer Container v2 (neu: `Core/Sources/NotebookCore/RecordArchive.swift`)

Ein reserviertes Manifest am Anfang geht nicht mehr. Die Zahl der Asset-Einträge ist beim Reservieren unbekannt, und ein Vorlauf hätte bei gleichzeitigem Commit ein Wettlaufproblem. Deshalb ein Datensatzstrom:

```text
magic (8) | uint32 BE Kopflänge | Kopf-JSON (≤ 64 KB)
{ uint32 BE Deskriptorlänge | Deskriptor-JSON (≤ 4 KB) | payload[byteCount] }*
Abschlussdatensatz {kind:"end", records, payloadBytes}  → danach EOF
```

- Deskriptoren: `{kind:"index"|"toolbar"|"notebook", id?, byteCount, crc32}` bzw. `{kind:"asset", sha256, byteCount}`.
- Assets haben kein CRC: der SHA-256 der Nutzlast muss dem Namen entsprechen. Sowohl `sha256` als auch `byteCount` sind aus der Referenz vorher bekannt, also muss nichts nachträglich gepatcht werden.
- Die Datei-CRC (`LibraryArchiveFileInfo`) bleibt für Staging-Vergleiche erhalten.
- CRC und SHA-256 erkennen Beschädigung, schützen aber nicht vor Manipulation (Formulierung wie in AGENTS).
- Senke und Quelle (`LibraryArchive.swift:120-169`), `StreamingCRC32` (`BackupArchive.swift:122-159`) und `BoundedFile` werden übernommen; Assets werden in 4-MB-Blöcken gelesen und geschrieben, mit streamendem SHA.

### 8.2 Einzelheft `.notybackup` v2

- Kopf: `backupFormatVersion: 2`, `checksumAlgorithm`, `assetHashAlgorithm: "sha256"`, `documentID`, `notebookSchemaVersion`, `createdAt`.
- Datensätze:
  - genau ein `notebook` (`payloadName` entfällt), danach genau die eindeutigen Assets in der Reihenfolge ihres ersten Auftretens (aktive Seiten, dann Papierkorb);
  - keine fehlenden, keine zusätzlichen, keine doppelten Assets;
  - danach `end`.
- Grenzen: Datei ≤ 800 MB (JSON ≤ 200 MB plus Assets ≤ 500 MB plus Overhead), Asset ≤ 20 MB.
- Schreiben: `BackupArchive.write(_:assets:to:)` in eine Datei unter `BackupScratch` (`BackupSupport.swift:106-123`), danach streamend vollständig zurücklesen und prüfen.
  - Export über ein neues `BackupArchiveFile(url:)` (wie `LibraryArchiveFile`, `BackupSupport.swift:129-136`).
  - `EditorModel.backupData` (`EditorModel.swift:670-685`) wird zu `backupFile() async -> URL?`.
  - `ContentView.swift:619` wird angepasst; `ExportFile.init(configuration:)` (`EditorModel.swift:765-769`) wirft wie `LibraryArchiveFile`.
- v1 bleibt lesbar. Der bestehende Pfad im Speicher (`decodeValidated`, `BackupArchive.swift:75-106`) bleibt auf ≤ 200 MB begrenzt. Eingebettete Bilder werden über `inlineImageBytes` zu Assets der Kopie. Den Abgleich `document.schemaVersion == manifest.notebookSchemaVersion` (`:102`) gegen `storedSchemaVersion` prüfen.
- Unbekannte Version ≥ 3 → `unsupportedVersion`.

### 8.3 Bibliothek `.notylibrary` v2

- Datensätze: `index`, `toolbar`, dann je Heft: `notebook`, gefolgt von seinen **noch nicht ausgegebenen** Assets; zum Schluss `end`.
- Regeln:
  - ein Asset steht nur nach `notebook` bzw. `asset` und wird vom unmittelbar vorangehenden Heft referenziert;
  - jeder Hash kommt im Archiv genau einmal vor;
  - jede Referenz jedes Hefts wurde in seiner eigenen oder einer früheren Gruppe ausgegeben;
  - Heft-IDs und Titel werden gegen den Index geprüft wie bisher (`LibraryArchive.swift:383-397`).
- Dedupe über Hefte hinweg ist damit gratis, etwa für duplizierte Hefte.
- Grenzen: Heftblock ≤ 200 MB, Asset ≤ 20 MB, Gesamtgröße höchstens 4 GB (Entscheidung 1).
- `LibraryBackupPlan.readableNotebook` (`:102-117`) liefert zusätzlich ein schreibgeschütztes `NotebookAssets`.
- Die Signatur der Callbacks wird `validate: (Notebook, ImageAssetProviding) throws -> Void`, und `BackupValidation.validate` (`BackupSupport.swift:10-38`) prüft je Asset einmal ImageIO-Maße und SHA.
- v1 bleibt lesbar (`readValidated`, `:348-401`, unverändert); eingebettete Bilder werden über den Altdekodierer übernommen.

### 8.4 Restore als Kopie (Heft)

`NotebookRepository.prepareRestore(from:)` (`:30-56`):
- `BoundedFile.copy` nach `BackupStaging/<id>/input.notybackup`;
- streamend prüfen;
- Assets nach `BackupStaging/<id>/Assets/<sha>` herausschreiben. Die Namen stammen ausschließlich aus geprüften Hashes, niemals aus Archivpfaden.
- Danach validiert die UI. `PreparedRestore` speichert `LibraryArchiveFileInfo` statt der CRC über Daten im Speicher (`BackupArchive.swift:228-234`).

`commitRestore` (`:69-82`):
- Größe und CRC des Stagings erneut prüfen, die SHA der Staging-Assets prüfen;
- `RevisionStore(directory: Restores/<neu>).save(copy, importingAssetsFrom: staging)`; unter APFS ist `copyItem` ein Klon;
- frisch zurücklesen und vergleichen, danach das Staging entfernen.
- Neue Dokument-ID und der Titelzusatz bleiben (`restoredCopy`).
- Neuer Eingang `IncomingBackup.swift:67` und `LibraryModel.swift:430` über denselben streamenden Weg.

### 8.5 Restore der Bibliothek

`WorkspaceStore.prepareRestore` und `commitStage` (`WorkspaceStore.swift:169-266`):
- Prepare-Durchlauf: Assets nach `Staging/<id>/AssetScratch/` herausschreiben, Apple-Prüfung je Asset.
- Commit: Größe und CRC des Stagings prüfen, SHA der Scratch-Dateien prüfen; zweiter Durchlauf über die Heft-JSONs:
  - `LibraryStore.populatePackage(document, root:, assetsFrom: scratch)` (`LibraryStore.swift:235-244`) klont die Assets zuerst in `Data/Library/Documents/<id>/Assets/`, dann folgen Revision und Manifest;
  - der Fingerprint-Vergleich bleibt (`LibraryArchive.fingerprint`, `:198-201`);
  - der Index zuletzt, danach veröffentlichen.
- Platzbedarf in der Spitze: Archiv plus Scratch; die Klone kosten unter APFS nichts.

### 8.6 Rand-Restore

Die Semantik bleibt (`restorePage`, `PageOperations.swift:253-256`): Snapshot und verdrängter Stand liegen im Seitenpapierkorb. `independentCopy` vergibt neue Objekt-IDs, **teilt aber die Asset-Referenz**. Keine Asset-Arbeit, nur Tests.

---

## 9. Was sich je Funktion ändert

- **Seite duplizieren, kopieren/einfügen, Randsnapshot, „Seite leeren“** (`PageOperations.swift:190-197`, `PageTransfer.swift:10-53`): neue Seiten- und Objekt-IDs wie bisher, gleicher Hash, keine zusätzlichen Bytes, zählt nicht gegen 500 MB. `copiedPage` bleibt im selben Heft (`EditorModel.swift:417-432`).
- **Heft duplizieren** (`LibraryStore.duplicateDocument`, `:298-313`): neues Paket über `writePackage(_:in:assetsFrom:)` (`:315-326`); die Assets werden geklont und per SHA verifiziert, danach zurücklesen. Das Original bleibt unberührt.
- **Seitenpapierkorb:** Referenzen über `deletedPages` sind GC-Wurzeln über die Revision. Endgültiges Löschen gibt den Platz verzögert frei (Abschnitt 7).
- **Bibliothekspapierkorb und Purge** (`LibraryStore.swift:423-469`): unverändert, das Paket wird samt `Assets/` entfernt.
- **Lokale Historie / Öffnen als Kopie** (`NotebookRepository.prepareLocalRecovery`, `:39-42`): kein Umweg mehr über `BackupArchive.encode`. Dokument aus der Revision; Assets aus dem eigenen Paket, wo sie als Wurzel garantiert noch liegen; dann `commitRestore` wie 8.4.
- **Revisionen:** klein (außer bei PDFs), Manifestformat 1 unverändert, `RevisionStore.maximumBytes = 200 MB` bleibt für das JSON.
- **Vorschau** (`LibraryModel.swift:221, 237-248`; `LibraryStore.previewDocument`, `:181-183`): liefert `(Notebook, NotebookAssets)` schreibgeschützt; `PageThumbnailCache.render(_:source:assets:)`.
- **PDF-Export:**
  - aus dem Editor über die Repository-Assets;
  - aus der Bibliothek (`LibraryView.swift:642`) über schreibgeschützte Assets;
  - `PDFExporter.swift:72` prüft Maße und SHA, ein defektes Original bricht wie bisher ab.
- **Suche:** Fingerprint über den Hash (`ContentSearchIndex.swift:210`); die Bild-OCR liest über die Assets.
- **Undo:** billige Vergleiche; die Kosten sind entkoppelt (4.2).

---

## 10. Python-Prüfer und Host-Roundtrip

**`scripts/notebook_format.py`**
- `range(1, 13)` (Zeile 268).
- `_images` (`:233-262`):
  - Schema ≥ 12: `asset` ist ein Dict mit `sha256`-Regex und `byteCount` von 1 bis 20e6, `data` ist verboten;
  - Konsistenz bei gleichem Hash; eindeutige Summe ≤ 500e6;
  - Schema 5–11 unverändert, `asset` verboten.
- `validate_notebook` gibt `refs = {sha: byteCount}` zurück. Die Konstanten in `:18-19` werden aufgeteilt (`LEGACY_IMAGES_TOTAL_LIMIT`, `IMAGES_TOTAL_LIMIT = 500_000_000`).

**`verify_backup.py`**
- Pfad v1 unverändert.
- Pfad v2: Datensatzstrom; `hashlib.sha256` und Länge je Asset in 1-MB-Blöcken; Menge = Referenzen; Abschlussdatensatz; kein Anhang; ≤ 800 MB.
- `--compare` bleibt. Ausgabe zusätzlich `assets`, `assetBytes`.

**`verify_library_backup.py`**
- v1 und v2; Gruppenregeln aus 8.3; nur ein Heft-JSON gleichzeitig im Speicher; Ausgabe `assets`, `sharedAssets`.

**`verify_device_store.py`** (`read_records` `:41-76`, `load_store` `:145-183`)
- je Paket `Assets/` als echtes Verzeichnis;
- Namen `^[0-9a-f]{64}$` oder `.partial-<UUID>` (als Rest gezählt);
- jede Referenz jeder geprüften Revision vorhanden, Größe und SHA richtig, mit Cache je Datei;
- unreferenzierte Assets und Teildateien werden gezählt, nicht als Fehler gewertet; keine Inhalte ausgeben;
- `--compare` prüft zusätzlich, dass die Assets früherer Dokumente noch vorhanden sind.

**`check_verifiers.sh`** (Generator plus `accept`/`reject`, auch unter `-O`): neue Fixtures für Schema 12, Paket mit `Assets/`, Archive v2 und weiterhin akzeptierte v1-Archive. Negativfälle:
- Schema 12 mit `data`; Schema 11 mit `asset`; Großbuchstaben bzw. 63 Zeichen bzw. `../` im Hash;
- Asset über 20 MB (nur deklariert); deklarierte eindeutige Summe über 500 MB (26 × 20 MB deklariert, ohne echte Bytes);
- gleicher Hash mit anderen Pixelmaßen;
- Archiv: fehlendes, zusätzliches oder doppeltes Asset, SHA-Abweichung, Asset vor jedem Heft, Asset nicht vom vorangehenden Heft referenziert, fehlender Abschlussdatensatz, Anhang, Version 3;
- Gerätespeicher: Referenz fehlt, Größe falsch, Inhalt gekippt, Symlink in `Assets/`.

**Host-Roundtrip** (`check_page_workflow.sh`, `PageWorkflowCheck.swift`)
- Erwartung Schema 12 statt 11 (`:69`); Bild über `store.assets.stage` (`:72-76`).
- Prüft:
  - duplizierte Seite mit Bild → genau eine Datei `Assets/<sha>`;
  - `originalImageBytesUnchanged` gegen die Asset-Datei (`:145`);
  - Heft- und Bibliotheksbackup v2 (`:94-112`), Restore-Paket mit Assets;
  - zusätzlich ein Altpaket mit Schema 11 und eingebettetem Bild (handgeschriebenes JSON): öffnen, nichts geschrieben; bearbeiten → exakte Altbytes unter `Migrations/`;
  - `corrupt.notybackup` kippt ein Byte im Asset-Bereich;
  - `verify_device_store.py` über `Source` mit `Assets/`.

---

## 11. Teststrategie (Core, XCTest)

- **`SHA256Tests`:** FIPS-Vektoren (`""` → `e3b0c442…`, `"abc"` → `ba7816bf…`, 448-Bit-Nachricht → `248d6a61…`, eine Million „a“ → `cdc76e5c…`); streamende Aufteilung an Blockgrenzen (55, 56, 63, 64, 65 Bytes).
- **`ImageAssetStoreTests`:**
  - Schreiben über Teildatei, fsync, Prüfung, Umbenennen;
  - Ziel existiert (gleich bzw. defekt → Reparatur);
  - Symlink als `Assets/` bzw. als Asset wird abgelehnt;
  - Pending-Obergrenze;
  - schreibgeschützte Instanz schreibt nie.
- **`ImageAssetMigrationTests`** (Vorbild `testFirstSchemaElevenCommitArchivesExactConfirmedOldBytes`, `PaperWritingSpaceTests.swift:167`):
  - bloßes Öffnen ändert nichts (Verzeichnisinventar gleich), unveränderter Flush ohne Commit;
  - erste Änderung → `notebook-v11.json` mit exakten Bytes, Assets identisch zu den eingebetteten Bytes, zwei gleiche eingebettete Bilder → ein Asset;
  - Sicherung scheitert (`Migrations` als Datei) → kein Commit, Altstand lesbar; Wiederholung nutzt dasselbe Archiv;
  - Schema 13 gesperrt; gemischte Formen ungültig; Undo nach Migration senkt nicht.
- **`ImageAssetCommitRecoveryTests`:**
  - `commitFault` je Stufe mit „Absturzabbild“ (Paketverzeichnis am Haken kopieren, frischen Store auf der Kopie laden) → immer der letzte bestätigte Stand;
  - `Assets/` als Datei → Save wirft, Neuladen ergibt den Altstand, Wiederholung gelingt;
  - fehlendes Asset → Rückfall bzw. `noCompleteRevision`, nichts gelöscht;
  - wiederholte Fehlschläge vermehren die Dateien nicht.
- **`ImageAssetGarbageCollectionTests`:**
  - Asset nur referenziert von: Checkpoint, vorigem Manifest, Seitenpapierkorb, Quarantäne-Revision, unlesbarer Revision (Rohsuche), Migrationsdatei mit Schema 12 → bleibt;
  - unreferenziert und alt → weg; jung → bleibt;
  - Teildatei alt bzw. jung; fremde Namen, Verzeichnisse und Symlinks unberührt;
  - Lesefehler bricht ab; Backup-Sperre;
  - Undo nach Löschen und vielen Commits in derselben Sitzung findet sein Asset.
- **`BackupArchiveV2Tests` / `LibraryArchiveV2Tests`:**
  - Roundtrip;
  - großes Verhalten mit absenkbaren Grenzen (wie `LibraryArchiveLimits`, `:52-59`) und kleiner Blockgröße;
  - alle Negativfälle aus Abschnitt 10;
  - v1-Archive mit eingebetteten Bildern stellen sich als Kopie mit Assets wieder her;
  - geteiltes Asset zweier Hefte genau einmal, Restore legt es in beide Pakete;
  - Original unverändert, Restore mit neuer ID.
- **Bestehende Tests anpassen:** `RevisionStoreTests`, `LocalHistoryTests` (Kopie eines Checkpoints, dessen Bild im aktuellen Stand gelöscht ist), `LibraryStoreTests` (Duplikat: Assets vorhanden; Löschen in der Kopie berührt das Original nicht), `PageTrashPurgeTests`, `MarginRestoreTests`, `ImageImportPolicyTests` (5 MB beim Import, 20 MB gespeichert gültig, eindeutige Summe), `PageUndoTests`, `ContentSearchIndexTests`.
- **Messung** (nicht eingecheckt): Host-Lauf mit synthetischen 500 MB (Zufallsbytes als Assets; Core dekodiert nicht). Commitzeit vorher/nachher, Archivzeit, Spitzenspeicher (`/usr/bin/time -v`).

---

## 12. Umsetzungsreihenfolge (jeder Commit für sich prüfbar)

1. **C1 – SHA-256 und `ImageAssetReference`** (nur Core). Prüfung: `swift test --filter SHA256Tests`.
2. **C2 – `NotebookAssets`** (Schreibprotokoll, Präsenzprüfung, Rohsuche, GC-Primitive), isoliert getestet, noch nicht eingebunden. Prüfung: Core-Tests.
3. **C3 – Container-Refactor:** die Streaming-Maschinerie aus `LibraryArchive` in `RecordArchive` herausziehen, **ohne Formatänderung**. Prüfung: Core-Tests unverändert grün, Host-Roundtrip.
4. **C4 – Umleitung in der App:**
   - jeder Bytezugriff über `ImageAssetProviding`, ImageIO aus `CGImageSource` (Datei oder Daten), Cache-Schlüssel über den Inhalt;
   - der Resolver liefert vorerst `object.data`; Fingerprint der Suche über einen berechneten Hash;
   - kein Formatwechsel.
   Prüfung: iPad-SDK-Build, Core-Tests.
5. **C5 – Archive v2:**
   - Heft- und Bibliotheksbackup als Datensatzstrom, Export über Dateien, streamender Import und Restore, v1 bleibt lesbar;
   - bei Schema ≤ 11 sind die Asset-Listen leer;
   - Python-Prüfer v2 plus Negativtests.
   Prüfung: Core-Tests, Host-Roundtrip, `check_verifiers.sh`, SDK-Build.
6. **C6 – Schema 12** (der eigentliche Formatwechsel; Swift und Python gemeinsam, wie AGENTS verlangt):
   - `ImageObject.asset`, `NotebookDecoding`, Limits;
   - `RevisionStore` (Assets zuerst, Laden mit Präsenzprüfung, `lastStoredSchema`);
   - Staging in Repository und Import;
   - Asset-Kopien bei Duplikat, Restore, Bibliotheksrestore und lokaler Historie; Archive tragen Assets;
   - `notebook_format.py` und `verify_device_store.py`; `PageWorkflowCheck` mit Altpaket.
   Prüfung: alles plus SDK-Build. **Nicht installieren** vor C7.
7. **C7 – Asset-GC** (Öffnen/Schließen, Backup-Sperre) plus Absturz- und GC-Testmatrix, optional Checkpoint-Budget mit Assets. Der Prüfer meldet unreferenzierte Assets und Teildateien.
8. **C8 – Feinschliff und Nachweise:**
   - Prüfung beim Öffnen nur noch Präsenz statt Dekodierung, Meldungstexte 500 MB;
   - Messung mit 500 MB;
   - Dokumente: STORAGE (Schema 12, Assets, GC), IMAGES, BACKUPS (Format 2), LIBRARY-BACKUP (Format 2), ARCHITECTURE, TESTING, README, CHANGELOG.
9. **Geräteupdate** nach AGENTS:
   - vorher vollständige Sicherung unter `/home/la/Backups/<Zeitstempel>/`;
   - gebündelter Test:
     - Alt-Heft mit Bildern öffnen, bearbeiten, Neustart;
     - zwei 5-MB-Bilder ziehen (kein Ruckeln?), Seite duplizieren, Papierkorb endgültig leeren;
     - Heft- und Bibliotheksbackup exportieren, am PC mit den Prüfern kontrollieren, extern zurückspielen und als Kopie bearbeiten;
     - PDF-Export mit HEIC;
     - großes Heft (etwa 300–500 MB) öffnen und Zeit messen.

---

## 13. Risiken, Entscheidungen, Aufwand

### Risiken

- **Reines Swift-SHA-256:** In Release etwa 0,1 s je 20 MB, in Debug-Tests deutlich langsamer; die Tests nutzen kleine Daten. Bei Bedarf injiziert die App CryptoKit über ein Hasher-Protokoll.
- **Heben im Speicher beim Laden:** Die Vergleiche „unverändert, also kein Commit“ und `lastStoredSchema` müssen exakt stimmen, sonst entsteht ein ungewollter Commit beim Öffnen. Gezielte Tests.
- **Fehlendes Asset sperrt das ganze Heft** (Rückfall bzw. Lesefehler). So festgelegt in Entscheidung 2.
- **Ältere Builds:** Schema-12-Hefte und v2-Archive sind dort gesperrt bzw. abgelehnt. Kein Downgrade-Weg.
- **Platzbedarf:**
  - gelöschte Bilder bleiben bis zum Durchrotieren der Historie und dem nächsten Öffnen oder Schließen;
  - Bibliotheksrestore braucht zeitweise Archiv plus Scratch;
  - auf Nicht-APFS-Pfaden (Linux-Tests) wird echt kopiert.
- **Externe Backups werden groß:** WebDAV-Server-Limits, Upload-Dauer, Grenze von 4 GB.
- **PDF-Quellen bleiben eingebettet (≤ 100 MB):** Revisionen und Heftblöcke bleiben bei PDF-lastigen Heften groß. Der Store ist bewusst generisch gehalten, damit PDFs später folgen können.
- **Die Rohsuche setzt voraus, dass Encoder Hex-Strings nicht escapen.** Test über die Ausgaben von `JSONEncoder` und Python.
- **Wettlauf zwischen Backup und GC beim Schließen:** durch das Sperr-Flag abgedeckt; Backup-Lesen bleibt bei der bestehenden Strategie „drei frische Versuche“.

### Entscheidungen (20.10.2026)

1. Das Bibliotheksarchiv bleibt bei höchstens 4 GB.
2. Fehlende oder defekte Assets werden behandelt wie heute: Rückfall auf ältere Revision bzw. Sperre, nichts wird gelöscht. Kein schreibgeschützter Platzhaltermodus.
3. PDF-Quellen bleiben eingebettet; das Asset-Konzept kann sie später übernehmen, jetzt nicht.
4. Verzögerte Freigabe nach endgültigem Löschen ist akzeptiert und wird dokumentiert.
5. Duplikate zählen für die 500-MB-Grenze nicht doppelt.

### Aufwand (grob)

| Schritt | Personentage |
|---|---|
| C1 | 0,5 |
| C2 | 1–1,5 |
| C3 | 0,5–1 |
| C4 | 1 |
| C5 | 2–3 |
| C6 | 3–4 |
| C7 | 1,5–2 |
| C8 | 1–2 |
| **Summe** | **etwa 11–15** |

Dazu kommt ein gebündelter Gerätetest. Der größte Unsicherheitsposten ist C6, wegen der vielen Kopierwege und der Migrationsgleichheit.

Hinweis: Während der Untersuchung kamen auf dem Branch die Commits „Build 53“ und „Bilder über Seiten ziehen“ hinzu. Die Zeilenangaben für `ImageObjectLayer.swift` und `SelectionTransfer.swift` beziehen sich auf diesen neuen Stand; die Speicher- und Archivdateien haben sich dabei nicht geändert.

---

## Umsetzungsnotizen

### C1 (SHA-256, `ImageAssetReference`)

- `SHA256` liegt wie geplant in `SHA256.swift`; `ImageAssetReference` bereits in `ImageAssets.swift` (dort kommen in C2 die übrigen Asset-Typen hinzu). Dateien, die zusätzlich CryptoKit importieren, müssen `NotebookCore.SHA256` schreiben (Namensgleichheit).
- `ImageAssetReference.isValid` prüft Hash-Regex und 1 … `ImageLimits.maximumFileBytes`. Das synthetisierte `Codable` validiert nicht; die Prüfung beim Dekodieren gehört zu C6.

### C2 (`NotebookAssets`)

- `init(directory:readOnly:)` erwartet den `Assets`-Ordner selbst; `init(package:readOnly:)` hängt `Assets` an. Die GC-Wurzeln übergibt der Aufrufer (`garbageRoots(inPackage:)` liefert die vier Ordner aus Abschnitt 7).
- Neuer Fehlertyp `ImageAssetError` (`invalidReference`, `missing`, `damaged`, `pendingFull`, `readOnly`, `invalidDirectory`, `garbageCollectionAborted`) mit deutschen Meldungen.
- `persist` prüft vorhandene Ziele mit passender Größe nur per `stat`, außer die Bytes liegen in diesem Pending-Bereich: dann einmal je Sitzung streamender SHA-Vergleich. So kostet ein Autosave kein erneutes Hashen von bis zu 500 MB. „Nachweislich falsch“ heißt: andere Größe oder SHA-Abweichung (auch über `verifiedPayload` festgestellt). Repariert wird nur mit einer bereits verifizierten Teildatei derselben Adresse (`replaceItemAt`). Falsche Größe ohne verfügbare Bytes wirft `damaged` und lässt die Datei unverändert.
- Ein Ziel, das während des Schreibens auftaucht, wird nie überschrieben (`moveItem` scheitert); passt seine Größe, gilt das Asset als geschrieben, sonst wirft `persist`.
- Bezugsquelle der Bytes: zuerst der eigene Pending-Bereich, dann `from:`. Eine Quelle mit falschen Bytes scheitert an der Rücklese-Prüfung (`damaged`); die eigene Teildatei wird bei jedem Fehler entfernt, wiederholte Fehlschläge hinterlassen keine Dateien.
- `stage` ist auch auf schreibgeschützten Instanzen erlaubt (nur Speicher, z. B. eingebettete Altbilder einer Vorschau). `persist` und `collectGarbage` werfen dort `readOnly`, ohne etwas anzulegen. `stage` prüft die Größe vor dem Hashen.
- `verifiedPayload` markiert eine SHA-Abweichung für die Sitzung als defekt; `payload` und `presentOnDisk` behandeln solche Assets danach als nicht vorhanden. Lesefehler gelten nicht als Beweis. Nichts wird beim Lesen gelöscht oder umgeschrieben.
- GC-Alter: Abstand zur jüngsten verfügbaren Dateizeit (Inhalt, Attribute/ctime, Erstellung), Referenzzeit über `clock`. Dadurch gelten frisch geklonte oder kopierte Assets mit alter Inhaltszeit trotzdem als jung. Fehlt jede Zeit, bleibt die Datei.
- Rohsuche: Symlinks und Sonderdateien unter den Wurzeln werden nicht verfolgt (der Store liest ohnehin keine Revision über Symlinks). Eine Wurzel, die existiert, aber kein echtes Verzeichnis ist (Datei, auch hängender Symlink), bricht den Lauf ab, ebenso jeder Listen- oder Lesefehler und mehr als 64 Verzeichnisebenen. Teildateien werden nur mit exakt dem geschriebenen Namen (`<sha>.partial-<UUID in Großbuchstaben>`) entfernt.

### C3 (`RecordArchive`, ohne Formatänderung)

- `RecordArchive.swift` enthält jetzt: Präfix-Helfer (Magic + uint32 BE, `lengthBytes`, `length(prefix:)`), `RecordArchiveSink`/`RecordArchiveSource` mit `DataSink`, `FileSink`, `DataSource`, `FileSource` (bisher `private` in `LibraryArchive.swift`, jetzt modulintern), `ChecksummedReader` (Datei-CRC beim Lesen), `drained`, sowie unverändert aus `BackupArchive.swift` verschoben `StreamingCRC32`, `LibraryArchiveFileInfo` und `BoundedFile`. Die alten Protokollnamen bleiben als `typealias LibraryArchiveSink`/`LibraryArchiveSource`; bestehende Tests sind unverändert.
- Ein zu kurzer Quellstrom wirft jetzt das interne `RecordArchiveTruncated`; `LibraryArchive.read` bildet es wie zuvor auf `LibraryArchiveError.invalid` ab. `BackupArchive` nutzt dieselben Präfix-Helfer (gleiche Bytes).
- **Bytegleichheit:** Encoder ohne `.sortedKeys` (Manifest des Bibliotheksarchivs, das ganze `.notybackup` v1) schreiben Schlüssel in `Dictionary`-Reihenfolge, die Swift je Prozess zufällig seedet. Schon vor C3 sind diese Bytes also zwischen zwei Läufen nicht gleich (bei `.notybackup` kann sogar die Länge um die CRC-Ziffern schwanken); lesbar und gültig sind sie immer. `RecordArchiveCompatibilityTests` enthält deshalb Golden-Archive, die der Code vor C3 (Stand `efd8ace`) mit `SWIFT_DETERMINISTIC_HASHING=1` geschrieben hat (von `verify_library_backup.py` und `verify_backup.py` akzeptiert). Jeder Lauf prüft Lesbarkeit, gleiche Längen und Offsets, bytegleiche sortierte Blöcke (Index, Werkzeuge, Hefte) sowie JSON-gleiche Köpfe und Nutzlasten, auch über den streamenden Dateiweg. Den exakten Bytevergleich führt `testExactBytesUnderDeterministicHashing` nur unter `SWIFT_DETERMINISTIC_HASHING=1` aus (sonst übersprungen). Unter dieser Variable ist er nach C3 grün.
- Hinweis für C5: Kopf und Deskriptoren von v2 mit `.sortedKeys` kodieren, damit Archive reproduzierbar sind.

### C4 (Umleitung in der App, Format unverändert)

- **`ImageObject.asset`** ist bis C6 ein berechneter Wert: SHA-256 der eingebetteten Bytes, einmal je Wert berechnet und über einen geteilten Zwischenspeicher (`ImageAssetCache`, nicht kodiert, nicht verglichen) an alle Kopien weitergegeben (`data` ist unveränderlich). `cachedAsset` liest ihn ohne zu hashen. C6 ersetzt das durch das gespeicherte Feld gleichen Namens; die Aufrufstellen bleiben.
- **Resolver ohne Registry (Abweichung):** Die `ImageRendering`-Funktionen haben den Parameter `assets: ImageAssetProviding? = nil`; `nil` bedeutet die eigenen eingebetteten Bytes des Objekts (`InlineImageAssets(images: [object])`). `ImageAssetRegistry` entsteht erst in C6, weil es vorher nichts zu registrieren gibt. Hintergrundwege (PDF-Export, Seitenvorschau, Such-OCR, Backupprüfung) nehmen den Parameter bereits entgegen; der PDF-Export baut seinen Provider außerhalb des Main Actors.
- **Neue Core-Typen:** `InlineImageAssets` (Bytes im Speicher nach Inhaltsadresse; in C6 auch für `inlineImageBytes` alter Hefte), `ChainedImageAssets` (erster Treffer, nachgewiesene Beschädigung vor bloßem Fehlen), `Notebook.allImages`. `ImageAssetProviding` hat zusätzlich `verifiedPayload(for:)` mit Standardimplementierung `payload(for:)`; `NotebookAssets` erfüllt es mit seiner SHA-Prüfung.
- **ImageIO** liest über `CGImageSourceCreateWithURL` bzw. `…WithData`. Renditionen sind nach `sha256-limit` zwischengespeichert, `Entry.bytes`/`sameBytes` entfallen, Duplikate teilen sich Renditionen. `cached`/`anyCached` hashen nie; `prepare` berechnet eine noch unbekannte Inhaltsadresse im Hintergrund. `ImageImport.object` berechnet sie beim Einfügen ebenfalls im Hintergrund.
- **Prüfung** (`EditorModelValidation.validateContent`, `BackupValidation`): je Original (Hash plus Pixelmaße) einmal ImageIO, über `verifiedPayload`; Quelle zuerst die eingebetteten Bytes, dann der übergebene Provider.
- **Suche:** Fingerprint über `image.asset.sha256`. Der abgeleitete Index berechnet die Bild-OCR-Ebene deshalb einmal neu.
- **CryptoKit (Zusatz):** Die App installiert beim Start `SHA256.installAccelerated` mit CryptoKit für Einmal-Digests von Daten im Speicher, also Inhaltsadressen und `stage`. Core übernimmt eine Implementierung nur, wenn sie die FIPS-Vektoren und Blockgrenzen-Längen exakt reproduziert. Streamende Prüfungen (Dateien, Archive) bleiben beim portablen Swift-SHA. Grund: `xtool dev build` baut standardmäßig Debug, dort ist das portable SHA langsam, und C4 hasht eingebettete Originale einmal je Sitzung.

### C5 (Archivformat 2)

- **Format wie umgesetzt** (`RecordArchive.swift`, `RecordDescriptor`): Kopf und Deskriptoren mit sortierten Schlüsseln und exakt festgelegten Schlüsselmengen; Swift und Python lehnen fehlende und zusätzliche Felder ab. Datensätze `index`/`toolbar`: `kind, byteCount, crc32`; `notebook`: zusätzlich `id`; `asset`: `kind, sha256, byteCount`; `end`: `kind, records, payloadBytes`. `records` zählt die Datensätze vor `end`, `payloadBytes` deren Nutzlast. Kopf `.notybackup`: `backupFormatVersion: 2, checksumAlgorithm, assetHashAlgorithm: "sha256", documentID, notebookSchemaVersion, createdAt`. Kopf `.notylibrary`: `libraryBackupVersion: 2, checksumAlgorithm, assetHashAlgorithm, createdAt`. Gleiche Magic wie Format 1, die Version steht im Kopf. Auch das Heft-JSON im Einzelbackup ist jetzt sortiert kodiert; gleiche Werte ergeben gleiche Bytes (Test).
- **Reihenfolge der Assets (Präzisierung):** Der Schreiber gibt die Assets in der Reihenfolge ihres ersten Auftretens aus (aktive Seiten, dann Papierkorb). Die Leser verlangen innerhalb der Regeln aus 8.2/8.3 aber nur die Menge, keine Reihenfolge.
- **Bibliothek:** `visit` bzw. die Apple-Prüfung sieht ein Heft erst, wenn seine Gruppe vollständig ist. So stehen der Prüfung die Assets der Gruppe schon zur Verfügung.
- **Asset-Listen:** `Notebook.externalImageAssets` ist bei Schema ≤ 11 leer. Tests hängen über die interne Naht `ExternalAssetSeam` synthetische Verweise an Hefte, damit Schreiben, Prüfen, Staging und Restore mit Assets ohne Formatwechsel laufen. Der Host-Roundtrip nutzt sie auch: Swift schreibt Asset-Datensätze, Python prüft sie unabhängig.
- **Schreiben:** Asset-Bytes werden in 4-MB-Blöcken gestreamt und dabei gehasht (`payload`, kein zweites Lesen über `verifiedPayload`). Eine Abweichung bricht ab und entfernt die Datei: Einzelheft mit `ImageAssetError.damaged`, Bibliothek mit dem neuen `LibraryArchiveError.damagedImage(Titel)`. Danach folgt wie bisher ein vollständiges streamendes Rücklesen mit SHA je Asset.
- **Lesen:** drei Modi. `verify` (SHA, Bytes verworfen); `extract` (geprüft nach `<Verzeichnis>/<sha>`, über `<sha>.partial-<UUID>`, fsync, Umbenennen; nie überschreiben); `skip` (nur Größe). `skip` dient nur für zweite Durchläufe, deren Datei-Größe und -CRC mit einem geprüften ersten Durchlauf verglichen werden.
- **Heft-Restore:**
  - Die Datei wird blockweise nach `BackupStaging/<id>/input.notybackup` kopiert, dann streamend geprüft; die Assets landen in `BackupStaging/<id>/Assets/`.
  - `PreparedRestore` hält `LibraryArchiveFileInfo`, die Asset-Liste und schreibgeschützte `assets` für die UI-Prüfung.
  - Eine gescheiterte Vorbereitung entfernt ihr Stage und ein leeres `BackupStaging/`.
  - `commitRestore` prüft das Staging erneut: ein Durchlauf mit `skip` (Größe und CRC der Datei, Heft neu dekodiert), dann SHA jedes gestagten Assets. Danach Assets zuerst über `NotebookAssets.persist`, dann wie bisher Revision und Manifest, frisch zurücklesen inklusive `presentOnDisk`. Erst dann wird das Stage entfernt.
  - Die Reihenfolge „Assets zuerst“ übernimmt in C5 der Aufrufer, `RevisionStore` bleibt unverändert. C6 verlegt sie in `save(_:importingAssetsFrom:)`.
- **Lokale Historie (Abweichung von Abschnitt 9):** Weiterhin der Weg über ein Archiv. `prepareLocalRecovery` schreibt ein v2-Archiv in das Stage (Assets aus dem eigenen Paket) und nimmt dann denselben Prüfweg wie ein Import. Grund: eine einzige Staging-Prüfung für alle Kopien. Der Preis ist eine zusätzliche Kopie der Assets; sie lässt sich nach Messung in C8 abkürzen.
- **Bibliotheks-Restore:** Die Vorbereitung extrahiert nach `Staging/<id>/AssetScratch/`. Der Commit vergleicht wie bisher Größe und CRC und macht dann einen zweiten Durchlauf mit `skip`: SHA jedes Scratch-Assets, dann `populatePackage(_:root:assetsFrom:)` (Assets zuerst). Der frische Store prüft zusätzlich `presentOnDisk`. Der Scratch wird vor dem Veröffentlichen entfernt und gehört nicht zum Bereich.
- **`NotebookAssets` (Änderung an C2):** Teildateien aus Dateiquellen (Paket, Stage) entstehen über `copyItem`, unter APFS ein Klon, und werden danach wie geschriebene Bytes synchronisiert und per SHA geprüft.
- **Grenzen:**
  - `.notybackup` Format 2: Datei ≤ 800 MB (`BackupArchive.maximumFileBytes`, neuer Fehler `fileTooLarge`), Heft-JSON ≤ 200 MB.
  - Format 1 und Prototyp-JSON weiter im Speicher ≤ 200 MB.
  - Bibliothek ≤ 4 GB; Kopf ≤ 64 KB, Deskriptor ≤ 4 KB, Asset ≤ 20 MB (`ImageLimits.maximumFileBytes`, unverändert).
- **Format-1-Schreiber** bleiben intern (`BackupArchive.encodeVersion1`, `LibraryArchive.encodeVersion1`/`writeVersion1`) für Fixtures und Kompatibilitätstests; die App schreibt nur Format 2. Unter `SWIFT_DETERMINISTIC_HASHING=1` sind die Golden-Archive weiter bytegleich.
- **App:**
  - `EditorModel.backupFile()` schreibt nach `BackupScratch` (`tmp/NotyBackupArchives`). `ExportFile(backupFile:)` übergibt die Datei per `FileWrapper(url:)`, die Scratch-Datei wird nach dem Dialog entfernt. `ExportFile` liest nicht mehr (`init(configuration:)` wirft).
  - „In noty öffnen“ kopiert Heft-Backups bis 800 MB und prüft streamend.
  - Die Prüf-Callbacks heißen `(Notebook, ImageAssetProviding)`; eingebettete Bytes werden zuerst gefragt.
- **Ältere Builds** (≤ 53 und Stände vor C5) lehnen Archive des Formats 2 als „Backupformat 2 …“ bzw. „Bibliotheksbackup 2 benötigt eine neuere noty-Version“ ab. Einen Rückweg gibt es nicht.
- **Python:**
  - Neues gemeinsames `scripts/record_archive.py`. `verify_backup.py` und `verify_library_backup.py` lesen Format 1 und 2; die Ausgabe enthält zusätzlich `formatVersion`, `assets`, `assetBytes`, bei der Bibliothek auch `sharedAssets`.
  - `VerificationError` ist jetzt ein `ValueError`; die Fehlerausgabe nennt den Typ.
  - `validate_notebook` gibt `{sha256: byteCount}` zurück, bis C6 leer.
  - `check_verifiers.sh` enthält v2-Fixtures, ein v1-Bibliotheksarchiv und die Archiv-Negativfälle aus Abschnitt 10, soweit ohne Schema 12 möglich. Dazu kommt ein Harness, der `validate_notebook` mit synthetischen Verweisen ersetzt (fehlend, doppelt, SHA, fremde Gruppe, zu spät, geteiltes Asset), auch unter `-O`.
  - Offen für C6: die Negativfälle, die Schema 12 brauchen (`data`/`asset` gemischt, Hash-Format im Heft, Summe über 500 MB, gleicher Hash mit anderen Maßen), und die Gerätespeicher-Fälle.

### C6 (Schema 12)

- **Format wie geplant:** `ImageObject.asset` ist das gespeicherte Feld, `data` gibt es im Modell nicht mehr. `init(from:)` liest über einen Kontext in `JSONDecoder.userInfo` (`NotebookDecodingContext`) bei gespeichertem Schema ≤ 11 `data` (Pflicht, `asset` verboten), sonst `asset` (Pflicht, `data` verboten). Ohne Kontext gilt die aktuelle Form. Kodiert wird nur `asset`; es gibt keinen Weg zurück zu `data`. `Notebook.currentSchemaVersion = 12`, `Notebook.imageAssetSchemaVersion = 12`.
- **`NotebookDecoding.decode`** ist der einzige Leser gespeicherter Bytes (Revisionen, Prototypdateien, beide Archive). Ergebnis `DecodedNotebook {notebook, storedSchemaVersion, inlineImageBytes}` plus `storedExternalAssets` (Referenzen, die nicht eingebettet sind: was Paket oder Archiv tragen müssen). Ablauf: Header prüfen (≥ 13 → `unsupportedSchema`), dekodieren, bei Schema ≤ 11 Altregeln (je ≤ 20 MB vor dem Hashen, Summe je Objekt ≤ 40 MB) und `validate(legacyImages: true)` unter dem gespeicherten Schema, danach mit Bildern auf 12 heben und erneut `validate()`. Hefte ohne Bilder behalten ihr Schema. `Notebook.decode` bleibt die Bequemlichkeitsfunktion und verwirft die eingebetteten Bytes.
- **Zusatz:** Byte-gleiche eingebettete Duplikate (duplizierte Seiten) werden per Vergleich statt erneutem Hashen erkannt.
- **Validierung:** Nicht leere `images` verlangen im Speicher Schema ≥ 12; eindeutige Summe ≤ 500 MB über aktive Seiten und Papierkorb; gleicher Hash ⇒ gleiche Größe und Pixelmaße (`Notebook.validateImageAssets`). `raiseSchemaForImageAssets()` hebt in `replaceImages`, `replaceContent` und `replaceContents`; Undo, Seitenkopien und Restore-Kopien nehmen `max`.
- **Limits:** `ImageLimits.maximumImportBytes = 5_000_000` (von `ImageCompression.importTargetBytes` benutzt), `maximumFileBytes = 20_000_000` je gespeichertem Asset, `maximumNotebookBytes = 500_000_000` (eindeutig), `legacyMaximumNotebookBytes = 40_000_000` nur für gespeichertes Schema ≤ 11. `uniqueImageAssetBytes` ersetzt `imageOriginalBytes`. `imageInsertionProblem(adding:pageID:)`: ein schon vorhandener Hash kostet 0 Bytes und ist nie „zu groß“; nur neue Originale unterliegen der 5-MB-Grenze. Undo-Kosten: 128 B je Bildobjekt statt der Originalgröße.
- **RevisionStore:** `assets` (die schreibbare Instanz des Pakets), `init(directory:readOnly:)`, `save(_:importingAssetsFrom:)`, `commitFault` mit `.assetsWritten`, `.revisionWritten`, `.checkpointsWritten`, `.previousWritten`. Reihenfolge: Migrationssicherung (Bedingung `(lastStoredSchema ?? old.schemaVersion) < document.schemaVersion`) → `assets.persist(Referenzen ∪ Pending, from: Quelle)` → Revision → `checkpoints.json` → `manifest-previous.json` → `manifest.json`. Danach `lastStoredSchema = document.schemaVersion` und `dropPending` genau der vorher geschriebenen Pending-Einträge (gleichzeitig gestagte bleiben). Laden: `presentOnDisk(storedExternalAssets)` je Kandidat, sonst Rückfall wie bei CRC-Fehlern, nichts gelöscht; eingebettete Altbytes kommen erst nach der Auswahl in den Pending-Bereich (ein voller Pending-Bereich ist ein Fehler, nie ein Grund für einen Rückfall). `localRevision(id:)` liefert `DecodedNotebook`.
- **Abweichung `readOnly`:** Lesewege (Vorschau, Suche, Bibliotheksbackup, Duplikatquelle, Restore-Katalog, Rücklesen) öffnen `RevisionStore(directory:readOnly: true)`; `save` wirft dort `ImageAssetError.readOnly`. Grund: Lesewege legen eingebettete Altbytes in den Pending-Bereich und dürfen nie schreiben.
- **Restore und Kopien:** `commitRestore`, `populatePackage(_:root:assetsFrom:)`, `writePackage(_:in:assetsFrom:)` (Duplizieren) gehen alle über `save(_:importingAssetsFrom:)`; danach frisch zurücklesen inklusive `presentOnDisk`. `commitRestore` prüft die SHA aller vom Heft referenzierten Staging-Assets, nicht nur der Archiv-Datensätze. `duplicateDocument` liest die Quelle schreibgeschützt und kopiert deren Assets (bei einem nicht migrierten Altheft die eingebetteten Bytes aus dem Pending-Bereich der Lese-Instanz); das Original bleibt unberührt (Test über das Dateiinventar).
- **Abweichung Extraktion:** Im `extract`-Modus schreiben beide Archivleser auch die eingebetteten Originale eines Schema-≤-11-Hefts (Format 1, Prototyp-JSON, Format-2-Datensatz aus C5) als `<sha256>` in das Zielverzeichnis. Grund: Heft- und Bibliotheksrestore haben danach genau einen Prüfweg (Staging-Dateien per SHA), jede Restore-Kopie wird ein Schema-12-Paket mit Assets.
- **Abweichung Format 1:** Format-1-Archive (und Prototyp-JSON) können keine Assets tragen; ein Heft mit nicht eingebetteten Referenzen darin wird abgelehnt (Swift und Python). Die Format-1-Schreiber nehmen deshalb für Fixtures die exakten Heftbytes (`BackupArchive.encodeVersion1(payload:)`, `LibraryArchive.writeVersion1(…, chunk:)`); `RecordArchiveCompatibilityTests` prüft das byte-genaue Framing mit den Golden-Chunks und liest das Golden-Heft (Schema 5 mit Bild) als Schema 12 mit `inlineImageBytes`.
- **Format 2:** Der Kopf nennt das gespeicherte Schema (`storedSchemaVersion`, Plan 8.2). Erwartete Asset-Datensätze sind `storedExternalAssets`; ein Schema-11-Datensatz aus C5 trägt also keine. `visit` bekommt eingebettete Bytes vor den extrahierten Assets (`ChainedImageAssets`).
- **Bibliotheksbackup bei fehlendem Asset:** Die neueste Revision gilt als unvollständig; das Backup nimmt wie bei jeder beschädigten Revision den neuesten vollständigen älteren Stand und meldet ihn über `olderState` (Test angepasst, vorher `damagedImage`). Ein beschädigtes Asset gleicher Größe bricht weiterhin mit `damagedImage(Titel)` ab.
- **Lokale Historie:** `prepareLocalRecovery` schreibt das Archiv aus `ChainedImageAssets([eingebettete Bytes der Revision, store.assets])`; eine Revision von vor der Migration lässt sich damit auch öffnen, wenn ihr Original im Paket fehlt (Test).
- **Backup:** `NotebookRepository.backup` liest aus `store.assets` (Dateien plus Pending).
- **App:**
  - `ImageAssetRegistry.shared` (schwache Referenzen, neueste Registrierung zuerst) ist der Standard-Provider von `ImageRendering`, `PDFExporter`, `PageThumbnailCache`, Such-OCR und `EditorModelValidation`. Der Editor registriert `NotebookRepository.assets` (neu: `nonisolated let`) beim Start und prüft beim Öffnen gegen diese Instanz. Bibliotheksvorschau, Bibliotheks-PDF-Export und Suche in geschlossenen Heften übergeben die schreibgeschützten Assets ihres Pakets (`LibraryStore.previewPackage(id:)`).
  - **Import (Abweichung zur Reihenfolge):** Hash berechnen → `imageInsertionProblem(adding:)` → Objekt bauen → letzte Seitenprüfung → `assets.stage` → `updateImages`. Grund: ein abgelehntes Bild landet nie im Pending-Bereich und damit nie als Waise auf der Platte. `pendingFull` erscheint als Meldung („Bitte erst erfolgreich speichern“).
  - **Zusatz Einfügen aus einem anderen Heft:** Die Objekt-Zwischenablage (`ObjectClipboard`) ist prozessweit. Damit ein Einfügen in ein anderes Heft dort kein fehlendes Asset hinterlässt (jeder spätere Commit würde scheitern), staget `EditorModel.adoptImageAssets` vor `updateImages`/`updateContent`/`replaceContents` jedes noch unbekannte Original aus der Registry (SHA-geprüft) in das Zielheft; nicht verfügbar → die Änderung wird mit Meldung abgelehnt. Beim Kopieren hält `pinClipboard` die Asset-Instanzen der Quelle am Leben. Bekannte Hashes kosten keinen Dateizugriff (Ziehen bleibt billig).
  - Meldungstexte: `ImageImportError.notebookFull` (500 MB, Mehrfachverwendung zählt einmal), Bildänderung im Editor (500 MB), `RevisionError.snapshotTooLarge` (Bildoriginale zählen nicht mit).
- **Python:** `notebook_format.py` kennt Schema 12 (`asset` Pflicht, `data` verboten; ≤ 11 umgekehrt; Hash-Regex; 1 … 20 MB; Konsistenz; eindeutige Summe ≤ 500 MB; Altsumme ≤ 40 MB) und gibt `{sha256: byteCount}` zurück. `verify_backup.py`/`verify_library_backup.py` lehnen Referenzen in Format 1 ab. `verify_device_store.py`: `Assets/` echtes Verzeichnis ohne Symlinks, jede Referenz jeder geprüften Revision vorhanden, Größe und SHA (1-MB-Blöcke), Zählung `assets`, `unreferenced_assets`, `partial_asset_files`, `foreign_asset_entries`; `--compare` prüft die Assets der früheren Dokumente. `check_verifiers.sh`: Harness entfernt, echte Schema-12-Hefte für alle Archivregeln, dazu die offenen Negativfälle (data/asset gemischt in beide Richtungen, Hash groß/63/Pfad, > 20 MB, > 500 MB, gleicher Hash mit anderen Maßen oder anderer Größe, Schema 13, Format 1 mit Referenzen, Gerätespeicher: fehlend, Größe, gekippt, Symlink als Asset, `Assets/` als Symlink), jeweils mit Prüfung, dass die Heftregel selbst ablehnt.
- **Host-Roundtrip:** Bild über `revisionStore.assets.stage`; geprüft werden genau eine Datei `Assets/<sha>` trotz duplizierter, kopierter und gelöschter Seiten, Heft- und Bibliotheksbackup mit echtem Asset-Datensatz, Format 1 als Schema-11-Bytes (`current-v11.json`), `corrupt.notybackup` mit gekipptem Byte im Asset, Restore-Kopien mit Assets (`verify_device_store.py` über `RestoreCheck`) und ein handgeschriebenes Schema-11-Paket mit eingebettetem Bild: Öffnen samt unverändertem Speichern ändert kein Byte, die erste Bearbeitung legt die exakten Altbytes unter `Migrations/<UUID>/notebook-v11.json` ab und schreibt Asset und Schema-12-Revision.
- **Tests:** `ImageAssetMigrationTests` (7), `ImageAssetCommitRecoveryTests` (5), neue Fälle in `ArchiveFormat2Tests` (Format 1/2/JSON mit eingebetteten Bildern als Kopie mit Assets, Bibliothek Format 1), `LibraryStoreTests` (Duplikat mit Assets, Altheft-Duplikat), `LocalHistoryTests` (Schema-11-Revision als Kopie), `PageTrashPurgeTests` (endgültiges Löschen lässt die Datei bis C7). Testhelfer `ImageObject.test(bytes:)`, `ImageAssetReference.declared`, `LegacyNotebookJSON` (nur Tests schreiben die Altform).
- **Nicht installiert, kein Gerätetest.** Ohne Asset-GC (C7) bleiben gelöschte Bilder und Waisen gescheiterter Commits liegen; deshalb erst nach C7 installieren.
