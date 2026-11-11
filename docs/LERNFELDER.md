# Lernfelder, Themen und Materialien

Stand: 08.11.2026, Branch `feat/lernfelder` (von `feat/kalender`), gemergt nach `feat/kalender`, **noty calendar Build 144**. Auftrag des Nutzers vom 08.11.2026 („bau bitte ein, wie wir es im Plan beschrieben haben“) nach dem Gespräch über die Ausbildung zum Steuerfachangestellten. Nachweise je Build: [CALENDAR-LOG](CALENDAR-LOG.md); Gesamtplan: [CALENDAR-PLAN](CALENDAR-PLAN.md).

## Ziel

Die Berufsschule ist nach **Lernfeldern** organisiert, nicht nach Fächern: WS = LF 1, FP = LF 2, SR in den ersten drei Stunden der Woche = LF 3, SR sonst = LF 4. Bisher legte der Kalender pro Stunde ein kleines Heft in „Kalendernotizen“ an. Für den Nutzer ist ein Heft pro Lernfeld richtig, mit den Stunden als **Überschriften** darin. Zu jeder Stunde gehört ein **Thema**, und zum Thema sollen die passenden Unterlagen der Lernplattform (steuer-azubis.de) einen Tipp entfernt sein: das Video, die Skriptseite und die Paragrafen.

## Stand

| Teil | implementiert | gebaut | installiert | am iPad getestet |
| --- | --- | --- | --- | --- |
| Materialpaket (`.notymaterial`): Import, Prüfung, Verwaltung | ja | 144 | nein | ungeprüft |
| Materialsuche (Thema, Lektion, Seite, Paragraf, Seitentext) mit Video-Link und Skriptansicht | ja | ja | nein | ungeprüft (unter Linux mit dem echten Paket geprüft, s. u.) |
| Kalenderformat 5: Lernfelder, Zuordnungsregeln, Themen mit festgehaltenem Material | ja | ja | nein | ungeprüft (Core-Tests, Host-Rundlauf, Python-Prüfer bestanden) |
| Stunde → Abschnitt mit Überschrift im Lernfeld-Heft, Block aus mehreren Stunden | ja | ja | nein | ungeprüft |
| **Fach-Hefte** (Kalenderformat 6, 09.11.2026, `feat/fachheft`, noty dev Build 150): Fach → eigenes Heft der Bibliothek, Stunde öffnet es groß an ihrer Seite | ja | ja | nein | ungeprüft (Core-Tests 1620, Host-Rundlauf, Python-Prüfer bestanden) |
| Themenkarte im Terminfenster (Thema, Material, Merksatz) | ja | ja | nein | ungeprüft |
| Einstellungen › Kalender › Lernfelder / Materialien | ja | ja | nein | ungeprüft |
| **Lernfeld-Heft wählen** (11.11.2026, `feat/lernfeld-heft`, noty dev Build 153): ein Lernfeld schreibt in ein vorhandenes Heft der Bibliothek | ja | ja | nein | ungeprüft (Core-Tests 1630, `xtool dev build` bestanden) |
| Inhalt der Lernfeld-Hefte in der Seitenleiste („Stunden“) | ja | ja | nein | ungeprüft |
| Gesetzes-Reader direkt am Paragrafen öffnen, Rückverweise „deine Seiten“ | nein | – | – | – |
| Lernfeld-Übersicht mit Abdeckung der Kapitel, Klausurmodus | nein | – | – | – |

## Bedienung

1. **Material übernehmen:** Die Datei `steuer-azubis.notymaterial` in der Dateien-App antippen (oder Einstellungen › Kalender › Materialien › „Materialpaket hinzufügen“). noty prüft das ganze Paket und übernimmt es nur vollständig.
2. **Lernfelder anlegen:** Einstellungen › Kalender › Lernfelder › „11 Lernfelder aus ‚Steuer-Azubis‘ übernehmen“ (oder einzeln „Lernfeld hinzufügen“).
3. **Zuordnen:** Darunter stehen die Fächer des Stundenplans mit ihren Blöcken. Fach → Lernfeld (z. B. SR → LF 4), abweichende Blöcke einzeln (SR Mo 08:00–10:15 → LF 3). Der genauere Eintrag gewinnt.
4. **Mitschreiben:** Eine Stunde eines Lernfelds zeigt statt der leeren Notizseite „Mitschrift beginnen“. Das legt im Heft „LF n – Titel“ eine Seite mit der Überschrift „Mo 09.11.2026 · SR · 08:00–10:15 – Thema“ an, nach Datum an die richtige Stelle. Das Heft entsteht beim ersten Mal und liegt oben in der Bibliothek. Aufeinanderfolgende Stunden desselben Fachs und Lernfelds sind **ein Block** mit einer Überschrift. „Seite hinzufügen“ fügt am Ende des Abschnitts ein, nicht am Heftende.
5. **Thema und Material:** In den Details der Stunde stehen „Thema“, „Skript und Video suchen“ und „Merksatz“. Die Suche ist mit dem Thema vorbelegt, Treffer des eigenen Lernfelds stehen weiter oben. Jeder Treffer hat ▶ Video (öffnet die Lektion auf der Plattform im Browser mit dem eigenen Login), Skript (öffnet das PDF auf der Seite) und **Festhalten**. Festgehaltenes steht an der Stunde. Eine spätere Suche mit demselben Begriff zeigt das Festgehaltene zuerst. Ein Paragraf-Knopf sucht nach dieser Vorschrift.
6. **Wiederfinden:** Im Lernfeld-Heft zeigt die Seitenleiste unter „Inhalt“ die Liste „Stunden“ (Thema, Datum, Seitenzahl). Im Kalender öffnet die Stunde ihren Abschnitt. Die Überschrift ist normaler Text im Heft, also auch durchsuchbar und im PDF-Export enthalten.

Stunden ohne Lernfeld (z. B. Deutsch) und eigene Termine bleiben wie bisher: eine kleine Notiz in „Kalendernotizen“ – oder, seit Kalenderformat 6, ein **Fach-Heft**:

## Fach-Hefte (Kalenderformat 6, 09.11.2026)

Auftrag des Nutzers („heute steht Religion an, ich tippe drauf, und ein Notizbuch wird geöffnet“, Entscheidung: der große Editor, nicht die Notiz neben dem Termin): Ein Fach ohne Lernfeld-Regel bekommt **ein bestehendes Heft der Bibliothek** als Fach-Heft, ohne Nummern, Material oder Regeln.

1. **Zuordnen:** In der Stunde im Kalender „…“ › „Fach-Heft für „Religion“ wählen …“ (nur bei einer noch leeren neuen Notiz und nur, wenn keine Lernfeld-Regel greift). Zur Wahl stehen gewöhnliche aktive Hefte: keine Textdokumente, keine Lernfeld-Hefte, keine Kalendernotizen, kein Heft eines anderen Fachs. Die Wahl legt sofort die Seite dieser Stunde an und öffnet das Heft.
2. **Danach:** Die Stunde zeigt statt des Editors eine Karte „„Religion“ öffnen“. Beim ersten Mal entsteht wie im Lernfeld eine Seite mit Überschrift („Mo 09.11.2026 · Religion · 08:00–08:45“, Doppelstunden als ein Block) an der richtigen Stelle nach Datum; dann öffnet sich das Heft **groß** an dieser Seite, mit „Zurück zu Religion · Mo 9. Nov.“ zum Kalender. Später öffnet die Karte die bestehende Seite. Thema, Merksatz und festgehaltenes Material funktionieren wie bei Lernfeld-Stunden; die Seitenleiste des Hefts zeigt die Liste „Stunden“.
3. **Ändern:** Unter der Karte „Fach-Heft ändern“ (anderes Heft, Zuordnung aufheben) oder Einstellungen › Kalender › Lernfelder › „Fach-Hefte“. Aufheben lässt Heft und bisherige Seiten unverändert; die Stunden bekommen wieder kleine Notizen. Stunden, die schon eine eigene kleine Notiz hatten, behalten sie.
4. **Vorrang:** Greift für eine Stunde eine Lernfeld-Regel, gilt das Lernfeld; das Fach-Heft gilt nur für Stunden ohne Regel.
5. **Heft weg:** Liegt das Heft im Papierkorb, bietet die Karte „Heft wiederherstellen“ oder „Anderes Heft wählen“. Endgültig gelöscht: „Heft wählen“; ein Backup lässt die Zuordnung dann weg. Ersetzen eines Hefts verlangt wie bei Lernfeld-Heften, dass niemand das Paket hält (ein Schreiber je Paket; die Karte öffnet den Editor erst, nachdem die Seite festgeschrieben und das Paket freigegeben ist).

Datenmodell: `subjectNotebooks` in `CalendarState` (Format 6): `{id, subjectKey (wie Fachfarben), subjectName (1–200, getrimmt), notebookID}`, höchstens 200, je Fach ein Heft, je Heft ein Fach, nie das Heft eines Lernfelds (`CalendarStudy.validate`). Die Seiten selbst sind gewöhnliche Abschnitte (`CalendarNoteLink.pageID`, `StudySections`), das Heftformat bleibt unverändert. Nur geschrieben, wenn nicht leer: ein Stand ohne Fach-Hefte ist bytegleich zu Format 5 bis auf die Versionsnummer.

## Lernfeld-Heft wählen (11.11.2026)

Auftrag des Nutzers vom 11.11.2026: Seine bisherigen Schulunterlagen liegen, nach Lernfeldern geordnet, als fertige Hefte vor (importierte `.noty`-Dateien „LF 1 – …“ bis „LF 4 – …“). Neue Stunden sollen in **diese** Hefte geschrieben werden, nicht in ein zweites, von noty angelegtes „LF n – Titel“.

1. **Wählen:** Einstellungen › Kalender › Lernfelder, am Lernfeld „…“ (oder langes Drücken) › „Heft wählen …“. Zur Wahl stehen gewöhnliche aktive Hefte der Bibliothek: keine Textdokumente, keine wiederhergestellten Kopien, keine Kalendernotizen, nichts aus dem Papierkorb, kein Heft eines anderen Lernfelds oder Fachs (`CalendarNotesFolder.sectionNotebookCandidates`, dieselbe Regel wie beim Fach-Heft). Die Liste ist durchsuchbar und nennt den Ordner.
2. **Wirkung:** Nur die Kennung am Lernfeld ändert sich (`CalendarStudy.setNotebook`); das gewählte Heft wird dabei nicht geöffnet und nicht verändert. Die nächste Mitschrift legt wie immer eine Seite mit Überschrift an. In einem Heft ohne Abschnitte kommt sie **ans Ende**, hinter die vorhandenen Seiten; spätere Stunden sortieren sich nach Datum unter die Abschnitte ein (`StudySections.insertionIndex`, unverändert). Die neue Seite nimmt Papier und Farbe aus den Seitenvorgaben des Hefts.
3. **Ändern / lösen:** „Anderes Heft wählen …“ stellt um, „Heft lösen“ nimmt die Kennung weg (die nächste Mitschrift legt dann wieder ein neues „LF n – Titel“ an). In beiden Fällen bleiben das alte Heft und seine Seiten unverändert, und die bisherigen Mitschriften bleiben an ihren Stunden verknüpft. Sie öffnen dann aber als gewöhnliches Heft neben dem Termin (ohne Abschnittsleiste), weil das alte Heft kein Lernfeld-Heft mehr ist; der Auswahldialog sagt, wie viele Mitschriften das betrifft.
4. **Heft weg:** Wie bisher: Papierkorb → „Heft wiederherstellen“ oder „Neues Heft anlegen“; endgültig gelöscht → die nächste Mitschrift legt ein neues an.

Kein Formatwechsel: `studyFields[].notebookID` gibt es seit Format 5, die Regel „ein Heft hat einen Besitzer“ prüft `CalendarStudy.validate` schon. Eine Wahl aus einer veralteten Liste wird vor dem Speichern noch einmal gegen die Bibliothek geprüft; ein vergebenes Heft lehnt der Core ab, der Stand bleibt unverändert. Eine noch laufende Neuanlage des Lernfeld-Hefts (`studyCreations`) wird nach der Wahl nicht mehr fortgesetzt.

Nachweis: `LernfelderTests.testFieldTakesAnExistingNotebookOnlyWhenItIsFree`, `testSectionNotebookCandidatesAreOrdinaryActiveNotebooks`, `testFirstSectionOfAChosenNotebookGoesBehindItsPages` (Core, Linux). Die Bedienung (Menü, Auswahlblatt, erste Mitschrift in einem importierten Heft mit PDF-Seiten) ist am iPad ungeprüft.

## Datenmodell

### Kalenderformat 5 (`CalendarState`)

Neue optionale Schlüssel, nur geschrieben, wenn nicht leer:

- `studyFields`: `{id, number 1–99 (eindeutig), title (1–200), notebookID?, package?}`. Höchstens 40. Zwei Lernfelder teilen sich kein Heft. Das Heft wird **über die Identität** gefunden, nie über den Namen.
- `studyRules`: `{id, subjectKey (wie Fachfarben), subjectName, weekday? (ISO 1–7), startFrom?/startTo? (Minuten in Schulzeit, beide oder keins, from < to), fieldID}`. Höchstens 500, jede Regel verweist auf ein vorhandenes Lernfeld. Die spezifischste passende Regel gewinnt (Tag + Zeit > Tag > Zeit > Fach), bei Gleichstand die erste.
- `lessonTopics`: `{id, target (Notizziel wie bei `noteLinks`), topic? (≤ 200, einzeilig), summary? (≤ 2000), materials? (≤ 30 × `{package, key, label, detail?}`), modifiedAt}`. Höchstens 20.000, je Ziel ein Eintrag.

Abschnitte werden **nicht** im Heft gespeichert: Ein Abschnitt ist die Seite, auf die ein `CalendarNoteLink.pageID` zeigt, plus alle folgenden Seiten bis zur nächsten verlinkten Seite (`StudySections`). Das Heftformat bleibt unverändert. Die Überschrift ist ein gewöhnliches Textfeld. Ihre Höhe wird großzügig für den Text berechnet, damit nichts abgeschnitten wird. Ändert sich das Thema, wird die Überschrift nur angepasst, solange sie noch genau dem erzeugten Text entspricht.

Migration: Formate 1–5 werden gelesen und beim ersten Commit migriert, die exakten Altbytes vorher unter `Migration/format-<n>-…`. Format 4 mit Lernfeld-Schlüsseln ist kein Format 4, Format 5 mit `subjectNotebooks` kein Format 5; beides wird abgelehnt. Format ≥ 7 sperrt. Ältere Builds (bis noty calendar 143) sperren Format 5, Builds bis noty 149 sperren Format 6.

Bibliotheksbackup: Der Kalenderdatensatz trägt Format 3 bis 6. Beim Sichern verliert ein Lernfeld, dessen Heft endgültig gelöscht ist, nur die Heft-Kennung (das nächste Mitschreiben legt ein neues Heft an); ein Fach-Heft, dessen Heft endgültig gelöscht ist, fällt aus dem Backup heraus (die nächste Stunde fragt neu). Beim Wiederherstellen werden Lernfeld- und Fach-Heft-Kennungen wie die Notizlinks auf die Kopie umgeschrieben. Beim Wiederherstellen wird die Heft-Kennung wie die Notizlinks auf die Kopie umgeschrieben; fehlt sie, wird abgelehnt. Python-Prüfer `calendar_format.py` prüft dieselben Regeln unabhängig und zählt die Lernfeld-Hefte zu den Heften, die im Archiv sein müssen.

### Materialpaket `.notymaterial`

ZIP **ohne Kompression** (`ZIP_STORED`, kein ZIP64, keine Verschlüsselung) mit genau:

- `catalog.json`: `MaterialCatalog` Format 1, also `{format, id ([a-z0-9-]{1,64}), title, lessonURL?, fieldURL? (https, mit {id}), created?, fields}`. Ein Feld ist `{number, title, courseID?, chapters}`. Ein Kapitel ist `{key, index, number, part?, title, preface, script?, lessons, units, pages}`. Das Skript ist `{file (sicherer relativer Pfad), pageCount, byteCount, sha256}`. Eine Lektion ist `{id (UUID der Plattform), title, seconds?, order, pages? [von, bis]}`, eine Einheit `{title, pages, headings, norms}`, eine Seite `{page, head?, heading?, norms}`.
- `text.json` (optional): `{format 1, pages: {datei: [Text je Seite]}}`, nur für die Suche.
- `pdf/<datei>` für **jedes** Skript des Katalogs, sonst nichts.

Import (`MaterialStore.install`): Erst den Katalog prüfen (Grenzen, Pfade, Seitenbereiche, eindeutige Kennungen), dann jedes Skript einzeln in einen Staging-Ordner kopieren und dabei Länge und SHA-256 prüfen. Danach den Katalog zurücklesen und erst dann umbenennen. Ein vorhandenes Paket mit gleicher Kennung wird erst danach ersetzt. Jeder Fehler lässt den alten Stand unverändert.

Speicherort: `Documents/NotyMaterials/<id>/`, für das ganze Gerät (alle Bereiche), wie die Gesetzessammlung. **Nicht** im Bibliotheksbackup: Das Paket ist Quelldaten, die Paketdatei selbst ist die Sicherung. Was am Thema festgehalten ist, enthält einen Textstand (Titel, „LF 3 · Kapitel 4 · S. 5–9“) und bleibt ohne Paket lesbar. Gelernte Suchvorlieben (Festhalten) liegen in `UserDefaults` unter `noty.v2.materialPins.<paket>`.

Bauen: `python3 -I scripts/build_material_package.py QUELLE ZIEL.notymaterial --id … --title … --lesson-url … --field-url …` aus `struktur.json`, `index.json` (vom Erfassungslauf) und den PDFs. Das Skript enthält keine Inhalte. **Die Skripte und das Paket sind privates Lernmaterial der Plattform und gehören nie in ein Repository** (`origin` ist öffentlich). Sie liegen auf dem Server unter `/home/la/Materialien/`.

### Suche

`MaterialSearch` (Core, unter Linux getestet) normalisiert Groß-/Kleinschreibung, Umlaute und Satzzeichen. Jedes Suchwort muss am Wortanfang stehen, Wörter ab 4 Zeichen dürfen auch innerhalb eines Kompositums stehen („lieferung“ in „Werklieferung“). Bewertung: Lektionstitel > Einheitentitel > Paragraf > Seitenüberschrift > Kapitel > Seitentext. Paragrafen werden auf Nummer und Gesetz reduziert, „§ 3 UStG“ findet also auch „§ 3 Abs. 6 UStG“. Gesetze ohne § werden erkannt, wenn das Paket sie zitiert („9 EStG“). Seitentexte werden einmal im Hintergrund vorbereitet, die Suche läuft nicht auf dem Hauptthread.

Prüfung mit dem echten Paket (`NOTY_MATERIAL_PACKAGE=… swift test --filter LernfelderTests`, nur lokal, 08.11.2026): 11 Lernfelder, 144 Kapitel, 136 Skripte, 705 Videolektionen (657 mit Skriptseiten), 96 MB. Beispiele:

- „Fahrtenbuch“ → LF 3 Kap. 5 S. 55–57, LF 3 Kap. 7 S. 23–26, LF 4 Kap. 5 S. 26–28, jeweils mit Video.
- „§ 15 UStG“ → Vorsteuer-Stellen in LF 2 und LF 3.
- „Probezeit“ → LF 1 Berufsausbildungsvertrag mit § 22 BBiG.

## Sicherheitsregeln des Ablaufs

- Die neue Seite wird gespeichert, **bevor** die Stunde auf sie verweist. Ein abgebrochener Versuch findet seine Überschriftenseite beim nächsten Mal wieder (gleicher Text, noch nicht verknüpft) und legt keine zweite an.
- Ein neues Lernfeld-Heft wird je Lernfeld nur einmal angelegt. Scheitert das Einsortieren in die Bibliothek oder die Verknüpfung, verwendet der nächste Versuch dasselbe Heft und dieselbe Seite (`CalendarStudyCreation`).
- Liegt das Heft eines Lernfelds im Papierkorb, bietet die Stunde „Heft wiederherstellen“ oder „Neues Heft anlegen“ an; ein endgültig gelöschtes oder unlesbares Heft wird durch ein neues ersetzt (die Kennung im Lernfeld wird umgestellt).
- Eine Stunde, deren kleine Notiz noch angelegt wird, zeigt zuerst diese Notiz, nicht den Lernfeld-Hinweis.
- Ein Block übernimmt die Verknüpfung seiner ersten (nicht ausgefallenen) Stunde, sonst die eines anderen Mitglieds. Seit 11.11.2026 (`feat/audit-fixes`, `CalendarLessonTopics`, `CalendarLessonTopicTests`; am iPad ungeprüft) gilt derselbe Block-Rückfall auch für das Thema (Thema, Merksatz, Material), nicht nur für die Notizverknüpfung: Das Thema bleibt bei der Stunde, wenn sich ihr Beginn ändert oder die erste Stunde des Blocks ausfällt, und es folgt wie die Notiz einem Quellenwechsel des Termins. Offen bleibt, ob WebUntis einer verschobenen Stunde dieselbe Perioden-ID lässt ([CALENDAR-PLAN](CALENDAR-PLAN.md#9-offene-punkte)).
- Die Themenkarte speichert nur, was dort geändert wurde. Ändert die andere Stunde desselben Blocks das Thema, übernimmt die Karte den neuen Stand, solange dort nicht getippt wird.
- Aufräumen beim Start löscht nur Reste, die älter als eine Stunde sind; ein durch Abbruch zurückgebliebenes altes Paket wird zurückgelegt statt gelöscht.

Unabhängige Durchsicht am 08.11.2026 (Agent): 1 hoher, 4 mittlere und mehrere kleine Befunde, alle oben behoben. Der Python-Prüfer bildet die Kennung von Systemterminen jetzt exakt wie Swift, und der Mutationstest „Format-5-Felder unter Format 4“ ist neu.

## Offene Punkte und Grenzen

- **Am iPad ungeprüft:** Import des 96-MB-Pakets (Dauer, Speicher), Mitschrift beginnen (neues und vorhandenes Heft), Block über mehrere Stunden, Seite hinzufügen im Abschnitt, Themenkarte, Video-Link mit Login im Browser, Skriptansicht, Seitenleiste „Stunden“, Rückkehr zum Abschnitt nach „Vergrößern“.
- Die Überschriftenhöhe ist geschätzt (keine Textmessung in Core). Bei sehr schmalen Seitenformaten kann das Feld höher als nötig sein, aber nie zu niedrig für den Text.
- Ein Abschnitt hängt an der Kalenderverknüpfung. Löscht man die Überschriftenseite, verschwindet der Abschnitt aus „Stunden“; die Stunde zeigt dann wieder „Mitschrift beginnen“ und legt eine neue Seite an. Seiten nachträglich zwischen Abschnitte zu verschieben ändert die Zuordnung entsprechend der Reihenfolge.
- Lernfeld-Abschnitte gibt es nur für WebUntis-Stunden. Eigene Termine und Systemtermine behalten die kleine Notiz, und die Themenkarte erscheint nur bei Unterricht.
- Die Plattform-Links öffnen die Web-App im Browser (Login dort). Skript-Links der Plattform sind signiert und etwa 15 Minuten gültig, deshalb liegen die Skripte lokal im Paket.
- Ein Lernfeld-Heft, dessen Anlage nach dem Speichern, aber vor dem Einsortieren in die Bibliothek abgebrochen wurde und über einen Bereichswechsel verloren ging, erscheint beim nächsten Start lose in der Bibliothek; die nächste Mitschrift legt dann ein zweites Heft an (der Bereichswechsel warnt davor).
- Noch nicht gebaut: Sprung vom Paragraf-Knopf in den Gesetzes-Reader (der Reader hat keine Schnittstelle von außen; heute sucht der Knopf im Material), Rückverweise im Reader, Lernfeld-Übersicht mit Abdeckung der Kapitel, Klausurmodus, Handschrift-Suche, Aktualisieren des Pakets aus der Plattform.
