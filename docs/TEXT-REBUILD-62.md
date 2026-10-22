# Textneubau, Textdokument und `.noty` – Plan vom 22.10.2026

Ergebnis einer Abstimmung mit dem Nutzer nach dem ersten Tag echter Nutzung. Verbindlich für die Umsetzung auf `feat/textneubau`. Gemeinsamer Teststand mit den Formen (Notebook-Schema 13); erst nach iPad-Test nach `main`. Stand: **Stufen 1 und 2 implementiert und gebaut (am iPad ungeprüft), Stufen 3–4 geplant**; Umsetzungsnachweise je Stufe unten ergänzen (implementiert / gebaut / installiert / auf dem iPad getestet getrennt).

Anlass: Die bisherige Textbedienung ist „mega nervig“: Felder lassen sich nur über kleine Icons verschieben, überlappende Felder sind darunter nicht greifbar, auf Papier entscheidet die Tippstelle zwischen Zeilentext (links) und freiem Feld (rechts). Die Leiste über der Tastatur (`TextFormatBar`) bleibt; der Rest wird neu gebaut.

## 1. Grundaufteilung

- **Hefte** (Papier- und PDF-Seiten) enthalten künftig nur noch **Textfelder**. Kein rahmenloser Seitentext/Textfluss mehr in Heften.
- Der bisherige Wortmodus (Textfluss über Seiten, Linienraster, Absatzstile, Listen, Checkboxen, Wortzähler, Schreibmaschine) wandert in den neuen Bibliothekstyp **Textdokument** (Abschnitt 4). Der Code bleibt, wird aber nur dort verwendet.
- **Migration**: vorhandener Fließtext in Heften (`TextBox.flowID != nil`) wird verlustfrei pro Seite zu einem freien Feld an exakt derselben Stelle, gleiche Breite, gleiche Runs/Stile. Mehrseitiger Fluss zerfällt in ein Feld je Seite. Regeln aus AGENTS/STORAGE: beim bloßen Öffnen keine Umstellung, erst bei der ersten Textänderung bzw. dem ersten Commit; exakte bestätigte Altbytes vorher sichern; Fehler verhindern den Commit; aktive Seiten, Papierkorb, Legacy-`Page.text` berücksichtigen; Swift-Validierung und Python-Prüfer gemeinsam anpassen.

## 2. Textfeld im Heft

**Anlegen**
- Textwerkzeug wählen, mit Finger oder Stift auf eine leere Stelle tippen → Feld dort mit Cursor.
- Doppeltipp-Menü „Textfeld hinzufügen“ (mit jedem Werkzeug, Einstieg `WorksheetView.addTextField(at:)`). Nach Verlassen des Felds automatisch zurück zum vorherigen Werkzeug.
- **Textwerkzeug fixieren**: Schloss-Symbol in den Optionen des Textwerkzeugs. Fixiert bleibt das Textwerkzeug nach dem Verlassen aktiv, und ein Tipp außerhalb des aktiven Felds legt sofort ein neues Feld an.
- Kein Knopf „Textfeld +“ als Hauptweg mehr nötig (darf als Ausweichweg bleiben).
- Neue Felder übernehmen den zuletzt benutzten Stil; „Formatierung entfernen“ führt zurück.
- Leere Felder verschwinden beim Verlassen.

**Auswählen und Bearbeiten**
- Finger (mit jedem Werkzeug): erster Tipp wählt aus, zweiter Tipp setzt den Cursor. Bei aktivem Textwerkzeug setzt der Tipp direkt den Cursor.
- Treffer nur auf echten Textzeilen (Zeilenflächen), leerer Rahmenteil reicht zum Feld darunter durch. Erneuter Tipp an derselben Stelle wechselt zum nächsten Feld darunter. „Nach vorne“/„Nach hinten“ im Menü.
- **Keine Icons** über dem Feld (kein Verschiebe-Griff, kein X). Ausgewählt: dünner Rahmen, links und rechts je ein Breitenpunkt, Drehgriff an kurzem senkrechtem Strich mittig über dem Feld.
- Ausgewählt, nicht in Bearbeitung: Ziehen irgendwo im Feld verschiebt. In Bearbeitung: Ziehen im Text markiert Text, Ziehen am Rahmen (ca. 20 pt Trefferzone) verschiebt.
- Löschen über das Menü oder die Rücktaste bei ausgewähltem, nicht bearbeitetem Feld.
- Menü am ausgewählten Feld: Ausschneiden, Kopieren, Duplizieren, Löschen, Feldstil, Nach vorne/Nach hinten, Bearbeiten.

**Stift**
- Ohne aktiven Cursor: Stift ist normale Tinte über dem Feld, kein Scribble.
- Bei aktivem Cursor: Stiftziehen scrollt das Dokument; Stifttipp im Feld setzt den Cursor; Stifttipp außerhalb beendet die Bearbeitung (ohne Strich) und kehrt zum vorherigen Werkzeug zurück – außer das Textwerkzeug ist fixiert (dann neues Feld). Textmarkierung nativ (Finger-Doppeltipp, Halten, Griffe).
- Fingertipp daneben beendet die Bearbeitung und hebt die Auswahl auf; „Fertig“/Esc bleiben.

**Größe, Drehung, Grenzen**
- Breite automatisch: wächst beim Tippen nach rechts bis zum Seitenrand, dann Umbruch. Nach manuellem Ziehen eines Breitenpunkts fest. Höhe immer aus dem Inhalt.
- Drehbar; weiches Einrasten bei 0/90/180/270°, schwächer bei 45°, kleine Gradanzeige. Bearbeitung direkt im gedrehten Zustand.
- Felder lassen sich nicht teilweise aus der Seite (inkl. Rand) schieben. Textüberlauf am Seitenende: vollständig gespeichert, rot markiert, nie still abgeschnitten.
- Lasso: Eckskalierung skaliert die Schrift mit (8–96 pt); Breitenpunkte am Feld ändern nur die Breite.
- Einsetzen von außen ohne aktives Feld: neues Feld an der zuletzt angetippten Stelle bzw. mittig in der sichtbaren Seite, Formatierung auf den aktuellen Stil gebracht.

**Feldstil** (Stufe 4): Füllung keine oder ca. 6 helle Farben (Gelb, Grün, Blau, Rosa, Grau, Lila), Rahmen an/aus (Textfarbe/Akzent, dünn), leicht abgerundete Ecken und Innenabstand sobald Füllung/Rahmen aktiv. Muss in Vorschau, PDF, Backup, Papierkorb und Revisionen erscheinen.

## 3. Weiches Einrasten (alle Objekte und Lasso)

- Ziele: linke/rechte Kante, Mitte (horizontal/vertikal), erste Grundlinie anderer Textfelder, gleiche Abstände zwischen drei und mehr Objekten, Papierlinien/Karos, Seitenränder und Seitenmitte.
- Gilt für Textfelder, Bilder, Formen und Lasso-Auswahlen.
- Weich: nur bei langsamer Bewegung innerhalb von ca. 5 Bildschirmpunkten, beim schnellen Ziehen nichts; kleine Bewegung löst wieder. Blaue Hilfslinie zeigt das Ziel.
- Zweiter Finger beim Ziehen unterdrückt Einrasten; Schalter in den Einstellungen.

## 4. Textdokument (neuer Bibliothekstyp)

- „+“ in der Bibliothek: „Heft“ und „Textdokument“, eigenes Symbol; Ordner, Suche, Papierkorb, Bibliotheksbackup wie bei Heften.
- A4 hoch oder quer je Dokument; Papier standardmäßig blanko, liniert/kariert optional; Ränder wie bisheriger Seitentext.
- Fließtext mit dem bisherigen Wortmodus (Formatleiste, Absatzstile, Listen, Checkboxen, offene Aufgaben, Wortzähler, Schreibmaschine).
- Seiten entstehen nur durch den Text, plus eine leere Reserveseite am Ende für Handschrift.
- Handschrift als Ebene darüber, **fest auf der Seite** (wandert nicht mit umfließendem Text).
- Freie Textfelder, Bilder und Formen wie im Heft. Tipp außerhalb von Objekten bleibt im Textdokument immer Text (Cursor in den Fluss).
- Export: PDF mit durchsuchbarem Text, vollständiges Backup (`.noty`), Text/Markdown. Word später.
- Gliederung aus Titel/Überschrift in der Seitenleiste: Stufe 4.

## 5. `.noty`-Datei

- Das bisherige Heft-Backup-Format (`.notybackup`, Format 2) wird als **`.noty`** geschrieben, für Hefte und Textdokumente. Inhalt/Prüfung unverändert (kein ZIP-Umbau). Alte `.notybackup` bleiben importierbar; `.notylibrary` unverändert.
- Import: Titel exakt aus der Datei, ganz normales Heft/Dokument, keine „Wiederhergestellt“-Kennzeichnung, nicht in „Wiederhergestellte Kopien“, immer eigene neue Identität.
- Gleiche Dokument-ID schon in der Bibliothek: Nachfrage „Vorhandenes ersetzen“ (alter Stand in den Papierkorb) oder „Beide behalten“.
- Namensgleichheit: „Titel (1)“, „Titel (2)“ … statt „(Wiederhergestellt)“ – **überall**, auch bei Kopien aus der lokalen Historie.
- „Teilen als .noty“ im Heft-/Dokumentmenü und Kontextmenü der Bibliothek; Dateiname `<Titel>.noty`. PDF-Teilen bleibt getrennt.

## Stufen

1. Textfeld im Heft (Abschnitt 2 ohne Feldstil) + Migration des Fließtexts. Parallel: `.noty` (Abschnitt 5).
2. Weiches Einrasten (Abschnitt 3).
3. Textdokument (Abschnitt 4 ohne Gliederung).
4. Feldstil, Gliederung.

Jede Stufe: Core-Tests, bei Format-/Archivänderung `scripts/check_page_workflow.sh` und Prüfer, `xtool dev build`. iPad derzeit nicht anschließbar: nichts installieren, alles **auf dem iPad ungeprüft**.

## Umsetzungsstand

### Stufe 1 · Textfeld im Heft und Migration des Fließtexts (22.10.2026)

**Implementiert und erfolgreich gebaut** (`xtool dev build`), **nicht installiert, auf dem iPad ungeprüft.** Core-Tests, `check_page_workflow.sh` (Host-Roundtrip) und `check_verifiers.sh` bestanden. Format: Notebook-Schema 14, Details in [STORAGE](STORAGE.md).

Abschnitt 1:
- Hefte enthalten nur noch Textfelder: Das Textwerkzeug legt keinen Seitentext/Fluss mehr an (kein „links Zeilen, rechts Feld“). Wortmodus-Code (`TextFlow.swift`, `TextFlowEditing`, `reflowText`, Listen-/Zählerlogik, Formatleiste) bleibt unverändert erhalten, Hefte rufen den Flussweg nur nicht mehr auf.
- Migration: `NotebookDecoding` macht aus jedem Flusssegment (aktive Seiten und Seitenpapierkorb) ein freies Feld an exakt demselben Rahmen, gleiche Breite, gleicher Text, gleiche Runs/Stile; mehrseitiger Fluss = ein Feld je Seite; leere Segmente entfallen. Die Region bleibt als `flowRegion` ohne `flowID` erhalten, damit Linienraster und Randeinheiten exakt gleich bleiben. Bloßes Öffnen schreibt nichts; erster Commit sichert die exakten Altbytes (`Migrations/<UUID>/notebook-v<alt>.json`), Sicherungsfehler verhindert den Commit. Legacy-`Page.text` bleibt virtuelles Feld. Swift-Validierung und Python-Prüfer gemeinsam angepasst.

Abschnitt 2 (ohne Feldstil):
- **Anlegen:** Textwerkzeug + Finger- oder Stifttipp auf leere Stelle → Feld mit Cursor an der Tippstelle (erste Zeile auf die Tippstelle zentriert). Doppeltipp-Menü „Textfeld hinzufügen“ wie bisher (bei Stift/Bleistift/Marker/Radierer). Schloss „Textwerkzeug fixieren“ in den Optionen des Textwerkzeugs (zweiter Tipp auf das aktive Textwerkzeug öffnet sie, Einstellung `noty.text.toolLocked`); „Textfeld +“ bleibt als Ausweichweg. Nach dem Verlassen eines Felds (Tipp daneben, Stifttipp daneben, Esc, „Fertig“) kehrt der Editor zum Werkzeug vor dem Textwerkzeug zurück; fixiert bleibt das Textwerkzeug und ein Tipp daneben legt sofort ein neues Feld an. Neue Felder übernehmen den zuletzt per Formatleiste benutzten Zeichenstil (Schrift, Größe, Fett/Kursiv, Farbe; ohne Markierung/Unterstreichung/Links/Absatzwerte), „Formatierung entfernen“ führt zurück. Leere Felder verschwinden beim Verlassen.
- **Auswählen/Bearbeiten:** Treffer nur auf belegten Textzeilen (TextKit-Zeilenflächen ± 8 Bildschirm-pt); leerer Rahmenteil reicht zum Feld/Objekt darunter durch (`PageObjectHitTest.all`, `textHit`). Mit Stift/Bleistift/Marker/Radierer (Finger) und mit dem Lasso (Tipp): erster Tipp wählt das Feld, zweiter Tipp auf dessen Text setzt den Cursor dort (Textwerkzeug vorübergehend); liegt an der Stelle Text eines weiteren Felds, wechselt der zweite Tipp stattdessen zum nächsten Feld darunter (Cursor dann über „Bearbeiten“). Bei aktivem Textwerkzeug setzt ein Tipp auf Text direkt den Cursor. Ausgewählt: dünner Rahmen, je ein Breitenpunkt links/rechts, Drehgriff an kurzem Strich mittig über dem Feld, keine Icons; Ziehen irgendwo im Feld verschiebt (auch auf andere Seiten wie bisher). In Bearbeitung: dünner Rahmen und Breitenpunkte; Ziehen in der Rahmenzone (14 pt außen + 6 pt innen) verschiebt, Ziehen im Text markiert nativ. Menü am ausgewählten Feld: Bearbeiten, Ausschneiden, Kopieren, Duplizieren, Löschen, Nach vorne, Nach hinten; Rücktaste löscht.
- **Stift:** ohne Cursor normale Tinte (Textebene inaktiv); mit Cursor scrollt Stiftziehen, Stifttipp im Feld setzt den Cursor, Stifttipp daneben beendet ohne Strich (Rückkehr bzw. neues Feld wie oben). Scribble bleibt aus.
- **Größe/Drehung/Grenzen:** automatische Breite (`autoWidth`) wächst mit dem Text bis zum Seitenrand (inkl. Schreibplatz), dann Umbruch; Ziehen eines Breitenpunkts macht die Breite fest. Höhe immer aus dem Inhalt (höchstens bis zum Seitenrand, Rest bleibt gespeichert und rot markiert; PDF-Export blockiert wie bisher). Drehen um die Feldmitte mit weichem Einrasten (±6° bei 0/90/180/270°, ±2,5° bei 45°), Haptik am Pencil Pro und kleine Gradanzeige; gespeichert wird die Drehung um die linke obere Ecke, damit Wachsen nach unten nichts verschiebt. Bearbeiten im gedrehten Zustand über die gedrehte UITextView. Felder lassen sich nicht teilweise aus der Seite schieben (gedrehter Rahmen). Lasso-Eckskalierung skaliert die Schrift (8–96 pt) wie bisher.
- **Einsetzen von außen ohne aktives Feld:** ⌘V/Einsetzen mit Text in der Zwischenablage legt ein neues Feld an der zuletzt angetippten Stelle der Seite bzw. mittig im sichtbaren Ausschnitt an, als reiner Text im aktuellen Stil (Textwerkzeug: mit Cursor; Stiftwerkzeuge: nur angelegt).
- **Andockstellen:** alle Verschiebungen (Lasso, Fingerauswahl, Rahmenzone) laufen über `ObjectMovement.translation(…, snapping:)` mit dem Protokoll `MoveSnapping` für Stufe 2. Feldstil (Stufe 4) fehlt im Menü bewusst.

Bewusste Abweichungen und Grenzen:
- „Finger mit jedem Werkzeug“ und Doppeltipp-Menü gelten für Stift, Bleistift, Marker, Radierer und Lasso; Form-, Bild-, Laser- und Lesewerkzeug behalten ihre bisherige Tippbedienung (eigene Ebenen, deren Touches nicht umgeleitet werden).
- Erneuter Tipp auf ein ausgewähltes Feld schaltet nur dann zum Feld darunter, wenn dort ebenfalls Text liegt; sonst setzt er den Cursor (beide Wünsche lassen sich sonst nicht unterscheiden).
- Migrierter Seitentext behält bis zur ersten Änderung die Höhe seines früheren Schreibbereichs; Auswahlrahmen, Ziehen, Breite und Drehung verwenden sofort die Inhaltshöhe und speichern sie dabei; im Bearbeitungsmodus ist der Rahmen bis zum ersten Tastendruck noch hoch.
- Migrierte Randfelder behalten Randeinheiten und Linienraster ihrer Region, auch wenn sie später verschoben oder auf eine andere Seite gezogen werden.
- Die Lese-Migration gilt für jedes dekodierte Dokument; Stufe 3 muss sie auf Hefte beschränken, sobald es Textdokumente gibt.

Gerätetestpunkte (gebündelt, alles **ungeprüft**):
1. Altes Heft mit Seitentext (auch mehrseitig, auf liniertem/kariertem Papier und im PDF-Rand) nur öffnen: Text an exakt derselben Stelle, keine neue Revision. Dann ein Feld ändern, App schließen/öffnen; `Migrations/…/notebook-v13.json` (bzw. alte Zahl) im Geräteabzug.
2. Textwerkzeug: Tipp auf leere Stelle, tippen (Breite wächst, am Rand Umbruch), Tipp daneben → zurück zum Stift; mit Schloss: Tipp daneben legt sofort das nächste Feld an. Stift-Tipp daneben ohne Strich.
3. Mit Stift aktiv: Fingertipp auf Text wählt (Rahmen, Breitenpunkte, Drehgriff, Menü), Tipp auf leeren Rahmenteil erreicht Objekt darunter, zweiter Tipp setzt Cursor; überlappende Felder durchschalten; Nach vorne/hinten; Rücktaste löscht.
4. Breitenpunkte (danach feste Breite), Drehen mit Einrasten/Gradanzeige, Bearbeiten im gedrehten Feld (Cursor, Auswahlgriffe, Tastatur), Ziehen am Rahmen im Bearbeitungsmodus, Rand der Seite als Grenze.
5. Undo/Redo für Anlegen, Tippen, Verschieben, Breite, Drehen; Zoom; zweite Ansicht.
6. Einsetzen von außen mit Stift und mit Textwerkzeug; Vorschau, PDF-Export (`pdftotext` findet gedrehten Text, Lage stimmt), Heft- und Bibliotheksbackup mit gedrehtem Feld.

### Integration 22.10.2026

Zusammengeführt in `feat/textneubau` (Merge-Commits): `feat/noty-datei` (`.noty`-Datei, Importnamen „Titel (n)“, Teilen als `.noty`), `feat/formen-tag2` (Form beginnt beim Aufsetzen, eigene Füllfarbe/Deckkraft, ungefüllte Formen zählen nur über ihren Strich) und `main` (einheitliche Werkzeugoptionen, Seitenausweichen und seitliches Federn, Gesetzesfenster an drei Kanten, Hover-Namen).
- Formate: Notebook-Schema 14 (Formen 13 enthalten), Werkzeugeinstellungen bleiben Format 8 (`shapeFillColor`/`shapeFillOpacity` nur optional), `.noty` = `.notybackup` Format 2. Keine weitere Anhebung.
- Treffer: Textfelder nur auf Textzeilen, ungefüllte Formen nur über den Strich (`PageObjectHitTest`, Lasso `LassoRegion.selects`); gemeinsamer Test in `PageObjectHitTestTests`. Lasso-Tipp prüft zuerst Textfeld-Treffer, sonst `selectByTap` wie der Pencil-Tipp im Formenwerkzeug.
- Optionen: Textwerkzeug zeigt Schloss „Textwerkzeug fixieren“ | „Textfeld hinzufügen“ (ersetzt „Textfeld +“); Formen mit Vieleck, nach „Füllung“ folgen Füllfarbe, „wie Strich“ und Deckkraft im einheitlichen Stil mit Hover-Namen. Die Optionszeile des Textwerkzeugs weicht wie die übrigen über `optionsAvoidance` aus (statt fester 60 pt).
- Prüfungen: Core-Tests (716, 3 übersprungen), `check_page_workflow.sh`, `check_verifiers.sh`, `xtool dev build` bestanden. **Nicht installiert, am iPad ungeprüft** (zusätzlich zu den Punkten oben: Seitenausweichen und seitliches Federn zusammen mit Feldauswahl/-ziehen, Pencil-Tipp im Formenwerkzeug neben Textfeldern, Füllregler in der Optionszeile).

Offen für Stufe 2/3: Snapping an `MoveSnapping` andocken (erledigt in Stufe 2, siehe unten; Lasso-Skalierung/-Drehung bewusst ohne); Textdokument als eigener Typ mit Fluss und Lese-Migration nur für Hefte; Feldstil und Gliederung (Stufe 4).

### Stufe 2 · Weiches Einrasten (22.10.2026)

**Implementiert und erfolgreich gebaut** (`xtool dev build`), **nicht installiert, auf dem iPad ungeprüft.** Core-Tests bestanden (726, 3 übersprungen; neu `SoftSnappingTests`). Kein Notebook-, Archiv- oder Werkzeugeinstellungsformat geändert.

- **Core (`SoftSnapping.swift`):** `SoftSnapper` rechnet plattformunabhängig je Achse Kandidaten, Abstand, Geschwindigkeit und Hysterese; `MoveSnapSession` ist die `MoveSnapping`-Andockung für `ObjectMovement` (erst Einrasten, dann Seitengrenzen) und rastet auch Einzelpunkte ein. `PaperLines` liefert die Papierlinien genau wie `PDFExporter.drawPaper` (24 pt liniert, 16-pt-Karos, 32 pt Seiteneinzug, eigene Bänder neben PDFs). `DragSpeed` misst die Touchgeschwindigkeit in Bildschirmpunkten/s (über ~50 ms geglättet).
- **Ziele:** linke/rechte bzw. obere/untere Kante und Mitte anderer Textfelder, Bilder und Formen (gedrehte über ihre gedrehten Grenzen, Formen über den gezeichneten Umriss statt der Trefferpolsterung); erste Grundlinie anderer ungedrehter Textfelder (Text auf einer Höhe); gleiche Abstände (mittig zwischen zwei Nachbarn oder ein in der Reihe schon benutzter Abstand neben dem nächsten Nachbarn; Reihe = Objekte, die sich quer zur Richtung überlappen); Papierlinien/Karos (Textfelder mit der Grundlinie, wie Seitentext 2,5 pt bzw. 1,5 pt über der Linie; Kanten anderer Objekte direkt auf Linien; Anfang/Ende der Linien als Ränder); Seitenränder, Seitenmitte und die Ränder des Schreibraums neben PDFs.
- **Was rastet:** Verschieben von Lasso-Auswahlen (als Ganzes, auch mit Tinte), Fingerauswahl (Felder, Bilder, Formen), Textfeld in der Rahmenzone beim Bearbeiten, Bilder im Bildwerkzeug (jetzt ebenfalls über `ObjectMovement`). Außerdem Breitenpunkte ungedrehter Textfelder (Kante an senkrechte Ziele) und Ankerpunkte von Formen (beide Achsen). Ein über eine andere Seite gehobenes Objekt rastet nicht.
- **Parameter:** Einrasten innerhalb von 5 Bildschirmpunkten (zoomunabhängig, Seitenpunkte = 5 / Zoom) und nur unter 250 Bildschirmpunkten/s; eingerastet bleibt es, bis die ungerastete Lage mehr als 8 Bildschirmpunkte entfernt ist (Hysterese). Ein näheres Ziel löst ab; bei Gleichstand Kanten vor Mitten, Grundlinien, Abständen, Seite, Papierlinien. Schnelles Ziehen rastet nie neu ein.
- **Hilfslinien:** blaue 1-pt-Linien (Bildschirmpunkte) über dem Inhalt in einer eigenen Ebene des Blatts (`SnapGuideView`), über Ziel- und bewegtes Objekt hinweg bzw. über die Seite/Papierlinie; gleiche Abstände als kleine Abstandsmarken mit Endstrichen. Nur Bildschirm, nie in Vorschau, Seitenleiste oder PDF. Beim Einrasten leichter Impuls (`UIImpactFeedbackGenerator` light, am Pencil Pro `alignmentOccurred`).
- **Unterdrücken/Schalter:** Ein zweiter Touch irgendwo auf dem Bildschirm während des Ziehens (Finger neben Finger oder Pencil) unterdrückt und löst das Einrasten, solange er liegt (`SnapPanGestureRecognizer` liest `UIEvent.allTouches`). Schalter „Einrasten“ in Einstellungen › Editor (alle Bereiche), Standard an; App-weite Einstellung `noty.editor.snapping` (UserDefaults wie Schreibscrollen, nicht in `toolbar.json`, daher keine Swift-/Python-Formatprüfung nötig).

Bewusste Abweichungen und Grenzen:
- Drehung unverändert (Stufe 1); Lasso-Eckskalierung und Lasso-Drehung rasten nicht ein.
- Tintenstriche sind keine Ziele (nur Objekte); eine Lasso-Auswahl mit genau einem Textfeld rastet ohne Grundlinie, nur die Feldauswahl nutzt sie.
- Grundlinien und Breitenpunkte nur bei ungedrehten Feldern; leere Felder sind keine Ziele.
- Die Geschwindigkeit wird nur bei Touchereignissen gemessen: Ein ruhender Finger ändert nichts, die nächste kleine Bewegung gilt als langsam.
- Ob iPadOS den zweiten Touch außerhalb der gezogenen Ansicht in `allTouches` meldet und ob die Impulse auf dem Gerät spürbar sind (iPads ohne Taptic Engine), ist ungeprüft.

Gerätetestpunkte (gebündelt, alles **ungeprüft**):
1. Textfeld langsam an Kante, Mitte und Grundlinie eines anderen Felds ziehen: rastet ein, blaue Linie, Impuls; kleine Bewegung darüber hinaus löst; schnelles Ziehen über Ziele hinweg rastet nicht. Bei 50 % und 200 % Zoom gleich weit.
2. Liniertes und kariertes Papier: Grundlinie auf Linie, Bild-/Formkanten auf Linien/Karos, Linienanfang als Rand; Seitenränder, Seitenmitte; PDF-Seite mit Schreibrand.
3. Gleiche Abstände bei drei Objekten waagerecht und senkrecht (mittig dazwischen und Abstand fortsetzen), Abstandsmarken sichtbar.
4. Lasso-Auswahl mit Tinte und Objekten, Fingerauswahl, Bild im Bildwerkzeug, Form, Feld in der Rahmenzone beim Bearbeiten; Breitenpunkte und Formanker.
5. Zweiter Finger während des Ziehens (mit Finger und mit Pencil) unterdrückt; Schalter aus → kein Einrasten; Hilfslinien nie in Seitenleiste, Vorschau oder PDF; Ziehen auf eine andere Seite ohne Hilfslinien, zurück wieder mit.
6. Undo/Redo eines eingerasteten Verschiebens als ein Schritt; Einrasten fühlt sich beim normalen Schreiben/Scrollen nicht störend an.

