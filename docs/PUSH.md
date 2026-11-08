# Push-Dienst für noty calendar

Stand 08.11.2026, Branch `feat/kalender`. **Server-Teil:** implementiert, getestet (`swift test --package-path push`, ohne Netzwerk: 46 Tests beim ersten Stand, 63 nach dem Review vom 08.11.2026), **auf dem VPS installiert und in Betrieb** (systemd, nginx-Pfade freigeschaltet, seit der Inbetriebnahme mit Build 137 am 08.11.2026; Review-Stand deployt 08.11.2026 12:49 UTC). Echter APNs-Versand belegt: Test-Push und `demo-push` zugestellt, vom Nutzer am iPad bestätigt. **Nicht belegt:** eine echte Stundenplanänderung über den Server, die Ruhezeit-Zusammenfassung, das Löschen beim Abmelden, das Verhalten nach dem Update. **App-Teil:** implementiert und gebaut, veröffentlicht ab noty calendar Build 137, vom Nutzer installiert (das Gerät hat sich registriert); die Korrekturen nach Build 139 (Commit `0fb2951`) sind gebaut, nicht installiert, am iPad ungeprüft. Nachweise je Build: [CALENDAR-LOG](CALENDAR-LOG.md#build-137--push-anbindung-und-server-noty-push-08112026).

Ziel (Nutzerentscheidung 08.11.2026): Stundenplanänderungen (Ausfall, Vertretung, Raumwechsel, verlegte Stunde) kommen als echte Mitteilung, auch wenn noty calendar geschlossen oder weggewischt ist. Das ist eine bewusste Abweichung von „Kein Backend“ in [CALENDAR-PLAN](CALENDAR-PLAN.md) §7: Nur für diesen Zweck liegt die Untis-Mobile-Freigabe **verschlüsselt** auf dem eigenen Server; „Trennen“ in der App löscht sie dort.

## Architektur

```
iPad (noty calendar) ──HTTPS──> nginx noty.xclipsen.de /push/v1/… ──HTTP──> 127.0.0.1:8795 noty-push
                                                                               │  stündlich (Zeitplan)
                                                                               ├─ curl ─> https://<schule>.webuntis.com (JSON-RPC, TOTP)
                                                                               └─ curl --http2 ─> api[.sandbox].push.apple.com
```

- **Ein Prozess, ein Schreiber.** `noty-push serve` (Swift, `push/`) enthält HTTP-API (SwiftNIO) und Abrufschleife; der Actor `PushService` ist der einzige Schreiber der Gerätedateien. Kein Timer-Prozess daneben, der konkurrierend schreibt.
- **Eine Quelle der Wahrheit mit der App.** `push/Package.swift` bindet `../Core` (NotebookCore) per Pfad ein: Freigabe-Prüfung (`WebUntisSetup`), Anfragekörper und TOTP (`WebUntis`, `TOTP`), Parser (`parseTimetableWithHomework`), Snapshot und Zusammenführung (`CalendarSourceSnapshot.merge`), Änderungserkennung (`CalendarChangeDetector.changes`, Datei `CalendarChanges.swift`), Mitteilungstext (`CalendarLessonChange.text`) und Ruhezeiten (`CalendarNotificationSettings.isQuiet`). Der Server schreibt keine eigene Diff-Logik.
- **Adapter.** `TimetableChangeDetecting` (push/Sources/NotyPushKit/ChangeDetection.swift) kapselt den Core-Aufruf in `CoreChangeDetector`; ändert sich die Core-API, wird nur dieser Adapter angepasst. Ein Test vergleicht IDs und Texte des Adapters direkt mit `CalendarChangeDetector`.
- **HTTP nach außen über das System-curl** statt FoundationNetworking: dieselbe TLS-/Zeitlimit-Behandlung für WebUntis und APNs, HTTP/2 über nghttp2 (curl 8.18 auf dem VPS), keine Laufzeitbibliotheken aus der Swift-Toolchain. URL, Header (JWT, Gerätetoken) und Körper (OTP) gehen ausschließlich über stdin als curl-Konfiguration (`curl -q -K -`): nichts Geheimes in der Prozessliste oder in Temp-Dateien; nur `https`, keine Weiterleitungen, Größen- und Zeitlimits.
- **Kryptographie** über swift-crypto: HMAC-SHA1 (TOTP), AES-256-GCM (Speicher), ES256 (APNs-JWT). Die Binärdatei wird mit `--static-swift-stdlib` gebaut und läuft ohne die Toolchain in `/home/la`.

Dateien: `push/Package.swift`, `push/Sources/NotyPushKit/*.swift`, `push/Sources/noty-push/main.swift` (CLI), `push/Tests/NotyPushKitTests/*.swift`, `push/deploy/` (systemd-Unit, Beispielkonfiguration, nginx-Vorschlag, `install.sh`).

### Ablauf je Gerät

1. **Registrierung** (`POST /v1/register`): Eingaben prüfen, Grenzen prüfen, dann **Testabruf** mit der Freigabe über das Fenster heute + 14 Tage. Nur bei vollständigem Erfolg wird das Gerät angelegt; dieser Abruf ist die **Basis** (keine Mitteilung, keine Flut). Abgelehnte oder unerreichbare Freigaben werden nicht gespeichert.
2. **Zeitplan** (Ortszeit des Geräts, Standard Europe/Berlin): Mo–Fr stündlich 5:00–20:59, Sa/So alle zwei Stunden 8–20 Uhr, **21:00–4:59 nie**. Jedes Gerät hat eine feste Minute 0–14 nach der vollen Stunde (verteilt die Last). Ein verpasster Termin (Server aus) wird nachts nicht nachgeholt, sondern auf das nächste Zeitfenster gelegt. Konfigurierbar (`schedule`).
3. **Abruf**: `getUserData2017` + `getTimetable2017` für [heute, heute+14). Nur eine vollständige, von Core validierte Antwort wird übernommen (`CalendarSourceSnapshot.mergeKeepingEmptiedDays`); Core vergleicht nur Tage, die beide Stände abdecken und die neu abgerufen wurden. Ein Tag mit Stunden, der leer zurückkommt, wird weder übernommen noch verglichen (eine leere Antwort ist keine Liste verschwundener Stunden; Folge: eine Zusatzstunde an einem bisher stundenfreien Tag wird nicht gemeldet). Stunden und Texte gelten in der Zeitzone der Verbindung (`connectionTimeZone`, Standard Europe/Berlin); die Gerätezeitzone (`timeZone`) bestimmt nur Zeitplan und Ruhezeit. Die Freigabe muss auf einen Host unter `allowedUntisHostSuffixes` zeigen (Standard `webuntis.com`, also `<schule>.webuntis.com`); andere werden vor jeder Anfrage abgelehnt. Daraus folgt (Regeln aus CALENDAR-PLAN §7, in Core umgesetzt und hier getestet): Fehler, Zeitüberschreitung, Teil-/Parsefehler → keine Änderung, Vergleichsstand bleibt; Fensterverschiebung → keine Änderung; **verschwundene Stunde ≠ Ausfall** (nur ausdrücklicher Status zählt); nur Stunden, die noch in der Zukunft beginnen.
4. **Mitteilung**: Neue Änderungen (ID noch nicht im Verlauf) außerhalb der Ruhezeit sofort: bis zu 3 Einzelmitteilungen, mehr als 3 als eine Zusammenfassung („6 Stundenplanänderungen“ + erste drei Zeilen + „…“).
5. **Ruhezeit** (Standard 21:00–6:00, vom Gerät übernehmbar): Änderungen werden gesammelt; ab Ende der Ruhezeit (6:00) **eine** Mitteilung – bei einer Änderung deren Text, sonst eine Zusammenfassung. Änderungen an Stunden, die bis dahin schon begonnen haben, verfallen (nur im Verlauf, `expired`). Entscheidung: Zusammenfassung statt stiller Zustellung, weil der Morgen der Zeitpunkt ist, an dem ein Ausfall noch nützt.
6. **Fehler/Backoff**: Fehlschläge in Folge verlängern den Abstand (15 min, verdoppelt, höchstens 12 h), immer innerhalb des Zeitplans. **Zweimal unmittelbar hintereinander „Anmeldung abgelehnt“/„Schule unbekannt“** (jeder erfolgreiche Abruf setzt den Zähler zurück) → Gerät `authFailed`, keine Abrufe mehr, **einmal** Mitteilung „Untis-Zugang prüfen“ (in der Ruhezeit morgens). Ein `PUT` mit neuer oder erneut gesendeter Freigabe macht es wieder aktiv (Testabruf, neue Basis).
7. **APNs**: 200 → zugestellt (an APNs, nicht unbedingt angezeigt). 410 oder `BadDeviceToken`/`Unregistered`/`DeviceTokenNotForTopic` → Gerät `tokenInvalid`, keine Abrufe mehr, bis die App per `PUT` einen neuen Token meldet. 429/5xx/Netz → nach 10 min erneut, höchstens 3 h lang. `ExpiredProviderToken` → JWT einmal erneuern. Konfigurationsfehler des Dienstes (403, z. B. `InvalidProviderToken`, oder 400 `BadTopic`/`TopicDisallowed`/`MissingTopic`/`BadCertificate(Environment)`; `providerError`) verwerfen nichts und schalten kein Gerät ab: Die Mitteilungen bleiben `pending` (bis zum Beginn der Stunde), der Versand pausiert ab 10 min, verdoppelt, höchstens 3 h, und das Log nennt die zu prüfenden Einstellungen.
8. **Aufräumen**: Geräte, die 30 Tage inaktiv (`authFailed`/`tokenInvalid`) sind, werden gelöscht (`inactiveRetentionDays`); ebenso jedes Gerät ohne authentifizierten Kontakt der App seit 45 Tagen (`noContactRetentionDays`; die App fragt `GET /v1/changes` bei jedem Öffnen des Kalenders und meldet sich nach einem 401 neu an). Verlauf: höchstens 200 Einträge, 60 Tage. Snapshot: nur ab vorgestern, ohne Hausaufgaben und Ferien.

### Änderungs-IDs und Entdoppeln mit der App

Die ID ist `CalendarLessonChange.id` aus Core, z. B. `change.<periodenID>.<datum>.<arten>.<start>.<räume>`. Dieselbe Änderung nach einer anderen dazwischen („Ausfall“ → „findet wieder statt“ → „Ausfall“) wird mit Endung `~2`, `~3` … erneut eingetragen (`CalendarChangeRepeats`, je Herkunft; vorher hätte das Entdoppeln über die ID sie verschluckt). Server und App bilden sie mit demselben Core-Code aus denselben Stunden (Verbindungs-ID = `CalendarConnectionRecord.id`), sie ist also bei gleichem Vergleichspaar identisch. Der Server liefert die **rohe** ID (`changeID`) plus `connectionID`; die App setzt Präfix und Bereich selbst. **Umgesetzt (abweichend vom ersten Entwurf):** Server-Einträge bekommen in der Glocke `CalendarNotificationLog.changePrefix + namespace + ".push." + changeID` (`pushChangeID`), eigene bleiben `… + namespace + "." + id`. Grund: Die Arten hängen vom Vergleichspaar ab (Server vergleicht stündlich, die App mit ihrem letzten Stand: dort „Raumwechsel“ und eine Stunde später „Vertretung“, hier „Raumwechsel, Vertretung“), die IDs stimmen dann **nicht** überein. Entdoppelt wird deshalb über `CalendarNotificationLog.changeMatchKey` (Periode, Tag, Beginn, Räume, Kategorie Ausfall/findet wieder statt/sonstige Änderung – ohne die Arten), und zwar **nur zwischen den Herkünften** (App ↔ Server, `addChanges`): Innerhalb einer Herkunft ist ein zweiter Eintrag derselben Stunde eine weitere Änderung und bleibt. Der zuerst eingetragene gewinnt; Antippen markiert beide Herkünfte als gelesen (`relatedChangeIDs`). Getestet in `CalendarNotificationTests.testPushEntriesAndAppEntriesAreDeduplicatedAcrossOrigins`. Zusätzlich zeigt die App bei aktivem Push **keine eigenen lokalen Änderungsmitteilungen** (nur Verlauf).

## HTTP-API

Basis öffentlich: `https://noty.xclipsen.de/push/v1/` (nginx entfernt `/push`). Antworten JSON, Zeiten als Unix-Sekunden, Fehler `{"error": "<code>", "message": "<deutscher Satz>"}`. Authentifizierung: `Authorization: Bearer <deviceID>.<deviceSecret>`. Körper höchstens 16 KiB, `Content-Type: application/json`. Jede 429-Antwort trägt `Retry-After` (Sekunden); die App wartet so lange (höchstens 6 h), auch bei „Erneut versuchen“. Ein 401 mit `unauthorized` heißt: Der Server kennt das Gerät nicht (mehr).

| Methode, Pfad | Zweck | Erfolg | Fehler |
| --- | --- | --- | --- |
| `GET /v1/health` | Erreichbarkeit | 200 `{"ok":true}` | – |
| `POST /v1/register` | Gerät + Freigabe anlegen | 201 `{deviceID, deviceSecret, status}` | 400 `invalid_*`/`consent_required`, 403 `limit_reached`, 422 `untis_rejected`, 429, 502 `untis_unavailable` |
| `PUT /v1/device` | Token/Umgebung/Einstellungen ändern, Freigabe ersetzen | 200 `{status}` | 400, 401, 422, 502 |
| `DELETE /v1/device` | abmelden, **alles löschen** | 204 | 401 |
| `GET /v1/device` | Status | 200 `{status}` | 401 |
| `GET /v1/changes?since=<unix>` | Verlauf für die Glocke (ohne `since`: alles, max. 60 Tage) | 200 `{changes, status, serverTime}` | 400, 401 |

`POST /v1/register`:

```json
{
  "deviceToken": "<hex vom APNs>",
  "apnsEnvironment": "sandbox",
  "bundleID": "XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar",
  "connectionID": "<UUID der Kalenderverbindung (CalendarConnectionRecord.id)>",
  "timeZone": "Europe/Berlin",
  "consent": "webuntis-push-1",
  "setup": {"server": "…", "school": "…", "user": "…", "key": "…", "schoolNumber": "…"},
  "settings": {"changes": true, "quietHours": true, "quietStart": 1260, "quietEnd": 360}
}
```

Optional `connectionTimeZone` (Zeitzone der Stunden der Verbindung, `CalendarConnectionRecord.timeZone`; fehlt = Europe/Berlin). `settings` ist dieselbe Struktur wie `CalendarNotificationSettings` (tolerant; weitere Schlüssel werden ignoriert). `deviceSecret` gibt es **nur in dieser Antwort**; der Server speichert nur dessen SHA-256. Registriert sich dasselbe Gerät (gleicher Token + Bundle-ID) erneut, ersetzt der neue Eintrag den alten (keine Doppelmitteilungen). `PUT /v1/device` nimmt dieselben Felder optional; `setup` nur zusammen mit `consent`. Neue Freigabe, `connectionID` oder Zeitzone → neuer Testabruf und neue Basis.

`status`: `{deviceID, state: active|authFailed|tokenInvalid, environment, connectionID, lastPoll, lastSuccess, nextPoll, lastError, baselineAt}`. `changes[]`: `{id, kinds[], title, body, detected, day ("YYYY-MM-DD"), entryID (CalendarLesson.id), periodID, lessonStart, delivery: sent|summarized|pending|expired|disabled|failed}`.

### Push-Inhalt

```json
{"aps": {"alert": {"title": "Stundenplanänderung", "body": "Di 10.11., 08:00 Deutsch fällt aus"},
         "sound": "default", "thread-id": "noty.calendar.changes.<connectionID>"},
 "noty": {"kind": "change", "connectionID": "…", "changeID": "…", "changeIDs": ["…"], "periodID": "77",
          "day": "2026-11-10", "entryID": "webuntis/<connectionID>/77/2026-11-10T08:00", "lessonStart": 1794380400}}
```

Header: `apns-push-type: alert`, `apns-priority: 10`, `apns-topic: <bundleID>`, `apns-expiration: <Beginn der Stunde>` (danach verwirft APNs die Mitteilung), `apns-collapse-id: <changeID>` (über 64 Byte: `h.` + SHA-256-Präfix). Zusammenfassung: `kind: "summary"`, `changeIDs` (bis 20), `day`/`entryID` der frühesten Stunde. Zugangshinweis: `kind: "auth"`. Testmitteilung: `kind: "test"`. Text gemäß Core: Fach, Zeit, Raum – sichtbar auf dem Sperrbildschirm (die Vorgabe „Do 2. Std. …“ wird nicht umgesetzt, weil Core die Stunde über die Uhrzeit benennt).

## APNs-Topic, Umgebung, Schlüssel

- **Topic = `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar`.** Geprüft am 08.11.2026 an `xtool/Noty.ipa` (Build 134, noty calendar) in diesem Worktree: `CFBundleIdentifier` im signierten Info.plist ist genau diese ID. Herleitung: `scripts/publish_ota.sh` setzt für `NOTY_CHANNEL=calendar` `BASE_ID=de.la.noty.calendar` und baut mit `bundleID: XTL-BAFXLQ964V.de.la.noty.calendar`; xtool stellt beim Signieren nochmals `XTL-BAFXLQ964V.` voran (wie in [ENVIRONMENT](ENVIRONMENT.md) für noty beschrieben). Die `application-identifier` im Profil trägt zusätzlich die Team-ID (`BAFXLQ964V.XTL-…`) – das ist **nicht** das Topic. Andere Kanäle: `…de.la.noty.dev`, `…de.la.noty.ai`, `…de.la.noty.prototype`; nur in `allowedBundleIDs` eingetragene Topics werden angenommen.
- **Umgebung:** Die Builds sind development-signiert (`get-task-allow = true` im Profil von Build 134) → `aps-environment = development` → Token gilt nur für **`api.sandbox.push.apple.com`**. Die App meldet `apnsEnvironment` je Gerät (`sandbox` bzw. später `production`); ein Token der falschen Umgebung führt zu `BadDeviceToken` → `tokenInvalid`.
- **Schlüssel:** APNs-Authentifizierungsschlüssel (.p8) im Apple-Developer-Konto (Team BAFXLQ964V) anlegen: *Certificates, Identifiers & Profiles → Keys → +*, „Apple Push Notifications service (APNs)“, Umgebung „Sandbox & Production“. Key-ID (10 Zeichen) in `/etc/noty-push/config.json` (`apnsKeyID`), Datei nach `/etc/noty-push/apns.p8` (root, 0600). Ein Schlüssel gilt für alle Apps des Teams.

## Datenschutz und Speicherung

- Gespeichert je Gerät, als **eine** Datei `/var/lib/noty-push/devices/<id>.sealed` (AES-256-GCM, Kontext an die Geräte-ID gebunden; Verzeichnis 0700, Datei 0600, Dienstbenutzer `noty-push`): Freigabe (Server, Schule, Benutzer, Schlüssel), Gerätetoken, Umgebung, Bundle-ID, Verbindungs-ID, Zeitzone, Einstellungen, SHA-256 des Gerätesecrets, Vergleichs-Snapshot (Stunden der letzten 2 bis nächsten 14 Tage), Änderungsverlauf (max. 200/60 Tage), Abrufstatus.
- Schreiben atomar: Temp-Datei (0600, `O_EXCL`) → `fsync` → `rename` → `fsync` des Ordners. Unlesbare Dateien werden gemeldet und **liegen gelassen**, nie gelöscht.
- Datenschlüssel `/etc/noty-push/data.key` (root, 0600), per systemd `LoadCredential` nur dem Dienst sichtbar. Ohne diese Datei ist `/var/lib/noty-push` unlesbar: **beide getrennt sichern**, sonst sind die Daten nach Verlust des Schlüssels weg (dann neu registrieren).
- Logs (journald) enthalten nur Kategorien, Anzahlen, HTTP-Status und die ersten 8 Zeichen der Geräte-ID – nie Token, Freigabe, Secret oder Mitteilungstext. curl-stderr wird verworfen (könnte die URL mit Token enthalten). nginx loggt Pfade, nicht den Authorization-Header.
- Lesen über die API nur mit Gerätesecret; Antworten enthalten die Freigabe nie.
- Missbrauchsschutz: höchstens `maxDevices` = 5 Geräte insgesamt, 5 Registrierungsversuche/Stunde je IP, 20 **erfolgreiche** Registrierungen/Tag gesamt (ungültige Anfragen verbrauchen das Tageslimit nicht), 60 Anfragen/Minute je IP, 120 **fehlgeschlagene** Anmeldungen/Stunde je Geräte-ID (danach 429 statt 401, damit die App ihr Secret nicht löscht), 16 KiB Körper, 30 s Leerlauf, Verarbeitung einer Anfrage höchstens 150 s (eine Registrierung ruft WebUntis zweimal mit je bis zu 40 s ab; nginx wartet 120 s). Nur WebUntis-Hosts unter `allowedUntisHostSuffixes`. Dienst lauscht nur auf 127.0.0.1 (weigert sich sonst zu starten); TLS nur über nginx.
- **Abmelden/Trennen**: `DELETE /v1/device` löscht die Datei sofort (inklusive Freigabe und Verlauf). Backups des VPS können ältere Kopien enthalten – verschlüsselt, ohne `data.key` unbrauchbar.

## Betrieb

Bauen und testen (Session ist root, deshalb als `la`):

```bash
cd /home/la/workspace/noty-kalender
runuser -u la -- bash -c '. ./scripts/env.sh >/dev/null 2>&1; swift test --package-path push'
```

Installieren bzw. aktualisieren (ausgeführt am 08.11.2026 zur Inbetriebnahme und erneut für den Review-Stand, 12:49 UTC):

```bash
sudo push/deploy/install.sh   # baut statisch, legt Benutzer/Ordner/data.key/config.json an, Unit installieren
# apnsKeyID in /etc/noty-push/config.json eintragen, .p8 nach /etc/noty-push/apns.p8 (chmod 600)
sudo push/deploy/install.sh   # zweiter Lauf: prüft (noty-push check) und startet
```

`install.sh` ist idempotent, überschreibt weder `data.key` noch `config.json` noch `apns.p8`, startet nur mit vorhandenem .p8 und erfolgreichem `noty-push check` (ausgeführt per `systemd-run` als Dienstbenutzer mit `LoadCredential`, ohne Kopie der Schlüssel in `/tmp`), und **verändert nginx nicht** (kopiert nur die Vorschläge nach `/etc/nginx/noty-push.conf` und `/etc/nginx/noty-push-proxy.conf`).

**nginx freischalten** (von Hand, mit `nginx -t`; am 08.11.2026 erledigt): im 443-Block von `/etc/nginx/sites-enabled/noty.xclipsen.de` vor `location / { return 404; }` `include /etc/nginx/noty-push.conf;` einfügen, die Rohpfad-Prüfung (`if ($request_uri !~ …)`) um `|push/v1/(health|register|device|changes)` erweitern und `limit_req_zone $binary_remote_addr zone=notypush:1m rate=30r/m;` im http-Kontext anlegen. Details als Kommentar in `push/deploy/nginx-noty-push.conf`. Danach `curl https://noty.xclipsen.de/push/v1/health`.

Werkzeuge (als root mit den Credentials, z. B. `systemd-run -P -p User=noty-push -p LoadCredential=data.key:/etc/noty-push/data.key -p LoadCredential=apns.p8:/etc/noty-push/apns.p8 -p ReadWritePaths=/var/lib/noty-push /opt/noty-push/noty-push status`):

- `noty-push check` – Konfiguration, Schlüssel, Ablage, JWT-Erzeugung.
- `noty-push status` – Geräte (ID, Zustand, Umgebung, letzter Erfolg, nächster Abruf, Fehler, Verlauf) ohne Geheimnisse.
- `noty-push test-push <deviceID>` – Testmitteilung „Testmitteilung des Mitteilungsdienstes.“ (beweist Topic, Umgebung und Schlüssel).
- `noty-push genkey` – neuer Datenschlüssel.

Logs: `journalctl -u noty-push`, nginx: `/var/log/nginx/noty-push.log`. Die Unit läuft gehärtet (u. a. `SystemCallFilter=@system-service`, `PrivateUsers=yes`). `noty-push`-CLI als Dienstbenutzer aus einem für ihn lesbaren Arbeitsverzeichnis starten (z. B. `cd /`), sonst scheitert der curl-Aufruf mit „Permission denied“. `noty-push demo-push <deviceID>` schickt jede Mitteilungsart einmal mit Beispieltexten (`kind: test`).

**Datenschlüssel rotieren:** `noty-push genkey` erzeugen, als **erste** Zeile in `/etc/noty-push/data.key` einfügen, alte Zeile darunter lassen, Dienst neu starten. Jede Datei wird beim nächsten Schreiben (spätestens beim nächsten Abruf) mit dem neuen Schlüssel versiegelt. Nach einem Tag mit `noty-push status` prüfen, dass alles lesbar ist, dann die alte Zeile entfernen und neu starten. **APNs-Schlüssel rotieren:** neuen .p8 anlegen, Datei ersetzen, `apnsKeyID` ändern, neu starten; alten Schlüssel danach bei Apple widerrufen.

Abmelden aller Geräte/Stilllegen: `systemctl disable --now noty-push`, `rm -rf /var/lib/noty-push/devices` (löscht alle Freigaben), nginx-Include entfernen.

## Grenzen und Risiken

- **Inoffizieller WebUntis-Zugang** (Untis-Mobile-Freigabe, CALENDAR-PLAN §7). Schule oder Untis können ihn jederzeit ändern oder sperren; der Server meldet das dann einmal als „Untis-Zugang prüfen“. Stündlicher Abruf von einer Server-IP statt vom iPad kann von der Schule anders bewertet werden (Rate-Limits, Sperre) – unbekannt.
- **WebUntis-Status:** Welche `is`-Werte die Schule außer `REGULAR` liefert, ist offen ([CALENDAR-PLAN §9](CALENDAR-PLAN.md#9-offene-punkte)). Weil nur ausdrückliche Status zählen, heißt das im Zweifel: weniger Mitteilungen, keine erfundenen.
- **Zustellung nicht garantiert:** APNs „200“ heißt angenommen, nicht angezeigt (Fokus, Mitteilungen aus, Gerät offline > Ablauf). Mindestverzögerung bis zu einer Stunde (Zeitplan) plus Minute 0–14.
- **Sandbox vs. Produktion:** Development-Builds → nur Sandbox-Token. Ein späterer Ad-hoc-/App-Store-Build hätte `production`; die App muss die Umgebung dann korrekt melden. Sandbox-Zustellung ist erfahrungsgemäß weniger zuverlässig.
- **Bundle-ID-Abhängigkeit:** Ändert sich das xtool-Präfixverhalten oder der OTA-Weg, ändert sich das Topic → `DeviceTokenNotForTopic`. `allowedBundleIDs` und die gemeldete `bundleID` müssen dann angepasst werden.
- **Ein Prozess, kleine Größe:** ausgelegt für ≤ 5 Geräte; Abrufe laufen nacheinander. Ratenlimits liegen im Speicher (Neustart setzt sie zurück).
- **Belegt:** Dienst läuft unter systemd mit den Hardening-Optionen (auch nach dem Review-Update, Health-Check 08.11.2026 12:56 UTC), nginx-Weiterleitung, echte APNs-Zustellung (Test-Push, `demo-push`), Testabruf der Freigabe vom Server aus bei der Registrierung. **Ungeprüft:** echte Stundenplanänderung über den Server, Ruhezeit-Zusammenfassung um 6 Uhr, Löschen beim Abmelden, Weiterbetrieb des schon registrierten Geräts nach dem Update (ohne gemeldete `connectionTimeZone` gilt Europe/Berlin).

## Nachträge aus dem Gegen-Review (08.11.2026, deployt 13:40 UTC)

- **Registrierung idempotent:** `POST /v1/register` nimmt optional `registrationID` (UUID; Server speichert nur den SHA-256-Hash als `registrationHash`, Gerätedatei bleibt Version 1). Dieselbe ID (gleiche Bundle-ID) liefert dasselbe Gerät mit neuem Secret, das alte wird ungültig, der Verlauf bleibt. Läuft dieselbe ID noch: `409 registration_in_progress` mit `Retry-After: 60`; zurückgezogen: `410 registration_cancelled`; ungültig: `400 invalid_registrationID`.
- **Löschen per ID:** `DELETE /v1/device` mit `Authorization: Registration <registrationID>` antwortet immer `204` (gelöscht, zurückgezogen oder unbekannt). Die App nutzt das bei „Aus“, „Trennen“, Bereich löschen und ausgeschalteten Änderungen, wenn eine Registrierung unklar endete. App-Zeitlimit für Registrierung/neue Freigabe 130 s, sonst 20 s; unklarer Ausgang → Wiederholung nach 3 Minuten mit derselben ID.
- **Lebenszeichen:** Die App schickt höchstens einmal täglich `GET /v1/device` (Start, Hintergrundabruf, Aktivieren eines anderen Bereichs). Aufbewahrung ohne Kontakt jetzt **120 Tage** (`noContactRetentionDays`).
- **Ratenbegrenzung:** eigener Begrenzer je Kategorie mit eigenem Zeitfenster, höchstens 10 000 Schlüssel je Kategorie (Überlauf verwirft die am längsten inaktiven), IPv6 je /64, IPv4-mapped wie IPv4, global `registrationAttemptsPerHour` = 60 (auch ungültige Versuche).
- **APNs:** Topic-/Umgebungsfehler (`BadTopic`, `TopicDisallowed`, `MissingTopic`, `BadCertificateEnvironment`, `BadEnvironmentKeyInToken`) pausieren nur das betroffene Gerät (10 min, verdoppelt, höchstens 3 h); nur Schlüssel-/JWT-Fehler pausieren global.
- **App:** Das Raster wartet nie auf den Server. Nur wenn lokal Änderungen gefunden wurden, fragt die App den Serververlauf (höchstens 5 s, nach Fehler 10 Minuten Pause). `429` lässt den Push-Status aktiv („Der Mitteilungsdienst bittet um eine Pause bis HH:MM“). Meldet die Schultag-Kachel eine Änderung, liegt die Mitteilung trotzdem still (`.passive`) in der Mitteilungszentrale.
- **Core:** Ein komplett verlegter Tag gilt nicht als leere Antwort, wenn seine Perioden-IDs im selben Abruf an einem anderen Tag auftauchen. Wiederholungen werden über beide Herkünfte (App und Server) erkannt. In Änderungs-IDs wird „~“ in Raumnamen als „%7E“ geschrieben; IDs ohne „~“ bleiben gleich.
- Tests: Core 1497 (3 übersprungen), push 71, alle grün. Der Abruf um 13:14 UTC lief unter der neuen systemd-Härtung (SystemCallFilter, PrivateUsers) fehlerfrei.

## Nachträge aus der Gesamtprüfung (08.11.2026, Build 145)

Unabhängige Durchsicht des Servers (71 Tests grün, nicht gegen den laufenden Dienst getestet). **Deployt** mit Stand `09d63f8` am 08.11.2026 um 20:59 UTC (`install.sh`, Dienst aktiv, Health-Check ok, `MemoryHigh`/`OOMPolicy` wirksam laut `systemctl show`). Umgesetzt:

- **Gleichzeitige Testabrufe begrenzt:** höchstens 2 WebUntis-Testabrufe (Registrierung oder neue Freigabe) zur gleichen Zeit (`PushService.maximumConcurrentBaselines`); weitere bekommen `503 busy` mit `Retry-After: 30`. Vorher konnten ~20 parallele Anmeldungen mit gültig geformten Freigaben (Wildcard-DNS von webuntis.com) je zwei curl-Prozesse starten und das `MemoryMax` von 256 MB reißen; `OOMPolicy=stop` hätte den Dienst beendet und der Neustart alle Limiter geleert.
- **Unit:** `MemoryHigh=192M` (Drosselung vor dem Limit) und `OOMPolicy=continue` (ein getöteter curl-Kindprozess nimmt den Dienst nicht mit).
- **`apns-collapse-id`** nur noch aus `[A-Za-z0-9._-]` (≤ 64 Byte), sonst gehasht – Raumnamen mit Leerzeichen/Umlauten könnten sonst von APNs als `BadCollapseId` abgelehnt werden und die Mitteilung endgültig fehlschlagen lassen.
- **Einstellungen geprüft:** `settings` mit ungültigen Ruhezeiten/Werten werden bei Registrierung und Update mit `400 invalid_settings` abgewiesen (vorher stillschweigend übernommen, mögliche Dauer-Ruhezeit).
- **Registrierungs-ID verfällt** beim ersten authentifizierten Kontakt des Geräts: Wer sie kennt, kann das Gerät dann nicht mehr unauthentifiziert löschen.

Bewusst nicht geändert: Nach 120 falschen Secrets je Geräte-ID und Stunde antwortet der Server auch dem richtigen Secret mit 429 (nie 401), damit die App es behält – wer die (nicht öffentliche) Geräte-ID kennt, könnte so eine Stunde Wartezeit erzwingen. Offen: Limiter leben im Speicher und starten nach einem Neustart leer.

## Was in der App umgesetzt ist (App-Anbindung)

Stand 08.11.2026: Schritte 1–11 **implementiert und gebaut**, veröffentlicht ab noty calendar **Build 137** und vom Nutzer installiert (Registrierung, Test-Push angekommen); die Korrekturen nach Build 139 (Commit `0fb2951`, in der Tabelle mit „seit 0fb2951“ markiert) sind gebaut, **nicht installiert, am iPad ungeprüft**. Gerätetest: [CALENDAR-LOG](CALENDAR-LOG.md). Code: `Sources/Noty/CalendarPushClient.swift` (Konfiguration, Schlüsselbund, Zustand, HTTP, Abgleich), `CalendarPushViews.swift` (Einwilligung, Abschnitt „Auch bei geschlossener App“), Anbindung in `CalendarNotificationHub` (Payload `userInfo["noty"]`, Antippen, Vordergrund), `CalendarModel(+Notifications)` (Unterdrücken, Zusammenführen, Verbinden/Trennen), `CalendarReminderCenter` (zugestellte Pushes in Glocke/entfernen), `CalendarView`, `CalendarConnectionSheet`, `CalendarRemindersSheet`, `WorkspaceAppModel`, `NotyApp` (`NotyAppDelegate` für den Token), `Info.plist` (`NotyPushURL`), Core `CalendarNotifications.swift` (Push-IDs, Entdoppeln), `scripts/publish_ota.sh`, `scripts/ota_check.py`.

| Schritt | Stand |
| --- | --- |
| 1 Entitlement | **Nur für noty calendar**: Die eingecheckte `Noty.entitlements` bleibt **ohne** `aps-environment`; `publish_ota.sh` ergänzt `aps-environment = development` nur bei `NOTY_CHANNEL=calendar` in die Arbeitskopie (wie `xtool.yml`/`Info.plist`, danach zurückgesetzt). So brauchen die Profile von noty, noty dev und noty AI die Fähigkeit nicht und `ota_check` bricht dort nicht. `ota_check.py` meldet jetzt `aps_environment` (Signatur, Profil, verlangt) und verlangt für IDs auf `.de.la.noty.calendar` (oder `--push`) den Eintrag in Signatur **und** Profil mit gleichem Wert; sonst `problems` → kein Veröffentlichen. Gegen das vorhandene `xtool/Noty.ipa` (Build 136, noch ohne Push) geprüft: meldet beide fehlenden Einträge, mit `--no-push` keine Probleme. **Belegt mit Build 137:** xtool 1.24 schaltet die Fähigkeit für die App-ID selbst ein (`aps-environment = development` in Signatur und Profil, `ota_check` ohne Probleme; ebenso Build 139). Ein `xtool dev build` ohne `publish_ota.sh` enthält kein Push. |
| 2 Info.plist | `NotyPushURL` = `https://noty.xclipsen.de/push` (Pfade `v1/…` laut nginx-Vorschlag). Keine Hintergrundmodi. Push nur, wenn `NotyChannel = calendar`, die URL gesetzt ist und das eingebettete Profil `aps-environment` trägt; sonst zeigt „Mitteilungen“ „nicht verfügbar“ (bzw. in anderen Apps nichts). |
| 3 Token | `NotyAppDelegate` (`@UIApplicationDelegateAdaptor`): `registerForRemoteNotifications` beim Start, sobald Push gewünscht ist, und beim Einschalten; Token als Hex nur im Speicher. Umgebung aus dem Profil: `development` → `sandbox`, `production` → `production`. `bundleID` = `Bundle.main.bundleIdentifier`. |
| 4 Einwilligung | Wortgleicher Text, Version `webuntis-push-1`, als Dialog „Mitteilungen auch bei geschlossener App?“ mit „Zustimmen“/„Nicht jetzt“: nach erfolgreichem „Verbinden“ (einmal, solange nie entschieden) und beim Einschalten des Schalters ohne gültige Einwilligung. Ohne „Zustimmen“ wird nichts hochgeladen, alles bleibt lokal. |
| 5 Registrieren | `POST /v1/register` nur mit Einwilligung, Erlaubnis für Mitteilungen, Token und Freigabe im Schlüsselbund. `deviceID`+`deviceSecret` als **ein** Schlüsselbundeintrag (`noty.calendar.push`, `AfterFirstUnlockThisDeviceOnly`), nie in Dateien/UserDefaults/Backups. Nicht-geheimer Zustand (gewünscht, Einwilligungsversion, Verbindung/Bereich, zuletzt gesendete Werte, Serverstatus, `since`, ausstehende Abmeldung) in `UserDefaults` (`noty.calendar.push.state`). Fehler deutsch (Servertext; 403 als „Mitteilungsdienst voll“, Netz-/HTTP-Fehler eigene Sätze). Nach einem Fehlschlag automatische Versuche frühestens nach 30 min (Server begrenzt Registrierungen), „Erneut versuchen“ sofort. Ein Secret ohne bekannte Registrierung (Neuinstallation, der Schlüsselbund überlebt sie) wird vorher abgemeldet. |
| 6 Aktualisieren | `PUT /v1/device` nur mit geänderten Feldern: Token, Umgebung, Einstellungen, Zeitzone; neue Freigabe derselben Bereichsverbindung („Mit anderer Freigabe verbinden“) → `connectionID` + `setup` + `consent`. Bei `authFailed` sendet die App dieselbe Freigabe erneut (+ `consent`), sobald sie selbst WebUntis damit erreicht (höchstens alle 6 h, oder über „Mit der vorhandenen Freigabe erneut versuchen“) – dafür im Server behoben, siehe unten. Bei `tokenInvalid` geht der Token beim nächsten Start bzw. „erneut versuchen“ noch einmal hin. 401 → Secret löschen, neu registrieren. |
| 7 Abmelden | Schalter aus, „Stundenplanänderungen“ aus, „Trennen“ und (seit 0fb2951) Löschen des Bereichs, zu dessen Verbindung Push gehört → `DELETE /v1/device`; Secret erst gelöscht, wenn der Server bestätigt, dass nichts mehr da ist: 204 oder ein 401 mit `unauthorized` von noty-push (seit 0fb2951; ein anderer 401, etwa von einem Proxy, beweist nichts). 429 → erst nach `Retry-After` erneut. Offline: `pendingDelete`, Wiederholung beim nächsten Start/Aktivieren; Blatt und „Trennen“ sagen „noch nicht gelöscht“ statt „gelöscht“. Nach „Trennen“ wird bei der nächsten Verbindung erneut gefragt. |
| 8 Glocke | `GET /v1/changes?since=<ganze Sekunden>` beim Laden des Kalenders, beim Aktivieren der App, beim Öffnen der Glocke und bei Push im Vordergrund/Antippen (höchstens alle 20 s, außer erzwungen); nur wenn `status.connectionID` die Verbindung dieses Bereichs ist. Nächstes `since` = `serverTime` − 120 s (Überlappung, entdoppelt über IDs). Einträge wie oben (`pushChangeID`). |
| 9 Keine Doppelten | `CalendarPushClient.isActive(for:)`: gewünscht, registriert, keine Abmeldung ausstehend, Server meldet für **diese** Verbindung `active`, letzter Kontakt < 36 h und seitdem kein Fehler, und (seit 0fb2951) der letzte erfolgreiche WebUntis-Abruf des Servers (`status.lastSuccess`) liegt unter 36 h. Vor eigenen Änderungsmitteilungen sammelt die App zugestellte Pushes ein und erneuert einen Kontakt, der älter als 30 min ist, mit einem `GET /v1/changes` (`refreshBeforeLocalChanges`, seit 0fb2951). Dann schreibt die lokale Erkennung nur in die Glocke. Sonst (Registrierung fehlgeschlagen, Netz-/Serverfehler, `authFailed`, `tokenInvalid`, anderer Bereich) wie bisher lokale Mitteilungen. |
| 10 Antippen | `userInfo["noty"]`: Bereich über `connectionID` (gespeicherte Zuordnung Verbindung → Bereich); `change`/`summary` → `openNotification` (Tag, Stunde `entryID`), `changeIDs` gelesen (auch die gleichbedeutenden eigenen), danach Serververlauf holen und erneut als gelesen markieren (Zusammenfassung); `auth` → Kalender und WebUntis-Blatt (seit 0fb2951 über `connectionSheetRequested`); `test` → nichts. Anderer Bereich → Hinweis wie bei lokalen Mitteilungen. Wartet wie bisher, bis das Modell geladen ist. |
| 11 Vordergrund | `willPresent`: Banner, Einzeländerung sofort in die Glocke, Serververlauf nachladen. Gelesen in der Glocke entfernt auch zugestellte Pushes (über `changeID`) aus der Mitteilungszentrale; beim Aktivieren werden zugestellte Pushes wie lokale Mitteilungen übernommen. |
| 12 Gerätetest | Registrierung und Test-Push mit Build 137 belegt, `demo-push` mit allen Mitteilungsarten angekommen (Nutzer); alles Weitere offen, siehe [CALENDAR-LOG](CALENDAR-LOG.md#ausstehend-gebündelter-gerätetest-für-den-nächsten-build). |

**Im Server behoben (`push/`):** `PUT /v1/device` mit **derselben** Freigabe setzte ein `authFailed`-Gerät nicht zurück (nur eine geänderte Freigabe löste Testabruf und neue Basis aus) – ein vorübergehend abgewiesenes Gerät blieb dauerhaft pausiert, bis eine neue Freigabe kam. Jetzt gilt eine erneut gesendete Freigabe bei `authFailed` als neuer Versuch (Testabruf, neue Basis); `testRepeatedAuthFailureMarksDeviceAndPushesOneNotice` erweitert, 46 Tests grün.

**Grenzen der App-Seite:** Ein Gerät kann nur **eine** Verbindung (einen Bereich) per Push melden lassen; Einschalten in einem anderen Bereich verlegt es dorthin (`PUT` mit neuer Verbindung und Freigabe). Ohne Erlaubnis für Mitteilungen wird nicht registriert; eine bestehende Registrierung bleibt dann bestehen. Eine Mitteilungs-Erlaubnis, die erst nach dem Einschalten erteilt wird, greift beim nächsten Aktivieren. Kurz nach einem Netzfehler kann eine lokale und eine Server-Mitteilung für dieselbe Änderung kommen (die Glocke entdoppelt).

### Ursprüngliche Schrittliste (Vorgabe)

Historische Vorgabe vor der Umsetzung (enthält den maßgeblichen Einwilligungstext in Schritt 4). Wo sie vom Umgesetzten abweicht oder etwas als „unbelegt“ nennt, gilt die Tabelle oben.

1. **Fähigkeit/Entitlement:** In `Noty.entitlements` `aps-environment` = `development` ergänzen. xtool 1.24.0 enthält laut Binärdatei einen Typ `APSEnvironmentEntitlement` und kennt die Fähigkeit `PUSH_NOTIFICATIONS` (wie bei `AppleSignInEntitlement`, siehe ENVIRONMENT „xtool 1.24.0“); `xtool --help`/`xtool dev build --help` nennen dazu nichts. **Unbelegt**, ob xtool die Fähigkeit für die App-ID einschaltet und das Profil sie enthält. Nachweis wie bei Sign in with Apple: signierten Build erzeugen und `python3 -I scripts/ota_check.py xtool/Noty.ipa XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar` – `aps-environment` muss in Signatur **und** Profil stehen, `problems` leer. Sonst Fähigkeit im Developer-Portal für die App-ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar` von Hand einschalten und erneut signieren. Gilt für alle Kanäle (eine Entitlements-Datei); für noty/noty dev ohne Push-Nutzung harmlos, aber die Fähigkeit muss dann auch dort im Profil sein, sonst scheitert `ota_check`.
2. **Info.plist:** keine Hintergrundmodi nötig (nur sichtbare Alert-Pushes). Die Server-Basis-URL nicht ins öffentliche Repo als Geheimnis – sie ist nicht geheim (`noty.xclipsen.de` steht bereits im Repo); Konstante oder `NotyPushURL` in Info.plist.
3. **Token holen:** `UIApplication.shared.registerForRemoteNotifications()` nach erteilter Mitteilungsberechtigung; `didRegisterForRemoteNotificationsWithDeviceToken` → Hex-String. Umgebung: aus dem eingebetteten Profil (`aps-environment`) oder `#if DEBUG`-unabhängig fest `sandbox`, solange nur development-signiert wird. `bundleID` = `Bundle.main.bundleIdentifier`.
4. **Einwilligung vor dem Hochladen** (Text, Version `webuntis-push-1`): „Damit Stundenplanänderungen auch bei geschlossener App gemeldet werden, speichert noty calendar deine WebUntis-Freigabe (Server, Schule, Benutzer, Schlüssel) verschlüsselt auf dem noty-Server (noty.xclipsen.de). Der Server ruft deinen Stundenplan stündlich zwischen 5 und 21 Uhr ab (am Wochenende seltener) und schickt Mitteilungen über Apple. Gespeichert werden außerdem dieses Gerät (Mitteilungs-Token) und die Stunden der nächsten zwei Wochen zum Vergleich. ‚Trennen‘ oder ‚Mitteilungen aus‘ löscht alles auf dem Server sofort.“ Erst nach „Zustimmen“ `POST /v1/register` mit `consent: "webuntis-push-1"`.
5. **Registrieren** beim Verbinden mit WebUntis (nach erfolgreichem lokalem Test) und beim App-Start, falls verbunden aber kein Gerätesecret vorhanden. `deviceID` + `deviceSecret` in den **Schlüsselbund** (wie `WebUntisKeychain`, `…ThisDeviceOnly`), nie in Dateien/Backups. Fehler 422 (`untis_rejected`) und 502 deutsch anzeigen (`message`), 403 `limit_reached` als „Mitteilungsdienst voll“.
6. **Aktualisieren** (`PUT /v1/device`): bei neuem Token (jeder Start liefert ihn, nur bei Änderung senden), bei geänderten Mitteilungseinstellungen (`settings`), bei neuer Freigabe (`setup` + `consent`), Zeitzone. Status `authFailed`/`tokenInvalid` aus `status.state` in den Einstellungen anzeigen. 401 → Secret löschen und neu registrieren (Server hat das Gerät gelöscht).
7. **Abmelden:** „Trennen“ der WebUntis-Verbindung und Ausschalten der Änderungsmitteilungen → `DELETE /v1/device`, danach Secret aus dem Schlüsselbund löschen. Schlägt das fehl (offline), Löschauftrag merken und beim nächsten Start wiederholen; dem Nutzer nicht „gelöscht“ melden, bevor 204 kam.
8. **Glocke zusammenführen:** beim Öffnen der App/Glocke `GET /v1/changes?since=<letzter serverTime>`; Einträge als `CalendarNotificationRecord` (`kind: .change`, `id = CalendarNotificationLog.changePrefix + namespace + "." + changeID`, `day`, `entryID`) in den Verlauf (`CalendarNotificationLog.add` entdoppelt). `serverTime` als nächstes `since` speichern.
9. **Doppelte Mitteilungen vermeiden:** Solange der Server für diese Verbindung aktiv ist (`state == active`), lokal erkannte Änderungen nur in den Verlauf schreiben, **keine** lokale Änderungsmitteilung planen. Fällt der Server aus (Registrierung fehlgeschlagen, `authFailed`), auf lokale Mitteilungen zurückfallen.
10. **Antippen → Termin öffnen:** `UNUserNotificationCenterDelegate.didReceive` liest `userInfo["noty"]`: `connectionID`, `day`, `entryID` (`CalendarLesson.id`) bzw. bei `summary` den Tag der frühesten Änderung; Kalender auf `day` öffnen und die Stunde `entryID` auswählen; Verlaufseinträge `changeIDs` als gelesen markieren. `kind == "auth"` → WebUntis-Einstellungen öffnen.
11. **Vordergrund:** `willPresent` für `kind == change/summary` als Banner zeigen und gleichzeitig in die Glocke übernehmen.
12. Prüfen am Gerät (gebündelt): Registrierung, `noty-push test-push`, echte Änderung bei geschlossener App, Ruhezeit-Zusammenfassung um 6 Uhr, Trennen löscht Serverdatei (`noty-push status`).

Der gebündelte Gerätetest des App-Teils steht seit 08.11.2026 bei Build 137 in [CALENDAR-LOG](CALENDAR-LOG.md#build-137--push-anbindung-und-server-noty-push-08112026).

## Betriebsstand (08.11.2026)

- Dienst `noty-push` auf dem VPS aktiv (systemd, `127.0.0.1:8795`); nginx `noty.xclipsen.de/push/v1/{health,register,device,changes}` freigeschaltet, übrige Pfade 404. In Betrieb seit der Inbetriebnahme mit Build 137; Review-Stand (Commit `0fb2951`) deployt 08.11.2026 12:49 UTC, Health-Check danach `{"ok":true}`.
- Registriert hat sich bei der Inbetriebnahme ein Gerät (iPad des Nutzers, sandbox, aus Build 137); den aktuellen Stand zeigt `noty-push status`.
- Nachweise der Inbetriebnahme (Push-Fähigkeit durch xtool, Registrierung, erste Test-Push mit vertippter Key ID, dann zugestellt und vom Nutzer bestätigt, `demo-push`) wörtlich in [CALENDAR-LOG, Build 137](CALENDAR-LOG.md#build-137--push-anbindung-und-server-noty-push-08112026); offene Prüfungen unter „Grenzen und Risiken“.
