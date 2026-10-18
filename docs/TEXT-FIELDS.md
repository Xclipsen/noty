# Freie Textfelder – erstes Paket, Build 17

## Aktueller Umbau – Build 27

Neue Vorgaben ersetzen die bisherige einheitliche freie Feldbedienung: auf PDF weiterhin freie Felder, auf Papier und im Schreibraum rahmenloser Seitentext mit automatischer Fortsetzung. Dunkle Tastatur, neue Formatierungszeile, stabile Cursor-/Scrollführung und eine virtuelle letzte Schreibseite auch für Handschrift. Notebook-Schema 8, 219 Core-Tests/Host-Archivroundtrip/signierter SDK-Build bestanden; native Abnahme offen. [Verbindliche neue Details und Referenzen](TEXT-REBUILD-27.md). Ältere Abschnitte sind Entwicklungsverlauf.

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
