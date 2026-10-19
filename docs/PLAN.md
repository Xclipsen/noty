# Entwicklungsplan

## Aktuell – Build 38

Lasso über Seiten, Einstellungen/Startseite/Papierkorb mit endgültigem Löschen, Marker gerade, Seitentrennlinie, weicher Schreibplatz-Übergang, UI-Logikfehler. Installiert, **am iPad ungeprüft**. Offen: Toolbar-Neubau nach Nutzerentscheidung, Fund 10 (Strich während Auto-Backup). [Details](EDITOR-FEEDBACK-34.md).

## Feedback 33 (Zoom, Schreibscrollen, Strichstärke)

Zoom-out-Grenze ca. drei Seitenbreiten mit Rückschnappen, mittiges Blatt beim Pinch, keine eigene Kopfleiste, Glasblase für Zurück/Titel, engere Seiten auf grauem Grund, Schreibscrollen bis zur Blattmitte bzw. halbem Schreibplatz, Strichstärke relativ zur Blattbreite. **270 Tests, SDK-Build erfolgreich; Build 33 installiert, alle 23 Hefte/159 Dateien unverändert; Bedienung am iPad ungeprüft.** [Details](EDITOR-FEEDBACK-33.md). Zoom-Hänger als PDFKit-Hauptthreadarbeit belegt und durch eigenen PDF-Ausschnittrenderer behoben (Build 36, Nutzer: keine Ruckler); Pinch-Zentrierung in Build 37 erstmals aktiv, ungeprüft.

## Bildbefunde und Halte-Linien, Build 32

Build 31 verursacht bestätigte Größenabweichung bei PDFs mit Rand (IMG_0274); Ausnahme zurückgenommen. Normaler Randtext-/Linienmaßstab ohne veränderte Schriftattribute, gleiche Grundseitenbreite, Canvas-Farbumgebung für Vorschauen und separate Konturanimation implementiert. IMG_0275 als zwei zu dunkle/dünne Halte-Linien präzisiert: auf finalen nativen Zeichnungsstand warten und konstante Vorschaufarbe/-stärke erhalten. **264 Tests und Host-Roundtrip bestanden, SDK-Build erfolgreich; Build 32 installiert, alle 23 Hefte/159 Dateien unverändert.** [Nachweise](TESTING.md).

Nächste Geräteabnahme: [drei gezielte Fälle](TEST-BUILD-32.md). Bereits unter Build 31 angelegte schmale Ränder ausdrücklich über 100 % erweitern; keine automatische Daten-/Maßänderung. Der erwartete Farb-/Stärkenerhalt und die echte Konturanimation sind ohne Gerätebericht nicht abgenommen. Frühere Linienausrichtungs-/Checkboxfälle sowie fremde Referenz-Zusatzfunktionen bleiben offen.

## Aktuell – Lasso, Hochzoom und Schreibplatz, Build 31

Build 30 wurde am Gerät für Lasso/mitgezogenen Inhalt erneut beanstandet. Regel jetzt ausdrücklich Berührung statt vollständiger Einschließung. Kontur für reine Handschrift, schnelle Ink-Vorschau, gemeinsame begrenzte Bewegung/Skalierung, dunkles Referenzmenü, reine Ink-Drehung/-Spiegelung implementiert. Hochzoom-Rasterflächen begrenzt und TextKit-Rekursion entfernt; Horizontalbereich je betrachteter Seite; neue Ränder in normalen A4-Einheiten und gleicher Text-Punktskala. **257 Core-Tests, Host-Roundtrip und finaler signierter SDK-Build bestanden; Build 31 installiert, alle 22 Hefte/153 Dateien unverändert.** Installation/Datenerhalt in [TESTING](TESTING.md).

Nächster Nachweis: [Build 31 gezielt testen](TEST-BUILD-31.md), insbesondere tatsächliches Mitziehen/Undo, Kontur/Menü, extremer Zoom und Randgrenzen. Kein Geräteerfolg aus Linux-Tests ableiten. Komplette fremde Referenzpalette mit Elementbibliothek/Speichern, Handschriftkonvertierung und nativen Ink-Strichmustern sowie freie Drehung/Spiegelung gemischter Text-/Formgruppen bleibt außerhalb dieser Umsetzung. Frühere Linienausrichtungs- sowie Halte-/Kreis-Abnahme noch offen.

## Aktuell – Rückmeldungen und Scrollen, Build 30

Ein gemeinsames Hauptlasso Freiform/Rechteck für Ink und freie Objekte mit Flow-Schutz, Kreis-Checklisten nach Referenz, ausgerichtete Formatierungsicons, Formen unter neuer Handschrift, kontinuierliche Halteerkennung mit Canvas-Haptik, schwarze neue PDF-Ränder und Wiederverwendung begrenzter Renderflächen implementiert. Keine erneute Änderung der zurückgenommenen Autostiftfarbmeldung. **248 Core-Tests, unabhängiger Host-Roundtrip und signierter SDK-Build bestanden; Build 30 installiert, alle 22 Hefte/153 Dateien bytegleich zum aktuellen Vorupdatebestand.** [Nachweise](TESTING.md).

Nächster Nachweis: [fünf gezielte Gerätetests](TEST-BUILD-30.md), insbesondere gemischte Auswahl, Halten/Haptik und tatsächliche Scrollverbesserung. Linienausrichtung aus Build-29-Test 2 wartet noch auf Nutzerbericht. Bereits bestätigte ältere Punkte nicht pauschal erneut offen nennen; neue native Wege dennoch separat abnehmen. Zitat-/Codeblöcke und gebündelte Inter-Schrift bleiben offen.

## Aktuell – Editorfehler, Build 29

Nachgereichte Textbedienung: Icon-Menüs, 14-pt-Start/Einerschritte, Cursor-/Auswahlsemantik, verbundener Listenwechsel und Absatz-Einfügeattribute umgesetzt und im finalen SDK-Build enthalten. Zitat-/Codeblöcke und gebündelte Inter-Schrift bleiben offen; nicht durch Textpräfixe oder andere Schriftbezeichnung vortäuschen. Native Abnahme gemeinsam mit dem übrigen Build-29-Paket.

Gemeldete Stiftmarkierung, gemischtes Lasso/Flow-Schutz/Rich-Text-Skalierung, Feldformatierung, Leistenanker/Griff, direkte Formen, Checkboxzyklus/Pencil-Tipp, Seitengrenzen, PDF-Randstandard/Autostift, gemeinsames Linienlayout und Halten für Stift-/Markerlinien umgesetzt. Zoom-Scrollweiterleitung und Caret während Pinch abgesichert; vollständige Ursache der kurzzeitigen Blockade noch nicht am Gerät reproduziert. **241 Core-Tests, unabhängiger Host-Roundtrip und SDK-Build bestanden; Build 29 installiert, alle 22 Hefte/153 Dateien unverändert.** Keine Formatänderung. Nächster Nachweis: einmal den gebündelten nativen Retest einschließlich Geräte-PDF aus [EDITOR-FEEDBACK-29](EDITOR-FEEDBACK-29.md) durchführen. Keine pauschale Alltagsfreigabe.

## Aktuell – Editor-Rückmeldung, Build 28

Listenbuttons toggeln, Ganzblatt-Rückkehr und Fokus laufen gemeinsam. Zoomabhängige Auflösung mit begrenztem PencilKit-/Papier-Viewport, korrigierte Seitenhintergründe und weniger Konfigurations-/Dekodierarbeit umgesetzt. 230 Core-Tests und signierter SDK-Build bestanden. Build 28 installiert und am Gerät direkt bestätigt; alle 22 Hefte/153 Dateien nach vollständigem Rücklesen unverändert. Keine Formatänderung. Native Schärfe, Ränder, Gesten/Undo und gemeldete kurze Blockaden bleiben im gebündelten Retest offen; kein genauer Freeze-Trace vorhanden. [Umsetzung und Prüfumfang](EDITOR-FEEDBACK-28.md), [Nachweise](TESTING.md).

## Aktuell – Texteditor, Build 27

Textfluss über mehrere Seiten ausdrücklich bestätigt. Papier/Schreibränder ohne Feldleisten, freie PDF-Felder, dunkle Tastatur und kompakte Formatierung nach vier neuen Referenzen umgesetzt. Eine virtuelle letzte Schreibseite wird durch Text oder ersten Pencil-Strich echt und vorher nicht exportiert/gezählt. Fokus-/Caret-/Scrollwege überarbeitet; mehrseitiges Text-Undo und Schema-8-Validierung/Migration. 219 Core-Tests, unabhängiger Archiv-/Bibliotheksrestore und signierter SDK-Build bestanden. Build 27 installiert und direkt am Gerät bestätigt; alle 22 Hefte/152 Dateien unverändert. Geräteupdate/Bestandsvergleich in [TESTING](TESTING.md); native Eingabe-/Textfluss-/Reserve-/PDF-Abnahme noch offen. [Arbeitsstand und Testpaket](TEXT-REBUILD-27.md).

Stand: 17.10.2026. Kleine, überprüfbare Schritte; Status immer als implementiert, gebaut und auf dem iPad getestet unterscheiden.

## Aktuell – Kopf und Eingabe, Build 26

Alle ergänzten Rückmeldungen implementiert: Kopf bleibt im gezeigten Sidebarfall einzeilig, einheitliches Glas, größere Trefferflächen, Ganzblattgrenze mit elastischem Zoom und Breiten-Snap, stärkere 90°-Drehung und Werkzeug-Hover. 207 Tests und signierter SDK-Build bestanden; Build 26 am Gerät bestätigt. Rücklesevergleich: 21 Hefte vollständig gleich, bei einem Heft ausschließlich Handschrift auf zwei vom Nutzer gerade bearbeiteten Seiten geändert. Signierung/Update und Bestandsvergleich in [TESTING](TESTING.md); die gebündelte native Eingabe-/Hover-/Zoomprüfung bleibt offen.

## Aktuell – Normalisierte Anzeige, Build 25

Nur Anzeige angleichen vom Nutzer bestätigt und implementiert: gleiche Grundbreite, Ränder erhalten, Arbeitsblatt lesbar einpassen, kanonische Inhalte und Export unberührt. Beide neuen Referenzleisten flacher/feiner/gruppiert übertragen. 198 Core-Tests, unabhängiger Archivroundtrip und signierter SDK-Build bestanden; Build 25 am Gerät bestätigt, alle 22 Heftinhalte unverändert; Updatebelege in [TESTING](TESTING.md). Nächster Schritt ist die gebündelte native Lese-/Eingabe-/Leistenprüfung gemäß [UI-REBUILD](UI-REBUILD.md#anzeige-normalisieren-und-leistenreferenzen--build-25).

## Aktuell – Bedienkorrekturen, Build 24

Weitere Rückmeldungen vollständig implementiert: neues Einpassen im Blättermodus, Mindestzoom, graues Glas ohne blaue Linie, angehängte Werkzeugoptionen, rechter Drehpfeil, 2×3-Punktgriff und längere Zonen. Standardmäßig Dockbindung, freies Platzieren optional; Drehsymbol aus der weiteren Ebene entfernt. 190 Tests, unabhängiger Format-6-Archivroundtrip und SDK-Build bestanden. Build 24 installiert; alle 22 Hefte/152 Dateien unverändert. Signierung/Update und Bestandsvergleich in [TESTING](TESTING.md); native Sicht-/Gestenprüfung bleibt offen.

## Aktuell – Seitenansicht, Build 23

Übersicht rechts, horizontaler Spielraum je 65 % und korrigiertes Vorladen aller sichtbaren Nachbarseiten implementiert; 183 Core-Tests und signierter iPad-Build bestanden; Build 23 installiert, alle 20 Heftinhalte unverändert. Native Sichtprüfung rechts/Schieben/Seitenfolge/Pencil bleibt offen; SDK-/Updatebelege in [TESTING](TESTING.md). Keine neuen Speicherformate oder Änderungen an Notizinhalten.

## Vorheriger Stand – Leistenkorrektur, Build 22

Rückmeldung zur Build-21-Leiste umgesetzt: Inhalt bestimmt Größe, Mitte exakt, freie Ausrichtung unabhängig vom Dock, sichtbare nahe Einrastzonen, hellere Symbole/Glas und gemeinsame Bedienanimationen. 178 Tests, Archivroundtrip und SDK-Build bestanden. Build 22 am Gerät bestätigt, alle 20 Hefte/139 Dateien beim Update unverändert; Nachweis in [TESTING](TESTING.md). Nächster Schritt ist die kurze Sicht-/Gestenprüfung der Leiste gemäß [UI-REBUILD](UI-REBUILD.md#korrektur-nach-gerätefeedback--build-22); übrige Rebuild-Abnahme bleibt offen. Build 21 wurde durch das Feedback nicht abgenommen.

## Aktuell – UI-Rebuild, Build 21

Bestätigte Vorgaben einschließlich Werkzeugaufteilung umgesetzt: vier Leistenanker plus Schweben, kompakter Kopf, mehrseitiger nativer Viewport/Blättern, Notizbuchdialog, Rich Text, Seitenmenü, optionaler Import-Schreibplatz, Autostift/Hover und Bild-Snapping. Notebook-Schema 7/Werkzeugformat 4; 169 Core-Tests, unabhängiger Archivroundtrip und iPad-SDK-Build bestanden. Als Update installiert, Build 21 direkt am Gerät bestätigt; alle 20 Hefte/133 vorherigen Dateien unverändert. Keine native Geräteabnahme. Nächster Schritt: ein gebündelter Geräte-/Neustart-/PDF-/Backup-Restoretest gemäß [UI-REBUILD](UI-REBUILD.md); kein erneutes Umfangsinterview. Anschließend die verbleibenden Build-20-/Alltagskriterien prüfen. Folgende Abschnitte sind Entwicklungsverlauf.

## Vorheriger Stand – Restliche Grundfunktionen, Build 20

Bestätigten Restumfang als zusammenhängendes Testpaket implementiert: Formen/Lineal/Halten/Pencil-Gesten, gemischtes Lasso, zwei Ansichten mit einem Writer je Heft, Textlisten/Checkboxen/Shortcuts, lokale Inhaltssuche einschließlich Vision-OCR/Handschrift, einzelne Seite als PDF, externe Sicherungen nach iCloud-Ordner oder WebDAV samt Aufbewahrung/Restore und Signierungserinnerung. Schema 6/Werkzeugformat 3. 158 Core-Tests, unabhängiger Schema-6-Host-Roundtrip und Migration einer Kopie von 19 gesicherten Heften/59 Seiten bestanden. iPad-Build signiert und als Update installiert; Geräteabfrage bestätigt Build 20, alle 20 Hefte/128 Dateien unverändert. **Neue Funktionen noch nicht am iPad abgenommen**. [Umsetzung und gemeinsamer Gerätetest](REST-FEATURES-20.md).

Vollständiges frisches Gerätebackup, Update und Bestandsvergleich bestanden. Nächster Schritt: den gebündelten Gerätetest durchführen; OCR-Qualität, echte PDF-/Backup-Artefakte, externe Zielrechte, 100-Seiten-PDF/Scans und Probetag bleiben notwendige Nachweise. Späterer UI-Umbau ist vorgesehen; stabile Speicher-/Inhaltsbesitzer und native Editorinstanzen dabei erhalten.

## Aktuell – Bilder und Screenshots, Build 19

Implementiert und signierte IPA gebaut: Import aus Fotos/Dateien/Zwischenablage, Verschieben/proportional skalieren/verlustfrei zuschneiden/frei oder 90° drehen/sperren, Reihenfolge unter Bildern, eigene Undo-Historie. Originale samt Parametern in Schema 5; Migration erst bei Bildänderung, Schema-5-Textbearbeitung ohne Downgrade. Vorschau/PDF/Seitenkopien/Papierkorb und beide Backuparten integriert. 139 Core-Tests sowie vollständiger Schema-5-Host-Roundtrip mit echter PNG und unabhängigen Pythonprüfern bestanden. Inzwischen als Update installiert: Gerät bestätigt Build 19, alle 19 Hefte/117 vorherigen App-Dateien unverändert. Nutzer bestätigt angeleiteten Bedienungs-/Neustart-/Exportdurchlauf ohne Auffälligkeiten. Tatsächliche fünfseitige Geräte-PDF und vollständiges Schema-5-Heftbackup geprüft; isolierter Host-Restore mit Bildweiterbearbeitung bestanden. Geprüftes Archiv bytegleich zurückübertragen; externer Schema-5-Geräterestore mit Bildzuschnitt/Sperre, neuer Handschrift und Neustart vom Nutzer mit „ja passt auch weiterhin“ bestätigt. Grundtest abgeschlossen; keine weiteren kleinen Einzeltests erforderlich. Bibliotheksbackup mit echten Gerätebildern und übriger V1-Umfang bleiben gesondert offen. [Umfang und ein gemeinsamer Gerätetest](IMAGES.md). Frühere Abschnitte sind Entwicklungsverlauf.

## Aktuell – Texteingang korrigieren, Build 18

Erster Build-17-Gerätetest scheitert bereits beim Einfügen: Textwerkzeug/Fingertipp erzeugt kein Feld. Neuer Featureausbau pausiert bis dieser Eingang funktioniert. Keine neue gespeicherte Box im AFC-Bestand, kein bestätigter Schema-4-Gerätebetrieb. Strikte Hit-View-/Touchtypfilter entschärft, direkte und Trackpad-Eingabe, zusätzlicher sichtbarer „Textfeld +“-Knopf über denselben geprüften Modellweg. Begrenzte Diagnose ohne Textinhalte. Quelltextbefund und Prüfgrenzen in [BUG-18-TEXT-INPUT.md](BUG-18-TEXT-INPUT.md); Ursache im tatsächlichen UIKit-Ereignisablauf noch nicht mit Trace bewiesen.

Build/Installation/Bestandsvergleich in TESTING.md. Knopf-/Fingertipp-/Eingabe-Retest vom Nutzer mit „ja passt und funktioniert“ bestätigt; Gerätelog zeigt zwei Einfügungen und akzeptierten direkten Touch. Griffe/Breite, vollständige Grundformatierung und Schließen/Öffnen inzwischen bestätigt; tatsächliche fünfseitige PDF mit echtem formatiertem Text und Schema-4-Heftbackup am PC geprüft, isolierter Host-Restore weiterbearbeitbar. Exakte Vor-Migrationsbytes am Gerät archiviert; andere 17 Hefte unverändert. Zurückübertragenes `noty-text18-geprueft.notybackup` am Gerät importiert und Text weiterbearbeitet/neugestartet, vom Nutzer mit „jo hat geklappt“ bestätigt. Grundweg des ersten Textpakets belegt. Nächster Entwicklungsschritt: Bild-/Screenshotobjekte mit eigenständigen Assets, Position/Größe/Zuschnitt/Drehung, Speicherung und PDF-/Backupintegration; noch nicht implementiert. Keine Wiederholung des bereits bestätigten Eingangs nötig.

## Aktuell – freie Textfelder, Build 17

Implementiert: mehrere native Textfelder je fester Seite inklusive PDF-Rand, stabile IDs/UIKit-Views, Einfügen/Verschieben/Breite/Löschen, eigene Formatleiste, Text-Undo und Überlaufhinweis. Schema 4 erst beim Textbearbeiten, alte Glyphpositionen erhalten und bestätigte Formatbytes vor neuem Commit sichern. Vorschau, echter PDF-Text, Heft-/Bibliotheksbackups und Seiten-/Rand-Sicherungen integriert. Umfang und verbleibende Textpakete in [TEXT-FIELDS.md](TEXT-FIELDS.md).

131 Core-Tests, Schema-4-Host-Backup-/Restore-Roundtrip samt Python-Gegenprüfung sowie Umstellung von Kopien zuerst 17 Hefte/50 Seiten und dann des aktuellen 18-Hefte-/56-Seiten-Bestands bestanden. Finaler signierter iPad-Build erfolgreich (8,62 s); als Update installiert, Geräteabfrage bestätigt Build 17, alle 18 Hefte/107 Dateien unverändert zurückgelesen. Native Texteingabe und Migration noch nicht am iPad bestätigt. Nächster Schritt: ein kurzer gebündelter Text-/Neustart-/Export-/Restoretest, keine Wiederholung aller Farb-/Schriftvarianten.

## Aktuell – bestehende Seite zurücksetzen, Build 16

Nutzer hat ausdrücklich bestätigt: „Bestehende Seite zurücksetzen und aktuellen Stand sichern“. Rand-Restore ersetzt jetzt den vollständigen Stand der passenden Originalseite unter ihrer stabilen ID/aktuellen Position. Der verdrängte Stand bleibt vorher vollständig im Seitenpapierkorb gesichert und ebenfalls wiederherstellbar. Wenn das passende Original fehlt, zusätzliche Seite statt einer geratenen Ersetzung. Reguläres Seiten-Wiederherstellen unverändert. UI-Generation verhindert alte Editor-Undo-/Callbackzustände beim Ersetzen derselben Seite; kein Schemawechsel.

123 Core-Tests, Host-Backup-/Restore-Roundtrip einschließlich aktueller Seitensicherung und signierter iPad-Build erfolgreich. Als Update installiert, Geräteabfrage bestätigt Build 16; alle 17 Hefte/97 Dateien unverändert zurückgelesen, siehe TESTING.md. Gezielter Geräte-Retest vom Nutzer mit „ja passt alles“ bestätigt: Seitenzahl unverändert, früherer Rand/Inhalt an derselben Seite, neuerer Stand im Papierkorb zurückholbar; Speichern/Neustart. Tatsächliche fünfseitige Geräte-PDF mit rechtem Karorand/Handschrift sowie vollständiges Heftbackup unabhängig am PC geprüft, alle Seitenmaße/Quelltext/Originalbytes korrekt, Host-Restore mit unabhängiger Weiterbearbeitung bestanden. Geprüftes Archiv bytegleich als `noty-rand-geprueft.notybackup` zurückübertragen. Import dieser Kopie über Explorer → + → Heft-Backup als Kopie importieren, neuer Pencil-Strich und Speichern/Neustart vom Nutzer mit „ja passt...“ bestätigt. Nächster Entwicklungsschritt: freie Textobjekte mit sicherer Übernahme bisheriger Texte; noch nicht implementiert. Details/Prüfgrenzen in TESTING.md. Keine Wiederholung aller UI-Varianten.

## Aktuell – Rand-Prozente bei gemischten PDF-Formaten, Build 15

Nutzer meldet 215 % auf kleiner Seite nach Anwendung auf den ganzen PDF-Import. Ursache: bisher dieselben absoluten Punktmaße kopiert. Jetzt dieselben Prozentwerte je dargestellter Grundseitengröße anwenden; Crop/Rotation und alte A4-Koordinaten berücksichtigen, nur denselben Import ändern. Vorhandene Ränder bleiben bis zur ausdrücklichen Änderung unverändert; Abschneidewarnung und vollständiger alter Seitenstand im Papierkorb bleiben erhalten. Kein neues Datenformat.

117 Core-Tests, vollständiger Host-Backup-/Restore-Roundtrip und signierter iPad-Build erfolgreich. Build 15 als Update installiert; abschließender Vergleich der zurückgelesenen Dateien siehe TESTING.md. Gezielter Prozent-Retest auf großer/kleiner Seite vom Nutzer mit „okay das schaut gut aus passt alles“ bestätigt. Keine Wiederholung aller Menüvarianten nötig. Übrige relevanten Paket-12-Pencil-/Restore-/Exportnachweise bleiben offen.

## Nächste Schritte nach Build 15

1. Ein kurzer risikobasierter Abschluss im bestehenden Testheft: links/oben im zusätzlichen Rand schreiben, speichern/neustarten; Randverkleinerung samt vollständigem Rand-Restore prüfen. PDF und vollständiges Backup dieses Testbestands exportieren, anschließend PC-Prüfung und gebündelter Geräte-Restore mit neuem Pencil-Strich. Keine erneute Prüfung aller Farb-/Reglervarianten.
2. Danach freie Textobjekte statt nur eines festen Textfeldes je Seite: mehrere Textfelder auch im Schreibrand, sichere Übernahme des vorhandenen Texts, Verschieben/Breite und sichtbarer Überlauf, native Fokus-/Tastaturbedienung. Objektmodell/Speicher-/Exportintegration zuerst; Formatierung schrittweise ergänzen. Vor Umsetzung offene Bedienungsdetails im Designgespräch festhalten.
3. Bilder und Formen auf derselben Objektebene, anschließend gemischtes Lasso. Zwei Ansichten, lokale Inhaltssuche/OCR und externe Backupziele bleiben Teil des bestätigten Umfangs, kommen in eigenen überprüfbaren Paketen.

## Aktuell – Vorschau und feste Seitenleiste, Build 14

Nutzer bestätigt den gezielten Build-13-Retest (Vorschau/Scrollen/Trefferflächen). Neue Anpassungen umgesetzt: störenden Trenner und Ziehgriff entfernen, Sidebar nicht mehr manuell skalierbar, proportionale Papierbilder ohne weißen Außenfüller und Auswahlrahmen am Papierbild. Rand-Schnellwerte Schmal 25 %/Mittel 60 %/Breit 100 %, neue Ränder Mittel. Vorhandene Werte erhalten. iPad-Build und Installation erfolgreich, Geräteabfrage bestätigt Build 14; alle 17 Hefte/96 Dateien unverändert zurückgelesen. Neue Darstellung noch nicht auf dem iPad bestätigt. Kein neues Datenformat, keine neuen Core-Tests für diese reine Darstellungsänderung.

## Aktuell – UI-Korrektur Build 13

Erster Build-12-Gerätedurchlauf nicht bestanden: Ladekreis im PDF-Schreibplatz, Zurückscrollen und versetzte Randregler. Test unterbrochen, kein neues Feature hinzufügen. Stabile UIKit-Vorschau, nur manuelles Zentrieren und Randkarten ohne wechselnde Kontrollzeilen umgesetzt; 111 Core-Tests weiter bestanden. Build 13 gebaut/signiert/installiert, alle 17 Hefte und 95 vorherigen Dateien nach Update unverändert. **Gezielter UI-Retest offen.** Details und kurzer Retest in [BUG-13-PREVIEW.md](BUG-13-PREVIEW.md). Gesamtpaket 12 bleibt unabgenommen.

## Aktuell vorbereitet – Build 12, Seitenverwaltung

Mit einem ausdrücklich gewünschten Subagenten umgesetzt: UI/Preview-Komponenten delegiert, Core/Speicher-/Editor-/Exportintegration und abschließende Prüfung beim Hauptagenten. Designgespräch Q16–29 in [DESIGN.md](DESIGN.md) festgehalten; neuer Umfang um PDF-Schreibränder ergänzt.

- [x] Echte linke Seitenleiste, verstellbar/einklappbar, schmal als Einblendung; Editorinstanz erhalten. Dunkles Raster nach Referenzbild mit nativen Glaseffekten/Fallback.
- [x] Seiten einfügen, unabhängig duplizieren, umordnen, löschen/wiederherstellen; mehrere unveränderte PDF-Quellen über stabile Referenzen. Lesezeichen und PDF-Inhaltsverzeichnis.
- [x] Eigenes Einfügefenster Vor/Nach/Letzte Seite, A4-Blanko/Linien/Karo in Weiß/Dunkel und weitere PDFs.
- [x] PDF-Schreibplatz an vier Rändern, Regler/Vorschau/Schnellwerte, Papierart/Farbe; aktuelle oder alle aktiven Seiten desselben Imports. Originalgröße/PDF-Farben und kanonische Ink-/Textkoordinaten erhalten.
- [x] Randverkleinerung mit betroffenen Strichen warnt. Nach Bestätigung vollständigen alten Seitenstand mit ursprünglichem Rand in den Seitenpapierkorb legen; Wiederherstellen als zusätzliche editierbare Seite.
- [x] Lazy Schema-3-Umstellung, vorher genaue ältere Revisionsbytes dauerhaft unter Migrations archivieren. Fehlgeschlagenes Archivieren lässt bisherigen Commit bestehen.
- [x] 111 Core-Tests und synthetischer vollständiger Host-Roundtrip mit echter vierseitiger Quell-PDF; unabhängige Python-Prüfung von Schema/Referenzen/CRC/Archivgleichheit.
- [x] Gesamte iPad-App gebaut/signiert und am 17.10.2026 als Update installiert. Vorheriges Gerätebackup gesichert; danach alle 15 Hefte und 82 Dateien unverändert zurückgelesen.
- [ ] Risikobasierter Sammeltest [BATCH-TEST-12.md](BATCH-TEST-12.md). Insbesondere PencilKit-Translation, Rand-Wiederherstellung, Neustart, PDF-Export und externer Schema-3-Restore nicht als bestanden ausgeben.

Nächster Schritt: Paket 12 gemeinsam auf getrenntem Testbestand prüfen; anschließend freie Text-/Bildobjekte und gemischte Auswahl gemäß Scope. Quellen sind innerhalb einer Revision geteilt, noch keine effiziente Asset-Deduplizierung über Revisionen. Großbestand/30-Minuten-Schreibtest/Alltagsfreigabe bleiben offen.

## Aktives Testpaket – Build 11

Nutzer erlaubt Vorbereitung weiterer Funktionen mit getrennten Testinstanzen und späterem Sammeltest. Umsetzung als logische Bereiche derselben App, ohne zusätzlichen Signierungsplatz. Build 11 als Update installiert; erste Bedienung und Bibliotheks-Roundtrip bestätigt/zurückgelesen. Auf Nutzerwunsch weitere Gerätetests nach Risiko bündeln; unwichtige Einzelvarianten überspringen und entsprechend kennzeichnen.

- [x] Getrennte Test-/Restore-Bereiche mit eigenen Notizen/Präferenzen, sichtbarem Kontext und zentralem Wechsel bei geschlossenen Editoren.
- [x] Vollständiger aktueller Bibliotheksbackup einschließlich Papierkorb/Ordnern/Stifteinstellungen; Restore über Staging und Veröffentlichung eines neuen Bereichs am Ende. Keine vorhandenen Pakete ersetzen.
- [x] Seitenübersicht mit PDF-/Ink-/Textvorschau, stabilen Seiten-IDs und begrenztem Vorschaubildcache.
- [x] Eigene Werkzeugleiste oben/links/rechts/frei schwebend; Reihenfolge, Farbe/Breite, Lieblingsstifte und optionales Fingermalen je Bereich speichern.
- [x] 92 Core-Tests; unabhängige Python-Prüfung und synthetischer vollständiger Bibliotheks-Roundtrip mit vierseitiger PDF erfolgreich.
- [x] Build 11 erfolgreich gebaut, signiert und am 17.10.2026 als Update installiert. Alle sechs Hefte und 32 vorhandenen App-Dateien unverändert zurückgelesen.
- [x] Wiederfinden, Testbereich, PDF-/Seitenübersicht und Grundbedienung der eigenen Leiste vom Nutzer bestätigt.
- [x] Echtes Bibliotheksbackup extern geprüft, zurückübertragen und auf dem Gerät wiederhergestellt. Zwei gültige Kopien zurückgelesen; Textänderung in Restore 3 gespeichert, Originalheftinhalte erhalten, vorhandene Ink/Metadaten korrekt übernommen. Beschädigter Import laut Nutzer abgewiesen.
- [ ] Neue Pencil-Änderung nach Restore und lokale Historie bei nächstem relevanten Speichertest bündeln; derzeit offen, kein weiterer Einzeltest.
- [ ] Übrige manuelle Varianten aus [BATCH-TEST-11.md](BATCH-TEST-11.md) nach Risiko auswählen; kleine UI-Varianten dürfen auf Nutzerwunsch ungeprüft bleiben.

Nächste Entwicklungsschritte: Seitenoperationen sowie effiziente Quellenverwaltung. Externer Bibliotheks-Roundtrip auf dem iPad für den kleinen Testbestand belegt; offene Ink-/Historien-/Großbestand-/Alltagsnachweise bleiben bestehen. Formate/Grenzen in [LIBRARY-BACKUP.md](LIBRARY-BACKUP.md).

### Nächstes Feature: linke Seitenverwaltung

Am 17.10.2026 ausdrücklich präzisiert: echte linke Seitenleiste ähnlich Goodnotes, passend zur Notizbuchnavigation, einklappbar neben der Schreibfläche. Die bestehende modale Seitenübersicht aus Build 11 ist nur der bisherige Zwischenstand.

- [ ] Vorschaubilder, Seitennummern, aktuelle Auswahl und direkter Rückweg zu den Notizbüchern in der Seitenleiste.
- [ ] Seiten per Ziehen umordnen, über „+“ Blanko-/Linien-/Karoseiten und PDFs an gewünschter Stelle einfügen.
- [ ] Seitenmenü mit unabhängigem Duplizieren, Verschieben und Löschen; gelöschte Seiten wiederherstellen.
- [ ] PDF-Quellen über stabile Referenzen von der Seitenreihenfolge trennen; Altpositionen, Originalbytes und Wiederherstellbarkeit erhalten.
- [ ] Zuerst isolierte Core-/Dateitests und iPad-Build; anschließend ein gebündelter Gerätetest mit Testheft. Implementierung, Build und Geräteabnahme separat dokumentieren.

Historischer Planungsstand: inzwischen als Build 12 oben umgesetzt/gebaut; Geräteabnahme weiterhin offen.

## Aktuelles gemeinsames Testpaket – Build 10

Nutzer wünscht ausdrücklich Vorbereitung mehrerer Funktionen und anschließende gebündelte Gerätetests. Deshalb Phase-3-Bibliothek als isolierten Index ergänzen, während der Sichttest aus Build 9 und die lokale Ink-Wiederherstellung weiterhin offen bleiben. Keine V1-Abnahme daraus ableiten.

- [x] Bibliotheksindex mit atomarem Commit, CRC, vorherigem Stand und Versionsschutz; bestehende Pakete ohne Verschieben/Neuschreiben übernehmen.
- [x] Native Seitenleiste/Ordnerbaum, neue Hefte, PDF als neues Heft, Umbenennen, Verschieben, manuelle Reihenfolge, Favoriten, Zuletzt verwendet, globale Namenssuche und Papierkorb/Wiederherstellen.
- [x] Editorwechsel wartet auf Speicherung; bei Fehler offen bleiben, alten Editor vor erneutem Öffnen stilllegen.
- [x] 73 Core-Tests; Bibliotheksoperationen zusätzlich an Kopie des echten Sechs-Hefte-Bestands geprüft, sechs alte Inhalte unverändert.
- [x] Build 10 für arm64 erfolgreich gebaut und signiert (8,48 s).
- [x] Build 10 als Update installiert; danach sechs vorhandene Hefte vollständig unverändert zurückgelesen. App für den ersten Bibliotheksstart noch nicht manuell geöffnet.
- [ ] Gemeinsamer iPad-Test einschließlich Wiederfinden/History: [BATCH-TEST-10.md](BATCH-TEST-10.md).

Historischer Build-10-Stand: Export sichert ein Heft. Build 11 ergänzt das oben beschriebene Bibliotheksformat; dessen Gerätetest ist noch offen.

## Phase 0 – kleiner Funktionstest abgeschlossen

- [x] Projektbestand prüfen; neues isoliertes Projekt `/home/la/workspace/noty`, Git initialisiert, vorhandene Projekte nicht geändert.
- [x] Architektur, installierte Werkzeuge und USB-Verbindung ermitteln.
- [x] Swift 6.4.1 und xtool 1.22.2 im Benutzerbereich einrichten; tatsächliche xtool-Hilfe lesen.
- [x] Minimale App mit PDFKit, PencilKit und UITextView implementieren.
- [x] Plattformunabhängigen Speicherkern bauen und unter Linux testen.
- [x] SDK aus `/home/la/Downloads/Xcode_27.1.xip` installieren; Versionen protokollieren.
- [x] iOS-App bauen: `xtool/Noty.app`, arm64, iOS/iPadOS mindestens 17.0, keine gemeldeten Warnungen/Fehler.
- [x] Nutzer meldet sich selbst mit `xtool auth` bei Apple an.
- [x] iPad verbinden und Version lokal ermitteln: `iPad17,1`, iPadOS 27.0.1. USB-Kommunikation möglich.
- [x] Manuellen App-Start auf dem iPad vom Nutzer bestätigt.
- [x] Installation erfolgreich; Nutzer bestätigt PDF-Testseite, Stift, Texteingabe und Speicherstatus.
- [x] Erneut als Update installiert; Hauptdokument samt IDs, Strichen und Text inhaltlich erhalten. JSON-Bytes können wegen Schlüsselreihenfolge variieren.

Signierung: bestehendes Entwicklungszertifikat mit ausdrücklicher Nutzerfreigabe widerrufen und ersetzt. Erster Installationsversuch danach scheiterte am Drei-App-Limit. Nutzer gab einen Platz frei; Installation und Update über `xtool dev build --sign --ipa` / `xtool install --usb xtool/Noty.ipa` erfolgreich. Siehe ENVIRONMENT.md für die tatsächlich installierte App-ID.

## Phase 1 – durchgehender Basistest abgeschlossen

Gesamtumfang und Abnahme in [SCOPE.md](SCOPE.md) und [ACCEPTANCE.md](ACCEPTANCE.md) sind nach Q1–Q15 ausdrücklich bestätigt. Das Interview ist abgeschlossen.

- [x] Gemeinsame CropBox-/Rotationsgeometrie, echte Seitengrößen für neue Importe; alte A4-Notizen behalten ihre Positionen. Schema-1-Migration mit gesicherten Originalbytes.
- [x] Native äußere Zoomansicht, eigene Grundwerkzeugleiste, beide PencilKit-Radierer, Ink-Lasso, Undo/Redo; keine sichtbare Apple-Palette.
- [x] PDF-Export komponiert Original-PDF, Handschrift und echten Tastaturtext ausdrücklich; Textüberlauf bricht Export verständlich ab.
- [x] 18 Core-Tests erfolgreich. Build 5 erfolgreich gebaut und als Update installiert.
- [x] Nutzer bestätigt erhaltene Altpositionen, Zwei-Finger-Zoom, Drehen und Undo/Redo.
- [x] Geräte-PDF mit vier Seiten zurückgeholt und vollständig gerendert; Seitengrößen, Rotation und extrahierbarer Quelltext korrekt. Handschrift/Marker und extrahierbarer Tastaturtext auf Seite 1 vorhanden.
- [x] Nutzer bestätigt Lasso-Fokuskorrektur aus Build 5, beide Radierer und Rückgängigmachen.
- [x] Zweiten Geräteexport geprüft: eigene Eckmarkierungen auf allen vier Rotationen, getippter Text auf Seite 1/2; Positionen passen zu den Farbmarken.
- [x] Nutzer bestätigt Inhalte auf allen vier Seiten nach Speichermeldung, erzwungenem App-Ende und erneutem Öffnen.

## Aktuell – Phase 2, Revisionen und Wiederherstellung

- [x] Revisionsspeicher samt Manifest-Commit, CRC-32-Prüfung, höchstens drei regulär referenzierten Ständen und separatem vorigen Manifest implementiert.
- [x] Migration erhält Prototypdateien bytegenau; frühere gültige Version bleibt auch bei fehlgeschlagenem ersten Manifest-Commit lesbar.
- [x] Bewusster Restore archiviert alle ursprünglichen Revisionen/Manifeste vor dem Ersetzen; unbekannte neuere Formate bleiben gesperrt.
- [x] 36 Linux-Tests bestanden, darunter konkurrierende Autosaves und tatsächliche Dateisystemfehler an Recovery-/Manifest-Zielen.
- [x] Build 6 erfolgreich gebaut/signiert (9,75 s). Erneutes Gerätebackup vor Update erstellt.
- [x] Build 6 erfolgreich als Update installiert.
- [x] Migration auf dem iPad bestätigt; zurückgelesene Revision vollständig gleich zum Vorbestand, beide Prototypdateien bytegenau erhalten, Prüfsummen unabhängig geprüft.
- [x] Neuer Text unter Build 6 gespeichert und nach erzwungenem App-Ende wieder vorhanden, Nutzer bestätigt.
- [x] Versionierter einzelner Heft-Backup-Export mit Längen-/CRC-Prüfung und Größenlimit implementiert. Restore über Staging in getrennte Kopie; Originalheft bleibt erhalten.
- [x] 50 Core-Tests bestanden; Build 7 gebaut/signiert (9,54 s) und erfolgreich als Update installiert.
- [x] Tatsächliches Heft-Backup außerhalb des Containers auf dem PC unabhängig geprüft und zurückübertragen. Restore-Kopie lädt vier Seiten; eindeutiges Testwort nach Schließen/Wiederöffnen erhalten, Hauptheft während dieses Tests unverändert. Beschädigtes Archiv auf dem iPad mit Prüfsummenfehler abgelehnt.
- [x] Lokale Historie mit Zeitangabe/stabiler Revisions-ID implementiert; öffnet jeden Stand als getrennte Kopie. Kopien aus Kopien erscheinen in derselben Sammlung.
- [x] 59 Core-Tests bestanden, einschließlich neun neuer Historien-/Kopien-Tests.
- [x] Build 8 erfolgreich gebaut/signiert (7,98 s) und als Update installiert; Hauptheft und bestehende Restore-Kopie zurückgelesen: vollständig erhalten.
- [ ] Build-8-Geräteprüfung nicht bestanden: Nutzer findet Änderungen zwischen mehreren gleich benannten Kopien nicht. Bestand vollständig gesichert; Testwort und neue Ink in ursprünglicher Kopie auf Seite 2 gefunden, Hauptheft unverändert.
- [x] Build-9-Korrektur implementiert und gebaut: Vollbild, Kopienbrowser/Seitenvorschau, stabile Editoridentität, gemerkte Seite und bewusste Auswahl. 61 Core-Tests bestanden.
- [x] Build 9 erfolgreich installiert; alle sechs Hefte zurückgelesen und vollständig gleich zum Vorbestand.
- [ ] Wiederfinden auf dem iPad über Suche `RESTORE-17` und direkten Seitensprung bestätigen. Erst anschließend lokale Ink-Wiederherstellung erneut abnehmen.
- [ ] Vollständiger V1-Bibliotheks-/Zielbackupweg bleibt offen.
- [ ] Quellen/Zeichendaten für große Dokumente deduplizieren; derzeit vollständige JSON-Snapshots je Revision.

Bibliothek im aktuellen Paket auf der vorhandenen Speicherschicht aufbauen, ohne das Heftformat umzubauen. Weitere Objekte und V1-Freigabe bleiben an die ausstehenden Nachweise gebunden. Details: [STORAGE.md](STORAGE.md), [LIBRARY.md](LIBRARY.md).

## Danach in dieser Reihenfolge

1. **Phase 1:** durchgehender PDF → Handschrift + festes Textfeld → Speichern → Neustart → PDF-Export; CropBox, Rotation und Zoom früh beweisen. PDFPageOverlayViewProvider als Grundlage bewerten.
2. **Phase 2:** endgültiges versioniertes Dokumentpaket, konsistente Revisionen, begrenzte Wiederherstellungspunkte, Prüfsummen, sicherer vollständiger Backup-/Restore-Weg; Schreibabbrüche gezielt testen.
3. **Phase 3:** Fächer, mehrere Dokumente, Suche, Zuletzt verwendet, Seitenübersicht/-operationen, Papierkorb und Wiederherstellung. Demo: Steuerrecht, Rechnungswesen, Wirtschaftsrecht.
4. **Phase 4:** Schreibgefühl, Textobjekte/Formatierung, Shortcuts, Fokus, Undo/Redo und Gesten. 30 Minuten gemischte Nutzung auf dem Gerät.
5. **Phase 5:** optionale externe Backupversuche während Nutzung, begrenzte Caches, große PDFs/Scans, Probetag und externer Restore in leeren Testbestand.

Fließtext über mehrere Seiten, Cloud-Synchronisierung, Zusammenarbeit, eigener Scanner, Audio, Handschrift-zu-Text-Konvertierung, Tabelleneditor und KI bleiben ausdrücklich für später. Zielumfang enthält globale Handschrift-, Scan-/Bild-OCR-, PDF- und Tastaturtextsuche. WebDAV und iCloud Drive werden als wechselbare Backupziele unterstützt, genau eines aktiv, Backups unverschlüsselt. Text-/Bildbearbeitung gemäß SCOPE.md ist bestätigt. Wöchentliche Signierung am PC akzeptiert; Datenerhalt ist Pflicht.

## Entscheidungen

- Name: noty, Bundle-ID zunächst `de.la.noty.prototype`, danach stabil halten.
- SwiftUI für die App, UIKit-Brücke für PDF/Pencil/Text. Keine externen App-Abhängigkeiten, kein Konto/Server zur Laufzeit.
- iPadOS 17 als vorläufiges Minimum: entspricht dem geprüften xtool-Template und den verwendeten SwiftUI-APIs. Das tatsächliche Testgerät entscheidet über die endgültige Untergrenze; Pencil-Pro-Funktionen sind noch nicht implementiert.
- Früh ein kleiner Speichertest, weil Datenverlust das höchste Risiko ist. Das JSON-Prototypformat ist noch nicht das endgültige V1-Archiv.

**Belegt:** Phase 1, Build-6-Speicherung/Migration, Build-7-Heftbackup mit PC-Prüfung/Rücktransfer, editierter Restore-Text und abgewiesenes beschädigtes Backup. Aktuell 73 Core-Tests bestanden; Build 10 gebaut/installiert, Gerätetest des Pakets offen. **Offen:** Build-8-Geräteprüfung lokaler Historie, neuer Pencil-Strich in Restore-Kopie, effiziente Assets, vollständiges Bibliotheksbackup und externe Zielverwaltung, Stift-Langzeittest und V1-Abnahme.

Offener Sichtnachweis: [Untersuchung und Navigationskorrektur](RECOVERY-2026-10-17.md). Auf ausdrücklichen Nutzerwunsch nächste Funktionen vorbereiten und gemeinsam testen; Wiederfinden als ersten Punkt in das Testpaket übernehmen. Keine Migration vorhandener Heftinhalte für den Explorer.
