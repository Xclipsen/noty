# noty KI-Bridge

Verbindet die App über HTTPS-Proxy mit einem kurzlebigen `codex app-server` je Lauf. Vertrag: [docs/AI-ASSISTANT.md](../docs/AI-ASSISTANT.md). Node 22, keine npm-Abhängigkeiten.

```bash
node --test                # alle Tests, ohne Netz und ohne echtes Codex
```

## Aufbau

- `server/main.mjs`: Start, Umgebung, zwei Listener an `127.0.0.1`, lehnt root ab.
- `server/http.mjs`: Rohpfadprüfung, Fehlerabbildung, Körpergrenzen, Upload-Deckel, App-Listener mit `/v1`.
- `server/admin.mjs`: Eigener Listener mit `/admin`: Anmeldung, Sperre, Cookie-Sitzungen, Origin-Prüfung, Routen. Oberfläche in `admin/`.
- `server/auth.mjs`: prüft die noty-Kontositzung gegen `NOTY_AI_ACCOUNT_URL/api/session` und drosselt diese Abfragen.
- `server/accounts.mjs`: Status, Rolle, Limit, Admin-Übersicht (`accounts.json`).
- `server/metering.mjs`: Zähler je Konto und UTC-Tag (`metering.json`).
- `server/runlog.mjs`: Laufprotokoll ohne Inhalte (`runs.json`), Kontingent davor und danach.
- `server/analytics.mjs`: Abfrageprüfung, Tagesreihe und CSV für `/admin/api/usage`, `/runs`, `/export`.
- `server/hub.mjs`: Läufe, Validierung, Prompt, Limits.
- `server/rpc.mjs`: Codex-Prozess und Katalog ohne Werkzeuge.
- `server/store.mjs`: Sitzungsdateien, Prüfung beim Laden, atomares Schreiben mit Wiederholung, Aufbewahrung.

Zustand in `STATE_DIR`, alles Modus 600: `sessions/*.json`, `accounts.json`, `metering.json`, `runs.json`, `tool-free-catalog.json`. Kontext und Bilder liegen nur während eines Laufs im Speicher.

Ungültige Sitzungsdateien wandern nach `sessions/*.json.corrupt`, blockieren den Start nicht und fallen nach der Aufbewahrungsfrist weg. `accounts.json`, `metering.json` und `runs.json` stoppen den Start dagegen weiter, auch bei falscher Struktur wie `[5]` oder `"abc"`: Sonst gingen Sperren, Limits und Nachweise still verloren. Ein kaputtes `runs.json` lässt sich zur Untersuchung beiseitelegen; ohne Datei startet das Protokoll leer, die Tageszähler bleiben unberührt.

Scheitert ein Schreiben, zum Beispiel bei voller Platte, wiederholt `LatestWriter` es mit Backoff (1 Sekunde bis 1 Minute), bis der neueste Stand auf der Platte ist. Neue Sitzungen und neue Konten rollen stattdessen sofort zurück und liefern `503`. Löschen ist ganz oder gar nicht: Scheitert es, bleibt die Sitzung bestehen und ein Lauf läuft weiter.

## Werkzeuge

Die `-c`-Schalter reichen allein nicht: das Modell bekommt seine Werkzeuge auch aus dem Modellkatalog. Jeder Lauf nutzt deshalb einen aus `CODEX_HOME/models_cache.json` erzeugten Katalog ohne Shell, Patch, Code-Modus und Unteragenten. Fehlt der Cache, startet kein Lauf. Übrig bleibt nur `request_user_input`, das die Bridge zurückweist. Bei jedem Codex-Update die tatsächliche Werkzeugliste neu prüfen.

## Einrichtung

Als root auf dem Server, startet nichts:

```bash
python3 -B deploy/provision.py
install -m 644 deploy/noty-ai.service /etc/systemd/system/noty-ai.service
```

`provision.py` bricht ab, wenn `state`, `state/codex`, `state/state` oder `config.toml` ein Symlink sind: Diese Ordner gehören dem Dienstkonto, das Skript läuft aber als root.

In der Unit `NOTY_AI_ADMIN_IDS` und `NOTY_AI_ADMIN_ORIGIN` prüfen. Eigene ChatGPT-Anmeldung, nie eine bestehende kopieren:

```bash
runuser -u noty-ai -- env HOME=/var/lib/noty-ai CODEX_HOME=/var/lib/noty-ai/codex \
  PATH=/opt/noty-ai/runtime/bin:/usr/bin:/bin /opt/noty-ai/runtime/node_modules/.bin/codex login
```

Danach `systemctl enable --now noty-ai`. Beide Listener binden nur an `127.0.0.1`:

| Variable | Standard | Pfade | Davor |
| --- | --- | --- | --- |
| `PORT` | 8790 | nur `/v1` | privates Tailscale-HTTPS |
| `ADMIN_PORT` | 8791 | nur `/admin` | Host-nginx |

Der jeweils andere Pfad ergibt `404`. nginx muss deshalb `/admin` an 8791 leiten, nicht mehr an 8790.

Die Unit begrenzt den Dienst mit `MemoryMax=1G`, `TasksMax=128`, `CPUQuota=200%` und `--max-old-space-size=384`. Gemessen: 4 parallele 24-MiB-Körper mit 2 Läufen im Speicher erreichen etwa 500 MiB RSS bei höchstens 140 MiB Heap. Echte Läufe mit Codex 0.166.0 liefen mit den neuen Grenzen und `RestrictNamespaces=yes`, geprüft als root ohne `ProtectHome` und `User=`. Codex führt hier keine Befehle aus und braucht deshalb keine eigenen Namespaces. Bei jedem Codex-Update erneut prüfen.

## Admin-Panel

Eigenständige Web-App unter `/admin` auf `ADMIN_PORT`, Vertrag in [docs/AI-ASSISTANT.md](../docs/AI-ASSISTANT.md), Abschnitt „Konto und Zugriff“. `boot()` startet diesen Listener immer. Fehlt `NOTY_AI_ADMIN_ORIGIN`, ist er kein exakter Ursprung (`https://host`, `http` nur lokal) oder ist `NOTY_AI_ADMIN_IDS` leer, antwortet `/admin` mit `503`; `/v1` läuft davon unberührt weiter. `provision.py` kopiert `admin/` mit, die Dateien werden beim Start einmal gelesen.

- Anmeldung: `POST /admin/api/login` reicht Name oder E-Mail und Passwort einmalig an `NOTY_AI_ACCOUNT_URL/api/login` weiter (`X-Noty-Client: 1`, sonst liefert das Backend kein Token). Nur Konten aus `NOTY_AI_ADMIN_IDS` kommen rein, alle anderen erhalten dieselbe Meldung wie bei falschem Passwort.
- Backend-Sitzung: Die Bridge beendet sie sofort per `/api/logout`, auch bei Nicht-Admins, und wiederholt das bei Fehlern dreimal im Abstand von 10 Sekunden. Das Backend behält je Konto die neuesten 10 Sitzungen und kürzt schon beim Login. Admin-Logins lassen die Zahl also nicht wachsen, aber bei genau 10 vorhandenen Sitzungen fällt die älteste, bevor das Abmelden greift. Das trifft höchstens einmal, danach stehen 9 Sitzungen. Verhindern ließe es sich nur im Backend, zum Beispiel mit einer Passwortprüfung ohne Sitzung.
- Sperre: 5 Fehlversuche je 15 Minuten je `X-Real-IP` und 20 über alle IPs, gleitendes Fenster, im Speicher, höchstens 1000 IPs. Ungültige oder fehlende `X-Real-IP` teilen sich einen Zähler. Ausfälle des Backends zählen nicht. Die globale Grenze sperrt bei einem Angriff auch echte Anmeldungen; bestehende Sitzungen bleiben.
- Sitzung: Cookie `noty_ai_admin`, 8 Stunden fest, höchstens 20, im Speicher nur als SHA-256. Ein Neustart meldet alle ab.
- Sperren: `status` ungleich `active` oder Limit 0 beenden laufende Läufe des Kontos sofort per `hub.abortUser`, der Codex-Prozess wird beendet, die Sitzung wird `interrupted`. Jeder Status außer `active`, der während des Hochladens eintrifft, verhindert den Laufstart in `hub.turn`.
- Übersicht: Kontodaten kommen immer. Codex-Abfragen enden nach 12 Sekunden, die Übersicht wartet höchstens 15 Sekunden, Fehlschläge werden 20 Sekunden gemerkt. `account` und `plan` sind dann `null`. Die Oberfläche zeigt nur bei `401` die Anmeldemaske, sonst das Panel mit Hinweis.
- nginx muss `/admin` an `127.0.0.1:8791` leiten, `X-Real-IP` selbst setzen, `Origin` und `Host` unverändert weiterreichen und nur `/admin` freigeben.

### Mit Apple anmelden

Vertrag: [docs/APPLE-LOGIN.md](../docs/APPLE-LOGIN.md), Abschnitt Admin-Panel. Aus, solange `NOTY_AI_APPLE_SERVICES_ID` fehlt oder ungültig ist: Dann antworten beide Apple-Pfade `404` und der Knopf bleibt verborgen. `NOTY_AI_APPLE_REDIRECT` (Standard `https://noty.xclipsen.de/admin/api/apple/callback`) muss genau `NOTY_AI_ADMIN_ORIGIN` plus `/admin/api/apple/callback` sein, sonst ist Apple ebenfalls aus; an einer anderen Adresse käme das Bindungs-Cookie nie an. Ob der Knopf erscheint, steht ohne Anmeldung und ohne Geheimnis als `<body data-apple="on">` in der ausgelieferten Seite.

- `GET /admin/api/apple/start`: `302` zu `https://appleid.apple.com/auth/authorize` mit `client_id`, `redirect_uri`, `response_type=code id_token`, `response_mode=form_post`, `state` und `nonce = sha256(Rohwert)`, ohne `scope`. `state` und Rohwert liegen 10 Minuten im Speicher, höchstens 200 offene Abläufe, davon 10 je `X-Real-IP`. Cookie `noty_ai_apple` (`HttpOnly; Secure; SameSite=None; Path=/admin/api/apple`, 10 Minuten) bindet den Ablauf an den Browser, gespeichert nur als Hash.
- `POST /admin/api/apple/callback`: nur `application/x-www-form-urlencoded`, höchstens 16 KiB, keine `Origin`-Prüfung. `state` muss offen, nicht abgelaufen und an das Cookie gebunden sein; erst dann ist er verbraucht. Danach `POST NOTY_AI_ACCOUNT_URL/api/apple/login { identityToken, nonce: Rohwert, create: false }` mit `X-Noty-Client: 1`, dieselbe Sperre wie beim Passwort (gemeinsame Zähler je IP und global), Admin-Prüfung, sofortiges Abmelden der Backend-Sitzung mit Wiederholung, Admin-Cookie wie beim Passwort. Unbekanntes Apple-Konto und Nicht-Admin ergeben dieselbe Meldung. Der Code von Apple wird nicht eingelöst.
- Antwort ist immer `303` auf `GET /admin/api/apple/callback?ergebnis=…`, nie JSON: eine Zwischenseite ohne Skript, die per Meta-Refresh auf `/admin` weiterleitet, bei Fehlern mit `#apple=abgelehnt|abgelaufen|abgebrochen|gesperrt|nicht-erreichbar|ungueltig`. `admin/app.js` zeigt das deutsch an und entfernt das Fragment.
- SameSite: Apples `form_post` ist eine seitenübergreifende Navigation. Das `SameSite=None`-Bindungs-Cookie kommt dabei an, und das `SameSite=Strict`-Admin-Cookie lässt sich in der Antwort setzen. Ein `303` direkt auf `/admin` käme aber ohne das Strict-Cookie an, weil die Weiterleitungskette seitenübergreifend begonnen hat. Der Meta-Refresh der Zwischenseite ist eine neue Navigation vom eigenen Ursprung und sendet es mit. In Chromium 153 im Rauchtest nachgewiesen; Safari ist ungeprüft.

nginx-Allowlist dafür: `apple\.svg` neben `app\.css` und `apple/(start|callback)` unter `api/`.

### Auswertung

Kennzahlen je Konto und gesamt für heute, 7, 30, 90 Tage oder alles Gespeicherte (höchstens 400 Tage), Tagesbalken für Tokens und Läufe als CSS-Klassen `h0` bis `h100` ohne Inline-Styles, Laufliste mit Konto- und Statusfilter (25 je Seite), Kontingentverlauf aus dem Laufprotokoll und CSV-Export. Zähler stehen exakt mit Tausenderpunkten, nur Durchschnitte und Quoten haben eine Nachkommastelle. Vertrag: [docs/AI-ASSISTANT.md](../docs/AI-ASSISTANT.md).

Der Anteil eines Laufs am Kontingent ist nur eine Näherung: Codex meldet ganze Prozent, und Nutzung desselben Abos außerhalb der Bridge zählt mit. Läufe vor dieser Version haben keinen Eintrag im Laufprotokoll; ihre Tageszähler haben Laufzeit, Bildbytes, Kontextzeichen und Cache-Schreiben 0, `totalTokens` ist dort abgeleitet.

nginx-Allowlist dafür: `usage|runs|export` unter `api/`; die Abfrage passt schon auf `(\?[A-Za-z0-9=&_-]*)?`, Konto-IDs dort als UUID.

Browser-Rauchtest, nicht Teil von `node --test`, nur synthetische Daten, Screenshots nach `/tmp/noty-admin-*.png`, die Auswertung nach `/tmp/noty-admin-analyse-*.png` (1440, 1180, 820 und 390 Pixel breit, ohne Querscrollen). Für Apple läuft ein Ersatz von `appleid.apple.com` auf `127.0.0.1`, die Bridge auf `localhost`, also auf einer anderen Site; der Test schneidet mit, welche Cookies bei der Bridge ankommen:

```bash
PLAYWRIGHT_MODULE=/pfad/zu/node_modules/playwright node tests/admin-browser.mjs
```
