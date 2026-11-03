# Überarbeitung Gesetzessammlung (feat/gesetze)

Auftrag des Nutzers vom 03.11.2026: Markieren komplett überarbeiten und reparieren, Fensterverhalten (✕ oben rechts schließt wirklich), Fehler suchen, Tastenkürzel ergänzen, ins noty-Design einpassen. Grundlage: Prüfbericht vom 03.11.2026 und [Datenvertrag](LAW-MARKS-CONTRACT.md). Server und Website bleiben in diesem Schritt unverändert; Farbsynchronisierung, Notizen und Unterstreichen sind nicht Teil davon.

## Bestätigte Fehler

- B1 (hoch, Daten): Wiederherstellen einer Sicherung nach Gastübernahme erzeugt doppelte Einträge (`importData` prüft Duplikate nur mit Eigentümer, `adoptGuests` gar nicht); `load()` sperrt dann den ganzen Bestand. Fix: Duplikatprüfung unabhängig vom Eigentümer; vorhandene Duplikate beim Laden kontrolliert zusammenführen (höchste Revision gewinnt, Altdatei vorher exakt sichern), statt zu sperren.
- B2: ✕, Esc, `Space l` parken nur; Heft-Menü und Palette schließen nie; „Ganz schließen“ ohne Animation.
- B3: Mit normaler Hardwaretastatur kein Gesetzeskürzel im Heft (nur Palette).
- B4: „Letzte Markierung rückgängig“ nimmt `marks.last` nach Speicherreihenfolge, trifft fremde/synchronisierte Markierungen; Entfernen nicht rückgängig zu machen. Gelöschte IDs sind auf Server und im Store für immer gesperrt → Undo braucht neue IDs.
- B5: Markierungsliste zeigt den kanonischen Schlüssel statt Originaltext; keine Gruppierung, keine Farbe; Löschen ohne Rückfrage.
- B6: Überlappungen doppelt, nie zusammengeführt oder geteilt; Entfernen löscht immer ganze Markierungen; spätere Farbe überdeckt frühere.
- B7: PDF-Auswahl wird je Zeile eine eigene Annotation ohne Anker; Textmarkierungen erscheinen nicht im PDF; im PDF kein Antippen/Ändern.
- B8: Farbe nur lokal (Server verwirft `color`); Umfärben mit gleicher ID würde nach künftiger Server-Erweiterung 409 ergeben → immer neue ID.
- B9: „Synchronisiert“ obwohl Einträge ausstehen (laufender Sync kehrt sofort zurück); dauerhaft abgelehnte Einträge ohne Auflösung; Status nur im „…“-Menü.
- B10: Neue Fassung: Markierungen der alten verschwinden ohne Hinweis; Lesestelle merkt sich die Fassung nicht.
- B11: Stift-Einrasten ungenau (Surrogatpaare, Zeilenende), Stifttipp tut nichts.
- B12: Leser zeigt Markierungen aller Konten; nach Logout gehen neue Markierungen an das alte Konto. Ziel: nur Einträge des aktuellen Eigentümers (angemeldet: Konto; abgemeldet: Gast), fremde bleiben gespeichert, erscheinen aber nicht.
- B13: Swift-Kanonisierung von Σ weicht von JS ab (σ statt ς); gemeinsamen Vergleichstest ergänzen, Abweichung beheben.
- B14: Geschlossenes Fenster bleibt im View-Baum und lädt den Leser; Andocken bei zweiter Ansicht blendet sie ohne Hinweis aus.
- B15: Katalogfehler verhindert das Laden der persönlichen Daten.
- B16: Jede Änderung schreibt die ganze `personal.json` neu, auch n-mal je Sync.
- Verdacht: ⌘Z im Gesetzesfenster geht an das Heft-Undo; Bildschirmtastatur verkleinert die Arbeitsfläche; PDF-Highlights ohne Quads; Lesezeichenzeile mit zwei Buttons.

## Zielbild Markieren

- Auswahl → schwebende Leiste an der Auswahl (Optik `SelectionActionBar`): 5 Farbpunkte (Tippen markiert sofort), Kopieren, Entfernen bei Überlappung, Schließen. Editmenü „Markieren ›“ mit Farben.
- Tippen auf Markierung → auswählen mit Kontur, Leiste: Farbe ändern, Entfernen, Bereich anpassen.
- Bereichsrechnung im Core (`LawMarkEditing`) auf kanonischen Offsets: gleiche Farbe überlappend/angrenzend → zusammenführen; andere Farbe → neue gewinnt, alte wird geteilt; Teilbereich entfernen → teilen; exaktes Duplikat → nichts. Jede Änderung = Löschungen + Neuanlagen mit neuen UUIDs (Server unveränderlich).
- Stift: an die Startzeile binden (Wechsel erst ab ~0,6 Zeilenhöhen), Wortgrenzen über Tokenizer, Stifttipp markiert Wort bzw. radiert, Radierer teilt.
- Rückgängig/Wiederholen als eigener Stapel (gelöschte Payloads + neue IDs), ⌘Z/⇧⌘Z bei Gesetzfokus, Toast „Markierung entfernt · Rückgängig“.
- Store: `batch(puts, removes)` als ein Commit/Schreibvorgang/Undo-Schritt; Sendereihenfolge Neuanlagen vor Löschungen.
- Sync-Status im Kopf (Gast „Nur auf diesem iPad“, ✓, ↑ n, ⚠), Details mit „Jetzt synchronisieren“; erneuter Lauf statt Rückkehr; „Synchronisiert“ nur bei leerer Warteschlange; abgelehnte Einträge sichtbar mit „Erneut versuchen“/„Nur lokal behalten“.
- Liste gruppiert nach Gesetz/Fassung/Abschnitt, Originaltext-Auszug, Farbpunkt, PDF-Seite, Wischen zum Löschen mit Undo.
- Fassung: Hinweis „n Markierungen in Fassung … – anzeigen“; Lesestelle merkt Fassung, Text/PDF, Versatz.
- PDF: eine Annotation je Seite mit allen Rechtecken plus Anker (wie Website), Stift mit Anker, Textmarkierungen im PDF anzeigen, Antippen zeigt Leiste.
- Darstellung: abgerundete Flächen in Glyphenhöhe (eigener `NSLayoutManager`), App-Gelb wie Website.

## Zielbild Fenster

- Zustandsmodell im Core (`LawPanelState`: open, stashed, docked, edge; Aktionen open, close, park, unpark, toggle) mit Tests.
- ✕ oben rechts schließt mit `NotyMotion.panel`; gemerkt werden Kante, Andocken, Größe sowie Gesetz, Fassung, Abschnitt, Text/PDF, Seite, Versatz.
- Parken als eigener Knopf links neben ✕ mit Kantensymbol und Tooltip „An den Rand“; Ziehen über den Rand bleibt; kleines ✕ an der Lasche schließt.
- Heft-Menü und Palette: echter Umschalter mit Häkchen; Esc, `Space l`, ⇧⌘L schließen.
- Leser erst laden, wenn das Fenster sichtbar wird; Andocken bei zweiter Ansicht mit Hinweis; Arbeitsfläche ignoriert die Bildschirmtastatur.

## Tastenkürzel (normale Tastatur)

Global im neuen Menü „Gesetze“ (Menüleiste und ⌘-Overlay): ⇧⌘L öffnen/schließen, ⌥⌘L parken/hervorholen, ⌘L Fundstelle suchen. Bei Gesetzfokus (Tipp ins Fenster, ⌘L/⇧⌘L; Berührung der Seite nimmt ihn zurück), als UIKeyCommand mit `discoverabilityTitle`: Esc (Auswahl → Eingabe → schließen), ⌘F im Gesetz suchen, ⌘G/⇧⌘G bzw. Enter/⇧Enter Treffer, ←/→ Vorschrift, ↑↓/⌥↑↓/Leertaste scrollen, ⌘↑/⌘↓ Anfang/Ende, ⌘+ ⌘- ⌘0 Schrift, ⌘D Lesezeichen, ⌘T Gesetz wählen, ⇧⌘T Inhaltsverzeichnis, ⌥⌘B Liste, ⌥⌘P Text ↔ PDF, 1–5 Farbe bei Auswahl/Markierung, ⇧⌘H letzte Farbe, ⌫ Markierung entfernen, ⌘Z/⇧⌘Z Markier-Undo. Andocken per ⌃⌘Pfeil nur, wenn iPadOS es nicht belegt. Nicht verwenden: ⌘H, ⌘Space, ⌘Tab, ⇧⌘3/4/5, ⌥⌘D, 🌐-Kombinationen, ⌘W bleibt Heft schließen. Helix (`GESETZE`): Esc/`Space l` schließen, `P` parken, `m1`–`m5`/`mm` markieren, `d` entfernen, `u`/`U` Undo/Redo. Core-Tabelle `LawShortcuts` mit Eindeutigkeitstest.

## Design (Ist → Ziel, Auszug)

noty-Stil: weiße Symbole auf `notyGlass` oder `white 0.065–0.13`, 44-pt-Zellen, `NotyToolStyle`/`NotyPressStyle`, `notyTooltip`, Rand `white 0.18`, Trenner `white 0.14`, Symbole 18 pt (Optionen) bzw. 23 pt (Leiste), Akzent für Auswahl, Abstände 4/6/8/12/16/20. Abweichungen: Fensterkopf `.ultraThinMaterial`, Knöpfe 44×36 systemblau, Menüsymbol wie „Zweite Ansicht“, kein Titel, Kapsel-Griff statt Punktgriff; Rahmen/Schatten; Hintergrund `.systemBackground` statt `white 0.065`; unterschiedliche Textfarben HTML/Klartext; Leserkopf `.borderless` blau, 30×32; doppelte Symbole (`bookmark`, `books.vertical`); Fassungsmenü ohne Häkchen; Suchfeld ohne Lupe und < 44 pt; zwei Eingabeflächen; Paragraphfeld 32 pt; Textknöpfe in `.caption`; Stiftschalter als Segmented Picker statt `ToolbarGlyph`-Zellen; Farbwahl als Textmenü statt Farbpunkte; Markierleiste `.regularMaterial` mit Textknöpfen; PDF-„Markieren“ als UIKit-Button; Fußzeile `.bordered` statt Glas-Navigator; Sheets mit großen Titeln, ohne Markierung des aktuellen Eintrags, ohne Suche, ohne Leerzustand; Lasche `white 0.28` ohne Druckrückmeldung; Drop-Vorschau ohne `.continuous`; Größengriff ohne Rückmeldung; `.help()` statt `notyTooltip`; Einstellungsseite ohne Symbole. Ziel für Kopf und Optionen: ein Glas-Kopf plus eine Optionszeile in der Grammatik von `EditorToolOptions`.

## Arbeitspakete und Dateizuständigkeit

Gemeinsame Vorarbeit (Schritt 0b): `LawPanelModel` aus `LawLibraryModel` herauslösen, Bausteine aus `EditorToolOptions` (swatch, glyphOption, labeled, groupDivider) in eine eigene Datei, Schnittstelle `LawMarkController`.

- A1 Daten und Abgleich: Core `LawPersonalStore`, `LawLibrary`, neu `LawMarkEditing`, Tests; `LawLibraryModel` (Speichern, Sync, Status, Eigentümer).
- A2 Markier-Bedienung: `LawMarking.swift`, `LawTextView.swift`, `LawPDFView.swift`, neu `LawMarkBar.swift`, `LawMarkController.swift` (Umsetzung), Markierungsliste.
- B1 Fenster: `LawPanelModel.swift`, `LawPanelView.swift`, `EditorWorkspace.swift` (nur Gesetzesebene), Core `LawPanelGeometry`, neu `LawPanelState`, Lasche/Drop/Griff, `LawSettingsView.swift`.
- B2 Tastatur: neu `LawKeyCommands.swift`, `LawReaderKeyboard.swift`, `NotyCommands.swift`, `ContentView.swift` (nur Gesetz-Stellen), Core `HelixKeymap` (Gesetzeszeilen), neu `LawShortcuts`, `KEYBOARD.md`.
- C Leser-Design: `LawReaderView.swift` (Hülle), `LawReaderControls.swift`, `LawReaderLists.swift` (ohne Markierungsliste), `LawReaderLookup.swift`, `DESIGN.md`.

## Stand nach Zusammenführung

03.11.2026, Branch `feat/gesetze`: die fünf Pakete (Daten `d040f39`, Markieren `26b5a98`, Fenster `cf40203`, Tastatur `7efb118`, Design `8cefeb7`) per `--no-ff` zusammengeführt, ohne Textkonflikte, danach verbunden:

- **Daten ↔ Markieren**: `commit(plan:)` schreibt jeden Plan als einen atomaren Vorgang (`commit(puts:removes:)` → Store `batch`), ohne Zwischenabgleich; IDs vergibt der Plan (`LawMarkAddition.id`), nichts wird nachträglich wiedergefunden. Entfernen, Listenlöschen, Rückgängig laufen darüber. Anker über `anchor(rendered:range:sectionText:sectionID:)`, Textvergleiche über UTF-16. Leser, Liste und Zähler sehen nur Einträge des aktuellen Eigentümers (`visibleItems`, `markCounts(law:)`).
- **Abgleichstatus**: Zeichen im Leser aus `syncState` (Gast, aus, abgelaufen, läuft, Fehler, ausstehend, abgelehnt, synchronisiert), nicht mehr am Text erkannt; abgelehnte Einträge mit „Erneut versuchen“/„Nur lokal behalten“, Hinweis zur Duplikatreparatur und Zahl fremder Einträge in Einstellungen › Gesetzessammlung.
- **Design ↔ Markieren**: Lesestil (`LawReadingStyle`) in der Textansicht; unterer Textabstand = Fußzeile + Markierleiste, Leiste und Toast bleiben über der Fußzeile. Eine Stift-Umschaltung (Design, `ToolbarGlyph`/`NotySwatch`); „Letzte Markierung rückgängig“ im „…“-Menü und die alte Auswahlleiste entfallen (Undo: Toast, ⌘Z/⇧⌘Z, Helix `u`/`U`).
- **Lesestelle**: `readingSpot`/`rememberReading` statt eigener Schlüssel (Fassung, Text/PDF, Abschnitt, PDF-Seite; aktuelle Fassung als „aktuell“ gemerkt). PDF wird beim Wiederöffnen nur gezeigt, wenn es schon offline liegt. Der Scrollversatz wird noch nicht wiederhergestellt.
- **Tastatur ↔ Fenster/Leser**: Fensteraktionen über `LawPanelModel` (`toggle`, `togglePark`, `close`, `park`, `dock`, `float`); Esc/`Space l` schließen wirklich. ⌘F/⌘L öffnen die gemeinsame Suchfläche. 1–5, ⇧⌘H (`lastColor` des Controllers), ⌫, `m1`–`m5`/`mm`/`d` laufen über `LawMarkController` und wirken auch im PDF. Text- und PDF-Ansicht hängen die Kürzel an ihre `keyCommands`; ein Tipp ins Fenster setzt den Fokus; der erst beim Sichtbarwerden entstehende Leser übernimmt einen vorher gesetzten Fokus im `onAppear`.

Nachweise: Core-Tests 1165 (3 übersprungen, 0 Fehler), `check_page_workflow.sh` grün, `check_law_workflow.sh` mit dem echten Katalog grün (`LawRealCatalogTests` 2 Tests, ≈ 264 s), `xtool dev build` erfolgreich ohne neue Warnungen in Law*-Dateien. **Nicht installiert, am iPad ungeprüft.** Offen: SCOPE nennt „nach Logout lokal sichtbar“, B12 zeigt nach dem Abmelden nur Gast-Einträge (Kontoeinträge bleiben gespeichert) – Nutzerentscheidung bestätigen; Scrollversatz der Lesestelle.

## Korrekturen nach Code-Prüfung (feat/gesetze-fix-code)

- Lesezeichen offline entfernt und am selben Ziel neu gesetzt ging beim Abgleich verloren: Lesezeichen-Löschungen gehen jetzt vor Neuanlagen; `record` übernimmt keine Server-ID eines gelöschten, noch ausstehenden Eintrags (`testBookmarkToggledOffAndOnOfflineSurvivesSync`, `testBookmarkNeverTakesOverTheIDOfAPendingDeletion`).
- `LawMarkEditing.add` teilt andere Farben nur an der neuen Auswahl, nicht am zusammengeführten Bereich; gleiche Farbe verbindet nur, wo keine fremde übrig bleibt.
- Undo/Redo: Core `LawMarkHistory` zieht neue IDs jeder Wiedergabe in beiden Stapeln nach; Eigentümerwechsel leert die Stapel, Schritte eines anderen Eigentümers werden nie geschrieben.
- Heftfläche (auch Split) endet wieder an der Bildschirmtastatur wie vor dem Gesetzesfenster (`LawPanelLayout.notebookFrame`/`notebookOverhang`, unten anliegende Hefte reichen wie früher unter die Tastatur); das Fenster weicht nur aus, solange eines seiner Felder tippt (`avoidsKeyboard` ← `LawKeyboard.fieldEditing`). Drop-Zonen und Größengriff beziehen sich auf die freie Höhe.
- Wiederherstellen im angemeldeten Zustand übernimmt Gasteinträge ins Konto (`importData(_:adoptingGuestsFor:)`).
- Pläne verlangen lebende Einträge (`batch(requireLive:)`, `LawPersonalConflict`): Teilstücke einer inzwischen vom Abgleich gelöschten Markierung werden nicht angelegt, Hinweis als Meldung.
- PDF-Nutzlasten gerundet, auf 0…1 begrenzt und unter 64 KiB (`LawPDFAnchoring.fitted`); `Space l` gibt den Fokus ohne feste Verzögerung (`LawKeyboard.openWithKeys`); Text- und PDF-Ansicht des Lesers geben Tastendrücke an den `KeyboardRouter` weiter.

Nachweise: Core-Tests 1181 (3 übersprungen, 0 Fehler, zweimal), `check_page_workflow.sh` grün, `xtool dev build` erfolgreich. **Nicht installiert, am iPad ungeprüft** (Tastatur/Split/Caret-Reveal, Helix nach Touch-Auswahl, `Space l`).

## Bedien- und Designbefunde (feat/gesetze-fix-ux)

Umgesetzt nach dem Prüfbericht zur überarbeiteten Sammlung, Einzelheiten in [DESIGN](DESIGN.md#gesetzessammlung-bedien--und-designbefunde--03112026) und [KEYBOARD](KEYBOARD.md#gesetzessammlung-normale-tastatur): kompakte Leserleiste (Suchen/§ eine Zelle, Lesezeichen an der Überschrift, Schrift im „…“), Abgleichzeichen nur bei Bedarf und Details ohne Servercodes, Markierleiste ≤ 360 pt mit Abstand zur Auswahl, Touch-Rückgängig im „…“-Menü und Toast nach Stiftmarkierungen, sichtbarer Tastaturfokus im Fensterkopf, Esc-Kaskade mit Suchfläche, Menü „Gesetze“ nur bei eingeschalteter Sammlung mit Titeln je Zustand. **Implementiert, SDK-Build und Core-Tests grün; nicht installiert, am iPad ungeprüft.**
