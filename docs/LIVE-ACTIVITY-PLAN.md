# Live Activity „Schultag“ – Plan (08.11.2026)

Status (08.11.2026): **Schritte 0, 1 und 3 implementiert und gebaut.** Build 138 (Extension noch mit den Entitlements der App, xtool #131) veröffentlicht; der Nutzer hat bestätigt, dass er sich **trotzdem installieren ließ**. **Build 139** (Extension nachsigniert, Test-Kachel) veröffentlicht, eigene Artefaktprüfung ohne Befund (`ota-check.json`), **vom Nutzer installiert, Test-Kachel vom Nutzer bestätigt** („das passt“). Ein echter Schultag mit Kachel, das Widget „Heute“ und der Start ab iPadOS 26 sind **am iPad ungeprüft**. Die Korrekturen nach Build 139 (Commit `0fb2951`: Kachel-Alert aus der Änderungserkennung, lückenloser 8-h-Neustart, Kachelarbeit nacheinander, Test-Kachel-Status aus ActivityKit) sind gebaut, nicht installiert, ungeprüft. Schritt 2 (Server) ist nicht beauftragt; sein Vertrag steht unten. Nachweise je Build: [CALENDAR-LOG](CALENDAR-LOG.md#build-138--live-activity-schultag-und-widget-heute-lokal-08112026). Grundlage: Machbarkeitsprüfung vom 08.11.2026 (Apple-Doku, xtool 1.24.0-Quellen, lokaler unsignierter Probe-Build außerhalb des Repos).

## Ziel

Eine dauerhafte, sich selbst aktualisierende Kachel auf dem Sperrbildschirm (und in der Mitteilungszentrale) während des Schultags – wie Liefer- oder Sport-Apps sie zeigen:

```
┌──────────────────────────────────────────────┐
│ ● Mathematik · R 112          noch 23:41 min │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░  Stunde 3/6          │
│ Danach: Deutsch · R 204  (fällt aus!)        │
└──────────────────────────────────────────────┘
```

Keine Hausaufgabenzeile (Entscheidung des Nutzers, siehe unten). Countdown und Fortschrittsbalken laufen vom System selbst (`Text(timerInterval:)`, `ProgressView(timerInterval:)`), ohne Push pro Sekunde. Änderungen (Ausfall, Vertretung, Raumwechsel) erscheinen rot in der „Danach“-Zeile bzw. an der laufenden Stunde, sobald noty sie kennt.

## Was Apple erlaubt (iPad)

- Live Activities auf dem iPad ab **iPadOS 17**: Sperrbildschirm + Mitteilungszentrale. Keine Dynamic Island, kein StandBy (nur iPhone).
- Höchstens **8 h aktiv**, danach bis 4 h stehend; Daten ≤ 4 KB; Höhe ≤ 160 pt.
- Updates lokal aus der App oder per **APNs** (`apns-push-type: liveactivity`, Topic `<Bundle-ID>.push-type.liveactivity`). Priorität 5 zählt nicht zum (undokumentierten) Stundenbudget, Priorität 10 schon.
- Start per Push ohne geöffnete App („push-to-start“) ab iPadOS 17.2; Start zu einem festen Zeitpunkt lokal ab iPadOS 26.
- Voraussetzung: `NSSupportsLiveActivities` in der App und eine **Widget Extension** (die Oberfläche lebt dort).

## Toolchain (entscheidender Punkt)

- **xtool 1.24 kann Widget Extensions bauen, einbetten und je Extension eine App-ID/Profil anlegen** (`extensions:` in `xtool.yml`, offizielle Anleitung `Appex.md`).
- **Bekannter Fehler:** xtool linkt mit `-e _NSExtensionMain`, die Extension wird dadurch leer. Lokal bewiesener Workaround: im Widget-Target `linkerSettings: [.unsafeFlags(["-Xlinker","-u","-Xlinker","_main"])]` (xtool-Issue #313, Draft-PR #393).
- **Bekannter Fehler 2:** xtool/zsign signiert Extensions mit den Entitlements der App (Issue #131). Umgangen durch Nachsignieren nach dem Build (`scripts/resign_extensions.py`, Abschnitt „Nachsignieren“); iPadOS hat das Ergebnis angenommen (Build 139 vom Nutzer installiert, Test-Kachel erscheint).
- Praxisbeleg Dritter: MicYou-iOS baut mit xtool unter Linux Live Activity + Widgets und meldet Betrieb am iPhone.
- Interaktive Buttons (App Intents) brauchen Metadaten, die normalerweise Xcode erzeugt → **erste Version ohne Buttons**, Antippen öffnet noty calendar.

## Umsetzung in Schritten

| Schritt | Inhalt | Aufwand | Nachweis (Ziel) · Stand |
|---|---|---|---|
| 0 | **Probe:** minimales Widget-Target (`NotyCalendarWidgets`) mit Workaround und einer Dummy-Live-Activity, lokal aus der App gestartet; nur Kanal `calendar`; `publish_ota.sh`/`ota_check.py` um die `.appex` erweitern (Buildnummer, ID-Präfix, Signatur). | S | Installation klappt, Kachel erscheint am iPad · **erreicht** mit Build 139 (Nutzer: Installation und Test-Kachel) |
| 1 | **Lokale Live Activity:** `ActivityAttributes` (Datum, Verbindung) + `ContentState` (aktuelle/nächste Stunde, Raum, Zeiten als Unix-Sekunden, Änderungsmarke, Fortschritt; laut Entscheidung **keine** Hausaufgabenzeile); Start durch die App am Schultag, Aktualisierung bei jedem Abruf/Änderung, Ende nach der letzten Stunde; Schalter im Blatt „Mitteilungen“; Antippen öffnet die aktuelle Stunde. | M | Kachel läuft einen Schultag mit, auch bei gesperrtem iPad · implementiert und gebaut, **am iPad ungeprüft** |
| 2 | **Server-Updates (noty-push):** zweiter Sendeweg `liveactivity`; Activity-Token und Push-to-start-Token je Gerät speichern (`PUT /v1/device`); Zeitplan an den Stundengrenzen (Priorität 5, ~8–12/Tag), echte Änderung mit Priorität 10 + Alert; morgens `start` per Push-to-start, abends `end`; ungültiger Activity-Token verwirft nur die Activity, nicht das Gerät. | M–L | Kachel aktualisiert sich bei weggewischter App · **nicht beauftragt, nicht umgesetzt** (nur Token-Übergabestelle) |
| 3 | **Widget ohne Live Activity** (optional): Startbildschirm/Sperrbildschirm „Heute/Als Nächstes“ aus einer Timeline je Stundengrenze; braucht App Group in der Extension (über das Nachsignieren, siehe unten). | S–M | Widget zeigt korrekten Plan offline · implementiert und gebaut, **am iPad ungeprüft** |
| 4 | **Buttons** (später, optional): z. B. „Hausaufgabe erledigt“ per `LiveActivityIntent`; eigene Metadaten-Erzeugung nötig. | M, Risiko hoch | – · nicht gewählt |

Reihenfolge: 0 → 1 → 2; 3 unabhängig nach 0; 4 nur auf ausdrücklichen Wunsch.

## Regeln und Risiken

- Kein neues Kalenderformat; die Kachel zeigt nur abgeleitete Daten. Keine Mandanten-/Privatdetails über Fach/Raum hinaus auf dem Sperrbildschirm.
- Ein 8-h-Limit kann lange Schultage überschreiten → rechtzeitig beenden und neu starten (lokal oder per Push).
- Ruhezeiten (21–6) gelten auch hier; nachts keine Kachel.
- Workarounds hängen an xtool-Versionen (bei Updates von xtool erneut prüfen).
- Welche WebUntis-Status außer `REGULAR` vorkommen, ist offen ([CALENDAR-PLAN §9](CALENDAR-PLAN.md#9-offene-punkte)); die Änderungsmarken hängen daran.

## Entscheidungen des Nutzers (08.11.2026)

- **Inhalt:** Jetzt + Danach (Fach, Raum, Countdown), Tagesfortschritt („Stunde 3/6“), in Pausen/Freistunden „Pause · noch 12 Min.“ bzw. „Freistunde“. **Keine** Hausaufgabenzeile.
- **Start:** automatisch an jedem Schultag 30 Min. vor der ersten Stunde (nur an Tagen mit Unterricht).
- **Ende:** direkt nach der letzten Stunde.
- **Änderung tagsüber:** Kachel-Update mit Alert (weckt den Bildschirm); Ruhezeiten 21–6 gelten weiter.
- **Zusätzlich ein normales Widget** „Heute/Als Nächstes“ (Schritt 3) wird gewünscht.
- Abends-Vorschau „Morgen“ und Buttons: nicht gewählt.

Bauauftrag: Schritte 0, 1 und 3 am 08.11.2026 erteilt (Stand unten).

## Umsetzungsstand (08.11.2026)

Stand: siehe Status oben; Nachweise je Build in [CALENDAR-LOG](CALENDAR-LOG.md). Beschrieben ist der Code nach Commit `0fb2951`.

| Teil | Ort | Stand |
|---|---|---|
| Logik (rein, plattformunabhängig) | `Core/Sources/NotebookCore/CalendarSchoolDay.swift` | `SchoolDayLesson`, `SchoolDayPhase`, `SchoolDayAttributes`, `SchoolDayContentState`, `CalendarSchoolDay` (Phase, Stunden-Nr., Zustandswechsel, 8-h-Neustartplan), `SchoolDayWidgetFile`, `SchoolDayWidgetContent`; 15 XCTests in `CalendarSchoolDayTests` |
| Geteiltes Modul App + Extension | `Sources/NotyCalendarShared/SchoolDayShared.swift` | `SchoolDayAttributes: ActivityAttributes` (eine Konformanz für beide Binärdateien), Deep Link `notycalendar://schultag?connection=…&day=…&entry=…`, Widget-Datei in der App Group, Texte |
| Widget-Extension | `Sources/NotyCalendarWidgets/`, `NotyCalendarWidgets.plist`, `NotyCalendarWidgets.entitlements` | Live Activity (Sperrbildschirm nach Skizze, Dynamic-Island-Pflichtteil minimal) und Widget „Heute“ (`systemSmall`, `systemMedium`, `accessoryRectangular`), keine Bilder, keine Buttons, Dynamic Type bis `xLarge`, hell/dunkel über Systemfarben, Hinweis „Stand veraltet“ ab `staleDate` |
| App | `Sources/Noty/CalendarSchoolDayCenter.swift`, Aufruf am Ende von `rescheduleRemindersNow`, Deep Link in `WorkspaceAppModel.onOpenURL` → `CalendarNotificationHub.openSchoolDay` | Start/Update/Ende/8-h-Neustart lokal, Widget-Datei + `WidgetCenter.reloadTimelines`, Token-Beobachtung, Schalter im Blatt „Mitteilungen“ |
| Bau je Kanal | `scripts/calendar_build.py` (von `publish_ota.sh` nur bei `NOTY_CHANNEL=calendar` aufgerufen), `scripts/resign_extensions.py`, `scripts/ota_check.py` | siehe „Bau“ und „Nachsignieren“ |

### Verhalten

- **Tag:** Lessons des Tages aus dem Offline-Stundenplan des angezeigten Bereichs (nur geladener Tag; nicht geladen ≠ kein Unterricht). Für Beginn, Ende, Anzahl und Phase zählen nur **stattfindende** Stunden; exakt gleichzeitige Stunden (Gruppen) zählen einmal. Ausgefallene Stunden innerhalb des Tages bleiben als „Danach: … fällt aus“ sichtbar; ausgefallene vor der ersten/nach der letzten stattfindenden Stunde verschieben Beginn/Ende. Ohne stattfindende Stunde (Wochenende, Ferien, alles fällt aus): keine Kachel.
- **Phasen:** `before` (bis zur ersten Stunde), `lesson`, `break` (Pause), `free` (Freistunde), `done`. **Freistunde** = Lücke zwischen zwei stattfindenden Stunden, die mindestens so lang ist wie die kürzeste stattfindende Stunde des Tages (mindestens 30 Min.), **oder** in der eine ausgefallene Stunde liegt. Folge: eine lange Mittagspause erscheint als „Freistunde bis 13:30“. Sonst `break` („Pause · noch 12:00“).
- **„Stunde 3/6“:** Nummer der laufenden, sonst der nächsten stattfindenden Stunde; Anzahl = stattfindende Stunden.
- **Änderungsmarke:** „fällt aus“, „Vertretung“, „Raumwechsel“, „Vertretung, Raumwechsel“ (rot, `changed`), „Prüfung“ (neutral); Belege der Status: [CALENDAR-PLAN §9](CALENDAR-PLAN.md#9-offene-punkte).
- **Zustandswechsel** (`transitions`): Start (30 Min. vor der ersten Stunde), jeder Beginn/jedes Ende einer stattfindenden Stunde, jeder Beginn einer ausgefallenen Stunde (die „Danach“-Zeile rückt weiter), Ende. Zwischen zwei Wechseln ist der Zustand konstant (getestet). Diese Liste ist auch der Zeitplan des Servers (Schritt 2).
- **8-h-Grenze:** `plan.restarts` = alle 7 h 45 min ab Start, solange vor dem Ende. Ab einem Neustartzeitpunkt gehört die Kachel zum nächsten Segment (die App merkt sich je Activity das Segment): zuerst wird die neue Kachel angefordert, erst danach enden die älteren; lässt sich keine neue starten, bleibt die neueste alte stehen und wird weiter aktualisiert. Läuft noty, plant der Takt das Update pünktlich zum nächsten Phasenwechsel bzw. Neustartzeitpunkt. Alle ActivityKit-Läufe (Update, Änderung, Test-Kachel) laufen nacheinander (`serial`); ein überholter Lauf entfällt, sodass nie zwei Kacheln entstehen.
- **Start:** iPadOS 26+: die App merkt die Kachel des heutigen bzw. (nach Schulschluss) morgigen Schultags mit `Activity.request(…, start:)` für 30 Min. vor der ersten Stunde vor (die API verlangt eine `AlertConfiguration`: „Schultag · 1. Stunde 08:00: …“; liegt der Start in den Ruhezeiten, wird nicht vorgemerkt). Ändert sich die erste Stunde, wird die vorgemerkte ersetzt. Vor iPadOS 26 bzw. ohne Vormerkung: Start beim nächsten Update nach dem Startzeitpunkt, und iPadOS erlaubt `request` nur im Vordergrund (Fehler erscheint im Blatt).
- **Update:** bei jedem Abruf/Commit/Aktivwerden und im Vordergrund pünktlich zu jedem Wechsel.
- **Änderungen des Tages** (`announce`, aufgerufen aus `recordChanges` mit den Funden von `CalendarChangeDetector`, nur künftige Stunden, nur wenn „Stundenplanänderungen“ an ist): Würde die App die Änderungsmitteilung selbst schicken (Push-Dienst nicht zuständig, außerhalb der Ruhezeiten), trägt stattdessen das Kachel-Update den Alert (Titel und Text wie die Mitteilung, weckt den Bildschirm) und die App schickt für diese Änderungen keine zweite Mitteilung. Ist der Push-Dienst zuständig, aktualisiert sich die Kachel still (die Mitteilung kommt vom Server). Grundlage ist derselbe Vergleich vor/nach einer Aktualisierung wie bei den Mitteilungen; der frühere eigene Vergleichsstand der Kachel im Speicher (leer nach jedem App-Neustart) entfällt.
- **Ende:** beim ersten Update nach der letzten Stunde mit `.immediate`. **Lokale Grenze:** läuft noty zu diesem Zeitpunkt nicht, bleibt die Kachel bis zum nächsten App-Lauf stehen (bzw. bis iPadOS sie nach 8 h beendet) und zeigt ab `staleDate` „Stand veraltet“; zwischen zwei App-Läufen bleiben auch Phasenwechsel aus (der Countdown läuft trotzdem). Schritt 2 schließt das.
- **Schalter** „Schultag auf dem Sperrbildschirm“ (Einstellungen › Kalender › Mitteilungen bzw. Blatt „Mitteilungen“, Standard an, Gerätepräferenz, nur noty calendar; die Test-Kachel steht seit 08.11.2026 unter Einstellungen › Entwickler) mit Hinweis, wenn Live-Aktivitäten in den iPad-Einstellungen aus sind (`areActivitiesEnabled`), und Zeile „Läuft: …“.
- **Bereich:** nur der angezeigte Bereich steuert die Kachel; Activities einer anderen Verbindung oder eines anderen Tages werden beendet. Antippen öffnet über den Deep Link den Tag/die Stunde (`openNotification`, normaler `show`-Weg); gehört die Kachel zu einer anderen Verbindung, nur ein Hinweis.
- **Widget „Heute“:** die App schreibt nach jedem Update `NotyWidgets/<Kanal>/schoolday.json` in die App Group (`group.de.la.noty.shared`, mit `XTL-`-Präfix wie beim App-Abgleich): heute und morgen, nur geladene Tage, abgeleitete Daten, ohne Verbindung gelöscht; neu geschrieben (und `reloadTimelines`) nur, wenn sich die Stunden ändern. Das Widget rechnet mit derselben Core-Logik Einträge für jeden Wechsel des Tages plus Mitternacht. Nach Schulschluss: „Schultag vorbei · Morgen 08:00: …“.
- **Tokens:** Push-to-start-Token (`pushToStartTokenUpdates`, iPadOS 17.2+) und je Activity `pushTokenUpdates` landen in `CalendarPushClient.liveActivityTokens` – **Übergabestelle für Schritt 2, ohne API-Aufruf** (TODO-Kommentare). Activities werden mit `pushType: .token` angefordert.

### JSON-Vertrag für noty-push (Schritt 2)

APNs: `apns-push-type: liveactivity`, Topic `<installierte Bundle-ID>.push-type.liveactivity` (noty calendar: `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar.push-type.liveactivity`), Priorität 5 für planmäßige Wechsel, 10 für echte Änderungen mit `alert`. Der Inhalt wird von ActivityKit mit dem **Standard-`JSONDecoder`** gelesen: alle Pflichtfelder senden, Zeiten als **ganze Unix-Sekunden** (Int), optionale Felder dürfen fehlen, unbekannte Felder werden ignoriert, ein unbekannter `phase`-Wert oder fehlendes Pflichtfeld verwirft das Update. Grenze 4 KB (typisch < 1 KB, getestet).

`attributes-type`: **`SchoolDayAttributes`**; `attributes`:

| Feld | Typ | Inhalt |
|---|---|---|
| `connectionID` | String | WebUntis-Verbindung (`CalendarConnectionRecord.id`, UUID groß geschrieben) |
| `day` | String | Schultag „YYYY-MM-DD“ (Europe/Berlin) |

`content-state` (`SchoolDayContentState`):

| Feld | Typ | Pflicht | Inhalt |
|---|---|---|---|
| `v` | Int | ja | Vertragsversion, `1` |
| `phase` | String | ja | `before`, `lesson`, `break`, `free`, `done` |
| `phaseStart`, `phaseEnd` | Int | ja | Beginn/Ende der Phase (Countdown `phaseStart…phaseEnd`); `before`: Start der Kachel … erste Stunde |
| `current` | Lesson | nein | nur bei `lesson`: laufende Stunde |
| `next` | Lesson | nein | `before`: erste stattfindende Stunde; sonst erste Stunde (auch ausgefallene) nach der laufenden bzw. nach jetzt; fehlt nach der letzten |
| `number`, `count` | Int | ja | „Stunde number/count“ (siehe oben) |
| `dayStart`, `dayEnd` | Int | ja | erste/letzte stattfindende Stunde (Tagesfortschritt) |

Lesson (`SchoolDayLesson`): `title` String (≤ 40 Zeichen, Pflicht), `room` String (≤ 24, „R 112“ oder „A, B“; optional), `start`/`end` Int (Pflicht), `note` String (optional: „fällt aus“, „Vertretung“, „Raumwechsel“, „Vertretung, Raumwechsel“, „Prüfung“), `changed` Bool (Pflicht, rot), `cancelled` Bool (Pflicht), `entryID` String (optional, ≤ 200; Kalendereintrags-ID = `CalendarLesson.id`, dieselbe wie `entryID` der Änderungs-Pushes; Deep Link).

Beispiel (Mo 09.11.2026, 3. von 6 Stunden, danach fällt Deutsch aus; wörtlich in `testDocumentedExampleDecodes`):

```json
{"v":1,"phase":"lesson","phaseStart":1794213900,"phaseEnd":1794216600,
 "current":{"title":"Mathematik","room":"R 112","start":1794213900,"end":1794216600,"changed":false,"cancelled":false,
            "entryID":"webuntis/6F1C2A4E-0000-4000-8000-000000000001/4711/2026-11-09T09:45"},
 "next":{"title":"Deutsch","room":"R 204","start":1794216900,"end":1794219600,"note":"fällt aus","changed":true,"cancelled":true},
 "number":3,"count":6,"dayStart":1794207600,"dayEnd":1794226500}
```

Push-Hülle (Server): `{"aps":{"timestamp":<jetzt>,"event":"update","content-state":{…},"stale-date":<nächster Wechsel + 60>,"relevance-score":100}}`; Start per Push-to-start: `"event":"start","attributes-type":"SchoolDayAttributes","attributes":{…},"content-state":{…},"alert":{"title":"Schultag","body":"…"}`; Änderung zusätzlich `"alert":{"title":"Stundenplanänderung","body":"…"}` (außer Ruhezeiten); Ende: `"event":"end","dismissal-date":<jetzt>` mit letztem `content-state` (`phase":"done"`). Der Server berechnet Zustände und Zeitpunkte am besten mit derselben Logik (`push/Package.swift` bindet `../Core` per Pfad ein, wie schon für die Änderungserkennung; `CalendarSchoolDay` ist dort direkt nutzbar und gegen das Beispiel unten getestet). Die App meldet ihre Tokens erst mit Schritt 2.

### Bau

- `Package.swift`: zweites Bibliotheksprodukt `NotyCalendarWidgets` (+ Ziel `NotyCalendarShared`), Linker-Workaround `-Xlinker -u -Xlinker _main` im Widget-Ziel. `xtool.yml` trägt deshalb `product: Noty`.
- **Standard-`xtool.yml` (noty, noty dev, noty AI und `xtool dev build` ohne Vorbereitung): ohne `extensions:` → keine `.appex`, kein `NSSupportsLiveActivities`, kein URL-Schema.** `NotyCalendarShared` wird mitgebaut, ActivityKit/WidgetKit sind gelinkt, `CalendarSchoolDayCenter` tut außerhalb von noty calendar (Kanal + `NSSupportsLiveActivities`) nichts. Geprüft: Standard-Build ohne `PlugIns/`.
- **noty calendar:** `publish_ota.sh` ruft nach `aps-environment` `scripts/calendar_build.py` auf: `extensions:` in `xtool.yml`, `NSSupportsLiveActivities(+FrequentUpdates)` und Schema `notycalendar` in `Info.plist`, Versionsnummern der App in `NotyCalendarWidgets.plist`; alles wird nach dem Build wiederhergestellt. Bundle-ID der Extension: App-ID + `.NotyCalendarWidgets`; xtool legt dafür eine eigene App-ID und ein eigenes Profil an.
- Nachweis des unsignierten Baus vom 08.11.2026 (`.appex` vorhanden, nicht leer, `CFBundleVersion` wie die App): wörtlich in [CALENDAR-LOG, Build 138](CALENDAR-LOG.md#build-138--live-activity-schultag-und-widget-heute-lokal-08112026).
- `ota_check.py` prüft jede `.appex` (ID unter App-ID, Versionen gleich, eigenes Profil zur eigenen ID, Gerät, Ablauf, Signatur lesbar, Programmdatei nicht leer, Entitlements vom eigenen Profil gedeckt, Versiegelung) und listet ihre signierten Entitlements; bei noty calendar fehlende Extension oder fehlendes `NSSupportsLiveActivities` = Problem.

### xtool #131 und Nachsignieren

Quelltext xtool 1.24.0 (`XKit/Signer/SignerImpl.swift`: „TODO #131 … temp hack to just pass along the root app entitlements“) und Zupersign (`asset.Init(… entitlements[0] …)`): **jede** Mach-O im Bundle, also auch die Extension, wird mit den Entitlements der App signiert – beim unsignierten Build und beim echten Signieren. `entitlementsPath` der Extension wird dabei ignoriert (lokal belegt: die ad-hoc-signierte `.appex` trägt `com.apple.developer.applesignin` und die App Group der App). Folgen beim echten Signieren:

1. xtool liest die Entitlements der Extension aus ihrer ad-hoc-Signatur und meldet ihre App-ID deshalb mit Sign in with Apple, App Group und Push an; ihr Profil erlaubt diese dann (wahrscheinlich unkritisch).
2. **Die Signatur der Extension enthält aber `application-identifier` der App** (`TEAM.…de.la.noty.calendar`), ihr Profil `TEAM.…de.la.noty.calendar.NotyCalendarWidgets`. Erwartet war, dass iPadOS die Installation deshalb ablehnt („invalid entitlements“/0xe8008016). **Das traf nicht zu:** Build 138 ließ sich laut Nutzer installieren; ob die Extension in diesem Zustand lief, ist ungeprüft. Das Nachsignieren (Punkt 3) bleibt der Weg, damit die Extension nur ihre eigenen Entitlements trägt. Belegt an Build 138 (`ota-check.json` vom 08.11.2026, damals mit der inzwischen entfernten Ausnahme `NOTY_ALLOW_APPEX_ENTITLEMENTS=1` veröffentlicht): Signatur `BAFXLQ964V.XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar`, Profil `….de.la.noty.calendar.NotyCalendarWidgets`; zusätzlich trug die Extension `applesignin`, `aps-environment` und die Schlüsselbundgruppe der App. `ota_check.py` meldet so etwas jetzt immer als Problem, `publish_ota.sh` bricht ab.
3. **Nachsignieren (umgesetzt 08.11.2026).** `publish_ota.sh` ruft nach `xtool dev build --sign --ipa` (und dem Zurücksetzen von `xtool.yml`/`Info.plist`) `python3 -I scripts/resign_extensions.py xtool/Noty.ipa .` auf, bei jedem Kanal; ohne `PlugIns/` tut das Skript nichts. Ablauf: IPA in einen privaten Temp-Ordner entpacken; je `.appex` Entitlements aus ihrem eigenen `embedded.mobileprovision` ableiten – `application-identifier`, `com.apple.developer.team-identifier`, `get-task-allow` aus dem Profil, `keychain-access-groups = [application-identifier]` (wie xtool es für die App setzt) und jeder Schlüssel aus `<Name>.entitlements` des Projekts, auf das Profil abgebildet (App Group `group.de.la.noty.shared` → `group.XTL-BAFXLQ964V.de.la.noty.shared`, wie xtool sie registriert); fehlt ein gewünschter Schlüssel im Profil, Abbruch. Dann zuerst die Extension signieren, danach die App mit `--shallow` und genau den Entitlements aus xtools App-Signatur neu signieren (innen nach außen: die `CodeResources` der App enthalten die Hashes der Extension-Dateien, auch ihrer neuen Programmdatei und `_CodeSignature/CodeResources`); `rcodesign verify` beider Programmdateien; Entitlements beider Signaturen gegen die Vorgabe vergleichen; IPA mit gleicher Reihenfolge/Attributen neu packen und atomar ersetzen. Jeder Fehler lässt das IPA unverändert und bricht die Veröffentlichung ab. Werkzeug: rcodesign 0.29.0 mit fester SHA-256 (docs/ENVIRONMENT.md), Schlüssel aus `~/.config/xtool/data/<TEAM>` nur als 0600-Temp-Datei.
   - **Profil der Extension enthält die App Group** (`group.XTL-BAFXLQ964V.de.la.noty.shared`), weil xtool die Extension-App-ID mit den aus der ad-hoc-Signatur gelesenen App-Entitlements anmeldet; es erlaubt daneben weiter `applesignin` und `aps-environment`, die die Extension aber nicht mehr verlangt. Ändert xtool das (z. B. Fix von #131) und fehlt die Gruppe im Profil, bricht das Skript mit „App Group … fehlt im Profil der Extension“ ab.
   - **Verworfen:** (a) xtool lokal patchen – braucht einen eigenen Swift-Bau von xtool samt Abhängigkeiten und einen geänderten Zupersign (C++, mehrere Entitlement-Sätze je Bundle); zu viel bewegliche Teile für einen Kanal. zsign-CLI aus dem Fork: signiert verschachtelte Bundles ebenfalls mit einem Signiersatz (`m_pSignAssets->front()`), müsste also auch geändert werden.
   - **Versiegelung:** Wie xtool/zsign versiegelt rcodesign die Extension in der App Datei für Datei (`files2`: Hashes von `PlugIns/…appex/*`), nicht Apple-typisch als `cdhash`-Eintrag. Signaturen von rcodesign tragen nur eine SHA-256-CodeDirectory (xtool: SHA-1 + SHA-256 alternativ); für iOS ≥ 11 und das Deploymentziel iOS 17 ausreichend. Anforderungen (Designated Requirement) und DER-Entitlements der App bleiben byte-gleich.
4. **Prüfung ohne Gerät:** `ota_check.py` prüft zusätzlich die Versiegelung (`seal_ok` für App und jede Extension): je CodeDirectory Kennung, Seitenhashes bis `codeLimit`, gebundene Info.plist/Anforderungen/CodeResources/Entitlements (XML und DER), nicht-leere CMS-Signatur, jede Datei gegen `_CodeSignature/CodeResources` (fehlend, falscher Hash, nicht versiegelt); ein `cdhash`-Eintrag einer Extension muss ihrer aktuellen CodeDirectory entsprechen. Die CMS-Kette prüft `rcodesign verify` im Nachsignierschritt. Gegenproben vom 08.11.2026 und das Ergebnis für die IPAs von noty, noty dev und noty AI: [CALENDAR-LOG, Build 139](CALENDAR-LOG.md#build-139--extension-nachsigniert-test-kachel-08112026).
5. **Probelauf und Veröffentlichung:** Probelauf vom 08.11.2026 (`NOTY_DRY_RUN=1`, Build 138) und der veröffentlichte Build 139 (`ota-check.json` ohne Befund, vom Nutzer installiert): [CALENDAR-LOG, Build 139](CALENDAR-LOG.md#build-139--extension-nachsigniert-test-kachel-08112026).

### Gerätetest

Der gebündelte Gerätetest steht seit 08.11.2026 bei Build 139 in [CALENDAR-LOG](CALENDAR-LOG.md#build-139--extension-nachsigniert-test-kachel-08112026): Installation und Test-Kachel sind vom Nutzer bestätigt, ein echter Schultag, Antippen, Widget, Ruhezeiten und der Start ab iPadOS 26 sind ungeprüft. Die Prüfpunkte der Korrekturen nach Build 139 (Kachel-Alert statt zweiter Mitteilung, 8-h-Neustart, Test-Kachel-Status nach Neustart) stehen unter „Ausstehend“ im selben Dokument.

## Normale noty (08.11.2026, Build 147)

Kachel „Schultag“ und Widget „Heute“ gibt es seit Build 147 auch in der **normalen noty**: `calendar_build.py` bettet die Extension für die Kanäle `stable` und `calendar` ein, `CalendarSchoolDayCenter.supported` lässt beide zu (`SchoolDayLink.calendarChannels`). Jede App hat ihr **eigenes Schema** für den Sprung aus Kachel und Widget (`noty://schultag…` bzw. `notycalendar://schultag…`, `SchoolDayLink.scheme(channel:)`), damit iPadOS nie die falsche App öffnet. Die Widget-Datei liegt je App unter `NotyWidgets/<Kanal>/` in der gemeinsamen App Group. Am iPad ungeprüft.
