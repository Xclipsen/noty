# Plan: Einheitliche Fehler- und Ruckler-Diagnose (Baustein 1)

Geplant am 08.11.2026, am selben Tag auf `feat/diagnose` umgesetzt (D1–D5). Aktuelle Beschreibung, Schwellen, Datenschutz, Server und Nachweise: [DIAGNOSE](DIAGNOSE.md). Dieses Dokument bleibt nur als Herkunft.

Auslöser war der Absturz in Build 130/131: Den Bericht musste der Nutzer von Hand aus den Analyseprotokollen holen, und für Ruckler gab es keine einheitliche Quelle.

## Bausteine (umgesetzt)

- **D1 Format und Ereignisprotokoll (Core):** `DiagnosticReport`, `DiagnosticJournal`, `DiagnosticStore`, `DiagnosticAnalysis`, `DiagnosticReporter`; Core-Tests `DiagnosticTests`.
- **D2 Erfassung in der App:** MetricKit, eigener Hänger-Wächter, Messpunkte, Einstellungen › Diagnose mit verstecktem Testmenü.
- **D3 Empfang:** `diagnostics/server.py` als systemd-Dienst `noty-diagnostics` hinter nginx; Schlüssel und Commit beim Veröffentlichen.
- **D4 Auswertung:** Binärdatei je Build, `scripts/diag_report.py` gruppiert, symbolisiert und benennt Muster.
- **D5 Doku:** DIAGNOSE, ENVIRONMENT, TESTING, README, AGENTS.

## Entscheidungen gegenüber dem Plan

- Schwellen: Hauptthread 250 ms (Ereignis) und 2 s (Bericht), je Vorgang eigene Schwellen (Tabelle in DIAGNOSE).
- Keine Benachrichtigung und kein Bot: Die Berichte liest ein Agent mit `diag_report.py`.
- Statt fester Arten wie `saveFailure` eine Art `failure` mit Vorgang; `LaunchGuard` fehlt noch, weil er nur auf `feat/feinschliff` liegt.
- Keine eigenen Signpost-Messungen über MetricKit; Messpunkte schreiben direkt Ereignisse und Berichte.
