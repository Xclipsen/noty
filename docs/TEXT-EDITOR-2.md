# Texteditor 2 (Phase 2, Prototyp)

Stand 31.10.2026, Branch `phase2/spike`. **Implementiert, erfolgreich gebaut, Core-Tests und Host-Roundtrip bestanden. Nicht installiert, am iPad ungeprüft.** Unter Linux läuft weder TextKit noch `UITextInteraction`: Alles unter „Eingabe“ und „Darstellung“ ist Code, der noch nie gelaufen ist. Dieser Prototyp entscheidet Go oder No-Go, er ist nicht fertig.

Schalter: Einstellungen › Über noty › Diagnose › „Neuer Texteditor (Test)“ (`noty.text.editor2`, Standard aus). Wirkt beim nächsten Öffnen eines Dokuments, nur in Textdokumenten, nicht im Blättermodus. Aus: `NotebookViewport.documentText` bleibt nil, der bisherige Weg läuft unverändert.

## Warum

Heute ist jede Seite ein eigenes `UITextView`. Pfeile, Auswahl und Cursor enden an der Seitengrenze, Mehrfachauswahl (Helix) kann die App nicht zeigen. Ziel: eine Eingabeansicht über allen Seiten, ein Puffer für das ganze Dokument, TextKit 1 verteilt den Text auf die Seiten.

## Architektur

```
Notebook (Quelle: Undo, Validierung, Speichern)
   ▲ TextFlowChange + Seitenlängen          │ Segmente (Undo, Formate)
DocumentTextController: hält Puffer und Modell zusammen
   ├─ DocumentTextStore: NSTextStorage, TaskLayoutManager, ein DocumentPageContainer je Seite
   │     └─ DocumentPageRaster in jeder geladenen Seite (TextObjectLayer): zeichnet
   └─ DocumentTextSurface: UIView im gezoomten `surface`, UITextInput + UITextInteraction
         └─ KeyboardRouter / TextEngine (`KeyboardTextTarget`)
Core: DocumentTextLayout.swift, reine Regeln gegen `DocumentTextMetrics`
```

- **Modell bleibt Quelle.** Das Speicherformat ändert sich nicht. Jede Änderung geht als `TextFlowChange` durch `EditorModel.changeFlow` → `Notebook.changingTextFlow` → das bestehende `reflowText`: Seiten anlegen, leere entfernen, Listen nummerieren, `validate`, `NotebookUndoHistory`. Es entstehen dieselben Segmente (`TextBox` mit `flowID`), keine Migration.
- **Seitenzuordnung aus der Layout-Maschine.** `DocumentTextStore.capacity` beantwortet `TextFlowLayout.capacity` aus dem gemeinsamen Layout. Passt der Text nicht zum Layout (Reflow hat eine Liste umnummeriert), misst das Modell selbst wie bisher (`TextFlowEditing.capacity`).
- **Puffer folgt dem Modell.** Eigene Eingabe steht schon im Puffer. Der Controller lädt nur neu, wenn die Segmente nicht mehr stimmen (Undo, Formate, Umnummerierung, abgelehnte Änderung).
- **Container und Slots.** Seiten mit Segment plus alle Seiten dahinter (`DocumentPageSlots`), wie `reflowText` weiterschreibt. Die Reserveseite ist ein normaler Slot.
- **Seitenregel.** TextKit prüft eine Zeile, bevor die Lineatur sie verschiebt. `DocumentPageContainer` fragt deshalb `DocumentPageRule` mit dem verschobenen Unterrand und liefert sonst ein leeres Rechteck: dann wechselt TextKit den Container. Die Containerhöhe selbst entscheidet nie (`spare`).
- **Eine Grundlinienregel.** `TextRuling.lineBaseline` in Core ist die frühere `RuledTextLayout.baseline`; beide Wege rufen sie auf.
- **Zeichnen.** `DocumentPageRaster` liegt in der Seite, im Zoom-Raster von `TextObjectLayer`, über der Tinte und unter freien Feldern. Es zeichnet nur den sichtbaren Glyphenbereich über den gemeinsamen Layout-Manager. Das Segment-Feld bleibt konfiguriert, aber versteckt: `boxes` muss alle Modellboxen behalten, sonst löscht `publish` den Fluss.
- **Cursor und Auswahl.** In INS zeichnet UIKit. In NOR, SEL und bei mehreren Cursorn ist `TextEngine` die Quelle: `refreshOverlay` zeichnet alle `shownSelections`, `caretRect`/`selectionRects` geben UIKit nichts zu zeichnen. Beim Tippen an mehreren Cursorn wirken `engine.insertText`/`deleteBackward`.
- **Stift.** `point(inside:)` nur bei aktivem Textwerkzeug. Tinte erreicht PencilKit, freie Felder und Griffe einer Fingerauswahl ihre Ebene. Mit dem Textwerkzeug bleibt der Stift wie heute Tippen und Scrollen.
- **Tastatur.** `KeyboardTextTarget` statt `PageTextView` im Router; `PageTextView` reicht an `TextObjectLayer` weiter wie zuvor. Pfeile laufen in INS über `UIKeyCommand` (Wiederholung, Spalte über Seiten), in NOR/SEL über den Router.

### Was in Core getestet ist (`DocumentTextLayoutTests`)

Seitenregel gegen `capacity` auf Blanko, Liniert, Kariert; Grundlinienformel; Seitenbereiche aus Messungen, auch mit Lücken; Segmente aus dem Layout mit `validate`; Tippstil; Seiten entfernen; Cursor an Seitengrenze, Textende und Leerzeile; Auswahlrechtecke über Seiten; `j`/`k` und Pfeile mit Zielspalte und leeren Seiten; Punkt ↔ Seite ↔ Position mit Maßstab; Wortbewegung; `shownSelections`. Die Tests laufen gegen einen Festbreiten-Ersatz für TextKit: Sie prüfen die Regeln, nicht TextKit.

## Abweichungen vom bisherigen Weg

| Fall | Abweichung |
| --- | --- |
| Zeile mit gemischten Schriften | Der Container schätzt die Oberlänge aus der vorgeschlagenen Höhe. Die gemessenen Zeilen entscheiden danach mit der `capacity`-Regel: ein Segment läuft nie über. Sonst kann eine Zeile im Editor unten stehen, im Modell schon auf der nächsten Seite. |
| Blocksatz, letzte Zeile einer Seite mitten im Absatz | Editor: Blocksatz. PDF/Vorschau: Segmentende, also linksbündig. Umbrüche gleich, Abstände nicht. |
| Aufgabe über eine Seitengrenze | Editor sieht eine Aufgabe, PDF/Vorschau erkennen die Folgezeilen auf der nächsten Seite nicht als Aufgabe (Durchstreichen, Abblenden fehlen dort). |
| `trailingLineFits` | Weiter über `TextObjectLayout`, nicht aus dem gemeinsamen Layout. |

Mit Hänger-Diagnose schreibt `logDeviations` Seiten mit abweichender Länge ins Protokoll (`idevicesyslog | grep noty.editor2`). Eine Abweichung ist am Gerät zu klären, sie darf nicht still bleiben.

## Fehlt im Prototyp

- **Formatleiste** samt Wortzähler. Da sind ⌘B/I/U, ⌘1–4, ⇧⌘X; es fehlen ⌘+/−, Listenkürzel, Link, Markieren.
- **Klick-und-Schreiben** unter dem Text (`CaretPlacement`): Ein Tipp darunter geht auf die letzte Zeile.
- **Listen:** Fortsetzen mit Return, automatische Liste und Checkbox-Tipp sind da; Einrücken mit Tab und Return auf leerer verschachtelter Zeile fehlen.
- **Gesten der Seite bei aktivem Textwerkzeug:** Die Touches enden auf der Fläche, die Erkenner der Seite sehen sie nicht (Doppeltipp-Menü, Fingerauswahl von Bildern).
- **Scrollen beim Ziehen der Griffe:** `NotebookViewport.scrollRectToVisible` ist bewusst leer, Auswahl über nicht sichtbare Seiten nur per Tastatur.
- **Abgelehnte Änderung** (Seitenlimit, kein Platz): Der Puffer geht auf den Modellstand zurück, das Modell zeigt den Fehler. Die letzte Eingabe ist weg; der alte Weg behält sie auf der Seite. Vor einem Go zu ändern.
- **Marked Text am Ende der letzten Seite:** Bis zum Abschluss gibt es keinen neuen Container.
- **VoiceOver:** nur Element mit Bezeichnung, kein `UIAccessibilityReadingContent`.
- **Rechts-nach-links**, vertikaler Text: nicht behandelt.
- **Blättermodus:** bleibt beim alten Weg.
- **⇧-Pfeile in NOR/SEL:** wirkungslos (bisher nativ).

## Risiken

1. **`UITextInteraction` auf einer etwa 40.000 pt hohen Ansicht in einem gezoomten Scrollview.** Griffe, Lupe und Gestenkonflikte mit Pan/Pinch waren nie zu sehen. Größtes Risiko, keine Linux-Absicherung möglich.
2. **Eingabesystem.** Autokorrektur, Diktat und Tottasten verlangen exakte `inputDelegate`-Meldungen und `text(in:)`. Fehler zeigen sich als verschluckte oder verdoppelte Zeichen.
3. **Verhalten von TextKit:** ob die `lineFragmentRect`-Absage zuverlässig den Container wechselt, die Vorschlagshöhe beim ersten Aufruf stimmt und die Leerzeile hinter dem letzten Umbruch im richtigen Container landet. Annahmen aus der Dokumentation, nicht gemessen.
4. **Leistung.** Je Taste: `taskItems` über den ganzen Text pro gezeichneter Seite, Segmente und Vergleich O(Text), Neuladen bei Umnummerierung. TextKit layoutet lazy, Sprünge ans Ende aber bis dorthin. Bei 50 Seiten zu messen.
5. **Zwei Stände während der Eingabe.** Der Puffer ist vor dem Modell, bei Marked Text über mehrere Aufrufe. Späte Modellupdates in dieser Zeit laden nicht neu.
6. **Tastenbefehle.** `⌘↑/↓` und Pfeile mit `wantsPriorityOverSystemBehavior` können mit Menübefehlen oder dem Systemverhalten kollidieren.

## Go/No-Go am Gerät

Nur in einem isolierten Bereich oder einer Kopie (AGENTS: Geräteupdates). Schalter an, Hänger-Diagnose an, App neu starten. Hardware-Tastatur und Softwaretastatur prüfen. Jede Zeile: bestanden, nicht bestanden oder **ungeprüft**. Ein No-Go in den ersten vier Zeilen stoppt den Weg, der Rest lässt sich nachbessern.

| Prüfung | Bestanden wenn | No-Go wenn |
| --- | --- | --- |
| **Tippen** über mehrere Seiten, Return, Löschen über die Grenze | Kein Zeichen fehlt oder doppelt, Text fließt zurück, Cursor stimmt | Zeichen verloren oder Absturz |
| **Stift durch den Text** | Stift zeichnet mit Pen-Werkzeug über Text ohne Verzug; mit Textwerkzeug setzt Tipp den Cursor, Ziehen scrollt | Tinte kommt nicht an |
| **Griffe** | Ziehen über Zeilen und über eine Seitengrenze, Griffe stehen richtig | Griffe springen oder lassen sich nicht greifen |
| **Lupe** | Erscheint bei langem Druck, folgt dem Finger, auch gezoomt | Fehlt oder steht falsch |
| **Zoom** | Text scharf nach dem Pinch, Cursor und Auswahl decken sich mit den Glyphen, Pinch auf Text zoomt | Versatz zwischen Text und Cursor |
| **Autokorrektur** | Vorschlag übernehmen, zurücknehmen, Leerzeichen danach stimmt | Text wird falsch ersetzt |
| **Diktat** | Längerer Satz, Korrektur danach | Text fehlt oder doppelt |
| **Tottasten** | `^` + `e`, `´` + `a`, japanische Eingabe; Pfeile bei offener Komposition | Zeichen falsch |
| **Trackpad** | Klick, Ziehen, Doppelklick, I-Balken | Keine Auswahl möglich |
| **Bearbeitungsmenü** | Kopieren, Ausschneiden, Einfügen, Alles auswählen, auch über Seiten | Aktion wirkt falsch |
| **Pfeile, `j`/`k`** | Über Seitengrenzen, Spalte bleibt, Ende und Anfang | Stoppt an der Grenze |
| **Mehrfachauswahl** | `C` und `s`, alle Auswahlen sichtbar, auch über Seiten; `c`, tippen, ⌫ an allen Cursorn | Nur eine sichtbar oder Text falsch |
| **Rückgängig** | ⌘Z nach Tippen und Format, Cursor kommt zurück | Stand fremd oder Schritt fehlt |
| **Freie Felder, Bilder, Tinte** | Felder bleiben bedienbar, Tinte bleibt auf der Seite, Text fließt darunter | Inhalte verschwinden |
| **VoiceOver** | Fläche erreichbar, Text vorlesbar | Dokument nicht erreichbar (für Go nachzubauen) |
| **50-Seiten-Dokument** | Tippen ohne spürbaren Verzug auf Seite 1, 25, 50, Sprung ans Ende unter 0,5 s, Öffnen ohne Hänger | Spürbarer Verzug je Taste |
| **Speichern und neu öffnen** | Schalter aus: dasselbe Dokument öffnet identisch, PDF-Export ohne Überlauf; `python3 -B scripts/verify_device_store.py BEREICHSROOT --compare VORHER_ROOT` bestanden | Prüfer meldet Fehler oder Export verweigert |

Dazu: `noty.editor2`-Protokoll auswerten. Abweichungen beim 50-Seiten-Dokument auf allen drei Papieren notieren.
