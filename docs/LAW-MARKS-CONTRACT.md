# Datenvertrag Gesetzes-Markierungen und Lesezeichen

Stand 03.11.2026, ermittelt aus App (`LawPersonalStore`, `LawLibrary`, Leser), Konto-Backend (`gesetzessammlung-noty/server/api.mjs`, `sync.mjs`) und Website (`lib/annotations.ts`, `hooks/useAnnotations.tsx`, `components/MarkedText.tsx`, `PdfViewer.tsx`). Grundlage für jede Änderung am Markieren: Was hier als Vertrag steht, muss App, Server und Website gemeinsam ändern.

## Markierungen

- Arten: `text` (Anker im Paragraphen), `pdf` (Freihand-Punkte), `pdf-text` (Zeilenrechtecke). Andere `kind`-Werte lehnt der Server mit 400 ab.
- Gemeinsame Felder: `id` (UUID in Kleinbuchstaben), `lawId`, `versionId` (müssen im Serverkatalog existieren), `page` (`text`: 0; PDF: 1…Seitenzahl).
- `text`-Anker: `{ sectionId, start, end, quote }`. Offsets in **UTF-16-Codeeinheiten** im **kanonischen Text** des Paragraphen `section.text` derselben Fassung. Kanonisch = NFKC, Kleinschreibung, nur `\p{L}` und `\p{N}` behalten (Leer-, Satzzeichen und kombinierende Zeichen fallen weg). `quote` ist der kanonische Ausschnitt und muss exakt passen; `end - start` ≤ 12 000 (App- und Website-UI begrenzen auf 4 000).
- `pdf`: 2–1 500 Punkte, normiert 0…1 auf die ungedrehte CropBox, Ursprung oben links; `width` setzt der Server fest. `pdf-text`: 1–500 Rechtecke, normiert.
- Der Server speichert nur `{lawId, versionId, kind, page, points?, width?, rectangles?, anchor?}`. **`color` und alle weiteren Felder verwirft er**; die App hält `color` nur lokal (`localOnlyKeys`). Andere Geräte und die Website zeigen deshalb Gelb.
- Einträge sind unveränderlich: kein UPDATE. Gleiche ID mit anderem Inhalt → 409; gelöschte ID ist für immer gesperrt (409 `deleted`). Ändern heißt löschen und mit neuer UUID neu anlegen.
- Grenzen: 10 000 Markierungen und 20 MiB je Konto, Körper ≤ 64 KiB, 240 Schreibzugriffe je Minute.

## Lesezeichen

- Felder: `lawId`, `versionId`, `sectionId`, `view` (`text`/`pdf`), `page` (PDF), `id`; `label` vergibt der Server.
- Schlüssel auf dem Server: `law:version:view:(page | sectionId)`. Ein vorhandenes Ziel liefert die bestehende ID zurück; die App übernimmt sie.

## Abgleich

- App: `GET /api/sync?after=N` (≤ 500 Ereignisse, Cursor, `hasMore`), dann ausstehende Einträge senden; Löschungen vom Server gewinnen; lokal geänderte oder gelöschte Einträge werden nicht überschrieben.
- Website: fragt je Fassung `GET /api/annotations` ab und hält eine eigene Warteschlange.
- Gäste gibt es nur in der App; beim Login gehen Gast-Einträge an das Konto.

## Bekannte Lücken (Stand der Ermittlung)

- Groß-Sigma: Swift kanonisiert anders als JavaScript; in den echten Daten derzeit ohne Treffer, aber ohne gemeinsamen Test.
- Farbe nur lokal; App-Gelb weicht von Website-Gelb ab.
- PDF-Lesezeichen: Server schlüsselt nur nach Seite, die App sucht zusätzlich `sectionId`.
- App erzeugt für PDF-Markierungen keinen Textanker und zeigt Textmarkierungen nicht im PDF; die Website kann beides.
- Nach Logout gehen neue Markierungen an das zuletzt angemeldete Konto; Leser und Liste zeigen Einträge aller Konten.
- Dauerhafte 4xx-Antworten bleiben ewig „nicht übertragen“.
- Freihandstriche bricht die App bei 1 500 Punkten ab, die Website dünnt aus.
