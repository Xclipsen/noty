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
- `server/hub.mjs`: Läufe, Validierung, Prompt, Limits.
- `server/rpc.mjs`: Codex-Prozess und Katalog ohne Werkzeuge.
- `server/store.mjs`: Sitzungsdateien, Prüfung beim Laden, atomares Schreiben mit Wiederholung, Aufbewahrung.

Zustand in `STATE_DIR`, alles Modus 600: `sessions/*.json`, `accounts.json`, `metering.json`, `tool-free-catalog.json`. Kontext und Bilder liegen nur während eines Laufs im Speicher.

Ungültige Sitzungsdateien wandern nach `sessions/*.json.corrupt`, blockieren den Start nicht und fallen nach der Aufbewahrungsfrist weg. `accounts.json` und `metering.json` stoppen den Start dagegen weiter, auch bei falscher Struktur wie `[5]` oder `"abc"`: Sonst gingen Sperren und Limits still verloren.

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

Browser-Rauchtest, nicht Teil von `node --test`, nur synthetische Daten, Screenshots nach `/tmp/noty-admin-*.png`:

```bash
PLAYWRIGHT_MODULE=/pfad/zu/node_modules/playwright node tests/admin-browser.mjs
```
