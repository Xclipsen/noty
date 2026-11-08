# Plan: Einheitliche Fehler- und Ruckler-Diagnose (Baustein 1)

Stand: 08.11.2026. Nur geplant, nichts umgesetzt. Auslöser war der Absturz in Build 130/131: Den Bericht musste der Nutzer von Hand aus den Analyseprotokollen holen, und für Ruckler gab es keine einheitliche Quelle.

## Ziel

Abstürze, Hänger, Ruckler und auffällige Abbrüche aus noty dev, noty AI und noty calendar landen ohne Zutun des Nutzers einheitlich auf dem eigenen Server. Sie sind symbolisiert und nach Ursache gruppiert. Heftinhalte werden nie übertragen. Die normale noty sendet nichts automatisch.

## Bausteine

### D1 Format und Ereignisprotokoll (Core, Linux-testbar)
- `DiagnosticReport` (JSON, `formatVersion 1`): App-Kanal, Build, Commit, Gerät/iPadOS, Art (crash, hang, cpu, memory, disk, launch, appHang, saveFailure, launchGuard), Zeit, Signatur (oberste App-Frames), Aufrufkette, letzte Ereignisse, Startphase.
- `DiagnosticBreadcrumbs`: Ringpuffer mit etwa 200 Ereignissen, nur feste Ereignisnamen und Zahlen, z. B. „Heft geöffnet (Seiten 34)“, „Gesetzesfenster sichtbar“, „⌘L“, „Speichern 412 ms“, „Speichern fehlgeschlagen (Fehlercode)“. **Keine Titel, Texte, Pfade oder Gesetzesinhalte.** IDs nur gekürzt gehasht.
- Speicherung als kleine Datei pro Start, die letzten 5 Starts bleiben; Schreiben gebündelt, nie im Stiftpfad.
- Datenschutzprüfung als Core-Test: Bericht darf keine Strings aus Heftdaten enthalten.

### D2 Erfassung in der App
- **MetricKit** (`MXMetricManager`): Absturz-, Hänger-, CPU-, Speicher- und Schreibdiagnosen (`MXDiagnosticPayload`) mit Aufrufketten beim nächsten Start; tägliche Kennzahlen (Startzeit, Ruckel-/Hitch-Rate, eigene Signpost-Messungen).
- **Eigener Hänger-Wächter** aus `HangProbe`: Hauptthread hängt mehr als 250 ms → Ereignis mit Dauer, Startphase und letzten Ereignissen. Bei über 2 s zusätzlich Bericht beim nächsten Start.
- **Messpunkte** (`os_signpost` + Ereignis bei Überschreitung): Heft öffnen, Seite wechseln, Speichern/Commit, Strich abschließen, Gesetzesfenster öffnen, Gesetz laden, Suche, PDF-Export, Backup, App-Abgleich. Schwellen pro Messpunkt.
- Start-Absturzschutz (`LaunchGuard`), Speicherfehler und Restore-Fehler schreiben ebenfalls Ereignisse bzw. Berichte.
- Einstellungen › Diagnose: „Fehlerberichte automatisch senden“ (dev/AI/calendar standardmäßig an, normale noty aus und nur manuell), „Letzte Berichte“ (Liste mit Klartext-Zusammenfassung), „Diagnose teilen …“ (Datei über das Teilen-Menü).

### D3 Empfang auf dem eigenen Server
- Kleiner Dienst `noty-diagnostics` (Python-Standardbibliothek, systemd, nur `127.0.0.1`), über nginx unter einem nicht erratbaren Pfad der vorhandenen Domain.
- Annahme nur mit Build-Token aus `.tools/ota.env` (beim Veröffentlichen in die App geschrieben, nie im öffentlichen Repo), Größenlimit 1 MB, Ratenbegrenzung, Ablage `…/noty-diagnostics/<kanal>/<build>/<zeit>-<art>.json`, Aufbewahrung 90 Tage.
- Keine Weitergabe an Dritte, kein Fremddienst.

### D4 Auswertung
- `publish_ota.sh` legt pro Build die unveränderte App-Binärdatei samt UUID privat ab (nicht im Webverzeichnis).
- `scripts/diag_report.py`: symbolisiert Aufrufketten mit `llvm-symbolizer` über Binär-UUID + Offset, gruppiert nach Signatur, zeigt Häufigkeit pro Build, erste und letzte Auftreten und die letzten Ereignisse vor dem Fehler. Ausgabe als Text oder JSON; `--since`, `--build`, `--kind`.
- Bekannte Absturzmuster (Stapelüberlauf, Swift-Laufzeitfalle, ObjC-Ausnahme, Watchdog 0x8badf00d) werden in Klartext benannt.

### D5 Nachweis und Doku
- Core-Tests für Format, Ringpuffer und Datenschutzfilter; Servertests für Token, Limits und Ablage; Testbericht über `curl`.
- Gerätetest gebündelt: absichtlicher Testabsturz und Testhänger nur in einem versteckten Diagnosemenü der Testkanäle, Bericht erscheint nach dem nächsten Start auf dem Server; normale Nutzung ohne messbare Verzögerung.
- `docs/ENVIRONMENT.md` (Server), `docs/TESTING.md` (Ablauf), README.

## Reihenfolge und Branch
`feat/diagnose` von `dev`: D1 → D2 → D3 → D4 → D5, danach noty dev. Die normale noty erst nach Freigabe; dort nur „Diagnose teilen“, nichts automatisch.

## Offene Entscheidungen
- Schwellen für Ruckler-Ereignisse (Vorschlag: Hauptthread 250 ms, Speichern 1 s, Heft öffnen 2 s).
- Ob Berichte zusätzlich per Benachrichtigung gemeldet werden sollen (z. B. an den vorhandenen Bot).
