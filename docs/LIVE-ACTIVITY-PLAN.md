# Live Activity „Schultag“ – Plan (08.11.2026)

Status: **Schritte 0, 1 und 3 implementiert und unsigniert gebaut (08.11.2026), nicht signiert, nicht installiert, am iPad ungeprüft.** Schritt 2 (Server) offen; sein Vertrag steht unten. Grundlage: Machbarkeitsprüfung vom 08.11.2026 (Apple-Doku, xtool 1.24.0-Quellen, lokaler unsignierter Probe-Build außerhalb des Repos).

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

## Entscheidungen des Nutzers (08.11.2026)

- **Inhalt:** Jetzt + Danach (Fach, Raum, Countdown), Tagesfortschritt („Stunde 3/6“), in Pausen/Freistunden „Pause · noch 12 Min.“ bzw. „Freistunde“. **Keine** Hausaufgabenzeile.
- **Start:** automatisch an jedem Schultag 30 Min. vor der ersten Stunde (nur an Tagen mit Unterricht).
- **Ende:** direkt nach der letzten Stunde.
- **Änderung tagsüber:** Kachel-Update mit Alert (weckt den Bildschirm); Ruhezeiten 21–6 gelten weiter.
- **Zusätzlich ein normales Widget** „Heute/Als Nächstes“ (Schritt 3) wird gewünscht.
- Abends-Vorschau „Morgen“ und Buttons: nicht gewählt.

Bauauftrag: Schritte 0, 1 und 3 am 08.11.2026 erteilt (Stand unten).

## Umsetzungsstand (08.11.2026)

**Implementiert und gebaut, nicht signiert, nicht installiert, am iPad ungeprüft.**

| Teil | Ort | Stand |
|---|---|---|
| Logik (rein, plattformunabhängig) | `Core/Sources/NotebookCore/CalendarSchoolDay.swift` | `SchoolDayLesson`, `SchoolDayPhase`, `SchoolDayAttributes`, `SchoolDayContentState`, `CalendarSchoolDay` (Phase, Stunden-Nr., Zustandswechsel, 8-h-Neustartplan), `SchoolDayWidgetFile`, `SchoolDayWidgetContent`; 15 XCTests in `CalendarSchoolDayTests` |
| Geteiltes Modul App + Extension | `Sources/NotyCalendarShared/SchoolDayShared.swift` | `SchoolDayAttributes: ActivityAttributes` (eine Konformanz für beide Binärdateien), Deep Link `notycalendar://schultag?connection=…&day=…&entry=…`, Widget-Datei in der App Group, Texte |
| Widget-Extension | `Sources/NotyCalendarWidgets/`, `NotyCalendarWidgets.plist`, `NotyCalendarWidgets.entitlements` | Live Activity (Sperrbildschirm nach Skizze, Dynamic-Island-Pflichtteil minimal) und Widget „Heute“ (`systemSmall`, `systemMedium`, `accessoryRectangular`), keine Bilder, keine Buttons, Dynamic Type bis `xLarge`, hell/dunkel über Systemfarben, Hinweis „Stand veraltet“ ab `staleDate` |
| App | `Sources/Noty/CalendarSchoolDayCenter.swift`, Aufruf am Ende von `rescheduleRemindersNow`, Deep Link in `WorkspaceAppModel.onOpenURL` → `CalendarNotificationHub.openSchoolDay` | Start/Update/Ende/8-h-Neustart lokal, Widget-Datei + `WidgetCenter.reloadTimelines`, Token-Beobachtung, Schalter im Blatt „Benachrichtigungen“ |
| Bau je Kanal | `scripts/calendar_build.py` (von `publish_ota.sh` nur bei `NOTY_CHANNEL=calendar` aufgerufen), `scripts/ota_check.py` | siehe „Bau“ |

### Verhalten

- **Tag:** Lessons des Tages aus dem Offline-Stundenplan des angezeigten Bereichs (nur geladener Tag; nicht geladen ≠ kein Unterricht). Für Beginn, Ende, Anzahl und Phase zählen nur **stattfindende** Stunden; exakt gleichzeitige Stunden (Gruppen) zählen einmal. Ausgefallene Stunden innerhalb des Tages bleiben als „Danach: … fällt aus“ sichtbar; ausgefallene vor der ersten/nach der letzten stattfindenden Stunde verschieben Beginn/Ende. Ohne stattfindende Stunde (Wochenende, Ferien, alles fällt aus): keine Kachel.
- **Phasen:** `before` (bis zur ersten Stunde), `lesson`, `break` (Pause), `free` (Freistunde), `done`. **Freistunde** = Lücke zwischen zwei stattfindenden Stunden, die mindestens so lang ist wie die kürzeste stattfindende Stunde des Tages (mindestens 30 Min.), **oder** in der eine ausgefallene Stunde liegt. Folge: eine lange Mittagspause erscheint als „Freistunde bis 13:30“. Sonst `break` („Pause · noch 12:00“).
- **„Stunde 3/6“:** Nummer der laufenden, sonst der nächsten stattfindenden Stunde; Anzahl = stattfindende Stunden.
- **Änderungsmarke:** „fällt aus“, „Vertretung“, „Raumwechsel“, „Vertretung, Raumwechsel“ (rot, `changed`), „Prüfung“ (neutral). WebUntis-Status außer REGULAR weiter real unbestätigt.
- **Zustandswechsel** (`transitions`): Start (30 Min. vor der ersten Stunde), jeder Beginn/jedes Ende einer stattfindenden Stunde, jeder Beginn einer ausgefallenen Stunde (die „Danach“-Zeile rückt weiter), Ende. Zwischen zwei Wechseln ist der Zustand konstant (getestet). Diese Liste ist auch der Zeitplan des Servers (Schritt 2).
- **8-h-Grenze:** `plan.restarts` = alle 7 h 45 min ab Start, solange vor dem Ende; dort endet die laufende Activity (`.immediate`) und eine neue beginnt (App merkt sich je Activity das Segment).
- **Start:** iPadOS 26+: die App merkt die Kachel des heutigen bzw. (nach Schulschluss) morgigen Schultags mit `Activity.request(…, start:)` für 30 Min. vor der ersten Stunde vor (die API verlangt eine `AlertConfiguration`: „Schultag · 1. Stunde 08:00: …“; liegt der Start in den Ruhezeiten, wird nicht vorgemerkt). Ändert sich die erste Stunde, wird die vorgemerkte ersetzt. Vor iPadOS 26 bzw. ohne Vormerkung: Start beim nächsten Update nach dem Startzeitpunkt, und iPadOS erlaubt `request` nur im Vordergrund (Fehler erscheint im Blatt).
- **Update:** bei jedem Abruf/Commit/Aktivwerden und im Vordergrund pünktlich zu jedem Wechsel. Eine echte Änderung der Stunden des Tages (nicht ein Phasenwechsel) geht mit Alert („Stundenplanänderung“, weckt den Bildschirm), in den Ruhezeiten ohne. Nach einem App-Neustart ist der Vergleichsstand leer: die erste Änderung danach kommt ohne Alert (die normale Änderungsmitteilung bleibt).
- **Ende:** beim ersten Update nach der letzten Stunde mit `.immediate`. **Lokale Grenze:** läuft noty zu diesem Zeitpunkt nicht, bleibt die Kachel bis zum nächsten App-Lauf stehen (bzw. bis iPadOS sie nach 8 h beendet) und zeigt ab `staleDate` „Stand veraltet“; zwischen zwei App-Läufen bleiben auch Phasenwechsel aus (der Countdown läuft trotzdem). Schritt 2 schließt das.
- **Schalter** „Schultag auf dem Sperrbildschirm“ (Blatt Benachrichtigungen, Standard an, Gerätepräferenz, nur noty calendar) mit Hinweis, wenn Live-Aktivitäten in den iPad-Einstellungen aus sind (`areActivitiesEnabled`), und Zeile „Läuft: …“.
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

Push-Hülle (Server): `{"aps":{"timestamp":<jetzt>,"event":"update","content-state":{…},"stale-date":<nächster Wechsel + 60>,"relevance-score":100}}`; Start per Push-to-start: `"event":"start","attributes-type":"SchoolDayAttributes","attributes":{…},"content-state":{…},"alert":{"title":"Schultag","body":"…"}`; Änderung zusätzlich `"alert":{"title":"Stundenplanänderung","body":"…"}` (außer Ruhezeiten); Ende: `"event":"end","dismissal-date":<jetzt>` mit letztem `content-state` (`phase":"done"`). Der Server berechnet Zustände und Zeitpunkte am besten mit derselben Logik (Swift-Paket `push/` kann `NotebookCore` nicht ohne Weiteres nutzen; sonst die Regeln oben 1:1 nachbauen und gegen das Beispiel testen). Die App meldet ihre Tokens erst mit Schritt 2.

### Bau

- `Package.swift`: zweites Bibliotheksprodukt `NotyCalendarWidgets` (+ Ziel `NotyCalendarShared`), Linker-Workaround `-Xlinker -u -Xlinker _main` im Widget-Ziel. `xtool.yml` trägt deshalb `product: Noty`.
- **Standard-`xtool.yml` (noty, noty dev, noty AI und `xtool dev build` ohne Vorbereitung): ohne `extensions:` → keine `.appex`, kein `NSSupportsLiveActivities`, kein URL-Schema.** `NotyCalendarShared` wird mitgebaut, ActivityKit/WidgetKit sind gelinkt, `CalendarSchoolDayCenter` tut außerhalb von noty calendar (Kanal + `NSSupportsLiveActivities`) nichts. Geprüft: Standard-Build ohne `PlugIns/`.
- **noty calendar:** `publish_ota.sh` ruft nach `aps-environment` `scripts/calendar_build.py` auf: `extensions:` in `xtool.yml`, `NSSupportsLiveActivities(+FrequentUpdates)` und Schema `notycalendar` in `Info.plist`, Versionsnummern der App in `NotyCalendarWidgets.plist`; alles wird nach dem Build wiederhergestellt. Bundle-ID der Extension: App-ID + `.NotyCalendarWidgets`; xtool legt dafür eine eigene App-ID und ein eigenes Profil an.
- Nachweis 08.11.2026 (unsigniert, `xtool dev build` nach `calendar_build.py`): `xtool/Noty.app/PlugIns/NotyCalendarWidgets.appex` (8,3 MB Debug), `LC_MAIN` auf den Import `_NSExtensionMain`, `T _main` vorhanden, `__text` 0x3cfa08 Byte, gelinkt gegen WidgetKit, ActivityKit, SwiftUI; Info.plist der Extension `CFBundleVersion` 137 wie die App, `NSExtensionPointIdentifier` `com.apple.widgetkit-extension`; App-Info.plist mit `NSSupportsLiveActivities` und Schema.
- `ota_check.py` prüft jede `.appex` (ID unter App-ID, Versionen gleich, eigenes Profil zur eigenen ID, Gerät, Ablauf, Signatur lesbar, Programmdatei nicht leer) und listet ihre signierten Entitlements; bei noty calendar fehlende Extension oder fehlendes `NSSupportsLiveActivities` = Problem.

### Risiko xtool #131 (verschärft)

Quelltext xtool 1.24.0 (`XKit/Signer/SignerImpl.swift`: „TODO #131 … temp hack to just pass along the root app entitlements“) und Zupersign (`asset.Init(… entitlements[0] …)`): **jede** Mach-O im Bundle, also auch die Extension, wird mit den Entitlements der App signiert – beim unsignierten Build und beim echten Signieren. `entitlementsPath` der Extension wird dabei ignoriert (lokal belegt: die ad-hoc-signierte `.appex` trägt `com.apple.developer.applesignin` und die App Group der App). Folgen beim echten Signieren:

1. xtool liest die Entitlements der Extension aus ihrer ad-hoc-Signatur und meldet ihre App-ID deshalb mit Sign in with Apple, App Group und Push an; ihr Profil erlaubt diese dann (wahrscheinlich unkritisch).
2. **Die Signatur der Extension enthält aber `application-identifier` der App** (`TEAM.…de.la.noty.calendar`), ihr Profil `TEAM.…de.la.noty.calendar.NotyCalendarWidgets`. Diese Abweichung lässt iPadOS die Installation sehr wahrscheinlich ablehnen („invalid entitlements“/0xe8008016). `ota_check.py` meldet das als Problem und `publish_ota.sh` bricht ab. Für den bewussten Gerätetest von Schritt 0 lässt `NOTY_ALLOW_APPEX_ENTITLEMENTS=1` genau diese Entitlement-Befunde der Extension als `warnings` durch (sonst nichts). Scheitert die Installation, bleibt die installierte Version unverändert.
3. Auswege, falls iPadOS ablehnt (nicht umgesetzt): (a) xtool mit Fix von #131 abwarten bzw. lokal patchen (Zupersign je Bundle eigene Entitlements), (b) nach `xtool dev build --sign --ipa` die `.appex` mit eigenem Entitlement-Plist (aus dem Profil der Extension) neu signieren und danach die App neu versiegeln – braucht Zugriff auf Schlüssel/Zertifikat aus `~/.config/xtool` und ein zsign-Werkzeug; Schlüssel nie ins Repo/Logs.

### Gebündelter Gerätetest (ungeprüft)

Vorher: Bibliotheksbackup in noty calendar ist nicht nötig (eigene Testdaten), App nicht löschen. `NOTY_CHANNEL=calendar NOTY_ALLOW_APPEX_ENTITLEMENTS=1 bash scripts/publish_ota.sh` (nach Commit, Buildnummer erhöht), `ota-check.json` lesen: `appex[0].application_identifier` (Signatur vs. Profil), `warnings`.

1. **Installation** über die Seite: klappt sie? (Nein → #131 bestätigt, Ausweg 3.) Danach App startet, Kalender/Push wie vorher.
2. Blatt Benachrichtigungen: Abschnitt „Schultag auf dem Sperrbildschirm“ an, kein Einstellungs-Hinweis.
3. An einem Schultag ab 30 Min. vor der ersten Stunde App öffnen → Kachel auf dem Sperrbildschirm: Fach · Raum, Countdown, Balken, „Stunde x/y“, „Danach“. Mit App im Vordergrund einen Stundenwechsel abwarten (Kachel springt pünktlich). App schließen: Kachel bleibt, Countdown läuft, nach dem Wechsel „Stand veraltet“ (erwartet ohne Schritt 2).
4. Antippen der Kachel öffnet noty calendar am Tag/an der Stunde.
5. Hell/dunkel, große Schrift, iPad quer/hoch.
6. Widget „Heute“ (klein, mittel, Sperrbildschirm) hinzufügen: richtige Stunde, wechselt ohne App-Start zur nächsten Stunde; nach Schulschluss „Schultag vorbei · Morgen …“.
7. Änderung (falls am Tag eine kommt): Alert weckt den Bildschirm, nicht in den Ruhezeiten.
8. Abends nach Schulschluss App öffnen (iPadOS 27): morgen früh startet die Kachel um „erste Stunde − 30 Min.“ von selbst mit Hinweis „Schultag“.
9. Schalter aus → Kachel weg; Verbindung trennen → Widget „Stundenplan nicht geladen“.

