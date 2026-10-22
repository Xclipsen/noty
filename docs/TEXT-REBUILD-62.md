# Textneubau, Textdokument und `.noty` – Plan vom 22.10.2026

Ergebnis einer Abstimmung mit dem Nutzer nach dem ersten Tag echter Nutzung. Verbindlich für die Umsetzung auf `feat/textneubau`. Gemeinsamer Teststand mit den Formen (Notebook-Schema 13); erst nach iPad-Test nach `main`. Stand: **Stufen 1–4 implementiert und gebaut (am iPad ungeprüft)**; Umsetzungsnachweise je Stufe unten ergänzen (implementiert / gebaut / installiert / auf dem iPad getestet getrennt).

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
- Die Lese-Migration gilt für jedes dekodierte Dokument; Stufe 3 muss sie auf Hefte beschränken, sobald es Textdokumente gibt. *(Erledigt in Stufe 3: Textdokumente behalten ihren Fluss.)*

Gerätetestpunkte (gebündelt, alles **ungeprüft**):
1. Altes Heft mit Seitentext (auch mehrseitig, auf liniertem/kariertem Papier und im PDF-Rand) nur öffnen: Text an exakt derselben Stelle, keine neue Revision. Dann ein Feld ändern, App schließen/öffnen; `Migrations/…/notebook-v13.json` (bzw. alte Zahl) im Geräteabzug.
2. Textwerkzeug: Tipp auf leere Stelle, tippen (Breite wächst, am Rand Umbruch), Tipp daneben → zurück zum Stift; mit Schloss: Tipp daneben legt sofort das nächste Feld an. Stift-Tipp daneben ohne Strich.
3. Mit Stift aktiv: Fingertipp auf Text wählt (Rahmen, Breitenpunkte, Drehgriff, Menü), Tipp auf leeren Rahmenteil erreicht Objekt darunter, zweiter Tipp setzt Cursor; überlappende Felder durchschalten; Nach vorne/hinten; Rücktaste löscht.
4. Breitenpunkte (danach feste Breite), Drehen mit Einrasten/Gradanzeige, Bearbeiten im gedrehten Feld (Cursor, Auswahlgriffe, Tastatur), Ziehen am Rahmen im Bearbeitungsmodus, Rand der Seite als Grenze.
5. Undo/Redo für Anlegen, Tippen, Verschieben, Breite, Drehen; Zoom; zweite Ansicht.
6. Einsetzen von außen mit Stift und mit Textwerkzeug; Vorschau, PDF-Export (`pdftotext` findet gedrehten Text, Lage stimmt), Heft- und Bibliotheksbackup mit gedrehtem Feld.

### Stufe 3 · Textdokument (22.10.2026, Branch `feat/textdokument`)

**Implementiert und erfolgreich gebaut** (`xtool dev build`), **nicht installiert, auf dem iPad ungeprüft.** Core-Tests (730, 3 übersprungen; neu `TextDocumentTests`), `check_page_workflow.sh` (Host-Roundtrip mit Textdokument) und `check_verifiers.sh` bestanden. Format: Notebook-Schema 15 nur für Textdokumente, Hefte unverändert ([STORAGE](STORAGE.md)). Ohne Gliederung (Stufe 4).

- **Dokumentart:** `Notebook.kind` (gespeichert nur `"textDocument"`, ab Schema 15); Hefte tragen keinen Schlüssel und werden nie auf 15 gehoben. Builds ≤ Stufe 2 sperren Textdokumente („Dokumentformat 15 … nicht unterstützt“), statt sie als Heft zu öffnen. Die Lese-Migration Fließtext → Felder läuft nur noch für Hefte. Bibliotheksindex: optionaler Anzeigehinweis `kind` am Eintrag (nur Dokumente); maßgeblich ist das Dokument selbst (Reparatur beim Vorschaubild, Bibliotheks-Restore übernimmt die Art aus den Dokumenten).
- **Bibliothek:** „Neu“ › Heft | Textdokument | Ordner; „.noty importieren …“ (Import erkennt die Art aus der Datei). Eigenes Symbol `doc.text` in Seitenleiste, Angeheftet, Raster/Liste, Papierkorb. Ordner, Suche (inkl. offene Aufgaben, über die Textfelder des Flusses), Papierkorb, Anheften, Duplizieren, Bibliotheksbackup, Teilen als `.noty` und PDF-Export wie bei Heften.
- **Anlegen:** Titel, A4 hoch oder quer, Papier blanko (Standard), liniert, kariert. Ohne Umschlag; der Fluss beginnt leer im Schreibbereich des bisherigen Seitentexts (`writingRect(.page)`: 32 pt links/rechts, 16 pt oben/unten), Fließtext 14 pt in automatischer Farbe.
- **Editor:** Fließtext mit dem erhaltenen Wortmodus (`reflowText`, `TextFlowEditing`, Linienraster auf liniertem/kariertem Papier, Formatleiste mit Absatzstilen, Listen, Checkboxen, Wortzähler über den ganzen Text, Schreibmaschine). Seiten entstehen nur durch den Text: Überlauf führt auf die nächste Seite, eine vorhandene Folgeseite ohne Fluss (z. B. mit Handschrift) wird an ihrer Stelle weiterverwendet; leere Endseiten verschwinden nach dem Kürzen (nie die erste, nie die Cursorseite, nie eine mit Tinte/Objekten). Dahinter steht immer die leere Reserveseite (bisheriger Entwurf, erst beim Beschreiben gespeichert). Keine manuellen Seiten (Hinzufügen, Anordnen, Kopieren, Löschen, Seite anpassen, Papier für neue Seiten entfallen; Lesezeichen bleiben).
- **Ebenen:** Handschrift (PencilKit) bleibt fest auf ihrer Seite und wandert nicht mit. Freie Textfelder (Stufe 1, über „Textfeld hinzufügen“ in den Optionen oder Doppeltipp-Menü), Bilder und Formen wie im Heft.
- **Tippen:** Mit Textwerkzeug setzt ein Tipp außerhalb von Objekten den Cursor an die nächstgelegene Stelle des Flusses; auf Seiten ohne Fluss und auf der Reserveseite hinter das letzte Zeichen. Mit Stift/Bleistift/Marker/Radierer setzt ein Fingertipp neben Objekten den Cursor (Textwerkzeug vorübergehend, Rückkehr wie bei Feldern); der Stift zeichnet weiter.
- **Export:** PDF mit durchsuchbarem Text (bestehender `PDFExporter`, alle Ebenen; „Ganzes Dokument“ ohne leere Endseiten, die Reserveseite ist nie Teil des Dokuments), `.noty`, „Als Text teilen (.txt)“ und „Als Markdown teilen (.md)“ (`TextDocumentExport`: Titel `#`, Überschrift `##`, Unterüberschrift `###`, Listen `-`/`1.`/`- [ ]`/`- [x]` mit vier Leerzeichen je Ebene, fett `**`, kursiv `_`, Sonderzeichen maskiert).
- **Seitenleiste/Vorschau:** unverändert über die gemeinsamen Renderer; Seitenaktionen nur Lesezeichen.

Bewusste Abweichungen und Grenzen:
- Stifttipp neben dem bearbeiteten Text beendet wie im Heft die Bearbeitung und kehrt zum vorherigen Werkzeug zurück (nur fixiertes Textwerkzeug setzt den Cursor); ein Fingertipp setzt immer den Cursor. Ein Fingertipp mit Stiftwerkzeug wirkt erst nach dem Doppeltipp-Fenster (0,3 s), damit „Textfeld hinzufügen“ erreichbar bleibt.
- Mit Textwerkzeug setzt ein Tipp auf ein Bild oder eine Form im Schreibbereich den Cursor (der Fluss liegt darüber); Bilder/Formen wählt man mit dem Finger bei Stiftwerkzeug oder mit Bild-/Lassowerkzeug.
- Text/Markdown enthalten nur den Fluss; Handschrift, freie Felder, Bilder und Formen nur im PDF. Unterstreichung, Markierung, Farben und Links gehen im Markdown verloren.
- Papier ist nach dem Anlegen fest (kein Umstellen im Dokument).

Gerätetestpunkte (gebündelt, alles **ungeprüft**):
1. Neu › Textdokument (hoch/quer, blanko/liniert/kariert); Symbol, Titel, Vorschau in Raster/Liste/Seitenleiste/Angeheftet; ein älterer Build zeigt „Dokumentformat 15 … nicht unterstützt“.
2. Tippen über mehrere Seiten (Absatzstile, Listen, Checkboxen, Wortzähler, Schreibmaschine); Seitenwechsel beim Überlauf, Reserveseite, Kürzen entfernt leere Endseiten; Undo/Redo über Seiten.
3. Handschrift auf der Reserveseite, danach Text bis dorthin schreiben: Handschrift bleibt fest; mit Stift Fingertipp neben Objekten setzt Cursor, Doppeltipp-Menü weiter erreichbar; Tipp unter dem Text/auf leerer Seite → Textende.
4. Freies Feld, Bild, Form im Textdokument; Lasso; Suche und offene Aufgaben.
5. Teilen als .txt/.md/.noty, PDF (`pdftotext` findet den Fluss, keine leere Endseite), `.noty`-Import als Textdokument, Bibliotheksbackup/-restore.

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

Offen für Stufe 4 (nach Stufe 3): Gliederung aus Titel/Überschrift in der Seitenleiste des Textdokuments (Absatzstile über `TextStylePreset.matching` je Absatz des Flusses, Sprung über `TextFlowFocus`), Feldstil (Füllung/Rahmen) für Hefte und Textdokumente samt Formatanhebung; optional Papierwechsel im Textdokument und Word-Export. *(Feldstil und Gliederung erledigt in Stufe 4, siehe unten; Papierwechsel und Word-Export weiter offen.)*

### Stufe 4 · Feldstil und Gliederung (22.10.2026, Branch `feat/stufe4`)

**Implementiert und erfolgreich gebaut** (`xtool dev build`), **nicht installiert, auf dem iPad ungeprüft.** Core-Tests (749, 3 übersprungen; neu `FieldStyleAndOutlineTests`), `check_page_workflow.sh` (Host-Roundtrip mit Feldstil in Heft und Textdokument) und `check_verifiers.sh` bestanden. Format: Feldstil in Notebook-Schema 14, kein neues Schema ([STORAGE](STORAGE.md)).

**Feldstil** (Hefte und Textdokumente, nur freie Felder):
- **Bedienung:** Menü des ausgewählten Felds: Bearbeiten, Ausschneiden, Kopieren, Duplizieren, Löschen, **Feldstil**, Nach vorne, Nach hinten. „Feldstil“ öffnet ein kleines Popover im einheitlichen Optionsstil (44-pt-Zellen, Auswahlplatte, Hover-Namen über `.notyTooltip`): Füllung „Keine“ oder Gelb, Grün, Blau, Rosa, Grau, Lila; Rahmen „Kein“, „Textfarbe“ oder „Akzentfarbe“. Jede Wahl ist ein Undo-Schritt.
- **Darstellung:** Sobald Füllung oder Rahmen aktiv ist: 6 pt Innenabstand um den Text, 5 pt Eckenradius, Rahmen 1 pt (innen an der sichtbaren Kante). Füllfarben hell und deckend, auch auf dunklem Papier; der Textfarben-Rahmen nimmt die (aufgelöste) Grundfarbe des Felds, der Akzentrahmen ein druckfestes Blau. Automatische Textfarbe wird gegen die Füllung aufgelöst (gefülltes Feld: dunkler Text, auch auf dunklem Papier und im PDF-Rand), ein reiner Rahmen lässt das Papier entscheiden.
- **Überall gleich:** ein Renderer (`TextFieldStyleRendering`) für PDF (Vektorfläche unter dem weiterhin echten, durchsuchbaren Text), Vorschaubilder/Seitenleiste und gehobene Auswahl; der Editor zeichnet dieselbe Geometrie als Ebene unter dem Text. Auswahlrahmen, Breitenpunkte, Drehgriff, Rahmenzone beim Bearbeiten, Lasso-Kontur und Lasso-Treffer, Seitengrenzen, Übertragen auf andere Seiten und Einrasten (Kanten/Mitten des sichtbaren Felds; Grundlinie relativ dazu; Breitenpunkte rasten mit der sichtbaren Kante) nutzen das Feld inklusive Innenabstand.
- **Treffer:** gefülltes Feld auf der ganzen Fläche (inklusive Innenabstand), Feld nur mit Rahmen auf der Rahmenlinie (± Fingertoleranz) wie ungefüllte Formen, sonst unverändert nur Textzeilen (`TextBox.fieldStyleHit` in `PageObjectHitTest.all` und `hitsTextLine`). Mit Textwerkzeug setzt ein Tipp in den Innenabstand den Cursor an die nächste Stelle.
- **Grenzen:** Passt der Innenabstand nicht mehr auf die Seite, rückt das Feld nach innen; ist es so breit/hoch wie die Seite, wird der Textrahmen um den Innenabstand kleiner und das sichtbare Feld deckt genau den alten Rahmen (Text bricht neu um, Überlauf bleibt rot markiert und vollständig gespeichert). Entfernen des Stils verschiebt den Text nie.

**Gliederung** (Textdokumente, kein Formatwechsel):
- Seitenleiste: Umschalter „Seiten | Gliederung“ (statt des PDF-Inhalts, den Textdokumente nicht haben). Liste der Absätze im Stil Titel, Überschrift, Unterüberschrift (`TextStylePreset.matching` des ersten Zeichens) in Leserichtung, hierarchisch eingerückt (Ebene = Zahl der übergeordneten Einträge, ohne Titel beginnen Überschriften links), Text auf 60 Zeichen gekürzt, Seitenzahl rechts; die Einträge der aktuellen Seite in Akzentfarbe. Ohne Überschriften ein Hinweis.
- Tippen: Seite kommt in den Blick, die Überschrift wird wie beim Sprung zu einer offenen Aufgabe kurz markiert, der Cursor steht hinter der Überschrift (Textwerkzeug, `TextFlowFocus`); schreibgeschützt nur Seite und Markierung. In der kompakten Ansicht schließt die Seitenleiste.
- Live: Jede Änderung startet eine 400-ms-Wartezeit neu; danach rechnet `Notebook.textOutline` (reine Core-Funktion) im Hintergrund. Nur bei sichtbarer Gliederung; nichts im Tippfad.

Bewusste Abweichungen und Grenzen:
- Feldstil gilt nur für freie Felder, nicht für den Fluss des Textdokuments. Neue Felder übernehmen den Feldstil nicht (nur den Zeichenstil wie bisher); Duplizieren/Kopieren behält ihn.
- Gefüllte Felder liegen wie aller Text über der Handschrift und verdecken darunterliegende Striche (Editor, Vorschau und PDF gleich).
- Lasso-Eckskalierung skaliert Schrift und Breite, Innenabstand und Rahmenstärke bleiben fest.
- Ein Absatz, der über einen Seitenwechsel läuft, erscheint mit seinem Teil auf der ersten Seite; markiert wird nur dieser Teil.
- Format: siehe STORAGE (Begründung für Schema 14 statt 16).

Gerätetestpunkte (gebündelt, alles **ungeprüft**):
1. Feld wählen › Feldstil: jede Füllfarbe, beide Rahmen, Kombination, zurück auf keine; Undo/Redo; Hover-Namen im Popover mit Pencil-Hover/Trackpad; Feld am Seitenrand und seitenbreites Feld (rückt ein bzw. wird schmaler, nichts abgeschnitten).
2. Dunkles Papier und PDF-Rand: automatischer Text wird im gefüllten Feld dunkel, Textfarben-Rahmen passt; Vorschaubild, Seitenleiste und PDF-Export identisch (`pdftotext` findet den Text, `pdftoppm` zeigt Fläche/Rahmen an derselben Stelle, auch gedreht).
3. Treffer: Tipp auf leere Fläche eines gefüllten Felds wählt es, beim reinen Rahmen nur auf der Linie, sonst Objekt darunter; mit Textwerkzeug Tipp in den Innenabstand setzt den Cursor; Rahmenzone/Breitenpunkte/Drehgriff an der sichtbaren Kante; Lasso-Kontur.
4. Einrasten an Kanten eines gestylten Felds und mit ihm (Kante inkl. Innenabstand, Grundlinie bleibt am Text); Ziehen auf eine andere Seite.
5. Heft- und Bibliotheksbackup, Seitenpapierkorb, lokale Historie und Restore-Kopie mit gestyltem Feld; älterer Teststand (Stufe 1–3) bewusst nicht mit Stufe-4-Daten öffnen.
6. Textdokument: Gliederung beim Tippen von Überschriften (Aktualisierung nach kurzer Pause, kein Ruckeln), Einrückung, Kürzung, Sprung mit Markierung und Cursor auf späteren Seiten, schreibgeschützte Ansicht, kompakte Breite.

### Build 62 installiert (22.10.2026)

Gemeinsamer Teststand `feat/textneubau` (Stufen 1–4, Formen Schema 13, `.noty`, Stand von `main` mit Lasso/Fingertipp/Werkzeugleiste) als signierte IPA gebaut (SHA-256 `080a16bb…dfa8`, IPA-ID `XTL-BAFXLQ964V.de.la.noty.prototype`, CFBundleVersion 62, UTTypes `de.la.noty.document`/`backup`/`library`).

- Sicherung bei geschlossener App: `/home/la/Backups/noty-before-build62-2026-10-22T17-09-51-927472029Z/` (22 Hefte in zwei Bereichsroots, 72 Revisionen, 189 Dateien, ohne Quarantäne). Ein erster Lauf (`…T17-08-45-…-abgebrochen-vor-installation`) brach nach der Sicherung im Prüfskript ab (veraltete `load_store`-Rückgabe seit Schema 12); vor dem Abbruch wurde nichts installiert.
- **Installiert**: InstallationProxy bestätigt Build **62** unter unveränderter ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`. Bei geschlossener App zurückgelesen: `verify_device_store.py --compare` für beide Bereichsroots gültig, **alle 22 Hefte und 189 Dateien unverändert**, keine neuen Dateien.
- **Auf dem iPad ungeprüft**: sämtliche Funktionen der Stufen 1–4, Formen, `.noty` und Einrasten (Gerätetestpunkte in den Abschnitten oben). Ab der ersten Bearbeitung mit neuen Funktionen können Hefte Schema 13/14 bzw. Textdokumente Schema 15 erhalten; Build ≤ 61 öffnet diese dann nicht mehr.
