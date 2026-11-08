# Live Activity „Schultag“ – Plan (08.11.2026)

Status: **Plan, nicht beauftragt, nichts umgesetzt.** Grundlage: Machbarkeitsprüfung vom 08.11.2026 (Apple-Doku, xtool 1.24.0-Quellen, lokaler unsignierter Probe-Build außerhalb des Repos). Am iPad ist nichts davon geprüft.

## Ziel

Eine dauerhafte, sich selbst aktualisierende Kachel auf dem Sperrbildschirm (und in der Mitteilungszentrale) während des Schultags – wie Liefer- oder Sport-Apps sie zeigen:

```
┌──────────────────────────────────────────────┐
│ ● Mathematik · R 112          noch 23:41 min │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░  Stunde 3/6          │
│ Danach: Deutsch · R 204  (fällt aus!)        │
│ Hausaufgabe fällig: Englisch                 │
└──────────────────────────────────────────────┘
```

Countdown und Fortschrittsbalken laufen vom System selbst (`Text(timerInterval:)`, `ProgressView(timerInterval:)`), ohne Push pro Sekunde. Änderungen (Ausfall, Vertretung, Raumwechsel) erscheinen sofort rot oben in der Kachel.

## Was Apple erlaubt (iPad)

- Live Activities auf dem iPad ab **iPadOS 17**: Sperrbildschirm + Mitteilungszentrale. Keine Dynamic Island, kein StandBy (nur iPhone).
- Höchstens **8 h aktiv**, danach bis 4 h stehend; Daten ≤ 4 KB; Höhe ≤ 160 pt.
- Updates lokal aus der App oder per **APNs** (`apns-push-type: liveactivity`, Topic `<Bundle-ID>.push-type.liveactivity`). Priorität 5 zählt nicht zum (undokumentierten) Stundenbudget, Priorität 10 schon.
- Start per Push ohne geöffnete App („push-to-start“) ab iPadOS 17.2; Start zu einem festen Zeitpunkt lokal ab iPadOS 26.
- Voraussetzung: `NSSupportsLiveActivities` in der App und eine **Widget Extension** (die Oberfläche lebt dort).

## Toolchain (entscheidender Punkt)

- **xtool 1.24 kann Widget Extensions bauen, einbetten und je Extension eine App-ID/Profil anlegen** (`extensions:` in `xtool.yml`, offizielle Anleitung `Appex.md`).
- **Bekannter Fehler:** xtool linkt mit `-e _NSExtensionMain`, die Extension wird dadurch leer. Lokal bewiesener Workaround: im Widget-Target `linkerSettings: [.unsafeFlags(["-Xlinker","-u","-Xlinker","_main"])]` (xtool-Issue #313, Draft-PR #393).
- **Offenes Risiko:** xtool/zsign signiert Extensions mit den Entitlements der App (Issue #131). noty hat Sign in with Apple, App Group und Push – ob iPadOS die Extension damit annimmt, ist unbelegt. Muss als erster Schritt am Gerät geklärt werden.
- Praxisbeleg Dritter: MicYou-iOS baut mit xtool unter Linux Live Activity + Widgets und meldet Betrieb am iPhone.
- Interaktive Buttons (App Intents) brauchen Metadaten, die normalerweise Xcode erzeugt → **erste Version ohne Buttons**, Antippen öffnet noty calendar.

## Umsetzung in Schritten

| Schritt | Inhalt | Aufwand | Nachweis |
|---|---|---|---|
| 0 | **Probe:** minimales Widget-Target (`NotyCalendarWidgets`) mit Workaround und einer Dummy-Live-Activity, lokal aus der App gestartet; nur Kanal `calendar`; `publish_ota.sh`/`ota_check.py` um die `.appex` erweitern (Buildnummer, ID-Präfix, Signatur). | S | Installation klappt, Kachel erscheint am iPad |
| 1 | **Lokale Live Activity:** `ActivityAttributes` (Datum, Verbindung) + `ContentState` (aktuelle/nächste Stunde, Raum, Zeiten als Unix-Sekunden, Änderungsmarke, Fortschritt, Hausaufgabenzeile); Start durch die App am Schultag, Aktualisierung bei jedem Abruf/Änderung, Ende nach der letzten Stunde; Schalter im Blatt „Benachrichtigungen“; Antippen öffnet die aktuelle Stunde. | M | Kachel läuft einen Schultag mit, auch bei gesperrtem iPad |
| 2 | **Server-Updates (noty-push):** zweiter Sendeweg `liveactivity`; Activity-Token und Push-to-start-Token je Gerät speichern (`PUT /v1/device`); Zeitplan an den Stundengrenzen (Priorität 5, ~8–12/Tag), echte Änderung mit Priorität 10 + Alert; morgens `start` per Push-to-start, abends `end`; ungültiger Activity-Token verwirft nur die Activity, nicht das Gerät. | M–L | Kachel aktualisiert sich bei weggewischter App |
| 3 | **Widget ohne Live Activity** (optional): Startbildschirm/Sperrbildschirm „Heute/Als Nächstes“ aus einer Timeline je Stundengrenze; braucht App Group in der Extension (Risiko #131). | S–M | Widget zeigt korrekten Plan offline |
| 4 | **Buttons** (später, optional): z. B. „Hausaufgabe erledigt“ per `LiveActivityIntent`; eigene Metadaten-Erzeugung nötig. | M, Risiko hoch | – |

Reihenfolge: 0 → 1 → 2; 3 unabhängig nach 0; 4 nur auf ausdrücklichen Wunsch.

## Regeln und Risiken

- Kein neues Kalenderformat; die Kachel zeigt nur abgeleitete Daten. Keine Mandanten-/Privatdetails über Fach/Raum hinaus auf dem Sperrbildschirm.
- Ein 8-h-Limit kann lange Schultage überschreiten → rechtzeitig beenden und neu starten (lokal oder per Push).
- Ruhezeiten (21–6) gelten auch hier; nachts keine Kachel.
- Workarounds hängen an xtool-Versionen (bei Updates von xtool erneut prüfen).
- WebUntis-Status außer REGULAR sind weiterhin real unbestätigt.

## Offene Entscheidungen des Nutzers

1. Inhalt: nur Jetzt/Nächstes oder auch Tagesfortschritt, Hausaufgaben, Pausen/Freistunden?
2. Start: automatisch an jedem Schultag (z. B. 30 Min. vor der 1. Stunde) oder nur per Schalter/Hand?
3. Ende: direkt nach der letzten Stunde oder noch eine Weile stehen lassen?
4. Änderung während des Tages: Bildschirm wecken (Alert) oder still aktualisieren?
5. Abends schon „Morgen“-Vorschau?
6. Zusätzlich ein normales Widget (Schritt 3)?
