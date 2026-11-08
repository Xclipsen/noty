# Fehler- und Ruckler-Diagnose

Stand: 08.11.2026, Branch `feat/diagnose`. Plan und Entstehung: [DIAGNOSE-PLAN](DIAGNOSE-PLAN.md).

## Ziel

Abstürze, Hänger, langsame Vorgänge und Fehler aus noty dev, noty AI und noty calendar kommen ohne Zutun auf dem eigenen Server an. Alle Berichte haben dasselbe Format, werden nach Ursache gruppiert und zeigen lesbare Code-Stellen. Heftinhalte sind nie enthalten.

Die normale noty sendet nichts automatisch: Der Schalter „Fehlerberichte automatisch senden“ ist dort aus. „Diagnose teilen …“ geht in jeder App. Es gibt keine Benachrichtigung und keinen Bot. Die Berichte sind dafür gedacht, dass ein Agent sie mit `scripts/diag_report.py` liest.

## Stand der Nachweise

- **Implementiert:** Core (Format, Ereignisprotokoll, Ablage, Auswertung), App (MetricKit, Hänger-Wächter, Messpunkte, Einstellungen › Diagnose), Empfangsdienst, Veröffentlichung mit Schlüssel und Binärdatei, Auswertungsskript.
- **Geprüft:** Core-Tests (`DiagnosticTests`) und Servertests (`diagnostics/test_server.py`, `scripts/test_diag_report.py`) bestehen. iPad-SDK-Build erfolgreich.
- **Server:** auf diesem Rechner installiert und aktiv. Ende-zu-Ende über den öffentlichen HTTPS-Pfad: Testbericht angenommen (201), derselbe Bericht erneut 409, ohne Schlüssel 401. Die Testdatei wurde danach gelöscht.
- **Nicht veröffentlicht, nicht installiert, auf dem iPad ungeprüft.** Insbesondere **ungeprüft**: Zustellung durch MetricKit, Hänger-Wächter am Gerät, Senden aus der App, Einfluss auf Leistung und Schreibgefühl. Ablauf: [TESTING](TESTING.md#fehler--und-ruckler-diagnose-08112026-branch-featdiagnose).

## Was erfasst wird

| Art (`kind`) | Quelle | Wann |
| --- | --- | --- |
| `crash` | MetricKit | Absturz, meist beim nächsten Start geliefert |
| `hang` | MetricKit | vom System erfasster Hänger des Hauptthreads |
| `appHang` | eigener Wächter (`HangProbe`) | Hauptthread steht ≥ 2 s; Aufrufkette des Hauptthreads |
| `cpu`, `diskWrite`, `launch` | MetricKit | CPU-Ausnahme, zu viele Schreibzugriffe, langsamer Start |
| `memory` | MetricKit-Tageswerte | App wurde wegen Speicherverbrauch beendet |
| `metrics` | MetricKit-Tageswerte | Startzeit, Hängerzeit, Scroll-Ruckler, Beendigungen nach Grund, Speicherspitze, CPU-Zeit |
| `slow` | Messpunkt | Vorgang über seiner Schwelle (höchstens ein Bericht je Vorgang und Stunde) |
| `failure` | Messpunkt | Speichern, Heft öffnen, Backup, Wiederherstellen, App-Abgleich, Suchindex, Gesetz laden, PDF-Export fehlgeschlagen (stündlich je Vorgang) |
| `abnormalExit` | eigene Sitzungsliste | voriger Lauf endete im Vordergrund oder nach der Startphase `launch` ohne sauberes Ende |
| `test` | verstecktes Testmenü | nur Test-Apps |

Hänger: Jeder zusammenhängende Arbeitsabschnitt des Hauptthreads (zwischen den Run-Loop-Grenzen, Layout und Zeichnen eingeschlossen) ab **250 ms** wird als Ereignis `hang` notiert, ab **2 s** entsteht ein `appHang`-Bericht. Er wird nach Ende des Hängers mit der tatsächlichen Dauer neu geschrieben und erst dann gesendet. Der Wächter ist ein Thread, der alle 100 ms aufwacht.

Schwellen für langsame Vorgänge (`DiagnosticThresholds`, Bezeichnungen aus `DiagnosticAnalysis`):

| Vorgang | Name | Schwelle |
| --- | --- | --- |
| Heft öffnen | `notebook.open` | 2 s |
| Seite wechseln | `page.switch` | 500 ms |
| Speichern | `save` | 1 s |
| Strich abschließen | `stroke.commit` | 150 ms |
| Gesetzesfenster | `law.window` | 1 s (Schwelle vorhanden, derzeit kein Messpunkt) |
| Gesetz laden | `law.load` | 2 s |
| Suche | `search` | 1 s |
| Suchindex erfassen | `search.index` | 30 s |
| PDF-Export | `pdf.export` | 15 s |
| Backup | `backup` | 30 s |
| App-Abgleich (Abzug / Spiegel) | `appSync`, `appSync.mirror` | 15 s |
| sonst | – | 1 s |

`stroke.commit` und `search` sind „leise“: Sie schreiben nur ein Ereignis, wenn sie zu langsam waren. Messpunkte im Code: `grep -rn "Diagnostics\." Sources/Noty`.

Zusätzlich notiert die App feste Ereignisse wie Startphasen (`phase.library`, `phase.notebook`, `phase.lawWindow`, `phase.running`), Szenenwechsel, Gesetzesfenster sichtbar/geparkt/geschlossen und Gesetzes-Tastenkürzel (`key.law.*`).

## Inhalt eines Berichts

`DiagnosticReport`, JSON, `formatVersion 1`. Gemeinsame Vorlage für Swift, Server und Skript: `diagnostics/fixtures/report-v1.json`.

- App: Kanal (`stable`, `dev`, `ai`, `calendar`), Bundle-ID, Version, Build, Commit (von `publish_ota.sh`; lokal leer).
- Gerät: nur Modellkennung (z. B. `iPad17,1`) und iPadOS-Version; kein Name, keine UDID.
- Art, Zeiten, Lauf-ID, letzte Startphase.
- `summary`: deutscher Einzeiler aus festen Wörtern und Zahlen. `signature`: Art, Vorgang oder Muster und die innersten drei App-Frames; gruppiert gleiche Ursachen.
- `details`: feste Schlüssel mit Systemcodes und Zahlen (Ausnahmetyp, Signal, `terminationReason`, Dauer, Fehlerdomäne und -code).
- `callStack`: Bildname + Offset (+ UUID), innerster Frame zuerst. Über 512 Frames bleiben die innersten 384 und die äußersten 64.
- `breadcrumbs`: die letzten bis zu 200 Ereignisse des Laufs, nur feste Namen und ganze Zahlen.
- `payload`: MetricKits eigenes JSON ohne Meldungstexte; über 600 KB entfällt es (`payloadDropped`).

Bekannte Muster werden benannt: Stapelüberlauf, Watchdog (`0x8badf00d`), Swift-Laufzeitfalle, Objective-C-Ausnahme, SIGABRT, Speicherzugriffsfehler, Speicherlimit.

## Ablage auf dem Gerät

Unter `Library/Application Support/Diagnose`, also nicht in `Documents` und nicht in Backups:

- `journal/<Lauf-ID>.jsonl`: Ereignisse eines Laufs, jede Zeile sofort geschrieben (kein Puffer, den ein Absturz verliert). Ab 2000 Zeilen auf die letzten 200 gekürzt. Journale der letzten 5 Läufe bleiben.
- `sessions.json`: die letzten 5 Läufe mit Build, Phase und Zustand. Nur bei Phasen- und Szenenwechseln geschrieben.
- `reports/pending` und `reports/sent`: Dateien `<ms>-<art>-<id>.json`. Nach `sent` erst, wenn der Server 2xx oder 409 meldet. 400 und 413 werden ebenfalls nach `sent` gelegt, damit nichts endlos wiederholt wird. Höchstens 50 wartende und 30 gesendete; beim Kürzen gehen zuerst die häufigen Arten (`slow`, `hang`, `appHang`, `failure`, `cpu`, `diskWrite`), damit Abstürze erhalten bleiben. Von diesen häufigen Arten höchstens 40 je 24 h. Löschung nach 90 Tagen.

Die ältere ausführliche Hänger-Diagnose (`Documents/Diagnose/haenger.txt`) und die Eingabe-Diagnose (`eingabe.txt`) sind davon getrennt und bleiben eigene Schalter.

## Datenschutz und wie er durchgesetzt wird

- Ereignisnamen und Zahlenschlüssel (`DiagnosticEvent`, `DiagnosticKey`) lassen sich nur aus String-Literalen bilden. Ein Titel oder Text kann so nicht zum Ereignis werden.
- `DiagnosticPrivacy` prüft beim Erstellen jedes Berichts erneut: Namen nur `A–Z a–z 0–9 . _ -`, höchstens 48 Zeichen; Angaben nur druckbares ASCII ohne `/`, `\`, `~`, höchstens 160 Zeichen. Anderes fällt weg oder wird `?`.
- Von Fehlern bleiben nur Domäne und Code, nie Beschreibung oder `userInfo`.
- Aus MetricKit-JSON werden `composedMessage`, `formatString`, `arguments`, `message` und der Text von `exceptionReason` entfernt; nur Klassen- und Ausnahmename bleiben.
- Der Server prüft Ereignisnamen, Zahlenschlüssel und Angaben noch einmal mit denselben Regeln und lehnt Abweichungen mit 400 ab. Das `payload` prüft er nicht inhaltlich; dort greift nur der Filter in der App.
- Nachweise: `testPrivacyFilterDropsAnythingButFixedNamesAndCodes`, `testNoNotebookContentReachesReportsOrTheJournal` (ein Heft mit erkennbarem Titel und Text durchläuft Speichern, Fehler und Ereignisse; weder Bericht noch Journal enthalten Titel, Text oder Pfad) und `test_rejects_wrong_form_and_free_text` im Server.

## Senden

Adresse und Schlüssel stehen nur in der gebauten App (Info.plist `NotyDiagURL`, `NotyDiagKey`). `scripts/publish_ota.sh` schreibt sie aus `DIAG_URL` und `DIAG_KEY` in `.tools/ota.env` hinein und setzt die Info.plist danach zurück. Lokale Builds kennen keinen Server und senden nichts. Gesendet wird per HTTPS-POST mit Header `X-Noty-Key`, einzeln, frühestens 15 s nach dem Start und 5 s nach jedem neuen Bericht oder Wechsel in den Vordergrund.

## Einstellungen › Diagnose

Abschnitt „Fehlerberichte“: Schalter „Fehlerberichte automatisch senden“ (Test-Apps an, noty aus; ohne Server gesperrt), „Letzte Berichte“ mit Zusammenfassung, Angaben, letzten Schritten und Aufrufkette, „Diagnose teilen …“ (eine JSON-Datei mit denselben Daten, die der Server bekäme), „Wartende Berichte jetzt senden“. Fünf Tipps auf die Build-Zeile öffnen in den Test-Apps das Testmenü: „Testbericht senden“, „Testhänger (3 s)“, „Testabsturz“.

## Server

Läuft auf diesem Rechner, demselben Host wie die OTA-Seiten. Einrichtung, Schlüsseltausch und Betrieb: [ENVIRONMENT](ENVIRONMENT.md#fehlerberichte-server). Kurz: `diagnostics/server.py` (nur Python-Standardbibliothek) hinter nginx unter einem geheimen exakten Pfad der OTA-Domain, Ablage `/var/lib/noty-diagnostics/reports/<kanal>/<build>/`, 90 Tage.

## Auswertung

```bash
sudo python3 -B scripts/diag_report.py                    # Gruppen der letzten 14 Tage
sudo python3 -B scripts/diag_report.py --since 24h --channel dev --kind crash
sudo python3 -B scripts/diag_report.py --show 3F2A        # ein Bericht, ID-Anfang genügt
sudo python3 -B scripts/diag_report.py --all --json       # mit Tageswerten/Tests, maschinenlesbar
```

Root ist nötig, weil die Ablage nur für root und `noty-diag` lesbar ist. Filter: `--since` (24h, 7d, 2w, Datum, all), `--channel`, `--build`, `--kind`, jeweils mehrfach. Die Ausgabe zeigt je Gruppe Anzahl, Builds, erstes und letztes Auftreten, Muster mit Hinweis, Hänger-Kategorie (SwiftUI, PencilKit, Dateizugriff, Warten auf Sperre, Systemaufruf, App-Code; Dateizugriff und Warten nur bei belegten Namen, ein Kernel-Frame allein heißt „Systemaufruf“, weil Systemfunktionen keine Namen tragen), symbolisierte App-Frames und die Ereignisse vor dem Problem. Ein `abnormalExit` desselben Laufs wird in den zugehörigen `crash` eingefaltet.

Symbolisierung: `llvm-symbolizer` und `swift-demangle` aus der Swiftly-Toolchain gegen die Binärdatei, die `publish_ota.sh` je Build unter `.tools/diag-binaries/<kanal>/<build>/` ablegt (`Noty`, `info.json` mit Kanal, Build, Branch, Commit, UUID; die letzten 60 Builds je Kanal). Das gibt es nur für Builds, die mit dem neuen `publish_ota.sh` veröffentlicht wurden. Frames mit abweichender UUID werden nicht übersetzt. Ergebnis sind nur Funktionsnamen, keine Datei- und Zeilennummern: Die Binärdatei hat kein DWARF, es gibt kein dSYM.

## Offen

- `LaunchGuard` (Start-Absturzschutz) liegt nur auf `feat/feinschliff`, nicht in `dev`. Nach dem Merge soll er Phasen und Ereignisse auch an `Diagnostics` melden.
- MetricKit-Signpost-Metriken werden nicht genutzt.
- Keine Datei-/Zeilennummern bei der Symbolisierung (siehe oben).
- Messpunkt für `law.window` fehlt.
- Alle Gerätepunkte aus „Stand der Nachweise“.
