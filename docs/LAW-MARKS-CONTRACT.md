# Datenvertrag Gesetzes-Markierungen und Lesezeichen

Stand 03.11.2026, ermittelt aus App (`LawPersonalStore`, `LawLibrary`, Leser), Konto-Backend (`gesetzessammlung-noty/server/api.mjs`, `sync.mjs`) und Website (`lib/annotations.ts`, `hooks/useAnnotations.tsx`, `components/MarkedText.tsx`, `PdfViewer.tsx`). Grundlage für jede Änderung am Markieren: Was hier als Vertrag steht, muss App, Server und Website gemeinsam ändern.

## Markierungen

- Arten: `text` (Anker im Paragraphen), `pdf` (Freihand-Punkte), `pdf-text` (Zeilenrechtecke). Andere `kind`-Werte lehnt der Server mit 400 ab.
- Gemeinsame Felder: `id` (UUID in Kleinbuchstaben), `lawId`, `versionId` (müssen im Serverkatalog existieren), `page` (`text`: 0; PDF: 1…Seitenzahl).
- `text`-Anker: `{ sectionId, start, end, quote }`. Offsets in **UTF-16-Codeeinheiten** im **kanonischen Text** des Paragraphen `section.text` derselben Fassung. Kanonisch = NFKC, Kleinschreibung, nur `\p{L}` und `\p{N}` behalten (Leer-, Satzzeichen und kombinierende Zeichen fallen weg). Kleinschreibung wie JavaScript `toLowerCase()` (ohne Gebietsschema, Groß-Sigma am Wortende → `ς`). Die Zuordnung zum Originaltext läuft über Gruppen `\P{M}\p{M}*|\p{M}+`; enthält ein Text kontextabhängige Kleinschreibung (Wortend-Sigma), gibt es dort keine Anker (Website wie App). Gemeinsamer Vergleich: `Core/Tests/Fixtures/law-canonical.json` aus `scripts/make_law_canonical_fixture.mjs` (Website und Server), geprüft von `LawCanonicalFixtureTests`. `quote` ist der kanonische Ausschnitt und muss exakt passen; `end - start` ≤ 12 000 (App- und Website-UI begrenzen auf 4 000).
- `pdf`: 2–1 500 Punkte, normiert 0…1 auf die ungedrehte CropBox, Ursprung oben links; `width` setzt der Server fest. `pdf-text`: 1–500 Rechtecke, normiert.
- Der Server speichert nur `{lawId, versionId, kind, page, points?, width?, rectangles?, anchor?}`. **`color` und alle weiteren Felder verwirft er**; die App hält `color` nur lokal (`localOnlyKeys`). Andere Geräte und die Website zeigen deshalb Gelb.
- Einträge sind unveränderlich: kein UPDATE. Gleiche ID mit anderem Inhalt → 409; gelöschte ID ist für immer gesperrt (409 `deleted`). Ändern heißt löschen und mit neuer UUID neu anlegen.
- Grenzen: 10 000 Markierungen und 20 MiB je Konto, Körper ≤ 64 KiB, 240 Schreibzugriffe je Minute.

## Lesezeichen

- Felder: `lawId`, `versionId`, `sectionId`, `view` (`text`/`pdf`), `page` (PDF), `id`; `label` vergibt der Server.
- Schlüssel auf dem Server: `law:version:view:(page | sectionId)`. Ein vorhandenes Ziel liefert die bestehende ID zurück; die App übernimmt sie.

## Abgleich

- App: `GET /api/sync?after=N` (≤ 500 Ereignisse, Cursor, `hasMore`), dann ausstehende Einträge senden; Löschungen vom Server gewinnen; lokal geänderte oder gelöschte Einträge werden nicht überschrieben.
- App sendet Neuanlagen vor Löschungen (Ersetzen = neue ID anlegen, dann alte löschen). Ein Aufruf während eines laufenden Abgleichs löst einen weiteren Lauf aus. „Synchronisiert“ nur bei leerer Warteschlange.
- Antworten: 2xx und 404 auf DELETE gelten als übernommen; 409 `deleted` macht den Eintrag lokal endgültig gelöscht; 400, 409 ohne `deleted` und 413 gelten als dauerhaft abgelehnt: Der Eintrag bleibt lokal, wird nicht erneut gesendet und wartet auf „Erneut versuchen“ oder „Nur lokal behalten“ (nie senden). 5xx/408/429 und andere 4xx werden beim nächsten Lauf wiederholt.
- Art + UUID ist in der App über alle Eigentümer eindeutig; eine Sicherung legt nichts doppelt an. Bestätigte Löschmarken verlieren nach 30 Tagen ihren Inhalt, ihre ID bleibt gesperrt.
- Website: fragt je Fassung `GET /api/annotations` ab und hält eine eigene Warteschlange.
- Gäste gibt es nur in der App; beim Login gehen Gast-Einträge an das Konto. Angemeldet zeigt die App nur Einträge des Kontos, abgemeldet nur die des Gasts; neue Einträge nach dem Abmelden gehören dem Gast. Einträge anderer Eigentümer bleiben gespeichert, erscheinen nicht und werden nicht von anderen gelöscht.

## Bekannte Lücken (Stand der Ermittlung; Groß-Sigma, Eigentümer nach Logout und dauerhafte 4xx am 03.11.2026 in der App behoben)

- Farbe nur lokal; App-Gelb weicht von Website-Gelb ab.
- PDF-Lesezeichen: Server schlüsselt nur nach Seite, die App sucht zusätzlich `sectionId`.
- App erzeugt für PDF-Markierungen keinen Textanker und zeigt Textmarkierungen nicht im PDF; die Website kann beides.
- Freihandstriche bricht die App bei 1 500 Punkten ab, die Website dünnt aus.
