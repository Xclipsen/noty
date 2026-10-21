# Verifikation

Aktuelle Prüfwege und Nachweise ab Build 47/48. Der vollständige frühere Verlauf (Phase 0 bis Build 46, Gerätechecks, Exportartefakte, Installationsbelege) liegt unverändert im [Archiv](history/TESTING-ARCHIV.md). Ergebnisse immer als **implementiert**, **erfolgreich gebaut**, **installiert** und **auf dem iPad getestet** trennen.

## Prüfungen auf diesem Rechner

```bash
cd /home/la/workspace/noty
. ./scripts/env.sh
swift test --package-path Core                      # Core-Tests (Linux, XCTest)
swift test --package-path Core --filter Klassenname # einzelne Testklasse
bash scripts/check_page_workflow.sh                 # Host-Roundtrip unter .tools/
bash scripts/check_verifiers.sh                     # Negativtests der Python-Prüfer (auch im Roundtrip)
script -qec "xtool dev build" .tools/build.log      # unsignierter iPad-Build mit SDK
```

- **Core-Tests** prüfen Datenmodell, Revisionen, Migration, Archive, Geometrie, Textfluss und Backup-Regeln mit echten Dateisystemfehlern in temporären Verzeichnissen. Sie führen weder PDFKit noch PencilKit, Vision oder UIKit aus. Testklassen heißen seit Build 47 nach ihrer Funktion statt nach Build-Nummern (`git log -p 78a60c9` zeigt die Umbenennung).
- **Host-Roundtrip** erzeugt ein Heft und eine Bibliothek, exportiert, prüft unabhängig mit `verify_backup.py`/`verify_library_backup.py` und weist beschädigte `.notybackup`/`.notylibrary` zurück. Die Prüfer verwenden keine `assert`-Anweisungen und wirken deshalb auch unter `python3 -O`.
- **`xtool dev build`** ist die Typprüfung gegen das iPad-SDK. Eine reine Swift-Syntaxprüfung ersetzt ihn nicht. Gesten, Schreibgefühl und Laufzeitverhalten belegt nur das Gerät.

Archivprüfer einzeln: `python3 -B scripts/verify_backup.py ARCHIV --compare REVISION.json`, `python3 -B scripts/verify_library_backup.py ARCHIV`. Geräteabzüge: `python3 -B scripts/verify_device_store.py BEREICHSROOT --compare VORHER_ROOT` je Root (`Documents/Noty` und jedes `NotyWorkspaces/Areas/*/Data`), nicht für `Documents` insgesamt.

## Update auf das iPad

Apple-Anmeldung, 2FA, Vertrauen und Entwicklermodus übernimmt der Nutzer (`xtool auth` im eigenen Terminal). Identität und Profil: [ENVIRONMENT](ENVIRONMENT.md).

1. `xtool dev build --sign --ipa` in einer PTY (`script -qec "…" LOG`). IPA prüfen: Bundle-ID `XTL-BAFXLQ964V.de.la.noty.prototype`, Team `BAFXLQ964V`, gleiches Zertifikat wie zuvor, erwarteter `CFBundleVersion`.
2. iPad entsperrt, noty geschlossen (`idevicesyslog pidlist | grep -i noty` leer). Läuft noty, nicht installieren.
3. Vollständige App-`/Documents` per AFC mit der installierten ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype` nach `/home/la/Backups/<eindeutiger Zeitstempel>/Documents/` sichern. Jeden Bereichsroot mit `verify_device_store.py` prüfen.
4. `xtool install --usb xtool/Noty.ipa` in einer PTY. Nicht deinstallieren, nicht auf `xtool dev run` wechseln. 100 % oder Exitcode 0 allein sind kein Beleg. Installierte Version per InstallationProxy lesen.
5. `/Documents` frisch zurücklesen und je Root mit `--compare` gegen den Vorher-Stand vergleichen.

Automatischer Start scheitert am fehlenden Developer-Disk-Image. Der Nutzer startet manuell.

## Bild-Assets (Schema 12) – Nachweise

Branch `feat/image-assets`, Schritte C1–C8 ([IMAGE-ASSETS](IMAGE-ASSETS.md)). **Implementiert und erfolgreich gebaut; nicht installiert, auf dem iPad ungeprüft.**

- **Core-Tests:** `swift test --package-path Core`: 625 Tests, 1 übersprungen (exakter Bytevergleich der Golden-Archive nur unter `SWIFT_DETERMINISTIC_HASHING=1`, dort grün), 0 Fehler; zweimal hintereinander. Neu für Schema 12 und Archivformat 2 u. a. `SHA256Tests`, `ImageAssetStoreTests`, `ImageAssetProviderTests`, `ImageAssetMigrationTests`, `ImageAssetCommitRecoveryTests`, `ImageAssetGarbageCollectionTests`, `ArchiveFormat2Tests`, `RecordArchiveCompatibilityTests`, `AcceleratedHashingTests`.
- **GC- und Absturzmatrix:** Asset nur von Checkpoint, vorigem Manifest, Seitenpapierkorb, Quarantäne, unlesbarer Revision, Migrationsdatei oder `Archives/` referenziert → bleibt; unreferenziert und alt → weg, jung → bleibt; Teildateien nach 1 h; fremde Einträge unberührt; Lesefehler bricht ohne Löschen ab; Backup- und Restore-Sperre vor und während des Laufs; nur der Writer, nur beim Öffnen vor dem ersten Commit bzw. beim Schließen mit bestätigtem Stand; Undo nach Löschen und zwölf Commits in derselben Sitzung findet sein Asset; Absturzabbilder nach jeder Commit-Stufe und während des Asset-Schreibens verlieren nie den bestätigten Stand.
- **Host-Roundtrip** (`bash scripts/check_page_workflow.sh`): Bild über den Asset-Bestand, genau eine Datei `Assets/<sha>` trotz duplizierter, kopierter und gelöschter Seiten; Heft- und Bibliotheksbackup im Format 2 mit echtem Asset-Datensatz, von Python unabhängig geprüft; Format 1 als Schema-11-Bytes; beschädigtes Asset im Archiv abgelehnt; Restore-Kopien mit Assets (`verify_device_store.py`); handgeschriebenes Schema-11-Paket: Öffnen samt unverändertem Speichern und Öffnungs-GC ändert kein Byte, die erste Bearbeitung legt die exakten Altbytes unter `Migrations/` ab, der Schließ-GC behält das migrierte Original. `check_verifiers.sh` mit allen Negativfällen aus Plan Abschnitt 10, auch unter `python3 -O`.
- **SDK-Build:** `script -q -e -c "xtool dev build" LOG` ohne Fehler und ohne Warnungen.
- **Messung** (Host, synthetisch, 500 MB): Werte und Grenzen in [IMAGE-ASSETS](IMAGE-ASSETS.md#c8-feinschliff). Kurz: kleiner Commit bei 500 MB Assets 0,07–0,14 s, Laden 0,15 s, Heftbackup schreiben und zurücklesen 8–10 s, Spitzenspeicher ≤ 163 MB; wiederholtes Laden eines nicht migrierten 52-MB-Althefts 0,12–0,14 s statt 1,2 s (`-O`). Am iPad nicht gemessen; dort übernimmt CryptoKit das Hashen.
- **Geräteprüfung nach einem Update** (noch offen, gebündelt): Sicherung wie oben; danach mit `verify_device_store.py --compare` gegen den Vorher-Stand (ohne Bearbeitung bleiben alle Hefte bytegleich, Althefte schreiben beim Öffnen nichts). Nach einer Bearbeitung meldet `--compare` für dieses Heft bewusst „A previous document changed“; dann ohne `--compare` prüfen (Assets vorhanden, Größe und SHA-256 richtig, unreferenzierte Assets und Teildateien gezählt). Am iPad: Altheft mit Bildern öffnen, bearbeiten, Neustart; zwei 5-MB-Bilder ziehen (Ruckeln?), Seite duplizieren, Papierkorb endgültig leeren, Heft schließen und wieder öffnen; Heft- und Bibliotheksbackup exportieren, am PC prüfen, als Kopie zurückspielen und bearbeiten; PDF-Export mit HEIC; ein großes Heft (etwa 300–500 MB) öffnen und die Zeit messen.

## Build 53 · Rückmeldung zu Build 52

**Implementiert** auf `ui/menu-polish`. Nutzer zu Build 52:
- Ruckeln beim Ziehen nach zwei 20-MB-Bildern: Neue Bilder werden beim Import auf höchstens 5 MB verkleinert. Die eigentliche Ursache, Bildbytes als Base64 in jeder vollständigen Revision, wird mit einem eigenen Asset-Format behoben (Schema 12, inzwischen auf `feat/image-assets` umgesetzt, siehe oben).
- Bilder ließen sich nicht über Seiten ziehen. Umgesetzt nach dem Lasso-Vorbild, siehe [IMAGES](IMAGES.md).
- Der Wunsch nach 500 MB pro Notizbuch kommt erst mit dem Asset-Format; bis dahin bleiben es 40 MB (Schema 12 erlaubt 500 MB, siehe oben).

Nachweise:
- `swift test --package-path Core`: 547 Tests, 0 Fehler. Host-Roundtrip mit Prüfer-Negativtests bestanden.
- **Erfolgreich gebaut:** `--sign --ipa` ohne Warnungen. IPA: `CFBundleVersion` 53, gleiche App-ID, Team und Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `6df603e7…`.
- **Installiert am 20.10.2026 um 22:39** über Build 52.
  - Sicherung unter `/home/la/Backups/noty-before-build53-2026-10-20T20-38-41-577854343Z/`.
  - Zurückgelesen: 14 Dokumente und 60 Dateien unverändert, 6 Dokumente laut `--compare` unverändert, keine Quarantäne.
- **Auf dem iPad ungeprüft.**

## Build 52 · Rückmeldung zu Build 51

**Implementiert** auf `ui/menu-polish`. Nutzer zu Build 51:
- Geschnittene Formen wurden zu einem sehr dünnen Strich. Behoben: Die Punktgröße wird an der gemessenen PencilKit-Breite ausgerichtet.
- Bilder über 20 MB sollen verkleinert importiert werden. Umgesetzt mit `ImageCompression`, siehe [IMAGES](IMAGES.md#ergänzung-nach-build-51--große-bilder-werden-verkleinert).
- Das Bild-Werkzeug soll zum noty-Stil passen. Umgesetzt: Optionszeile, Auswahlrahmen und Anfasser in Akzentfarbe, Aktionsleiste, Zuschneiden; siehe [DESIGN](DESIGN.md).

Nachweise:
- `swift test --package-path Core`: 543 Tests, 0 Fehler.
- **Erfolgreich gebaut:** `--sign --ipa` ohne Warnungen. IPA: `CFBundleVersion` 52, gleiche App-ID, Team und Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `ad609c8f…`.
- **Installiert am 20.10.2026 um 22:20** über Build 51 (danach meldet InstallationProxy 52).
  - Sicherung unter `/home/la/Backups/noty-before-build52-2026-10-20T20-20-21-279539027Z/`.
  - Frisch zurückgelesen: 14 Dokumente und 60 Dateien unverändert. `--compare` meldet 6 unveränderte Dokumente, keine Quarantäne.
- **Auf dem iPad ungeprüft:** alle drei Änderungen; Foto-Import und PDF-Export aus Build 51 weiterhin ohne Rückmeldung.

## Build 51 · Rückmeldung zu Build 50

**Implementiert** auf `ui/menu-polish` (66f3c90, auf Build 50). Nutzertest von Build 50:
- Am iPad bestätigt: Werkzeugleiste, Schnellmenü (scrollen, Start, 10 s), Formen mit dem Stift, Halten über den Rand, Schreibscrollen, PDF-Schreibplatz-Linien, „Seite anpassen“, Bibliothek.
- Offen gemeldet:
  - Foto-Import scheitert weiter (Systemmeldung zu `ImportedStillImage`).
  - Der Präzisionsradierer soll Formen nur teilweise radieren.
  - Wiederholen soll vor Rückgängig stehen, aber erst nach Scrollen sichtbar sein.
- Der PDF-Export (Bilder und Text) ist ohne Rückmeldung, also weiter ungeprüft.

Umgesetzt:
- Präzisionsradierer schneidet Formen ([DESIGN](DESIGN.md#präzisionsradierer-und-formen--20102026)).
- Foto-Import mit Rückfallwegen ([IMAGES](IMAGES.md#ergänzung-nach-build-50--foto-import-mit-rückfallwegen)).
- Schnellmenü-Reihenfolge angepasst.

Nachweise:
- `swift test --package-path Core`: 543 Tests, 0 Fehler, davon 6 neue in `ShapeEraseMaskTests`. Format unverändert.
- **Erfolgreich gebaut:** `xtool dev build` und `--sign --ipa` ohne Warnungen. IPA geprüft: `CFBundleVersion` 51, gleiche App-ID, Team und Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `cc4bf964…`.
- **Installiert am 20.10.2026 um 21:57** über Build 50 (danach meldet InstallationProxy 51).
  - Sicherung unter `/home/la/Backups/noty-before-build51-2026-10-20T19-57-17-975437957Z/`.
  - Frisch zurückgelesen: 14 Dokumente und 60 Dateien unverändert. `verify_device_store.py --compare` meldet 6 unveränderte Dokumente, keine Quarantäne.
- **Auf dem iPad ungeprüft:** Foto-Import, Formen schneiden, Wiederholen im Schnellmenü, PDF-Export.

## Build 50 · Rückmeldung zu Build 49

**Implementiert** auf `ui/menu-polish` und auf Basis von Build 49. Details in [DESIGN](DESIGN.md#rückmeldung-zu-build-49--20102026) (Werkzeugleiste, Schreibscrollen, PDF-Linien, „Seite anpassen“, Pencil-Schnellmenü) und [IMAGES](IMAGES.md) (HEIC und Live Photos, Bildleiste).

Weitere Änderungen:
- PDF-Export zeichnet Bilder und Text wieder (UIKit-Seitenrenderer, `Page.exportLayers`).
- Bibliothek: Zahnrad oben rechts, Bereiche entfernen. „Meine Bibliothek“, der geöffnete und der letzte Bereich bleiben immer erhalten (`WorkspaceRemoval`).
- Halten zum Begradigen über den Seitenrand: Linien und Pfeile werden an der Kante abgeschnitten, geschlossene Formen auf die Seite geschoben (`HeldShapeFitting`).
- Der Präzisionsradierer entfernt berührte Formen ganz, zusammen mit der Tinte in einem Undo-Schritt.
- Der Textmarker hat einen eigenen Halten-Schalter (`markerHoldStraighten`). Vorher hat sein Schalter auch die Formerkennung von Stift und Bleistift abgeschaltet.

Eine eindeutige Ursache für „Formen mit dem Stift gehen nicht mehr“ ist nicht gefunden: Der Halte-Code ist seit Build 46 gleich. Behoben sind nur die beiden passenden Auslöser, die Randablehnung und der gemeinsame Schalter. Notebook-Schema unverändert (11).

- `swift test --package-path Core`: 537 Tests, 0 Fehler. Host-Roundtrip mit Prüfer-Negativtests vor dem letzten Merge bestanden; der letzte Merge ändert kein Format.
- **Erfolgreich gebaut:** `xtool dev build --sign --ipa` ohne Warnungen. IPA geprüft: `CFBundleVersion` 50, `XTL-BAFXLQ964V.de.la.noty.prototype`, Team BAFXLQ964V, gleiches Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `417123c4…`.
- **Installiert am 20.10.2026 um 21:13** über Build 49. InstallationProxy meldet danach 50, die ID ist unverändert.
  - Sicherung unter `/home/la/Backups/noty-before-build50-2026-10-20T19-13-03-803036796Z/`.
  - Frisch zurückgelesen: 13 Dokumente und alle 56 Dateien unverändert, keine neuen Dateien. `verify_device_store.py --compare` meldet 5 unveränderte Dokumente in `Documents/Noty`, keine Quarantäne.
  - Ein erster Lauf brach vor der Installation an einem veralteten lokalen Prüfhelfer ab. Am Gerät wurde dabei nichts verändert.
- **Auf dem iPad ungeprüft.**

## Build 49 · Editor-Korrekturen

**Implementiert.** Sechs restliche Review-Funde im Editor (Commits 23102fb, e65ba49, d3d9c56, b866e35, 444a1b6 auf Build 48). Die Regel für das Zurücksetzen des Canvas steht als `EditorInteractionPolicy.canvasNeedsReset` in Core und hat einen eigenen Test. Den UIKit-Ablauf selbst prüft nur das Gerät.

- `swift test --package-path Core`: 496 Tests, 0 Fehler (`.tools/core-build49.log`). Host-Roundtrip mit Prüfer-Negativtests bestanden (`.tools/roundtrip-build49.log`).
- **Erfolgreich gebaut:** `xtool dev build --sign --ipa` ohne Warnungen (`.tools/build-build49.log`). IPA geprüft: `CFBundleVersion` 49, `XTL-BAFXLQ964V.de.la.noty.prototype`, Team BAFXLQ964V, gleiches Zertifikat wie Build 46/48 (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `66bf1889…`.
- **Installiert am 20.10.2026 um 16:11** über Build 48 (InstallationProxy danach: 49, ID unverändert `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`). Sicherung vorher: `/home/la/Backups/noty-before-build49-2026-10-20T14-10-51-566363586Z/`. Rücklesen danach: 3 Hefte, 26 Dateien unverändert, keine neuen Dateien. `verify_device_store.py --compare` meldet `previous_documents_unchanged: 3`, 1 Zwischenstand aus Build 48 erhalten, keine Quarantäne. Ein erster Lauf brach vor der Installation ab, weil das Audit-Hilfsskript den neuen Rückgabewert von `load_store` nicht kannte (Teilsicherung `…T14-10-10-808481660Z`, keine Installation).
- **Auf dem iPad ungeprüft.**

### Gerätetest Build 49

1. Tinte mit dem Lasso auswählen und über den Seitenrand ziehen. Währenddessen per Squeeze oder Doppeltipp das Werkzeug wechseln, dann einen Strich zeichnen. Die ausgewählten Striche bleiben an ihrem Platz, auch nach Schließen und erneutem Öffnen des Hefts. Dasselbe beim Ziehen innerhalb der Seite und beim Abbruch mit zwei Fingern.
2. Eine Form halten und kurz nach dem Abheben das Werkzeug wechseln: Die Freihandlinie darf nicht verschwinden.
3. Heft mit 5–10 großen Fotos zoomen und scrollen: kaum graues Aufblitzen, kein ständiges Neuladen.
4. Ein Bild unter ein anderes schieben: Das vordere bleibt vorne. Wieder wegziehen läuft flüssig.
5. Präzisionsradierer benutzen, danach mit dem Stift eine gehaltene Form zeichnen: Die Vorschau hat die richtige Breite.
6. Einen Werkzeugregler bewegen, sofort die App wechseln und die App beenden: Die Einstellung bleibt erhalten.

## Review-Überarbeitung (Build 47, ausgeliefert mit Build 48)

**Implementiert und erfolgreich gebaut.** Build 47 wurde nie separat installiert; der Stand ist vollständig in Build 48 (`ui/menu-polish`) enthalten. Umfang: [README](../README.md#aktueller-stand), Formatdetails in [STORAGE](STORAGE.md) und [LIBRARY-BACKUP](LIBRARY-BACKUP.md), Architektur in [ARCHITECTURE](ARCHITECTURE.md#build-47--review-überarbeitung).

Nachweise auf diesem Rechner (Stand `fix/review-2026-10` @ 39281fa, vor dem UI-Merge):

- `swift test --package-path Core`: 486 Tests, 0 Fehler. Neu u. a. Quarantäne nur nach Rückfall, Build-46-kompatibles Manifest, `checkpoints.json`, Schema 10 für Quellen über 20 MB, Migrationsarchiv-Wiederverwendung, Streaming-Bibliotheksarchiv, Backup-Status/Backoff, persistenter Suchindex, Textfluss ohne unnötiges Neumessen.
- Host-Roundtrip einschließlich beschädigtem `.notylibrary` und Prüfer-Negativtests bestanden.
- `xtool dev build` vollständig, 0 Warnungen.

Zusammen mit dem UI-Strang: 495 Core-Tests, Roundtrip und SDK-Build ohne Warnungen ([PAGE-ADJUST](PAGE-ADJUST.md#nachweise)). Installation von Build 48 und deren Belege: [UI-POLISH](UI-POLISH.md#stand-und-nachweise). **Auf dem iPad ungeprüft.**

### Gerätetest Review-Überarbeitung (nach Risiko gebündelt)

1. **Bestand:** alle Hefte öffnen. Lokale Historie eines oft bearbeiteten Hefts öffnen und einen älteren Stand als Kopie öffnen. Neue Änderung → „Lokal gespeichert“.
2. **Schreiben:** Stift, Marker, beide Radierer, Lasso über mehrere Seiten, schneller Seitenwechsel. Achten auf Ruckler, verlorene Striche, falsches Werkzeug nach Stift-Heben und Werkzeugwechsel. Autostift auf dunklen und hellen PDF-Seiten.
3. **Objekte:** Text-, Bild- und Formobjekte ziehen und skalieren, danach Undo/Redo. Mehrere große Bilder auf einer Seite, hinein- und herauszoomen: Bilder dürfen nicht dauerhaft grau bleiben.
4. **Undo und Tastatur:** Undo in Text-, Lese- und Lassomodus. Mit Hardwaretastatur ⌘N, ⌘F, ⌘S, ⌘E, ⇧⌘E, ⌘↑/⌘↓ und ⌘X/⌘D/⌘A/Pfeile bei Auswahl. ⌘↑/⌘↓ im Textfeld: Cursor oder Seitenwechsel?
5. **Pencil-Doppeltipp:** folgt der Systemeinstellung unter Einstellungen → Apple Pencil.
6. **Seitenleiste und Suche:** Vorschauen nach Bearbeitung aktualisiert. Suche zweimal ausführen (zweiter Lauf schneller). Treffer springt zur markierten Stelle.
7. **PDF:** Export des ganzen Hefts mit Fortschritt, einmal abbrechen. Export mit `pdfinfo`/`pdftoppm`/`pdftotext` prüfen. Import eines PDF über 20 MB.
8. **Seitenpapierkorb:** Seite löschen, wiederherstellen, endgültig löschen, Papierkorb leeren.
9. **Externes Backup:** Ordnerziel „Jetzt sichern“ und dabei weiterschreiben. Ziel entfernen bzw. offline → verständlicher Fehler ohne Wiederholschleife. `.notybackup`/`.notylibrary` aus der Dateien-App öffnen → Importdialog.
10. **Neustart:** während „Speichert …“ in den Hintergrund wechseln, App beenden, wieder öffnen: letzter bestätigter Stand vorhanden.

Ohne Gerätezugriff **ungeprüft** bleiben: automatische Speicher-Wiederholung nach Schreibfehler, Rückfall/Quarantäne auf dem Gerät, Speicherwarnung, Signierprofil-Hinweis 24 h vor Ablauf, WebDAV gegen einen echten Server.

## Offene Abnahme

Verbindliche Kriterien in [ACCEPTANCE](ACCEPTANCE.md). Weiterhin nicht durchgeführt: vollständiger externer Restore in einen leeren Bestand, 30 Minuten Mischbetrieb, 100-Seiten-Text-PDF und hochauflösender Scan, Platzmangel, Flugmodus, Probetag. Keine Latenz- oder FPS-Versprechen.
