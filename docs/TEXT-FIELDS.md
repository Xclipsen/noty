# Freie Textfelder – erstes Paket, Build 17

> Ab dem Textneubau (22.10.2026, [TEXT-REBUILD-62](TEXT-REBUILD-62.md), Schema 14) enthalten Hefte nur noch Textfelder; Seitentext/Klicken-und-Schreiben, Verschiebegriff oben links, Breitengriff unten rechts und X gelten dort nicht mehr. Die folgenden Abschnitte sind Entwicklungsverlauf.

> Erste Zeile im Textdokument und Cursor per Tipp: seit Feedback zu Build 65 gilt [TEXT-REBUILD-62](TEXT-REBUILD-62.md), letzter Abschnitt.

## Nachtrag 19.10.2026 · Klicken und Schreiben, Karopapier, verschachtelte Listen, offene Aufgaben

Implementiert, Core-Tests/Host-Roundtrip/SDK-Build erfolgreich; auf dem iPad **ungeprüft**. Kein Formatwechsel: Listenzeichen bleiben Textpräfixe, die Verschachtelungsebene ist der vorhandene Absatzeinzug (20 pt je Ebene, Formatgrenze 240 pt = 12 Ebenen).

- **Tippen auf beliebige Linie** (nur Seiten-/Randtext): Tippen unterhalb des Textes setzt einen vorgemerkten Cursor auf die nächstgelegene Linie (das Schreibband einer Linie reicht bis zu ihrer Unterlänge). Leerzeilen und Einzug werden erst mit dem ersten getippten Zeichen geschrieben; dieses Zeichen samt Leerzeilen ist ein Undo-Schritt. Bloßes Tippen ändert nichts, materialisiert keine Reserveseite; Rücktaste verwirft die Vormerkung. Blanko: gleicher Zeilenabstand wie getippter Text in der aktuellen Schrift (natürliche Zeilenhöhe), keine unsichtbare Lineatur. Unterhalb der letzten passenden Zeile: letzte Zeile des Schreibbereichs (`TextPlacement.below`).
- ~~**Waagerecht platzieren**~~ (ab Build 45 entfallen, siehe [EDITOR-FEEDBACK-35](history/EDITOR-FEEDBACK-35.md): links immer Zeilen, ab der Mitte rechts freies Textfeld): in einer leeren Zeile (auch leerer Absatz mitten im Text) Einzug in 20-pt-Schritten gerundet, höchstens 240 pt. Weiter rechts gewinnt die Variante mit Cursor am nächsten zur Tippstelle: Einzug 240, zentriert oder rechtsbündig (`TextPlacement.horizontal`).
- **Karopapier**: Seitentext steht auf den 16-pt-Karozeilen (erste Grundlinie 40 wie liniert, 1,5 pt Anhebung). Eine Zeile darf bis 2 pt enger als natürlich werden, damit 14–15-pt-Text jede Karozeile nutzt; größere Schrift belegt mehrere Zeilen, die erste Zeile wird nie angehoben. Liniert unverändert (`TextRuling`). Gemeinsamer `RuledTextLayout`/`TextObjectLayout(box, on: page)` für Editor, Textflusskapazität, Vorschau, PDF und Aufgabensuche. Vorhandener Karo-Seitentext wird dadurch neu umbrochen.
- **Auto-Listen**: „- “, „* “, „• “, „1. “, „1) “, „[] “, „[ ] “ am Absatzanfang werden nach dem Leerzeichen zu Aufzählung/Nummerierung/Checkbox („• “ und „1. “ sind bereits Listen). Die Umwandlung ist ein eigener Undo-Schritt (`NotebookUndoHistory.separateNextStep`): einmal Rückgängig stellt die getippten Zeichen wieder her.
- **Verschachtelte Listen**: Tab/⇧Tab (Hardwaretastatur, auch Tab der Bildschirmtastatur) und die Einzug-Knöpfe der Formatleiste rücken Listeneinträge um eine Ebene ein/aus; außerhalb von Listen bleibt Tab ein Tabulator, die Knöpfe ändern wie bisher den Einzug, ⇧Tab verkleinert ihn. Aufzählungszeichen je Ebene • ◦ ▪ (zyklisch); „- “ bleibt. Return auf leerem eingerücktem Eintrag rückt aus statt die Liste zu beenden. Listentyp-Wechsel am Cursor bleibt auf Einträgen derselben Ebene.
- **Nummerierung**: jede Ebene zählt dezimal neu (1. → 1.), keine a./i.-Zeichen, weil deutsche Absätze wie „z. B.“ oder „i. d. R.“ sonst als Liste gälten. Nach Einfügen, Löschen, Verschieben, Ein-/Ausrücken werden die berührten Listen neu gezählt, auch über Seitenumbrüche des Textflusses (Zählstand der vorherigen Seiten). Ein Lauf zählt ab seinem ersten Eintrag; dessen Nummer bleibt (z. B. „3. Mai“), außer die Änderung hat den bisherigen ersten Eintrag entfernt. Eingerückter Erklärtext bleibt in der Liste, normaler Absatz oder Leerzeile beendet sie. Weiter entfernte Listen bleiben unberührt (`TextListEditing.normalize`).
- **Offene Aufgaben**: Suche im Heft und in allen Heften mit Umschalter „Alle Inhalte/Offene Aufgaben“; listet nicht abgehakte Checkboxen ohne OCR, Suchfeld filtert, Tippen springt zur Seite und markiert die Aufgabenzeile.

Undo-Cursor für Textfluss-Schritte wird jetzt in den alten Text zurückgerechnet (`TextListEditing.caret(before:after:)`). Gerätetest gebündelt: auf linierter, karierter und blanker Seite unter den Text und mittig in eine leere Zeile tippen, schreiben, Undo; „- “/„[] “ tippen und Undo; Liste mit Tab/⇧Tab/Knöpfen verschachteln, über eine Seitengrenze nummerieren; offene Aufgaben suchen und anspringen; PDF-Export einer Karoseite mit Text prüfen.

## Nachtrag 19.10.2026 · Wortmodus wie Notability (Formatierung, Farben, Schreibmaschine)

Formatleiste über der Tastatur (implementiert, SDK-Build erfolgreich, auf dem iPad **ungeprüft**):

- Absatzstile „Titel“ 30 pt fett (zwei Linien), „Überschrift“ 20 pt fett, „Unterüberschrift“ 17 pt fett, „Text“ 14 pt, „Beschriftung“ 12 pt (`TextStylePreset`). Im Seitentext gilt der Stil für den ganzen Absatz bzw. alle berührten Absätze; freie PDF-Felder ohne Auswahl wie bisher für das ganze Feld. Ältere Größen (Überschrift 1–3) werden passend benannt, nicht umgeschrieben.
- Farbe „Automatisch“ (halb schwarz/halb weiß): Schwarz oder Weiß passend zum Hintergrund wie der Autostift, auch nach späterem Umstellen von Papier, Rand oder ganzem Heft; in Vorschau und PDF gegen die jeweilige Seite aufgelöst. Neue Texte sind standardmäßig automatisch. Feste Farben heben die Automatik auf.
- Marker: Tippen wiederholt die zuletzt gewählte Markerfarbe (erneut: entfernen), langes Drücken wählt Gelb/Grün/Blau/Pink/Orange/Violett oder „Markierung entfernen“.
- „Formatierung entfernen“ unter „Weitere Textformate“: Text 14 pt System, automatische Farbe; Ausrichtung, Einzug und Links bleiben.
- Kürzel: ⌘1 Titel, ⌘2 Überschrift, ⌘3 Unterüberschrift, ⌘4 Text, ⌘+/⌘= größer, ⌘− kleiner, ⌘⇧X Durchstreichen, ⌘⇧7 Aufzählung, ⌘⇧8 Nummerierung, ⌘⇧9 Checkliste (zusätzlich zu ⌘B/I/U).
- Wortzähler: „n Wörter“, Menü mit Wörtern/Zeichen/Zeichen ohne Leerzeichen für die Auswahl, sonst den ganzen seitenübergreifenden Textfluss bzw. das Feld; Listenzeichen zählen nicht (`TextStatistics`).
- Schreibmaschinen-Modus (ab Build 45 Standard **aus**, Nachführung nur bei verdecktem Cursor, siehe EDITOR-FEEDBACK-35; vorher Standard an; Schalter in der Leiste und Einstellungen → Editor): beim Tippen an einer Einfügemarke bleibt die Zeile höchstens im oberen Drittel des freien Bereichs über der Tastatur; schwebende Tastatur zählt nicht als Abdeckung, externe Tastatur nur mit der Leiste. Tippen auf eine Stelle, Auswahl ziehen oder Pfeiltasten behalten die bisherige minimale Nachführung.

Format: Notebook-Schema 9, siehe [STORAGE](STORAGE.md).

## Nachtrag 19.10.2026 · Grundlinie und Cursorhöhe

Nutzerwunsch: Seitentext auf Linien etwas höher, Cursor nicht größer als der Text. `PaperRuling.baseline(forNatural:)` setzt die Grundlinie um `baselineLift` = 2,5 Linieneinheiten über den Linienstrich (Unterlängen kreuzen ihn bei Textkörpergröße weiterhin). Text wird nie über seine natürliche Position gehoben und braucht nie mehr Linien als vorher; der Abstand schrumpft nur, wo der Platz fehlt. Gemeinsamer `RuledTextLayout`-Delegate: Editor, Vorschau, PDF und Textflusskapazität bleiben gleich. Kein Formatwechsel. `PageTextView.caretRect(for:)`/`selectionRects(for:)` verwenden Ober-/Unterlänge der Schrift an der Grundlinie statt des ganzen Linienfragments; leere letzte Zeile nutzt dieselbe Linienrechnung. Core-Tests für 8–96 pt; SDK-Build erfolgreich; auf dem iPad **ungeprüft** (Cursor, Auswahlgriffe, Lage im Export).

## Aktueller Umbau – Build 27

Neue Vorgaben ersetzen die bisherige einheitliche freie Feldbedienung: auf PDF weiterhin freie Felder, auf Papier und im Schreibraum rahmenloser Seitentext mit automatischer Fortsetzung. Dunkle Tastatur, neue Formatierungszeile, stabile Cursor-/Scrollführung und eine virtuelle letzte Schreibseite auch für Handschrift. Notebook-Schema 8, 219 Core-Tests/Host-Archivroundtrip/signierter SDK-Build bestanden; native Abnahme offen. [Verbindliche neue Details und Referenzen](history/TEXT-REBUILD-27.md). Ältere Abschnitte sind Entwicklungsverlauf.

## Ergänzung Build 21

Gemischte Formatierung markierter Wörter/Abschnitte implementiert; neue freie Felder links mit voller Seitenbreite statt höchstens 240 pt. Beweglichkeit/Breitenänderung bleiben, vorhandene Feldrahmen unverändert. Runs speichern Schriftfamilie/-größe, Fett/Kursiv/Unterstrichen/Farbe, Hervorhebung, Link und Absatz-Ausrichtung/Einzug. Eigene Formatleiste über der Tastatur mit Textstil-Vorgaben; weiterhin drei Schriftfamilien/vier Farben. Native Auswahl und Text-Undo, sichtbarer Überlauf und gemeinsame PDF-/Vorschaurenderer erhalten. Schema-7-Runs inklusive Archiv-/Kopier-/Papierkorbpfaden und unabhängiger Pythonvalidierung. 169 Core-Tests/Host-Roundtrip/SDK-Build bestanden; neue native Formatierung, Tastatur/Caret und Geräte-PDF/Restore ungeprüft. [Nachweise/Testablauf](UI-REBUILD.md). Folgende Abschnitte beschreiben die früheren Textpakete.

**Gerätestand:** Erster Build-17-Test scheiterte: Fingertipp im Textmodus erzeugt kein Feld. Keine Geräteabnahme. Build 18 korrigiert Eingangsfilter und ergänzt direkt beim gewählten Textwerkzeug „Textfeld +“; Knopf/Fingertipp und Eingabe inzwischen vom Nutzer bestätigt, zwei Einfügungen im Gerätelog belegt. Verschieben/Breite/Formatierung und Erhalt nach Schließen/Öffnen inzwischen vom Nutzer bestätigt. Echte PDF und Schema-4-Heftbackup am PC geprüft; externer Schema-4-Geräte-Restore mit Textbearbeitung/Neustart nun ebenfalls bestätigt. Details in [BUG-18-TEXT-INPUT.md](BUG-18-TEXT-INPUT.md).

## Implementiert

- Textwerkzeug wählen und mit dem Finger auf freie Seitenfläche tippen: neues Feld. Ab Build 18 zusätzlich „Textfeld +“ direkt beim Textwerkzeug für ein Feld in der sichtbaren Seitenmitte; auch Trackpad-Klicks zulassen. Vorhandenes Feld antippen: native UITextView-Eingabe/Auswahl. Stabile Ansichten je Objekt-ID; Autosave baut sie nicht neu auf.
- Blauer Griff oben links verschiebt, Griff unten rechts ändert die Breite, X löscht. Eigene Formatleiste über der Tastatur: System/Serif/Festbreite, A−/A+, Schwarz/Weiß/Blau/Rot, Fett/Kursiv/Unterstrichen, Aufzählung/Nummerierung/Checkbox-Zeichen und Fertig. Esc beendet Bearbeitung. Formatierung zunächst je vollständigem Feld; Listen sind einfache Textpräfixe, noch keine automatisch fortgesetzten strukturierten Listen oder anklickbaren Aufgaben.
- Mehrere Felder auf festen Seiten, auch im zusätzlichen PDF-Schreibplatz. Feldhöhe wächst bis Seitenende; vollständiger Text bleibt gespeichert, Überlauf wird rot markiert. PDF-Export bricht bei Platzmangel ab, statt Text unbemerkt abzuschneiden. Kein automatischer mehrseitiger Textfluss.
- Separate gemeinsame Undo-Historie für native Texteingabe und Feldoperationen, getrennt von Ink. Beim Seiten-/Layout-/Restorewechsel frische Historie; alte responder-/generationgebundene Aktionen greifen nicht auf neue Seiten über. 50 Undo-Stufen, maximal 400 gehaltene aktive/ehemalige Feldansichten; vor Freigabe alter Ziele Historie leeren.
- Neue Felder maximal 240 pt breit, an verfügbaren Platz angepasst. Stiftfarben unverändert; Standardtext auf dunklem Papier/dunklem Rand weiß, auf weißer PDF schwarz. Späteres Verschieben ändert die gewählte Textfarbe nicht.
- Höchstens 200 Felder pro Seite, Text je Feld maximal 1 MB UTF-8; vollständige Revision weiterhin maximal 200 MB. Schriftgröße im UI 10–72 pt, Dateiformat validiert 8–96 pt.

## Speicherung und alte Texte

Notebook-Schema 4 ergänzt `Page.textBoxes`; Manifest-/Backup-Containerformate unverändert. Jedes Feld enthält stabile ID, kanonische x/y/Breite/Höhe, vollständigen Unicode-Text und strukturierten Stil. Koordinaten beschreiben den Glyph-Inhaltsrahmen ohne UITextView-Innenabstand; links/oben im Rand dürfen sie negativ sein. Anzeige/Export addieren denselben Seitenversatz.

Beim bloßen Öffnen keine Umstellung. Alte Einzeltexte erscheinen virtuell mit stabiler ID an exakt ihrem bisherigen Glyph-Ursprung, inklusive alter 5-/8-pt-Einzüge. Erst erste Textobjektänderung stellt aktive und gelöschte Seiten des Hefts um; vorhandener Text wird vollständig übernommen, altes `text` geleert. Vor höherem Schema archiviert der Revisionsspeicher die exakten zuletzt bestätigten alten Bytes. Fehler dabei verhindert den neuen Commit. Schema 1–3 bleibt lesbar; ältere App-Versionen müssen Schema 4 ablehnen. Kein Downgrade über den Arbeitsbestand.

Seitenkopien und Rand-Sicherungen erhalten unabhängige Feld-IDs. Ganze Seitenstände/Papierkorb, Heft- und Bibliotheksbackup enthalten editierbare Felder; Texte erscheinen auch in Kopien-/Historienvorschauen. PDF und Seitenvorschau verwenden dasselbe native Glyph-Layout; PDF-Text wird als echter Text ausgegeben, Handschrift weiterhin separat gerastert.

## Noch offen

- Bestätigt: Anlegen/Eingabe, Verschieben/Breite, Formatierung und Schließen/Öffnen. Tatsächliche PDF und Schema-4-Backup geprüft. Externer Schema-4-Geräte-Restore mit Weiterbearbeitung/Neustart bestätigt. Noch offen: gezielte Zoom-/Fokus-/Shortcutvarianten; nicht jede kleine Variante einzeln nachtesten. Linux-Tests ersetzen Gerätebedienung nicht.
- Unterschiedliche Formatierungen innerhalb eines Feldes, freie Schriftwahl über die drei Familien hinaus, automatische Listen-/Checkboxlogik und größere Farbpalette bleiben spätere Textpakete.
- Bei Textfeldern im zu entfernenden Rand wird Verkleinern in diesem Paket verständlich blockiert: zuerst Feld verschieben/löschen. Keine unbemerkte Textabschneidung. Bisherige bestätigte Ink-Entfernung mit vollständigem Rand-Restore bleibt erhalten.
- Bilder sind ab Build 19 implementiert/gebaut; Geräteabnahme offen, siehe [IMAGES.md](IMAGES.md). Formen, gemischtes Lasso, zwei Ansichten und OCR bleiben offene Pakete. Keine Gesamtfreigabe für V1.

## Kurzer gemeinsamer Gerätetest

1. Ein Testheft mit altem Text zunächst nur ansehen: alte Positionen/Handschrift erhalten? Dann Textwerkzeug wählen und zwei Felder per Fingertipp ergänzen, eines im PDF-Schreibplatz; „ÄÖÜ ß – TEXT-17“ tippen.
2. Ein Feld über oberen Griff verschieben, über unteren rechten Griff verbreitern, Schriftgröße/Fett/Farbe ändern. Undo/Redo einmal für Text/Feldoperation prüfen, danach Pencil/Lasso wählen: Tastatur schließt, Handschrift bleibt bedienbar.
3. „Lokal gespeichert“, App beenden und neu öffnen: alte und neue Inhalte an derselben Stelle. PDF als `noty-text17.pdf` und Heftbackup als `noty-text17` nach „Auf meinem iPad → noty“ exportieren. Beim Dateinamen des Backups keine Endung selbst anhängen; System ergänzt sie.
4. PC prüft PDF/Archiv; danach geprüfte Kopie über Explorer → + → Heft-Backup als Kopie importieren öffnen, Text weiterbearbeiten und speichern/neustarten. Original behalten.

Nur diesen relevanten Ablauf bündeln; nicht jede Schrift-/Farbvariante einzeln testen. Ergebnisse getrennt in TESTING.md festhalten.
