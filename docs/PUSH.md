# Push-Dienst für noty calendar

Stand 08.11.2026, Branch `feat/kalender`. Server-Teil: **implementiert und mit `swift test --package-path push` getestet (46 Tests, ohne Netzwerk)**. **Nicht installiert, nicht in nginx eingebunden, kein echter APNs-Versand, kein Abruf gegen die echte WebUntis-Schule.** Der App-Teil fehlt noch (Liste unten).

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
3. **Abruf**: `getUserData2017` + `getTimetable2017` für [heute, heute+14). Nur eine vollständige, von Core validierte Antwort wird mit `merge` in den gespeicherten Snapshot übernommen; Core vergleicht nur Tage, die beide Stände abdecken und die neu abgerufen wurden. Daraus folgt (Regeln aus CALENDAR-PLAN §7, in Core umgesetzt und hier getestet): Fehler, Zeitüberschreitung, Teil-/Parsefehler → keine Änderung, Vergleichsstand bleibt; Fensterverschiebung → keine Änderung; **verschwundene Stunde ≠ Ausfall** (nur ausdrücklicher Status zählt); nur Stunden, die noch in der Zukunft beginnen.
4. **Mitteilung**: Neue Änderungen (ID noch nicht im Verlauf) außerhalb der Ruhezeit sofort: bis zu 3 Einzelmitteilungen, mehr als 3 als eine Zusammenfassung („6 Stundenplanänderungen“ + erste drei Zeilen + „…“).
5. **Ruhezeit** (Standard 21:00–6:00, vom Gerät übernehmbar): Änderungen werden gesammelt; ab Ende der Ruhezeit (6:00) **eine** Mitteilung – bei einer Änderung deren Text, sonst eine Zusammenfassung. Änderungen an Stunden, die bis dahin schon begonnen haben, verfallen (nur im Verlauf, `expired`). Entscheidung: Zusammenfassung statt stiller Zustellung, weil der Morgen der Zeitpunkt ist, an dem ein Ausfall noch nützt.
6. **Fehler/Backoff**: Fehlschläge in Folge verlängern den Abstand (15 min, verdoppelt, höchstens 12 h), immer innerhalb des Zeitplans. **Zweimal hintereinander „Anmeldung abgelehnt“/„Schule unbekannt“** → Gerät `authFailed`, keine Abrufe mehr, **einmal** Mitteilung „Untis-Zugang prüfen“ (in der Ruhezeit morgens). Ein `PUT` mit neuer Freigabe macht es wieder aktiv (neue Basis).
7. **APNs**: 200 → zugestellt (an APNs, nicht unbedingt angezeigt). 410 oder `BadDeviceToken`/`Unregistered`/`DeviceTokenNotForTopic` → Gerät `tokenInvalid`, keine Abrufe mehr, bis die App per `PUT` einen neuen Token meldet. 429/5xx/Netz → nach 10 min erneut, höchstens 3 h lang. `ExpiredProviderToken` → JWT einmal erneuern.
8. **Aufräumen**: Geräte, die 30 Tage inaktiv (`authFailed`/`tokenInvalid`) sind, werden gelöscht. Verlauf: höchstens 200 Einträge, 60 Tage. Snapshot: nur ab vorgestern, ohne Hausaufgaben und Ferien.

### Änderungs-IDs und Entdoppeln mit der App

Die ID ist `CalendarLessonChange.id` aus Core, z. B. `change.<periodenID>.<datum>.<arten>.<start>.<räume>`. Die App bildet ihren Verlaufseintrag als `CalendarNotificationLog.changePrefix + namespace + "." + id`; der Server liefert die **rohe** ID (`changeID`) plus `connectionID`, die App setzt Präfix/Namespace selbst. Grenze: Die Art einer Änderung hängt vom Vergleichspaar ab (Server vergleicht stündlich, die App mit ihrem letzten Stand). Meist sind die IDs gleich; wenn nicht, erscheint dieselbe Änderung in der Glocke zweimal mit leicht anderer Art. Darum soll die App bei aktivem Push **keine eigenen lokalen Änderungsmitteilungen** mehr anzeigen (nur Verlauf), siehe App-Liste.

## HTTP-API

Basis öffentlich: `https://noty.xclipsen.de/push/v1/` (nginx entfernt `/push`). Antworten JSON, Zeiten als Unix-Sekunden, Fehler `{"error": "<code>", "message": "<deutscher Satz>"}`. Authentifizierung: `Authorization: Bearer <deviceID>.<deviceSecret>`. Körper höchstens 16 KiB, `Content-Type: application/json`.

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

`settings` ist dieselbe Struktur wie `CalendarNotificationSettings` (tolerant; weitere Schlüssel werden ignoriert). `deviceSecret` gibt es **nur in dieser Antwort**; der Server speichert nur dessen SHA-256. Registriert sich dasselbe Gerät (gleicher Token + Bundle-ID) erneut, ersetzt der neue Eintrag den alten (keine Doppelmitteilungen). `PUT /v1/device` nimmt dieselben Felder optional; `setup` nur zusammen mit `consent`. Neue Freigabe, `connectionID` oder Zeitzone → neuer Testabruf und neue Basis.

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
- Missbrauchsschutz: höchstens `maxDevices` = 5 Geräte insgesamt, 5 Registrierungen/Stunde je IP, 20/Tag gesamt, 60 Anfragen/Minute je IP, 120 Anmeldeversuche/Stunde je Geräte-ID, 16 KiB Körper, 30 s Leerlauf. Dienst lauscht nur auf 127.0.0.1 (weigert sich sonst zu starten); TLS nur über nginx.
- **Abmelden/Trennen**: `DELETE /v1/device` löscht die Datei sofort (inklusive Freigabe und Verlauf). Backups des VPS können ältere Kopien enthalten – verschlüsselt, ohne `data.key` unbrauchbar.

## Betrieb

Bauen und testen (Session ist root, deshalb als `la`):

```bash
cd /home/la/workspace/noty-kalender
runuser -u la -- bash -c '. ./scripts/env.sh >/dev/null 2>&1; swift test --package-path push'
```

Installieren (nur auf ausdrücklichen Auftrag; **bisher nicht ausgeführt**):

```bash
sudo push/deploy/install.sh   # baut statisch, legt Benutzer/Ordner/data.key/config.json an, Unit installieren
# apnsKeyID in /etc/noty-push/config.json eintragen, .p8 nach /etc/noty-push/apns.p8 (chmod 600)
sudo push/deploy/install.sh   # zweiter Lauf: prüft (noty-push check) und startet
```

`install.sh` ist idempotent, überschreibt weder `data.key` noch `config.json` noch `apns.p8`, startet nur mit vorhandenem .p8 und erfolgreichem `noty-push check`, und **verändert nginx nicht** (kopiert nur die Vorschläge nach `/etc/nginx/noty-push.conf` und `/etc/nginx/noty-push-proxy.conf`).

**nginx freischalten** (von Hand, mit `nginx -t`): im 443-Block von `/etc/nginx/sites-enabled/noty.xclipsen.de` vor `location / { return 404; }` `include /etc/nginx/noty-push.conf;` einfügen, die Rohpfad-Prüfung (`if ($request_uri !~ …)`) um `|push/v1/(health|register|device|changes)` erweitern und `limit_req_zone $binary_remote_addr zone=notypush:1m rate=30r/m;` im http-Kontext anlegen. Details als Kommentar in `push/deploy/nginx-noty-push.conf`. Danach `curl https://noty.xclipsen.de/push/v1/health`.

Werkzeuge (als root mit den Credentials, z. B. `systemd-run -P -p User=noty-push -p LoadCredential=data.key:/etc/noty-push/data.key -p LoadCredential=apns.p8:/etc/noty-push/apns.p8 -p ReadWritePaths=/var/lib/noty-push /opt/noty-push/noty-push status`):

- `noty-push check` – Konfiguration, Schlüssel, Ablage, JWT-Erzeugung.
- `noty-push status` – Geräte (ID, Zustand, Umgebung, letzter Erfolg, nächster Abruf, Fehler, Verlauf) ohne Geheimnisse.
- `noty-push test-push <deviceID>` – Testmitteilung „Testmitteilung des Mitteilungsdienstes.“ (beweist Topic, Umgebung und Schlüssel).
- `noty-push genkey` – neuer Datenschlüssel.

Logs: `journalctl -u noty-push`, nginx: `/var/log/nginx/noty-push.log`.

**Datenschlüssel rotieren:** `noty-push genkey` erzeugen, als **erste** Zeile in `/etc/noty-push/data.key` einfügen, alte Zeile darunter lassen, Dienst neu starten. Jede Datei wird beim nächsten Schreiben (spätestens beim nächsten Abruf) mit dem neuen Schlüssel versiegelt. Nach einem Tag mit `noty-push status` prüfen, dass alles lesbar ist, dann die alte Zeile entfernen und neu starten. **APNs-Schlüssel rotieren:** neuen .p8 anlegen, Datei ersetzen, `apnsKeyID` ändern, neu starten; alten Schlüssel danach bei Apple widerrufen.

Abmelden aller Geräte/Stilllegen: `systemctl disable --now noty-push`, `rm -rf /var/lib/noty-push/devices` (löscht alle Freigaben), nginx-Include entfernen.

## Grenzen und Risiken

- **Inoffizieller WebUntis-Zugang** (Untis-Mobile-Freigabe, CALENDAR-PLAN §7). Schule oder Untis können ihn jederzeit ändern oder sperren; der Server meldet das dann einmal als „Untis-Zugang prüfen“. Stündlicher Abruf von einer Server-IP statt vom iPad kann von der Schule anders bewertet werden (Rate-Limits, Sperre) – unbekannt.
- **Status außer `REGULAR` real unbestätigt.** Ob die Schule `CANCELLED`/`IRREGULAR`/`SUBSTITUTION`/`ROOMSUBSTITUTION` und `orgId` wirklich so liefert, ist nicht belegt. Weil nur ausdrückliche Status zählen, heißt das im Zweifel: **weniger Mitteilungen, keine erfundenen**. Erste echte Änderungen gegen WebUntis im Browser vergleichen.
- **Zustellung nicht garantiert:** APNs „200“ heißt angenommen, nicht angezeigt (Fokus, Mitteilungen aus, Gerät offline > Ablauf). Mindestverzögerung bis zu einer Stunde (Zeitplan) plus Minute 0–14.
- **Sandbox vs. Produktion:** Development-Builds → nur Sandbox-Token. Ein späterer Ad-hoc-/App-Store-Build hätte `production`; die App muss die Umgebung dann korrekt melden. Sandbox-Zustellung ist erfahrungsgemäß weniger zuverlässig.
- **Bundle-ID-Abhängigkeit:** Ändert sich das xtool-Präfixverhalten oder der OTA-Weg, ändert sich das Topic → `DeviceTokenNotForTopic`. `allowedBundleIDs` und die gemeldete `bundleID` müssen dann angepasst werden.
- **Ein Prozess, kleine Größe:** ausgelegt für ≤ 5 Geräte; Abrufe laufen nacheinander. Ratenlimits liegen im Speicher (Neustart setzt sie zurück).
- Ungeprüft: Laufzeit unter systemd mit allen Hardening-Optionen (insbesondere `MemoryDenyWriteExecute`, `RestrictAddressFamilies` mit curl-Namensauflösung), echte APNs-Antworten, echte WebUntis-Antworten vom Server aus, nginx-Weiterleitung. Erste Inbetriebnahme deshalb mit `noty-push check`, `test-push` und `journalctl` begleiten.

## Was in der App noch zu tun ist

Der App-Agent arbeitet parallel an Glocke/`CalendarChanges.swift`/`CalendarNotifications.swift`; die folgenden Punkte betreffen nur die Server-Anbindung.

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
