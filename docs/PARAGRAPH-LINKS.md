# Gesetzesverweise im Heft und im Gesetzesleser (P1–P3)

Stand: 06.11.2026, Branch `feat/paragraphen`. P1 als noty dev Build 125/126 veröffentlicht, P2/P3 als noty dev Build 128 veröffentlicht. Zugehöriger Gesamtplan: [MERKER-PLAN](MERKER-PLAN.md).

**Status:** implementiert und für das iPad-SDK **erfolgreich gebaut**. Core-Tests und Host-Roundtrip sind bestanden. **Auf dem iPad ungeprüft**, und zwar Hover-Gefühl, Erkennung von Pencil gegenüber Zeiger, Haptik, Kartenplatzierung und Gestenkonflikte.

## Was es macht

- Verweise wie „§ 35a Abs. 2 EStG“, „§§ 4, 5 EStG“, „Art. 3 GG“, „R 9.1 LStR“, „Abschnitt 1.1 UStAE“ und „AEAO zu § 122 AO“ werden in **Textfeldern, Fließtext und PDF-Text** dezent gepunktet unterstrichen, auch im Fließtext von „Neuer Texteditor (Test)“ (Text editor 2). Handschrift siehe unten (P3). Die Schnellsuche im Gesetzesfenster nimmt seit 11.11.2026 (`feat/audit-fixes`, `LawReference.parse`; am iPad ungeprüft) dieselben Schreibweisen an: „Art.“/„Artikel“ („Art. 3 GG“), Satz/Nr./Buchst./Halbsatz/Alt. hinter dem Absatz („§ 3 Nr. 26 EStG“, für die Navigation ohne Wirkung) und ein Satzzeichen am Ende; vorher fielen sie in die Volltextsuche und endeten mit „… nicht gefunden“. Freier Text bleibt Volltextsuche.
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
- Ausgeschriebene Namen aus dem Katalog werden mit Beugung erkannt („des Einkommensteuergesetzes“, „der Abgabenordnung“, „Einkommensteuergesetz (EStG)“), nur ganz und eindeutig. Zu einem Verweis gehört nur eine Klammer mit der Abkürzung; das Gesetz in der Klammer nimmt seit 11.11.2026 (`feat/audit-fixes`) selbst keine Klammer mehr (keine verschachtelte Lesart), der Erkenner ist damit begrenzt und linear. Vorher kostete „AO (AO (AO (…“ quadratische Zeit und ließ ab etwa 2000 Wiederholungen den Stapel überlaufen.
- „§ 3 (6) UStG“, „§ 3 Abs. 6 UStG“, „§ 3 VI UStG“ und „§ 3 Absatz 6 UStG“ ergeben UStG § 3 Abs. 6.
- **Gesetzestext-Modus** (`lawText: true`, im Leser): Ein bloßes „§“ meint das gelesene Gesetz (im AEAO die AO), ebenso „dieses Gesetzes“. Alte Fassungen („in der am … geltenden Fassung“, „a.F.“), Artikelgesetze, Aktenzeichen und Sätze über die Vorschriften eines anderen Gesetzes bekommen keinen Link. Verweise ins selbe Gesetz, deren Paragraph dort fehlt, werden verworfen.
- Nicht erkannt: EStH (nicht im Katalog), „§ 122 AEAO“, zweistellige UStAE-Nummern ohne „Abschnitt“ und „§ 4, 5 EStG“ mit nur einem „§“ für die 5 ohne geschriebenes Gesetz.

## Text editor 2 und Handschrift (P2/P3, Seitenseite)

**Status:** implementiert, iPad-Build siehe Übergabe; **auf dem iPad ungeprüft**.

- **Text editor 2:** Der Fließtext steht im gemeinsamen `DocumentTextStore`. Jede Seite liest ihren Teil der gemeinsamen Anordnung (Container der Seite, Ursprung aus `DocumentPageRaster`) und unterstreicht dort. Gescannt wird der ganze Fließtext auf einmal (ein bloßes „§ 35a“ nimmt das zuvor genannte Gesetz, auch von früheren Seiten), je Textspeicher läuft höchstens ein Scan, auf den alle sichtbaren Seiten warten. Solange die Dokumentansicht kurz abgehängt ist, werden die Fließtextabschnitte nicht als Textfelder gescannt. Bei jeder Textänderung (`NSTextStorage`-Mitteilung) verschwinden die Unterstreichungen des Fließtexts, bis neu gescannt ist (entprellt). Mit dem Textwerkzeug liegt die Textfläche über den Seiten: Ihr Hover wird an die Seite darunter weitergereicht (`DocumentTextSurface+LawCitations.swift`), eine Berührung blendet eine Karte aus. Fingertipps setzen dort weiter den Caret, ein Klick mit dem Textwerkzeug öffnet nichts.
- **Handschrift:** Nur mit der Einstellung „Handschrift einbeziehen“. Die Tinte wird frühestens etwa 2,5 s nach dem letzten Strich erkannt, nur solange kein Strich, Radierer, Lasso oder Ziehen aktiv ist, mit Hilfspriorität abseits des Hauptthreads und für alle Seiten nacheinander. Erkennung wie die Suche (`PageTextRecognition.swift`, dieselbe Rasterung und dieselbe Vision-Anfrage). Erkannt wird nur eine Seite, die tatsächlich im Bild ist, nachdem nicht mehr gescrollt oder gezoomt wurde (etwa 1 s). Hat die Inhaltssuche die Seite mit genau dieser Tinte schon erfasst (gleicher Handschrift-Fingerabdruck, gleiche kanonischen Koordinaten), werden ihre Zeilen übernommen, ohne OCR (dann ohne Wortboxen, also anteiliger Zeilenausschnitt). Sonst werden Ergebnisse nach dem Fingerabdruck im Speicher gehalten (400 Stände), unveränderte Tinte wird nie erneut erkannt. Ändert sich die Tinte oder verlässt die Seite das Bild, wird eine laufende Erkennung verworfen; eine wartende startet nicht mehr. Die erkannten Zeilen werden als ein Text gescannt; die Box eines Verweises kommt aus den Wortboxen von Vision (`boundingBox(for:)`), sonst aus dem anteiligen Zeilenausschnitt.
- Handschriftliche Verweise bekommen einen schwachen gestrichelten Rahmen statt der Punktlinie. Hover und Zeigerklick wie sonst (Karte mit `fromHandwriting`), ein Fingertipp gehört nie einem Handschrift-Verweis.
- **„§“ in Handschrift:** Vision liest es oft als „S“ oder „$“. Ein solches Zeichen wird nur dann als „§“ gelesen, wenn der Erkenner daraus genau „§ <Nummer> <Gesetz>“ mit geschriebenem, bekanntem Gesetz direkt hinter der Nummer macht, und nie nach einer Zahl, „Abs.“, „Nr.“, „S.“ oder „Satz“ (dort heißt „S 1“ Satz 1). Nicht behandelt: „§“ als „8“ gelesen.
- Heftkontext: Standardgesetz des Hefts geht in den Scan ein (Cache-Schlüssel), Karte bekommt Kontext und Seitenrechteck.

## Gesetzesleser (P2)

- **Sprung an einen Absatz** („§ 3 (6) UStG“): Der Leser hält das Ziel nach dem Sprung etwa 1,5 s fest (über HTML-Wechsel, Layout und Fenstergröße hinweg), bis gezogen, ausgewählt oder mit Pfeiltasten gescrollt wird. Der Absatz leuchtet etwa 2 s weich auf. Vorher sprang der Text wieder an den Anfang zurück (Ursache aus dem Code ermittelt, nicht am Gerät nachgestellt).
- **Querverweise im Gesetzestext:** gepunktet unterstrichen. Hover mit Pencil oder Trackpad zeigt dieselbe Karte wie im Heft, Antippen der Karte oder des Verweises springt im Leser dorthin. „← Zurück zu § …“ geht schrittweise zurück (bis 30 Schritte, nur im Speicher). Beim Markieren und Radieren sind die Links aus.
- **Esc** schließt eine sichtbare Karte. Sonst wird Esc nicht abgefangen.
- „Zurück zur Notiz“ stellt auch die PDF-Ansicht und die Scrollposition im Text wieder her.

## Heft (P2)

- **Gesetzesbezug pro Heft** (Heft-Menü › „Gesetzesbezug …“): Standardgesetz für bloße „§ 35a“ und Veranlagungsjahr. Das ist eine Geräteeinstellung (`noty.laws.notebookContext`), nicht im Heft, Backup, PDF oder Abgleich.
- **Fassung nach Jahr:** Bei mehreren Fassungen im Katalog nimmt die Karte die für das Jahr (`LawVersionChoice`, Datum der letzten Änderung, also Ausfertigung statt Inkrafttreten). Der Katalog hat derzeit eine Fassung pro Gesetz, dann zeigt die Karte „Stand …“ und gegebenenfalls „für 2023 ggf. abweichend“.
- **„Als Zitat einfügen“** auf der Karte legt den Absatz (bis etwa 1500 Zeichen) mit Quellenzeile als normales, rückgängig machbares Textfeld unter den Verweis. Ist dort kein Platz, sucht noty die nächste freie Stelle auf der Seite. Abgeschnitten wird nie.
- **Tippvorschlag:** Tippt man „§ 35a“, zeigt die Leiste über der Tastatur bis zu 3 Gesetze. Antippen ergänzt das Gesetz. Reihenfolge: Standardgesetz, zuletzt genanntes Gesetz, Gesetze offline mit diesem Paragraphen. Das geht nur in normalen Textfeldern, noch nicht im Texteditor 2.

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
7. „§ 3 (6) UStG“ öffnen: Der Leser bleibt bei (6), der Absatz leuchtet kurz auf.
8. Im Gesetzestext über einen Verweis hovern und ihn antippen, dann mit „← Zurück“ zurück. Markieren mit dem Pencil funktioniert wie vorher.
9. Gesetzesbezug „EStG“ setzen, „§ 35a“ tippen: Ein Link entsteht, der Vorschlag erscheint. „Als Zitat einfügen“ legt das Feld unter den Verweis, ⌘Z nimmt es zurück.
10. Handschriftlich „§ 35a EStG“ schreiben, etwa 3 s warten: ein schwacher Rahmen, die Karte fragt nach.
