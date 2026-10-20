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
