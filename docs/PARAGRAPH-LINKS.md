# Gesetzesverweise im Heft (P1)

Stand: 06.11.2026, Branch `feat/paragraphen`, als noty dev Build 125 vorgesehen. Zugehöriger Gesamtplan: [MERKER-PLAN](MERKER-PLAN.md).

**Status:** implementiert und für das iPad-SDK **erfolgreich gebaut**. Core-Tests und Host-Roundtrip sind bestanden. **Auf dem iPad ungeprüft**, und zwar Hover-Gefühl, Erkennung von Pencil gegenüber Zeiger, Haptik, Kartenplatzierung und Gestenkonflikte.

## Was es macht

- Verweise wie „§ 35a Abs. 2 EStG“, „§§ 4, 5 EStG“, „Art. 3 GG“, „R 9.1 LStR“, „Abschnitt 1.1 UStAE“ und „AEAO zu § 122 AO“ werden in **Textfeldern, Fließtext und PDF-Text** dezent gepunktet unterstrichen, auch im Fließtext von „Neuer Texteditor (Test)“ (Text editor 2). Handschrift siehe unten (P3).
- **Apple Pencil (Hover):** Ruht der Stift etwa 0,5 s über einem Verweis und wurde seit etwa 1 s kein Strich gezogen, erscheint eine Vorschaukarte mit einem kurzen Signal im Pencil Pro. Antippen der Karte mit dem Stift öffnet das Gesetzesfenster an dieser Stelle. Der Stift auf dem Papier öffnet nie etwas. Squeeze und Doppeltippen behalten ihre bisherige Belegung.
- **Trackpad/Maus:** Etwa 0,4 s über dem Verweis zeigt die Karte. Ein Klick, während die Karte sichtbar ist, öffnet das Gesetz. Ein schneller Klick ohne Karte wählt wie bisher aus.
- **Finger:** Ein Tipp auf einen Verweis im PDF-Text (ohne Objekt darüber) oder mit dem Lesewerkzeug auf einen Verweis in einem Textfeld zeigt die Karte, ein zweiter Tipp öffnet das Gesetz. Mit Text-, Radier-, Laser-, Form-, Lasso- und Bildwerkzeug, beim Zeichnen mit dem Finger, auf Checkboxen und bei bestehender Auswahl verhalten sich Finger-Tipps wie bisher.
- **Karte:** Überschrift, Titel der Vorschrift und einige Zeilen ab dem genannten Absatz, aus dem lokalen Bestand. Ein Hover lädt nie etwas herunter. Ist ein Gesetz noch nicht offline, sagt die Karte das, und erst das Öffnen lädt es. Fehlt der Paragraph in der aktuellen Fassung, steht das so in der Karte.
- **„← Zurück zur Notiz“** im Gesetzesfenster nach einem Sprung: Es stellt den vorigen Zustand des Fensters wieder her (geschlossen, geparkt, sichtbar) und ebenso die vorherigen Lesestellen der aufgerufenen Gesetze.
- Einstellung: Einstellungen › Gesetzessammlung › „Gesetzesverweise im Heft verlinken“ (`noty.laws.citationLinks`, standardmäßig an). Sie erscheint nur, wenn die Gesetzessammlung aktiv ist.

## Regeln des Erkenners (`LawCitationScanner`, Core)

Lieber kein Link als ein falscher:

- Ein Gesetz nach einer Kette („§ 10 Abs. 1 i.V.m. § 10 Abs. 3 EStG“, „§ 4 und 5 EStG“, „§ 4 bis § 7 EStG“) gilt für die vorangehenden Glieder derselben Art. § und Art. bekommen nur Gesetze, R/Abschnitt/„zu §“ nur Verwaltungsvorschriften.
- Ein bloßes „§ 35a“ übernimmt das zuletzt genannte Gesetz im selben Text (`inferredLaw`, auf der Karte vermerkt). Ein unbekanntes Gesetz („§ 3 SolZG“, „§ 5 des Gesellschaftsvertrags“, „§ 15 Handelsgesetzbuch“) sperrt diese Übernahme bis zum nächsten bekannten Gesetz.
- Römische Absätze („§ 15 I 1 Nr. 2 EStG“), ein abgesetzter Buchstabe („§ 35 a EStG“) und Abkürzungen ohne Rücksicht auf Groß- und Kleinschreibung (ab 4 Zeichen) werden erkannt. „EStG-E“, „AO-Kommentar“ und datumsartige Nummern werden ausgeschlossen.
- Nicht erkannt: ausgeschriebene Gesetzesnamen, EStH (nicht im Katalog), „§ 122 AEAO“ und zweistellige UStAE-Nummern ohne „Abschnitt“.

## Text editor 2 und Handschrift (P2/P3, Seitenseite)

**Status:** implementiert, iPad-Build siehe Übergabe; **auf dem iPad ungeprüft**.

- **Text editor 2:** Der Fließtext steht im gemeinsamen `DocumentTextStore`. Jede Seite liest ihren Teil der gemeinsamen Anordnung (Container der Seite, Ursprung aus `DocumentPageRaster`) und unterstreicht dort. Gescannt wird der ganze Fließtext auf einmal (ein bloßes „§ 35a“ nimmt das zuvor genannte Gesetz, auch von früheren Seiten), das Ergebnis teilen sich die sichtbaren Seiten. Bei jeder Textänderung (`NSTextStorage`-Mitteilung) verschwinden die Unterstreichungen des Fließtexts, bis neu gescannt ist (entprellt). Mit dem Textwerkzeug liegt die Textfläche über den Seiten: Ihr Hover wird an die Seite darunter weitergereicht (`DocumentTextSurface+LawCitations.swift`), eine Berührung blendet eine Karte aus. Fingertipps setzen dort weiter den Caret, ein Klick mit dem Textwerkzeug öffnet nichts.
- **Handschrift:** Nur mit der Einstellung „Handschrift einbeziehen“. Die Tinte wird frühestens etwa 2,5 s nach dem letzten Strich erkannt, nur solange kein Strich, Radierer, Lasso oder Ziehen aktiv ist, mit Hilfspriorität abseits des Hauptthreads und für alle Seiten nacheinander. Erkennung wie die Suche (`PageTextRecognition.swift`, dieselbe Rasterung und dieselbe Vision-Anfrage). Ergebnisse werden nach dem Hash der Strichdaten zwischengespeichert (24 Stände), unveränderte Tinte wird nie erneut erkannt. Die erkannten Zeilen werden als ein Text gescannt; die Box eines Verweises kommt aus den Wortboxen von Vision (`boundingBox(for:)`), sonst aus dem anteiligen Zeilenausschnitt.
- Handschriftliche Verweise bekommen einen schwachen gestrichelten Rahmen statt der Punktlinie. Hover und Zeigerklick wie sonst (Karte mit `fromHandwriting`), ein Fingertipp gehört nie einem Handschrift-Verweis.
- **„§“ in Handschrift:** Vision liest es oft als „S“ oder „$“. Ein solches Zeichen wird nur dann als „§“ gelesen, wenn der Erkenner daraus genau „§ <Nummer> <Gesetz>“ mit geschriebenem, bekanntem Gesetz direkt hinter der Nummer macht, und nie nach einer Zahl, „Abs.“, „Nr.“, „S.“ oder „Satz“ (dort heißt „S 1“ Satz 1). Nicht behandelt: „§“ als „8“ gelesen.
- Heftkontext: Standardgesetz des Hefts geht in den Scan ein (Cache-Schlüssel), Karte bekommt Kontext und Seitenrechteck.

## Architektur

- `Core/Sources/NotebookCore/LawCitation.swift`: plattformunabhängiger Parser über UTF-16 mit Bereichen als `NSRange`, Tests in `LawCitationTests` (inklusive Fuzz und optional Prüfung der Schlüssel gegen den echten Katalog über `NOTY_LAW_FIXTURE_ROOT`).
- `Sources/Noty/WorksheetView+LawCitations.swift`: sammelt die Texte einer Seite, scannt abseits des Stiftpfads (entprellt, Scan in einem `Task.detached`) und zeichnet die Unterstreichung. Dazu kommen die Hover-, Klick- und Tipp-Gesten. Der PDF-Text wird pro Seite einmal gelesen, und jeder Treffer wird gegen `selection(for:)` geprüft. In wiederhergestellten Kopien gibt es keine Links.
- `Sources/Noty/LawCitationPreview.swift`, `LawCitationCard.swift`: geteiltes Modell (eine Szene) mit Karte, Platzierung (Tastatur, sichere Ränder) und einem Auszugs-Cache (64 Auszüge plus ein Dokument, wird bei Speicherwarnung geleert).
- `Sources/Noty/LawReaderCitation.swift`, `LawLibraryModel.swift`: Sprunganfrage an den Leser und der Rückweg.
- **Kein Formatwechsel:** Die Links sind abgeleitete Daten. Im Heft, im Backup oder im Abgleich wird nichts gespeichert.

## Gerätetest (gebündelt)

1. Ein Textfeld mit „§ 35a EStG“ und Fließtext mit „§ 10 Abs. 1 Nr. 2 i.V.m. § 10 Abs. 3 EStG“: Hover mit dem Pencil zeigt die Karte, Antippen der Karte öffnet, „Zurück zur Notiz“ führt zurück.
2. Beim Schreiben direkt neben einem Verweis darf keine Karte aufblitzen. Lasso, Radierer, Laser, Squeeze-Palette und die Hover-Vorschau des Werkzeugs müssen unverändert funktionieren.
3. Ein Feld, das nur „§ 9 EStG“ enthält, lässt sich mit dem Finger auswählen und verschieben. Ein Textfeld über einem PDF-Verweis lässt sich auswählen.
4. Ein PDF-Bescheid mit Paragraphen: Unterstreichungen liegen an der richtigen Stelle, auch auf gedrehten Seiten.
5. Trackpad: Hover, dann Klick auf die Karte bzw. den Verweis. Ein schneller Klick wählt aus.
6. Ein Gesetz, das noch nicht offline ist, im Flugmodus: Die Karte zeigt den Hinweis, beim Öffnen erscheint eine verständliche Fehlermeldung.
