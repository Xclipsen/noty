# Noty

Native, deutschsprachige iPad-Notiz-App für persönliche Schulunterlagen. Kernfunktionen offline; Text bleibt auf festen Seiten. Verbindlicher Produktumfang: [SCOPE](docs/SCOPE.md), Abnahme: [ACCEPTANCE](docs/ACCEPTANCE.md), Bedienungsentscheidungen: [DESIGN](docs/DESIGN.md).

README, PLAN und TESTING enthalten auch überholte historische Aussagen. Relevante Nachweise mit aktuellem Code und Tests abgleichen; Scope-Anforderungen nicht als implementiert ausgeben.

## Umgebung und Befehle

Aus dem Projektroot; `env.sh` in jeder neuen Shell aktivieren (lokale Swift-/xtool-Pfade und Linux-Kompatibilitätsbibliotheken):

```bash
cd /home/la/workspace/noty
. ./scripts/env.sh
swift --version
xtool --version
xtool sdk status

swift test --package-path Core
bash scripts/check_page_workflow.sh
xtool dev build
```

Prüfungen nach Änderung auswählen. Einzelne XCTest-Klassen: `swift test --package-path Core --filter Klassenname`. Der Host-Roundtrip erzeugt isolierte Daten unter `.tools/`. Root-Package und `Core/Package.swift` sind getrennt: Linux-Tests in Core, iPad-Build über xtool.

xtool-Build/Signierung in PTY/Terminal ausführen: dokumentierter Non-TTY-/SwiftNIO-Abbruch. Bei Toolchainproblemen [ENVIRONMENT](docs/ENVIRONMENT.md), installierte `--help` und offizielle xtool-Dokumentation prüfen; SDK/Tools nicht auf Verdacht neu installieren. Xcode läuft nicht unter Linux. Bei neuen APIs Deploymenttarget in `Package.swift`, SDK und Gerät berücksichtigen.

## Welche Änderung braucht welche Prüfung?

| Änderung | Zuerst lesen / prüfen | Passende Verifikation |
| --- | --- | --- |
| Datenmodell, Migration, Speichern, Seitenoperationen | [STORAGE](docs/STORAGE.md), [ARCHITECTURE](docs/ARCHITECTURE.md), betroffene Core-Tests | Core-Tests; bei Format-/Archiv-/Layeränderung zusätzlich Host-Roundtrip |
| Bibliothek, Bereiche, Backup/Restore, App-Abgleich | [LIBRARY](docs/LIBRARY.md), [BACKUPS](docs/BACKUPS.md), [LIBRARY-BACKUP](docs/LIBRARY-BACKUP.md), [APP-SYNC](docs/APP-SYNC.md) | Core-Tests und Host-Roundtrip; echte Archive unabhängig prüfen |
| Editor, Gesten, Fokus, Undo, Werkzeugleiste, Tastatur | DESIGN, ARCHITECTURE, [KEYBOARD](docs/KEYBOARD.md); je nach Inhalt [TEXT-FIELDS](docs/TEXT-FIELDS.md) / [IMAGES](docs/IMAGES.md) | iPad-Build; betroffene Eingabe-/Fokus-/Neustartfälle gebündelt am Gerät |
| PDF, Koordinaten, Ränder, Rendering | `PageGeometry.swift`, `PagePresentation.swift`, gemeinsame Text-/Bildrenderer | Geometrie-/Seiten-/Objekttests, iPad-Build; tatsächliches Geräte-PDF mit `pdfinfo`, `pdftoppm`, `pdftotext` prüfen |
| Fehlerberichte, Messpunkte, Diagnose-Server | [DIAGNOSE](docs/DIAGNOSE.md); Format in Swift, `diagnostics/server.py`, `scripts/diag_report.py` und die gemeinsame Vorlage `diagnostics/fixtures/reports-v1-kinds.json` gemeinsam ändern | Core `DiagnosticTests`, `python3 -B -m unittest diagnostics/test_server.py scripts/test_diag_report.py`, iPad-Build; Gerätetest nach TESTING |
| Nur Dokumentation/Agent-Anweisungen | Aussagen gegen betroffene Quellen, Befehls-Hilfe und Links prüfen | Kein App-Build allein wegen Textänderungen |

Archivprüfer: `python3 -B scripts/verify_backup.py ARCHIV --compare REVISION.json`, `python3 -B scripts/verify_library_backup.py ARCHIV`. Für Geräteabzüge: `python3 -B scripts/verify_device_store.py BEREICHSROOT --compare VORHER_ROOT`. Letzterer erwartet `Documents/Noty` bzw. jeden `NotyWorkspaces/Areas/*/Data`-Root separat; bloßes `Documents` kann sonst irreführend null Hefte melden.

## Fehlerberichte auslesen

Meldet der Nutzer, dass etwas hängt, ruckelt, langsam ist oder abgestürzt ist, zuerst die Berichte vom eigenen Server lesen ([DIAGNOSE](docs/DIAGNOSE.md)):

```bash
sudo python3 -B scripts/diag_report.py                 # Gruppen der letzten 14 Tage
sudo python3 -B scripts/diag_report.py --since 24h --channel dev --kind appHang
sudo python3 -B scripts/diag_report.py --show ID       # ein Bericht vollständig; --json maschinenlesbar
```

- Als root, weitere Filter `--build`, `--kind`, `--all` (mit Tageswerten und Tests). Gruppen, Muster, letzte Schritte und symbolisierte Frames lesen, dann im passenden Branch beheben.
- Funktionsnamen gibt es nur für Builds, die mit dem aktuellen `publish_ota.sh` veröffentlicht wurden (Binärdatei unter `.tools/diag-binaries`); keine Datei-/Zeilennummern.
- Berichte enthalten keine Heftinhalte. Ablage (`/var/lib/noty-diagnostics`), Schlüssel und `.tools/ota.env` nie committen oder in Doku zitieren.

## Daten und Architekturgrenzen

- Bei Core-Änderungen: `Core/Sources/NotebookCore` plattformunabhängig halten; Apple-Frameworks liegen in `Sources/Noty`. UI-/PencilKit-Daten auf dem UI-Actor erfassen; große Serialisierung/I/O nicht in den Stiftpfad legen.
- Bei Speicheränderungen: keinen konkurrierenden Writer für denselben Paketroot einführen. Neuere Revisionen dürfen nicht durch ältere Autosaves ersetzt werden. Der bestehende Commit schreibt unveränderliche vollständige Revisionen und ersetzt das Manifest zuletzt; einzeln atomare Dateien ersetzen diese Konsistenz nicht. „Gespeichert“ erst nach Commit; Fehler erhalten gültigen Altstand und ungesicherte Änderungen. Recovery-, Reihenfolge- und Schreibfehlertests heranziehen.
- Bei Formatänderungen: exakte bestätigte Altbytes vor dem neuen Commit sichern; Migrationsfehler müssen den Commit verhindern. Aktive Seiten, Papierkorb und Legacy-Positionen berücksichtigen; andere Bearbeitungswege dürfen das Schema nicht wieder herabsetzen. Unbekannte neuere Formate sperren, statt auf ältere Daten zurückzufallen oder leere Hefte anzulegen. Swift-Validierung, unabhängigen Pythonprüfer und relevante Archiv-/Migrationstests gemeinsam anpassen.
- Bei Seiten-/Objektoperationen: stabile IDs statt Positionen referenzieren; duplizierte Seiten erhalten neue Seiten-/Objekt-IDs, Restorekopien eine getrennte Dokumentidentität. PDF-/Bildoriginale und editierbare PencilKit-Daten erhalten; Importquellen vollständig lokal kopieren. Temporäre Dateianbieterpfade sind kein Speicherformat, Vorschauen nur abgeleitete Daten. Neue Layer auch in Papierkorb, Revisionen, Backups, Vorschau und PDF berücksichtigen.
- Bei Geometrieänderungen: gemeinsame Transformation für Editor, Save, Vorschau und Export nutzen; CropBox, Rotation, gemischte Größen und Legacy-A4 beachten. Kanonische Inhaltskoordinaten enthalten keinen Bildschirmzoom; linke/obere Ränder erlauben negative Werte. PDF nicht zur Randergänzung skalieren. Beim PDF-Export alle Ebenen ausdrücklich zusammensetzen, Quell-PDF und Text soweit möglich durchsuchbar erhalten. Überlauf oder gefährdete Inhalte nie still abschneiden. Details: STORAGE und Layerdokumente.
- Bei UI-Änderungen: bestehende Canvas-/UITextView-Instanzen bei normalen SwiftUI-/Autosaveupdates erhalten; späte Callbacks/Undo dürfen nach Seiten-/Restorewechsel keinen fremden Stand verändern. PencilKit bleibt die native Ink-Grundlage, die Werkzeugleiste ist app-eigen. Eingabeprobleme mit [BUG-18](docs/BUG-18-TEXT-INPUT.md), Vorschau-/Layoutprobleme mit [BUG-13](docs/BUG-13-PREVIEW.md) abgleichen. Beim PhotosPicker den expliziten `_PhotosUI_SwiftUI`-Import nur nach erfolgreichem SDK-Build entfernen: dokumentierter Linux-Overlay-Fallstrick.
- Bei Backupänderungen: Autosave, lokale Historie, vollständiges editierbares Backup und PDF-Export getrennt halten. Größen, Versionen, Identitäten, Prüfsummen und sichere Pfade prüfen; CRC ist kein Manipulationsschutz. Restore erst separat validieren, vor Veröffentlichung Staging erneut prüfen, bestehende Notizen standardmäßig als Kopie erhalten. Rand-Restore hat bewusst andere Semantik: bestehende passende Seite zurücksetzen, aktuellen Stand vorher im Seitenpapierkorb sichern (STORAGE). Bibliotheksbackup umfasst auch Papierkorb, Ordner und Präferenzen. Kein Cloud-Upload-/Sync-Erfolg aus lokalem Schreiben ableiten.

## GitHub

`origin` ist das **öffentliche** Repo `github.com/Xclipsen/noty`; es soll immer `main` spiegeln. Lokale Hooks (`post-commit`, `post-merge`, `post-rewrite` → `.git/hooks/noty-autopush`) pushen jeden neuen Stand von `main` im Hintergrund, Protokoll in `.git/autopush.log`; andere Branches bleiben lokal. Nach Merges prüfen: `git rev-list --count origin/main..main` muss 0 sein, sonst manuell pushen. Wegen Öffentlichkeit nie private Hefte, Gerätesicherungen, UDIDs, Zugangsdaten oder `.tools/`-Artefakte committen.

## Branches und Apps

| Branch | Worktree | App | Regel |
| --- | --- | --- | --- |
| `main` | `/home/la/workspace/noty` | **noty** (`de.la.noty.prototype`, echte Hefte) | Nur freigegebene Stände aus `dev`, per `git merge --no-ff dev`, nachdem der Nutzer den Stand in noty dev getestet und ausdrücklich freigegeben hat. Spiegelt GitHub. Jede Installation bekommt das Tag `stable/build-N`. |
| `dev` | `/home/la/workspace/noty-dev` | **noty dev** (`de.la.noty.dev`, eigene Daten) | Alles, was in die nächste normale Version soll. Hier wird gearbeitet. |
| `exp/<name>` | eigener Worktree, z. B. `noty-ki` für `exp/ki` | **noty AI** (`de.la.noty.ai`, eigene Daten, `NOTY_CHANNEL=ai`); noty dev nur auf ausdrücklichen Wunsch | Experimente wie der KI-Assistent. Nehmen `dev` regelmäßig auf (`git merge dev`), gehen nur nach Entscheidung des Nutzers nach `dev`. `exp/ki` trägt zusätzlich `bridge/`, von dem der Dienst `noty-ai` läuft. |
| `feat/<name>` | eigener Worktree | noty dev | Größere Einzelthemen, von `dev` abgezweigt, nach dem Merge in `dev` gelöscht. |
| `dev` oder `feat/<name>` | wie oben | **noty calendar** (`de.la.noty.calendar`, grünes Icon, eigene Daten) | Test-App für Kalenderarbeit (der Kalender ist seit 08.11.2026 in `main`): `NOTY_CHANNEL=calendar bash scripts/publish_ota.sh`, Installationsseite `…-calendar`. Push, Schultag-Kachel und Widget haben **noty und noty calendar**; meldet dasselbe WebUntis-Konto in beiden Push an, kommt jede Änderung doppelt. |

- Abgleich zwischen den Apps ([APP-SYNC](docs/APP-SYNC.md)): noty legt nur einen Abzug in der App Group ab und übernimmt nie etwas; noty dev und noty AI spiegeln ihn als eigenen Bereich. Diese Einbahnstraße nicht aufweichen.
- `scripts/publish_ota.sh` setzt das durch: noty AI nur von `exp/*`; noty dev nur von `dev`, `exp/*` oder `feat/*` und nur committet (`NOTY_ALLOW_DIRTY=1` als bewusste Ausnahme); die normale noty nur von `main`, sauber und mit `NOTY_STABLE_CONFIRMED=1`, nachdem der Nutzer zugestimmt und vorher ein Bibliotheksbackup bzw. eine Sicherung gemacht hat. Die Installationsseite nennt Branch und Commit.
- Buildnummern (`CFBundleVersion`) zählen über beide Apps durchgehend hoch; das Skript lehnt eine Nummer ab, die nicht größer als die zuletzt veröffentlichte ist.
- Ablauf einer Änderung: in `dev` (oder `feat/*`) bauen und testen → noty dev → Nutzer prüft → auf Wunsch `main` + normale noty. Ohne ausdrückliche Freigabe nichts auf `main` oder die normale noty.
- Nicht mehr gebrauchte Branches nach dem Merge löschen; vorher prüfen, dass sie enthalten sind (`git merge-base --is-ancestor`).

## Geräteupdates und Nachweise

- Bei einem autorisierten Update: Basis-ID in `xtool.yml`, Signierungsidentität und App-Container erhalten. Bewährter Weg: `xtool dev build --sign --ipa`, dann `xtool install --usb xtool/Noty.ipa`. Nicht ungeprüft auf `xtool dev run` wechseln: Build und Installation präfixieren die ID hier zweimal; ein anderer Weg kann einen anderen Container erzeugen. IPA-ID und installierte ID prüfen (ENVIRONMENT). App nicht deinstallieren; Zertifikatswiderruf oder Entfernen anderer Apps nur mit ausdrücklichem Auftrag.
- Vor Update vollständige App-Documents unter `/home/la/Backups/<eindeutiger-Zeitstempel>/` sichern; nachher frisch zurücklesen und Heftinhalte vergleichen. AFC benötigt die tatsächliche installierte App-ID; remote `/Documents` sichern. Für destruktive Tests isolierte Bereiche/Kopien benutzen, keine zusätzliche App-ID nötig. Gerät entsperrt und noty geschlossen halten; bei fehlendem USB-Gerät oder hängender Installation erst Zustand prüfen. 100 % oder Exitcode 0 allein sind kein Installationsbeleg. Profilablauf und Personal-Team-Limits in ENVIRONMENT beachten; Apple-Anmeldung/2FA/Vertrauen/Entwicklermodus übernimmt der Nutzer.
- Ergebnisse immer als **implementiert**, **erfolgreich gebaut**, **installiert** und **auf dem iPad getestet** unterscheiden. Core-Tests beweisen weder PDFKit/PencilKit-Ausführung noch Gesten/Schreibgefühl; Swift-Syntaxprüfung ist kein SDK-Build, Installation kein Laufzeittest. Fehlendes Developer-Disk-Image kann automatischen Start verhindern; manuellen Start nicht mit fehlgeschlagenem Build verwechseln.
- Gerätetests nach Daten-/Bedienungsrisiko auswählen und bündeln, kleine Varianten nicht ständig wiederholen. Übersprungenes ausdrücklich **ungeprüft** lassen; Nutzerbestätigung und eigene Artefaktprüfung getrennt nennen. Nach funktionalen Änderungen README und betroffene PLAN-/ARCHITECTURE-/TESTING-Abschnitte mit tatsächlichen Nachweisen aktualisieren; keine pauschale Produktionsreife behaupten.
