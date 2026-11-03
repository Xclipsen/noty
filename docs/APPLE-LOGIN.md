# Mit Apple anmelden

Status: in Arbeit auf `exp/ki` (App) und im Konto-Backend `gesetzessammlung-noty` (Server, Website). Vom Nutzer am 03.11.2026 beauftragt: App und Web, bestehendes Konto „Leon“ verknüpfen, Live-Backend mit Sicherung ausrollen. Ersetzt die frühere Grenze „kein Apple-Login im kostenlosen Signierungssetup“ (seit 29.10.2026 bezahltes Developer-Konto).

## Grundsätze

- Apple ist ein zusätzlicher Anmeldeweg zu einem noty-Konto, kein zweites Kontosystem. Gespeichert wird nur Apples stabile Kennung `sub` je Konto, gehasht ist nicht nötig, aber nie E-Mail oder Name aus dem Token. Ein `sub` gehört höchstens einem Konto, ein Konto hat höchstens eine Apple-Verknüpfung.
- Bestehende Konten werden nur verknüpft, wenn der Nutzer gerade mit diesem Konto angemeldet ist. Kein Zusammenführen über E-Mail-Adressen.
- Unbekanntes `sub` beim Login legt ein neues Konto an (wie offene Registrierung, gleiches Ratelimit). Name: Apple-Vorname, wenn vorhanden und frei, sonst `apple-` plus 6 zufällige Zeichen; immer eindeutig.
- Identity-Token werden serverseitig vollständig geprüft: RS256-Signatur gegen `https://appleid.apple.com/auth/keys` (gecacht, bei unbekanntem `kid` einmal neu laden), `iss == https://appleid.apple.com`, `aud` aus `APPLE_AUDIENCES`, `exp` in der Zukunft, `iat` höchstens 10 Minuten alt, `nonce` passend. Jede Unklarheit lehnt ab.
- Keine Client-Secrets nötig: Die App liefert das Token direkt, das Web nutzt `response_type=code id_token` mit `response_mode=form_post` und prüft nur das `id_token`. Der Code wird nicht eingelöst.
- Ohne konfigurierte Services ID bleibt der Web-Knopf ausgeblendet; die App funktioniert unabhängig davon.

## Konto-Backend (`gesetzessammlung-noty/server`)

Additive Migration: `CREATE TABLE IF NOT EXISTS apple_identities(sub TEXT PRIMARY KEY, user_id TEXT NOT NULL UNIQUE REFERENCES users(id), created_at INTEGER NOT NULL)`. Sonst keine Schemaänderung.

Umgebung: `APPLE_AUDIENCES` (kommagetrennt: App-Bundle-IDs und Services ID; für die App ist das die **tatsächlich installierte, doppelt präfixierte** Bundle-ID, also `aud = XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.dev` für noty dev bzw. `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype` für noty, nicht die Basis-ID aus `xtool.yml`), `APPLE_SERVICES_ID` (nur Web), `APPLE_WEB_REDIRECT` (`https://law.xclipsen.de/api/apple/callback`).

| Pfad | Eingabe | Antwort |
| --- | --- | --- |
| `POST /api/apple/login` | `{ identityToken, nonce, name?, create? }`; `nonce` ist der Rohwert, im Token steht immer `sha256(nonce)` hex; `create: false` legt kein neues Konto an (Admin-Panel) | wie `/api/login`: Sitzung, mit `X-Noty-Client: 1` Token im JSON; `created: true` bei neuem Konto |
| `POST /api/apple/link` | `{ identityToken, nonce }`, angemeldet | `200 { user, apple: true }`; `409` wenn `sub` schon an anderem Konto oder Konto schon verknüpft |
| `DELETE /api/apple` | angemeldet | `200 { apple: false }`; abgelehnt, wenn das Konto sonst kein Passwort hätte |
| `GET /api/session` | | zusätzlich `user.apple: true\|false` |
| `GET /api/apple/start?mode=login\|link` | Web, `link` nur angemeldet | `302` zu Apple mit `state` und `nonce = sha256(Rohwert)`; Rohwert serverseitig 10 Minuten, einmalig |
| `POST /api/apple/callback` | Formular von Apple: `state`, `id_token`, optional `user` | setzt die Website-Sitzung bzw. verknüpft, `303` auf `/` mit Ergebnis im Fragment |

Fehlermeldungen deutsch. Ratelimits wie bei Login. Konten ohne Passwort, die nur per Apple entstehen, sind erlaubt; sie können später ein Passwort setzen, falls die Website das anbietet, sonst bleibt nur Apple.

## App (noty dev)

- Entitlement `com.apple.developer.applesignin = [Default]` über `entitlementsPath` in `xtool.yml`; xtool muss die Fähigkeit für die App-ID einschalten (Build-Nachweis).
- Kontoseite: „Mit Apple anmelden“ (`ASAuthorizationAppleIDButton`) beim Login, „Apple verknüpfen“ und „Trennen“ im angemeldeten Zustand. Nonce: 32 Zufallsbytes, Rohwert an das Backend, `sha256` an Apple.
- Keine Apple-Daten in UserDefaults, Backups oder Logs; die Sitzung landet wie bisher im Keychain des noty-Kontos.

### Stand App (03.11.2026)

**Implementiert und erfolgreich gebaut, nicht installiert, nicht auf dem iPad getestet.** `Noty.entitlements` über `entitlementsPath` in `xtool.yml`; Core `AppleSignIn.swift` (Nonce, Hash, Request-Körper, Antworttypen, Fehlertexte) mit `AppleSignInTests`; App `AppleSignInController.swift` (ASAuthorizationController, Anker = Key-Window der aktiven Szene, `ASAuthorizationAppleIDButton`), `LawLibraryModel.appleLogin/appleLink/appleUnlink/refreshAccount` mit derselben Sitzungsübernahme wie der Passwortweg, Kontoseite mit Apple-Knopf, „Apple verknüpfen“, „Apple trennen“. Lokal gehalten wird nur `user.apple` (im Keychain-Eintrag des Kontos).

**Blocker Signierung: xtool 1.22.2 kann die Fähigkeit nicht setzen.** Signierter Testbuild (Bundle-ID vorübergehend `XTL-BAFXLQ964V.de.la.noty.dev`, danach byte-gleich wiederhergestellt): Die App-Signatur enthält `com.apple.developer.applesignin = [Default]`, das frisch erzeugte Profil aber nur `application-identifier`, `team-identifier`, `get-task-allow`, `keychain-access-groups`. Ursache im Quelltext von 1.22.2 (`DeveloperServicesCapability.swift`, `DeveloperServicesAddAppOperation.swift`): Für den Schlüssel gibt es keinen Entitlement-Typ, also keine Capability; zusätzlich löscht xtool bei jedem signierten Build alle Capabilities der App-ID, die nicht aus den Entitlements folgen (außer In-App-Kauf). Im Developer-Portal von Hand eingeschaltetes „Sign in with Apple“ würde deshalb beim nächsten Build wieder entfernt. Ein so gebautes IPA würde iOS wegen nicht erlaubter Entitlements nicht installieren. xtool **1.24.0** ergänzt `AppleSignInEntitlement` mit `APPLE_ID_AUTH`/`PRIMARY_APP_CONSENT`; Update von xtool nur mit Nutzerfreigabe (ENVIRONMENT). Bis dahin dürfen mit `entitlementsPath` keine OTA-/USB-Builds veröffentlicht werden.

### Nachbesserung App (03.11.2026, Review)

- **Kein stilles neues Konto:** Ist die Sitzung eines bekannten Kontos abgelaufen oder liegen auf dem iPad noch nicht übertragene Markierungen eines anderen Kontos, sendet „Mit Apple anmelden“ zuerst `create: false` (`AppleLoginPlan`). Antwortet der Server `401 apple_unknown`: bei abgelaufener Sitzung Hinweis „mit Passwort anmelden, dann Apple verknüpfen“, kein Konto; bei fremden Daten Nachfrage „Neues noty-Konto anlegen?“, nur nach Bestätigung zweite Anfrage mit demselben Token (der Server prüft Nonce und Alter ≤ 10 min, keine Einmalverwendung; sollte er das künftig tun, scheitert die zweite Anfrage mit Meldung).
- `401` beim Verknüpfen setzt `sessionExpired` (das Apple-Token selbst wird serverseitig mit anderem Status abgelehnt).
- Der Apple-Knopf wird bei Wechsel von Typ (Anmelden ↔ Registrieren) oder Stil neu erzeugt; die Delegate-Rückmeldungen wechseln per `Task { @MainActor … }` statt `MainActor.assumeIsolated`, der Präsentationsanker antwortet auf dem Hauptthread direkt, sonst über `DispatchQueue.main.sync`.
- Abbruch 1001 innerhalb von 0,8 s (oder mit unterliegendem `AKAuthenticationError` -7026/-7027) gilt als „kein Apple-Fenster“ und zeigt den Hinweis auf eine angemeldete Apple-ID; ein echter Abbruch bleibt still. Die Erkennung ist eine Heuristik, nur am Gerät prüfbar.
- `refreshAccount` übernimmt seine Antwort nur, wenn seitdem keine lokale Kontoänderung (Verknüpfen, Trennen, Anmeldung, E-Mail) lief (`AccountUpdateGate`) und kein Kontovorgang aktiv ist.
- Nachweise: `AppleSignInTests` (Request-Körper mit `create: false`, Plan, Gate, Abbruchhinweis), SDK-Build. Signierung: xtool 1.24.0, Build 93 enthält die Fähigkeit in Signatur und Profil (ENVIRONMENT). Nicht installiert durch diese Änderung, am iPad ungeprüft.

## Admin-Panel

Das Admin-Panel gehört zum KI-Dienst. Ein experimenteller KI-Assistent existiert separat auf dem Branch exp/ki und ist nicht Teil dieses Release-Kandidaten.

## Apple-Developer-Portal (nur der Nutzer)

Für das Web eine Services ID, z. B. `de.xclipsen.noty.web`, mit „Sign in with Apple“ anlegen. Primäre App-ID: die noty-App-ID. Domains `law.xclipsen.de`, `noty.xclipsen.de`; Return-URLs `https://law.xclipsen.de/api/apple/callback`, `https://noty.xclipsen.de/admin/api/apple/callback`.
