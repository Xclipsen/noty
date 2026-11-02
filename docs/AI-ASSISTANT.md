# KI-Assistent (experimentell)

Status: erste Version in `feat/ki-panel`, nur für **noty dev**. Ausbaustufen: Fragen zum Heft, Handschrift als Bild. Lernkarten und automatische Chats folgen später. Diese Datei ist der Vertrag zwischen App und Bridge; tatsächliche Nachweise stehen in [TESTING](TESTING.md).

## Grundsätze

- Läuft über das ChatGPT-Abo: `bridge/` spricht auf dem eigenen Server mit `codex app-server` und einer eigenen ChatGPT-Anmeldung. Kein API-Schlüssel, kein Anmeldeschlüssel von OpenAI auf dem iPad. Die Kontenverwaltung kann mehrere Konten führen, freigeschaltet ist aber nur der Inhaber: Ein ChatGPT-Abo gehört einer Person, andere Konten bleiben `pending`, solange der Inhaber nichts anderes entscheidet.
- Standardmäßig aus. Ohne KI und offline funktioniert alles andere unverändert.
- Inhalte verlassen das iPad nur mit sichtbarem Kontext und nach Freigabe je Heft. Heftkontext und Bilder liegen auf dem Server nie auf der Platte; gespeichert werden nur Frage, Antwort und ein Kontextname. Chats werden nach 30 Tagen gelöscht.
- Die KI schreibt nie in ein Heft und hat keine Werkzeuge: keine Shell, keine Dateien, kein Web. Kontext ist Datenmaterial, keine Anweisung.
- Kein Heftschema, keine neue Ebene, kein zweiter Writer. Die App liest nur Momentaufnahmen.

## Konto und Zugriff

Die Bridge kennt keine eigenen Passwörter. `Authorization: Bearer <token>` ist die vorhandene noty-Kontositzung der App (`LawLibraryModel.user.token`). Die Bridge prüft sie serverseitig gegen `GET NOTY_AI_ACCOUNT_URL/api/session` (auf IONOS `http://127.0.0.1:18083`), Ergebnis höchstens 60 Sekunden im Speicher, Schlüssel nur als SHA-256. `{ user: null }` ergibt `401`; ein nicht erreichbares Konto-Backend ergibt `503`, niemals Zugriff.

Diese Abfragen laufen beim Backend in einem gemeinsamen Limit von 1200 je 5 Minuten. Die Bridge drosselt sie deshalb selbst, Überschreitungen ergeben `429` oder `503` mit `Retry-After`, niemals Zugriff:

- Abgelehnte Tokens werden 30 Sekunden gemerkt, Ausfälle des Backends 3 Sekunden, beides gehasht und auf 2000 Einträge begrenzt. Gültige Einträge liegen getrennt und werden von einer Flut nicht verdrängt.
- Höchstens 900 Abfragen je 5 Minuten, davon höchstens 300 für unbekannte Tokens, höchstens 60 davon je Client (`X-Real-IP`, sonst Socket-Adresse). Der Rest bleibt für die erneute Prüfung bekannter Tokens reserviert; das sind Tokens, die in den letzten 24 Stunden gültig waren, seit dem letzten Neustart.
- Höchstens 8 gleichzeitige Abfragen, davon 4 für unbekannte Tokens.
- Antwortet das Backend selbst mit `429`, pausieren alle Abfragen für die Dauer von `Retry-After`, höchstens 5 Minuten. Tokens im 60-Sekunden-Cache laufen weiter.

`X-Real-IP` auf `/v1` ist nur eine Fairness-Hilfe, kein Schutz: Setzt der Proxy davor den Kopf nicht selbst, stammt er vom Client. Gefälschte Werte umgehen die Grenze je Client, aber nicht die globale.

Kontostatus in der Bridge: `pending` (neu, Standard), `active`, `blocked`. Konten in `NOTY_AI_ADMIN_IDS` (kommagetrennte Konto-IDs) sind immer `active` mit Rolle `admin`. `/v1/me` geht in jedem Status, alle anderen `/v1/*`-Pfade verlangen `active`, sonst `403 { error, code: "pending"|"blocked" }`. `POST …/turns` prüft das nach dem Hochladen erneut; ein Statuswechsel während des Uploads startet keinen Lauf. Sitzungen gehören einem Konto; fremde IDs ergeben `404`. Limit `0` im Konto bedeutet: kein Lauf erlaubt; fehlt es, gilt `NOTY_AI_DAILY_LIMIT`.

Verbrauch steht je Konto und UTC-Tag als reine Zähler: `turns`, `failedTurns`, `images`, `inputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningOutputTokens`. Tokenzahlen kommen aus `thread/tokenUsage/updated` (je Lauf der letzte Stand von `tokenUsage.total`) und werden laufend gebucht, sodass auch abgebrochene Läufe ihren letzten bekannten Stand zählen. Alle Zähler eines Laufs gehören zum UTC-Tag seiner Reservierung, auch über Mitternacht. Ein Neustart im Lauf zählt einmal als `failedTurns`. Keine Inhalte. Tage älter als `NOTY_AI_USAGE_DAYS` (400) werden gelöscht.

Admin-Panel: eigenständige Web-App unter `https://noty.xclipsen.de/admin`, nicht Teil der iPad-App. Host-nginx leitet öffentlich ausschließlich `/admin` an `127.0.0.1:8791` weiter, `/v1/*` bleibt von außen `404` und nur über Tailscale erreichbar. `/` führt auf `/admin`. Die Bridge liest die Client-IP aus `X-Real-IP` nur für die Anmeldesperre und lauscht weiter nur auf `127.0.0.1`. `GET /admin` liefert eine statische Seite ohne externe Ressourcen, mit `Content-Security-Policy: default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` plus `Strict-Transport-Security`, `Referrer-Policy: no-referrer` und `X-Frame-Options: DENY`. Erlaubter `Origin`: `NOTY_AI_ADMIN_ORIGIN`. Anmeldung `POST /admin/api/login { name, password }` reicht die Daten einmalig an `POST NOTY_AI_ACCOUNT_URL/api/login` weiter, speichert sie nicht und akzeptiert nur Admin-Konten. Danach gilt ein zufälliges Cookie `noty_ai_admin` (`HttpOnly; Secure; SameSite=Strict; Path=/admin`, 8 Stunden, serverseitig nur gehasht im Speicher). 5 Fehlversuche je 15 Minuten und IP sperren, zusätzlich 20 insgesamt. Die Backend-Sitzung der Anmeldung wird sofort beendet; bei bereits 10 Sitzungen verdrängt das Backend die älteste schon beim Login. Schreibende Anfragen verlangen JSON und passenden `Origin`.

| Admin-Pfad | Eingabe | Antwort |
| --- | --- | --- |
| `GET /admin/api/overview` | | `200 { account, plan: Usage, running, today: Zähler, users: [{ id, name, status, role, dailyLimit, lastSeenAt, today: Zähler, last7: Zähler, last30: Zähler, total: Zähler }] }`; `account` und `plan` sind `null`, wenn Codex ausfällt oder nicht binnen 15 Sekunden antwortet, Kontodaten kommen immer |
| `PATCH /admin/api/users/:id` | `{ status?, dailyLimit? }` (`null` = Standard) | `200 Konto`; Admins lassen sich nicht sperren |
| `POST /admin/api/logout` | | `204` |

Sperren oder Limit 0 bricht laufende Läufe des Kontos sofort ab. Inhalte von Chats sind im Admin-Panel bewusst nicht einsehbar. Die Oberfläche zeigt die Anmeldemaske nur bei `401`; `5xx` und Netzfehler lassen das Panel mit einem Hinweis stehen.

## HTTP-Schnittstelle

`/v1` nur auf `127.0.0.1:8790`, nach außen ausschließlich privates Tailscale-HTTPS. `/admin` nur auf `127.0.0.1:8791` für nginx. Keiner der beiden Listener bedient die Pfade des anderen, dort antworten sie mit `404`. JSON, `Cache-Control: no-store`. Alle `/v1/*`-Pfade verlangen `Authorization: Bearer <token>`. Fehler: Status plus `{ "error": "deutscher Text" }`, bei Bedarf `code` und `Retry-After`.

Beide Listener lehnen Rohpfade mit `404` ab, bevor sie gedeutet werden: `//`, `\`, `..`, einzelne `.`-Abschnitte, Steuerzeichen, deren Prozentkodierung auch mehrfach, `#` und absolute URLs. Hintergrund: nginx normalisiert anders als Node, `//admin/v1/me` wäre für Node der Host `admin` mit Pfad `/v1/me`. Eine einzelne Kodierung wie `konto%2Fid` bleibt erlaubt.

| Methode und Pfad | Eingabe | Antwort |
| --- | --- | --- |
| `GET /v1/me` | | `200 { user: { id, name }, status, role, dailyLimit, today: Zähler }` |
| `GET /v1/info` | | `200 { account: "chatgpt"\|null, models: [{ id, name, isDefault }], limits: { maxImages, maxImageBytes, maxContextChars, maxQuestionChars, dailyTurns, usedToday } }` |
| `GET /v1/usage` | | `200 { checkedAt, limits: [{ id, name, windows: [{ usedPercent, windowDurationMins, resetsAt }] }] }` |
| `GET /v1/sessions?documentId=UUID` | | `200 [Zusammenfassung]`, neueste zuerst |
| `POST /v1/sessions` | `{ documentId?, title? }` | `201 Sitzung`; `409 code: too_many_sessions` ab 500 Sitzungen je Konto; `503` wenn nicht gespeichert, dann gibt es die Sitzung nicht |
| `GET /v1/sessions/:id?after=REV` | | `200 Sitzung`, oder `204` wenn `revision == REV` |
| `DELETE /v1/sessions/:id` | | `204`; `503` wenn nicht löschbar, dann bleibt alles unverändert und ein Lauf läuft weiter |
| `POST /v1/sessions/:id/turns` | Anfrage (unten) | `202 Sitzung`; `409` läuft schon; `429` Limit oder Upload-Grenze; `403` Status nicht `active`; `400` Modell nicht in der sichtbaren Liste; `503` nicht bei ChatGPT angemeldet |
| `POST /v1/sessions/:id/cancel` | | `200 { ok: true }` |

Zusammenfassung: `{ id, documentId, title, status, revision, updatedAt }`. Sitzung zusätzlich `messages: [{ id, role: "user"|"assistant"|"system", text, contextLabel?, imageCount? }]`. `status`: `idle`, `running`, `error`, `interrupted`. `updatedAt` in Millisekunden seit 1970. Liefert ein Lauf keinen Antworttext, endet er als `error` mit einer `system`-Nachricht statt still `idle`.

Eine Sitzung behält die neuesten 400 Nachrichten und höchstens 1 000 000 Zeichen, dazu die jüngsten 200 `requestId`. Ältere Einträge fallen beim nächsten Lauf weg; Wiederholungen der jüngsten 200 Anfragen bleiben idempotent.

Abgelaufene Sitzungen ergeben sofort beim Lesen `404`, nicht erst nach dem täglichen Aufräumen.

Sämtlicher Text ist wohlgeformtes UTF-16, damit Swift die JSON-Antworten lesen kann. Einzelne Surrogate in `text`, `title`, `context.label`, `context.text` oder Bildnamen ergeben `400`, Altdaten werden beim Laden mit `U+FFFD` repariert, Titel an Graphemen gekürzt.

Anfrage:

```json
{ "requestId": "8–80 Zeichen a-zA-Z0-9-, Wiederholung startet keinen zweiten Lauf",
  "text": "Frage, höchstens 20 000 Zeichen",
  "context": { "label": "Mathe, Seite 3", "text": "…" },
  "images": [{ "mimeType": "image/jpeg", "base64": "…", "label": "Seite 3" }],
  "model": "optional", "effort": "optional" }
```

`context` und `images` sind optional. `model` muss eine `id` aus `/v1/info` sein. Grenzen: 4 Bilder, je 4 MiB dekodiert, nur `image/jpeg` oder `image/png`, Kontext 200 000 Zeichen, Anfragekörper 24 MiB, 2 parallele Uploads je Konto und 4 insgesamt. Ein zu großer Körper ergibt `413`; die Bridge liest den Rest ungepuffert weg, damit der Client die Antwort sieht, und trennt nach 64 MiB oder 15 Sekunden.

Seiten im Kontext tragen den Kopf `--- Seite N ---`. Antworten nennen Fundstellen als `[S. N]`, `[S. 1, 3]` oder `[S. 1 und 3]`. Die App merkt sich beim Senden lokal requestId → {N: stabile Seiten-ID} (höchstens 200 Einträge in UserDefaults, nicht in Heft oder Backup) und springt über die ID; verlinkbar sind nur Seiten aus dem Kontext dieser Frage, sonst bleibt es Text. Dafür ist die `id` einer `user`-Nachricht ihre `requestId`, eine Antwort gehört zur Frage davor.

## Bridge

- Je Lauf ein kurzlebiger `codex app-server --stdio` mit `ephemeral: true`, abgeschalteten Werkzeugen, `sandbox: read-only`, leerem Arbeitsordner. Der bisherige Verlauf (höchstens 20 Nachrichten, 40 000 Zeichen) geht als Text mit.
- Die Werkzeugfreiheit hängt an Schaltern und einem je Lauf erzeugten Modellkatalog aus `CODEX_HOME/models_cache.json`. Dieses interne Format nach jedem Codex-Update neu prüfen.
- Gleichzeitig höchstens 2 Läufe über alle Konten, 200 je Konto und Tag (`NOTY_AI_DAILY_LIMIT`), 5 Minuten Laufzeit. Nach einem Neustart werden laufende Sitzungen `error`.
- Ohne ChatGPT-Anmeldung lautet die Meldung „Der Dienst ist nicht bei ChatGPT angemeldet.“, auch bei fehlendem Modellkatalog und objektförmigen Codex-Fehlern wie `{ httpConnectionFailed: { httpStatusCode: 401 } }`. `/v1/usage` antwortet dann `503` mit `code: not_signed_in`. `/v1/info` hält fehlende Anmeldung und Ausfälle nur 20 Sekunden im Cache, Erfolge 60 Sekunden.
- Volle Platte: Sitzungsabschluss und Zähler bleiben im Speicher und werden mit Backoff nachgeschrieben. Ungültige Sitzungsdateien werden nach `.corrupt` verschoben und übersprungen.
- Umgebung: `STATE_DIR`, `CODEX_HOME`, `CODEX_BIN`, `PORT` (8790), `ADMIN_PORT` (8791), `NOTY_AI_ACCOUNT_URL`, `NOTY_AI_ADMIN_IDS`, `NOTY_AI_ADMIN_ORIGIN`, `NOTY_AI_DAILY_LIMIT`, `NOTY_AI_RETENTION_DAYS` (30), `NOTY_AI_USAGE_DAYS` (400). Keine Inhalte, Schlüssel oder Passwörter in Logs.

## App

- Core: `AIAssistant.swift` mit Antworttypen, Prüfung der Server-Adresse, Kontextaufbau und Fundstellen-Parser, unter Linux getestet.
- App: `AIAssistantModel` (Server-Adresse in UserDefaults, Schlüssel nur aus der noty-Kontositzung, URLSession ohne Cookies, Abfrage bei laufender Sitzung), `AIPanelView`, Einstellungsseite „KI (experimentell)“ mit Status aus `/v1/me`.
- Ohne Anmeldung, bei `pending`, `blocked` oder abgelaufener Sitzung zeigt das Panel den Grund und sendet nichts.
- Kontext je Frage sichtbar wählbar: keiner, diese Seite, ganzes Heft. Bei „diese Seite“ kann die gerenderte Seite als Bild mit, nötig für Handschrift. Die Heftfreigabe wird lokal je Server, Konto und Heft gemerkt.
- Panel-Zustand ist reine Anzeige in UserDefaults, nicht Teil von Heft oder Backup.
