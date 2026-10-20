# Feedback zu Build 44 · Build 45

## Auftrag

Gerätetest-Rückmeldung zu Build 44 (19.10.2026): Wortmodus (Schärfe beim Zoomen, zu viel Bewegung, Cursor unter Zurück-Pfeil/Werkzeugleiste, links immer Zeilen statt Einrücken, Markerfarbe, Checkliste, Stift scrollt im Textwerkzeug, Sprungmarkierung 3 s), Undo inkl. Seitenänderungen, Bleistift mit Autostift, Laserpointer/Hand auf zweite Leistenebene, häufige Pencil-Pro-Vibration beim Lasso, Formen beim Halten skalieren, Glasmenü (Stift-Tipps, Härtung, Scroll-Ende, schneller), Startseite (Angeheftet zweispaltig, Ziehen in der Seitenleiste, Einfügelinien im Hauptbereich).

## Umsetzung

### Wortmodus

- **Schärfe:** Seitentext/Feldtext wird von einer eigenen Ansicht nur für den sichtbaren Bereich (plus Rand) in Zoomauflösung gezeichnet (`TextRasterScale.quantized`, Stufen √2, nie gröber als Anzeige, max. ≈16 MP je Feld), Neuzeichnen nach Pinch-Ende. Glyphenpositionen unverändert.
- **Weniger Bewegung:** Beim Tippen nur noch scrollen, wenn der Cursor sonst den freien Bereich verlässt (20 pt Rand); Antippen, Cursor ziehen, Pfeiltasten, Tastatur und Seitenwechsel nur bei wirklich verdecktem Cursor; Auswahl/Griffe nie (`NotebookViewportGeometry.caretRevealDelta`, `CaretReveal`). Schreibmaschinen-Modus standardmäßig **aus** (ausdrücklich gespeicherte Wahl bleibt).
- **Cursor unter Bedienelementen:** Kopfzeile mit Zurück-Pfeil, oben angedockte oder schwebende Werkzeugleiste und Tastatur mit Formatleiste zählen als verdeckt; verdeckter Cursor wird knapp zur näheren Seite freigescrollt.
- **Klicken und Schreiben neu:** Einzug/Zentrieren/Rechtsbündig per Tippen entfällt (`TextPlacement.horizontal` entfernt). Linke Seitenhälfte (bzw. Schreibrand) bietet immer Zeilen: Tippen unter den Text setzt den Cursor an den linken Rand der Linie (Leerzeilen erst mit dem ersten Zeichen, ein Undo-Schritt wie bisher). Ab der Mitte rechts neben/unter dem Text öffnet ein Tipp ein freies Textfeld an der Tippstelle (`TextPlacement.opensFreeField`, `freeFieldFrame`, mindestens 120 pt breit). Freie Felder auf Papier bleiben frei (bisher still in Seitentext umgewandelt) und haben Griffe; leere freie Felder werden beim Verlassen entfernt (eigener Undo-Schritt „Leeres Textfeld entfernen“, gilt auch für PDF-Felder).
- **Markerfarbe:** Nach jedem Tastendruck übernahm iOS die Tippattribute ohne app-eigene Schlüssel → zurück auf Gelb. App-Schlüssel werden jetzt vom getippten Zeichen zurückkopiert; Markerfarbe zusätzlich aus der sichtbaren Hintergrundfarbe gelesen.
- **Checkliste:** Kreis auf halber Versalhöhe über der Grundlinie, Durchstreichung auf halber x-Höhe zeilenweise ohne Leerzeichen am Ende; gemeinsamer Renderer → Editor, Vorschau und PDF gleich.
- **Stift im Textwerkzeug:** Pencil-Ziehen verschiebt das Papier, Pencil-Tipp setzt Cursor/öffnet Feld; Scribble auf diesen Textansichten aus.
- **Sprungmarkierung** (Suche, offene Aufgaben, Treffer aus der Bibliothek) verblasst nach ≈3 s.

### Undo inkl. Seitenänderungen

Neue Schrittart `.pages` in `NotebookUndoHistory` (`recordPages`, Diff `PageStructureChange` nach Seiten-/Papierkorb-IDs). Ein Schritt je: Seitenstandard ändern (auch mit leeren Seiten), Ganzes Notizbuch umstellen (exakte Tintenbytes, Text-/Formfarben), Seite einfügen, PDF einfügen, Duplizieren, Einfügen/Ausschneiden, Verschieben/Umordnen, Löschen (Undo holt dieselbe Seite an dieselbe Stelle und entfernt den Papierkorbeintrag; Redo legt denselben Eintrag zurück), Wiederherstellen, Seite leeren, Lesezeichen, Schreibrand. PDF-Original wird beim Undo nur entfernt, wenn nichts anderes es nutzt. Veraltete Schritte (Seite außerhalb des Verlaufs geändert, Papierkorbeintrag fehlt) werden übersprungen; Darstellungsnormalisierung des Texts zählt nicht als Änderung. Speichern über den bestehenden Commit, Grenzen 100 Schritte/≈80 MB unverändert. Grenze: allererste Seitenoperation eines Hefts im alten Prototypformat nicht rückgängig (sonst Formatherabsetzung).

### Werkzeuge

- **Bleistift folgt Autostift**, solange keine eigene Bleistiftfarbe/-einstellung gewählt wurde; Autostift-Umschalten beim Stift koppelt den Bleistift wieder.
- **Zweite Leistenebene:** Laserpointer und Hand („PDF lesen“) werden im Code auf die zweite Ebene verteilt (gespeicherte Reihenfolge und Werkzeugformat 8 unverändert); Punkt am Ebenenpfeil, wenn das aktive Werkzeug auf der anderen Ebene liegt; Anpassen mit Abschnitt „Zweite Ebene“. Behoben: falsche Leistenlänge beim Ebenenwechsel.
- **Lasso-Vibration:** leichter Pencil-Pro-Tick etwa alle 44 Bildschirmpunkte (höchstens alle 80 ms) beim Lasso-Zeichnen und Ziehen einer Auswahl, auch seitenübergreifend. Laser-Haptik-Generator wird bei Bedarf erzeugt.
- **Formen beim Halten skalieren:** nach der Erkennung folgt die Form der Spitze bis zum Abheben, ein Undo-Schritt. Linie: Anfang fest, Ende folgt (Winkel-Einrasten); Pfeil: gleichmäßig vom Anfang; geschlossene Formen gleichmäßig um die Mitte nach Abstand Spitze–Mitte, ohne Drehung (Rechteck/Ellipse bleiben bearbeitbar). Mindestens 6 pt, höchstens 20-fach, innerhalb der Seite.
- **Glasmenü:** öffnet nach 0,16 s statt 0,3 s, Einblendung ≈0,16 s; zweiter Druck innerhalb 0,35 s bleibt Doppeldruck (offene Palette schließt sofort, Radiererwechsel). 46-pt-Trefferflächen ohne Lücken, Scrollen erst ab 12 pt (Stift-Tipps bleiben Tipps), hartes Scroll-Ende statt Federn/Springen; schließt bei Drehung/Größenänderung, App-Wechsel und Wechsel zu Text/Bild/PDF lesen; nie zwei Paletten.

### Startseite/Bibliothek

- Seitenleiste ohne `List` neu aufgebaut. Wahrscheinliche Ursache des Ausfalls: die auswählbare Sidebar-Liste übernahm Langdruck/Ziehen selbst, die Zeilen-Drop-Delegates aus Build 43 liefen nie. Ein Drop-Delegate je Spalte berechnet das Ziel aus gemessenen Zeilen-/Kachelrahmen (Core `LibraryDropLayout`, `LibrarySnapshot.placement(of:at:)`).
- Einfügelinie im Baum (eingerückt nach Zieltiefe), in Angeheftet (senkrecht) und im Hauptbereich (Raster senkrecht, Liste waagerecht); Ordnermitte = hinein (hervorgehoben), „Alle Unterlagen“ = oberste Ebene, sonst im Hauptbereich in den gezeigten Ordner. Wirkungslose/unmögliche Ziele zeigen keine Linie. Ablegen über `LibraryStore.place` in einem Indexcommit; Positionen nur bei „Eigene Reihenfolge“.
- Angeheftet als Kacheln, zwei nebeneinander ab 230 pt Breite; Reihenfolge per Ziehen, Einfügen zwischen Kacheln heftet an. Pin-Reihenfolge ist Anzeigepräferenz je Bereich in UserDefaults (`noty.v2.libraryPinOrder.<Bereich>`, stabile IDs) und **nicht** Teil des Bibliotheksbackups (Anheften selbst über `favorite` schon).

## Nachweise

426 Core-Tests ohne Fehler (`.tools/core-batch45.log`; neu u. a. `PageUndoTests`, `PencilFeedback45Tests`, `LibraryDropLayoutTests`, Text-Platzierung/Caret-Reveal/Rasterstufen). Host-Roundtrip mit unabhängigen Prüfern bestanden (`.tools/roundtrip-batch45.log`, Schema 9). Signierter Build 45 im ersten Anlauf erfolgreich, gleiche ID/Team/Zertifikat wie Build 44 (`.tools/build-batch45-artifact.json`).

Installation: vollständige Sicherung `/home/la/Backups/noty-before-batch45-2026-10-19T18-07-00-987407271Z/` (Gerät vorher Build 44), `xtool install --usb` erfolgreich, InstallationProxy bestätigt Build 45 mit unveränderter ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`. Rücklesung danach: Bibliotheksindex bytegleich (nur Ordner, 0 Notizbücher – Bestand war schon vor diesem Update nach dem früheren „Alles löschen“ vom 19.10. leer, Sicherung `/home/la/Backups/noty-before-delete-all-2026-10-19T16-47-11-259014Z`).

**Auf dem iPad ungeprüft:** alle neuen Bedienabläufe – Textschärfe und Tippgefühl bei hohem Zoom, Scrollverhalten mit schwebender Leiste/Hardwaretastatur, Links-/Rechts-Tipp, Markerfarbe, Checkbox/Durchstreichung in Editor und echtem PDF-Export, Pencil-Scrollen im Textwerkzeug, 3-s-Markierung; Undo nach Ganzes-Heft-Umstellen/Löschen der offenen Seite/PDF-Einfügen/Umordnen samt Neustart; Bleistift-Autostift auf dunklem Papier/PDF, Leistenebenen in allen Andockpositionen, Vibrationsgefühl, Skalieren beim Halten, Glasmenü mit Stift; Ziehen in Seitenleiste/Angeheftet/Hauptbereich, zweispaltige Pins in Slide Over. Nicht umgesetzt: automatisches Scrollen beim Ziehen am Rand der Bibliothek.

## Build 46

Gerätebefund IMG_0282/0283 (Build 45): Marker füllte den ganzen Zeilenbereich inkl. Abstand über der Schrift; Text begann 16 pt links vor den Linien.

- Marker: `TaskLayoutManager.fillBackgroundRectArray` begrenzt jede Markierung zeilenweise auf Ober- bis Unterlänge der markierten Schrift (Editor, Vorschau, PDF über denselben Renderer).
- Textbeginn: `Page.writingRect` rückt links/rechts 32 pt (×Schreibraumskala) ein wie die Linien in `PDFExporter.drawPaper`, oben/unten unverändert 16 pt; zu schmale Bereiche behalten 16 pt. Bestehender Fließtext mit altem Rahmen (`legacyWritingRect`) wird bei seiner nächsten Bearbeitung in `reflowText` auf den neuen Rahmen gesetzt und neu umbrochen; ungeändert bleibt er wie gespeichert. Kein Formatwechsel.
- Neuer Test `testFlowTextStartsWithRuledLinesAndOlderTextAlignsOnEdit`, zwei Randbreiten-Erwartungen angepasst.

Weitere Rückmeldung zu Build 45 (alle Prüfpunkte vom Nutzer bestätigt) plus neue Befunde:

- **Linksdrift beim Zeichnen** nach Einpassen auf Bildschirmbreite: `blendedHorizontalOffset` mischte bereits begrenzte Werte im Nahtbereich zu Seiten anderer Breite und war damit nicht idempotent; jeder Layoutdurchlauf (jeder Strich → `constrainHorizontalOffset`) schob x weiter. Jetzt werden die erlaubten Bereiche gemischt (`horizontalRange`, `blendedHorizontalRange`) und einmal begrenzt; Schreiben erst ab 0,5 pt Abweichung; nach Einrasten auf Breite/Mindestzoom einmal animiert begrenzt. Tests `StrokeHorizontalDriftTests`.
- **Zweite Ansicht:** Heftauswahl war beim ersten Öffnen leer (SwiftUI-`sheet(isPresented:)` las `@State choices` veraltet); neuer `SecondViewPicker` mit `sheet(item:)` und eigenem Laden. Gleicher Fehler in „Inhalte suchen“ der Bibliothek behoben. Erweiterung: Griffleiste mit Anfasspunkt je Hälfte, Ziehen mit Live-Vorschau der Zielseite (Links/Rechts bzw. Oben/Unten), Tauschen beim Loslassen ohne Neuaufbau der Zeichenflächen; Seite/Anordnung beim Öffnen wählbar; Trennlinie rastet bei ⅓ · ½ · ⅔ (min. 320 pt), Doppeltipp = Hälfte; Griffmenü (Seiten tauschen, Anordnung, Gleich groß, Anderes Heft, Schließen); „Zuletzt geöffnet“ in der Auswahl; VoiceOver. Anzeigepräferenz `noty.editor.splitArrangement`. Gleiches Heft in beiden Hälften nutzt dasselbe Modell (kein zweiter Schreiber). Core `SplitPaneLayout` + Tests. Grenze: Griffbereich der Trennlinie reicht ≈6 pt in die Hälften.
- **Runder Textmarker:** Spitze „Rund“ (Standard, PencilKit-Monoline, Markerfarbe × 0,42) oder „Keil“ (bisherige Markertinte × 0,55); in Werkzeugoptionen, Einstellungen, Symbol, Lieblingsstiften. Optionales Feld `markerTip` in Werkzeugformat 8 (kein Formatwechsel; ≤7 mit Feld, unbekannte Werte und Spitze an Nicht-Marker abgelehnt, Python-Prüfer und Roundtrip ergänzt). Gerade-Ziehen gilt auch für runde Striche; Lasso-Umfärben erhält Markertransparenz (auch Keil). Abwägung: runde Striche tönen darunterliegende Tinte leicht und dunkeln bei Überlappung nach. Eigenes Werkzeugsystem statt PencilKit bewusst nicht umgesetzt (AGENTS, Latenz/Handballen/Datenmigration/Undo).

Nachweise: 441 Core-Tests ohne Fehler (`.tools/core-batch46.log`), Host-Roundtrip (`.tools/roundtrip-batch46.log`), signierter Build 46 nach einer Korrektur (Typprüfungs-Zeitlimit in `ToolbarGlyph`), gleiche ID/Team/Zertifikat (`.tools/build-batch46-artifact.json`). Installiert nach Sicherung `/home/la/Backups/noty-before-batch46-2026-10-19T18-42-31-416505539Z/`; InstallationProxy bestätigt 46; Rücklesung 3 Notizbücher/17 Dateien unverändert. Nutzerrückmeldung 19.10.2026 nach Gerätetest: „passt alles“ (alle Build-46-Punkte bestätigt; eigene Artefaktprüfung am Gerät-PDF nicht erfolgt).
