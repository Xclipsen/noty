# Designentscheidungen für noty

## Gesetzessammlung – bestätigte Bedienung, 20.10.2026

Appweites **Konto** in den Einstellungen, eigener Punkt **Gesetzessammlung** mit drei unabhängigen Schaltern: Aktivierung (aus), persönlicher Abgleich (an), automatische neue Gesetzesfassungen (an). Ohne Anmeldung lesen/markieren; nach Logout bleiben Markierungen sichtbar. Gesetzesfenster über das Editor-Optionenmenü öffnen. Griff ziehen für Seite bzw. Andock-/Schwebemodus, Menü für explizite Anordnung, seitlicher Griff für Breite. Angedockt erhält das Heft eigenen Platz; das zweite Heft wird erhalten, schwebend sind zwei Hefte plus Gesetzesfenster möglich. Bei zu geringer Breite schwebend anzeigen.

Native Suche: Gesetz wählen und Nummer eingeben oder `144 HGB`/`HGB 144` im direkten Suchfeld. Eindeutige Fundstellen nach kurzer Pause öffnen, Volltextsuche mit Suchen/Enter. Apples Zahlen-/Texttastatur mit direktem Wechsel für Zusätze/Absätze; keine eigene Ziffernpalette und keine zugesicherte schwebende iPad-Tastaturgröße. Text/PDF, Inhaltsverzeichnis und Fassungen im Leser. Details und tatsächliche Nachweise: [LAW-INTEGRATION-PLAN](LAW-INTEGRATION-PLAN.md), [TESTING](TESTING.md#native-gesetzessammlung--feature-worktree).

## Bild-Werkzeug im noty-Stil – 20.10.2026

Nutzer: Das Bild-Werkzeug passt nicht zum Stil von noty. Angeglichen an Werkzeugleiste, Lasso-Leiste und Formatleiste, ohne Funktionen hinzuzufügen oder zu entfernen. Gesten und Speichern sind unverändert.
- **Optionszeile:** „Foto“, „Bilddatei“ und „Einfügen“ zeigen jetzt ein Symbol in derselben Größe wie die anderen Optionen (18 pt) und daneben eine kurze Beschriftung. Die Flächen sind 44 pt hoch. Ein feiner Gruppentrenner wie in der Werkzeugleiste trennt die Quellen von der Zwischenablage. „Bilddatei“ passt zum Hinweis bei nicht lesbaren Fotos. VoiceOver und Tooltips nennen jeweils die ganze Aktion.
- **Auswahlrahmen:** Der Rahmen ist im Akzent (#7DD3FC) statt Systemblau, 2 pt breit, mit einem feinen dunklen Saum. So bleibt er auch auf weißem Papier und auf PDFs sichtbar.
- **Anfasser:** Statt voller blauer 44-pt-Kreise gibt es schlichte 26-pt-Scheiben im Akzent mit weißem Ring, dunklem Symbol und leichtem Schatten. Die Trefferfläche bleibt 44 × 44 pt. Rastet das freie Drehen auf einen rechten Winkel ein, wird die Scheibe weiß mit Akzentring (vorher Türkis).
- **Aktionsleiste:** Die dunkle Kapsel bleibt. „Gesperrt“ wird jetzt wie ein ausgewähltes Werkzeug angezeigt, mit eingefärbtem Schloss im Akzent statt einem blau hinterlegten Kasten. Löschen bleibt rot. „Auf nächsten 90°-Winkel drehen“ heißt kurz „Um 90° drehen“.
- **Zuschneiden:** Der Ausschnittrahmen, die Regler und die Schaltflächen sind im Akzent statt Weiß/Systemblau.

Stand: implementiert und erfolgreich gebaut (`xtool dev build` ohne Warnungen). Nicht installiert, am iPad ungeprüft (Erkennbarkeit auf hellem/dunklem Papier, Gefühl der Anfasser).

## Rückmeldung zu Build 49 – 20.10.2026

Nutzertest Build 49. Umgesetzt in diesem Strang:
- **Werkzeugleiste:**
  - Kein sichtbarer Kasten mehr um das ausgewählte Werkzeug.
  - Hover hebt nur das Symbol selbst an, ohne Systemplatte und ohne Trefferfläche.
  - Ausgewählt: Das Symbol wird etwas größer (1,2-fach), und nur der schreibende Teil trägt die aktive Farbe. Das sind die Mine bei Stift/Bleistift, der Strich unter dem Textmarker und der Punkt beim Laserpointer. Andere Werkzeuge färben nichts ein, sondern nehmen die Farbe des zuletzt benutzten Stifts nur dort an, wo es einen schreibenden Teil gibt.
  - Aktive Hilfsknöpfe (Lineal, Schreibscrollen) sind eingefärbt statt hinterlegt.
- **Schreibscrollen:** Der Blattrand (mit Schreibplatz) kann höchstens bis zur Bildschirmmitte gezogen werden. Vorher wanderte die Mitte des äußersten Bereichs bis zum gegenüberliegenden Rand. Der Schalter heißt jetzt „Schreibscrollen bis zur Bildschirmmitte“.
- **PDF-Schreibplatz:** Die Linien im Rand beginnen mit 32 pt Abstand zum PDF statt direkt an dessen Kante. Jeder Rand wird für sich liniert, in Editor, Vorschau und Export gleich (`PageLayout.ruledColumnsBesidePDF`). Papierseiten bleiben ein durchgehendes Blatt.
- **„Seite anpassen“:** Die Vorschau ist scharf und folgt den Reglern ohne Verzögerung. Die gespeicherte Seite wird einmal gerendert, Papier und Linien des neuen Platzes werden live gezeichnet.

## Präzisionsradierer und Formen – 20.10.2026

Nutzer zu Build 50: Der Präzisionsradierer entfernte eine berührte Form ganz, er soll aber nur das berührte Stück wegradieren. Jetzt:
- **Schneiden statt Entfernen:** Durchgezogene Formen ohne Füllung (Linie, Pfeil, Rechteck, Ellipse) werden entlang der Radiererspur geschnitten. Während des Radierens ist schon zu sehen, was übrig bleibt. Beim Abheben werden die Reste zu normaler Stift-Tinte in Farbe und Breite der Form (`ShapeEraseMask`). Sie lassen sich danach wie jeder Strich weiterradieren, sind aber keine bearbeitbare Form mehr.
- **Gefüllte, gestrichelte oder gepunktete Formen** haben keine Tinten-Entsprechung und werden weiterhin ganz entfernt.
- **Undo:** Radieren der Tinte und Schneiden der Formen sind ein Schritt.
- **Strich-Radierer („Ganz“):** entfernt Formen weiterhin ganz.
- **Strichbreite der Reste (Nutzer zu Build 51: „sehr dünner Strich“):** PencilKit zeichnet einen Stift-Punkt dünner als seine Größe. Beim ersten Schneiden misst noty die tatsächlich gezeichnete Breite eines Teststrichs (Alpha-Abdeckung im Bild) und vergrößert die Punkte entsprechend, damit der Rest so breit bleibt wie die Form.

## Pencil-Schnellmenü – 20.10.2026

Nutzer zu Build 49: Im Schnellmenü (einmal Drücken bzw. Doppeltippen mit Palette-Einstellung) klappt das erste Scrollen. Beim zweiten Scrollen wird aber das Werkzeug gewählt, auf dem gescrollt wurde. Außerdem soll das Menü immer gleich beginnen und sich kurz merken, wo es geschlossen wurde. Umgesetzt:
- **Nur Tippen wählt.** Eine Berührung auf dem Rad ist entweder ein Tippen oder ein Scrollen. Ab 12 pt Bewegung scrollt sie endgültig, und das Abheben wählt dann nichts, auch wenn der Finger wieder auf einem Eintrag landet. Ursache: Die Scrollgeste lief gleichzeitig mit den Eintrags-Buttons. Weil der Eintrag dem Finger folgt, endete die Berührung auf ihm und zählte als Tippen. Nur wenn das Scrollen am festen Ende anschlug, verließ der Finger den Eintrag, meist beim ersten Scrollen.
- **Feste Reihenfolge**, unabhängig vom aktiven Werkzeug: Rückgängig | Stift, Bleistift, Textmarker, Radierer, Text. Das ist der Standardbereich; dafür sind 6 Plätze sichtbar, und der Bogen ist etwas größer (Radius ca. 146 statt 117 pt). Per Scrollen folgen die übrigen Werkzeuge in Leistenreihenfolge (Standard: Lasso, Formen, Bilder, PDF lesen, Laserpointer), dann Farbe, Breite und Autostift. Wiederholen steht direkt vor Rückgängig und ist erst sichtbar, wenn man einen Platz zurückscrollt (Nutzer zu Build 50; vorher stand es am Ende). Das aktive Werkzeug bleibt markiert; der Radierer gilt auch für den Präzisionsradierer.
- **10-s-Gedächtnis:** Beim Schließen merkt sich das Menü die sichtbare Position. Öffnet es innerhalb von 10 s wieder, erscheint es dort, sonst im Standardbereich. Das Gedächtnis gilt app-weit und wird nicht gespeichert.
- Unverändert bleiben Doppeldrücken (Radierer ↔ Schreibwerkzeug), Platzierung für Linkshänder, „Bewegung reduzieren“, Haptik und das dunkle Glas. VoiceOver liest die Einträge als Tasten; mit drei Fingern wischen blättert.

Core: `PencilPaletteContent`, `PencilPaletteTouch`, `PencilPaletteMemory` mit Tests. Stand: implementiert, Core-Tests und SDK-Build. Gefühl beim Tippen/Scrollen und die 10 s sind am iPad ungeprüft.

## Schreibplatz für Papierseiten – 20.10.2026

Nutzer: Normale Seiten sollen sich wie PDF-Seiten über „Schreibplatz hinzufügen“ erweitern lassen, vor allem nach **rechts**. Die Linien sollen in den neuen Platz übergehen, nicht abschneiden. Umgesetzt:
- Papierseiten bekommen Platz nur rechts/unten, in Papierart und -farbe der Seite. Die Lineatur läuft nahtlos weiter, kein Inhalt verschiebt sich.
- Startwert rechts 100 %; Geltung „Aktuelle Seite“ oder „Alle Papierseiten“.
- Zugang über das Seitenmenü und das „…“ im Editor.
- Notebook-Schema 11.

Der erste Vorschlag „nur nach unten verlängern“ ist damit ersetzt. [Details](PAGE-ADJUST.md).

## UI-Feinschliff: Menüs und Icons – 19.10.2026

Nutzer: Das „…“-Menü im Editor erschlägt; einfaches Konzept, andere Menüs dürfen angepasst werden, Wirkung einer fertigen App. Eigene Entwürfe für App-Icon und Werkzeug-Icons, Anpassungen erlaubt. Umgesetzt: Optionenmenü mit Statusüberschrift und gruppierten Untermenüs (Teilen und exportieren, Ansicht), Kopf-Duplikate nur bei Platzmangel im Menü, Statushinweis nur bei Handlungsbedarf/kurz nach Exporten, gruppierte Seiten-/Seitenleistenmenüs mit bestätigter Reihenfolge, Bibliothek mit einem „Neu“-Menü, Einstellungen gruppiert, einheitlich „Notizbuch“. Neue Werkzeugglyphen und App-Icon nach Nutzerentwurf; Bleistift/Laser im selben Stil ergänzt. [Konzept, Details und Nachweise](UI-POLISH.md).

## Bleistift, Laserpointer, Pencil-Haptik – 19.10.2026

Nutzerwunsch: Laserpointer mit mehreren Funktionen, echter Bleistift, Vibration des Pencils bei Lasso und Laserpointer. Technische Startwerte, reversibel:

- **Bleistift**: native PencilKit-Bleistifttinte (Textur, Druck, breite Schattierung durch Neigen). Start Graphitgrau, Breite 1–16 (3), eigener Autostift, Lieblingsstifte. Halten begradigt/erkennt Formen, Ergebnis bleibt Bleistifttinte statt Formobjekt. Durchkritzeln-Löschen bewusst nur beim Stift: Schraffieren gleicht Kritzeln. Leiste/Squeeze-Palette direkt nach dem Stift; Doppeltippen/-drücken wechselt Radierer ↔ zuletzt benutztes Schreibwerkzeug, vom Laserpointer direkt zurück.
- **Laserpointer**: eigene Ebene über allen Seiten des Viewports, durchgehend über Seitengrenzen, Schreibraum und PDFs. „Punkt“ (Leuchtpunkt mit kurzem Schweif) oder „Spur“ mit Dauer Kurz 0,7 s / Mittel 1,5 s / Lang 3 s / Bis Absetzen; fünf Farben, Start Rot/Spur/Mittel; Pencil-Hover zeigt einen gedimmten Punkt. Nie gespeichert, kein Undo, keine Vorschau/kein Export. Finger scrollen weiter; mit Fingermalen zeigt ein Finger, zwei navigieren.
- **Haptik** nur Apple Pencil Pro ab iPadOS 17.5 (`UICanvasFeedbackGenerator`), sonst ohne Ersatz: Lasso schließt mit Auswahl; gedrehte Handschrift rastet bei 90°-Vielfachen ein; schwebende Auswahl erreicht eine andere Seite; Laserpointer setzt nach vollständigem Ausblenden neu an. Bestehend: Halten-Erkennung.
- **Werkzeugformat 8**: Format 7 wird beim Laden übernommen (Bleistift nach Stift, Laserpointer nach „PDF lesen“). Exakte Format-7-Bytes bleiben vor dem ersten Format-8-Commit als `toolbar-format7.json`; ältere Builds sperren Format 8 statt Standards zu schreiben. Python-Bibliotheksprüfer akzeptiert 1–8.

Stand: implementiert, Core-Tests/Host-Roundtrip/SDK-Build; Gefühl, Haptik, Hover und Laserdarstellung am iPad ungeprüft.

## Präzisierungen 32 – 18.10.2026

IMG_0274 bestätigt: Die Build-31-Ausnahme für PDF-Randseiten ist falsch. Bei einheitlicher Anzeige müssen Papier und PDF dieselbe Grundbreite haben, auch mit Schreibrand. 100 % neuer Rand folgt wieder der PDF-Grundbreite und erscheint damit als normale Seitenbreite. Randtext/Lineatur nutzen normale Seiteneinheiten; 14 bleibt 14 in den Stilen/Bedienelementen, keine künstlich hochgerechneten Schriftgrößen. Gespeicherte individuelle Ränder nicht still umdeuten; einen unter Build 31 zu schmal angelegten Rand ausdrücklich über Rechts/Breit/100 % erweitern.

Lasso: Farbe während Vorschau und nach Commit erhalten; Handschrift mit umlaufender animierter Kontur und Drehgriff, bei Bewegung-reduzieren statisch. Nutzer präzisiert IMG_0275: Die dünnen dunklen Linien sind zwei fehlgeschlagene begradigte Stiftlinien. Halten muss die sichtbare Vorschaufarbe und konfigurierte Stärke bis zum gespeicherten nativen Strich erhalten. [Umsetzung und Geräteprüfung](history/EDITOR-FEEDBACK-32.md).

## Präzisierungen 31 – 18.10.2026

Die neue Rückmeldung ersetzt die Einschließungsregel aus Build 30: Lasso wählt alles Berührte/Enthaltene; Seitentext und gesperrte Bilder bleiben geschützt. Freiform/Rechteck zum Auswählen, bei reiner Handschrift anschließend Kontur um die Striche statt rechteckigem Rahmen. Menü ausdrücklich dunkel nach Referenz, lesbare Aktionsleiste und kleine Griffe mit großer Trefferfläche; reine Handschrift seitlich drehen/spiegeln. Kein bloß bewegter Rahmen ohne Inhalt.

Starken Zoom ohne volle hochaufgelöste Seitenraster betreiben. Horizontal nur den Bereich der tatsächlich betrachteten Seite freigeben; breite Nachbarseiten dürfen schmale Seiten nicht seitlich ins Leere scrollen lassen. Neuer Import-Schreibplatz startet rechts/schwarz/100 %, wobei 100 % einer normalen A4-Seitenbreite entspricht. Schreibseiten in gemeinsamen Punktgrößen anzeigen, auch bei aktivierter PDF-Breiten-Normalisierung; vorhandene Inhalte/Ränder nicht automatisch umschreiben. Die PDF-Höhe/-Geometrie erhalten. [Umsetzung, Referenzgrenzen und Retest](history/EDITOR-FEEDBACK-31.md).

## Präzisierungen 30 – 18.10.2026

Ein einziges Hauptlasso mit Freiform/Rechteck: vollständig eingeschlossene Handschrift, freie Textfelder, Bilder und Formen gemeinsam auswählen; seitengebundenen Text schützen. Die vorherige Trennung zwischen Objekt- und Handschrift-Lasso entfällt. Neue Handschrift liegt sichtbar über Formen, ebenso in Vorschau/PDF. Halten soll die erkannte Linie vor dem Abheben gerade anzeigen und auf unterstütztem Pencil fühlbar bestätigen.

Checkboxen nach IMG_0265/0266: dünner offener Kreis, erledigt gefüllter Kreis mit Haken sowie gedimmtem/durchgestrichenem Text. Dreistufiger Formatbutton und Pencil-Tipp bleiben. Formatierungsicons auf gleicher Höhe. Neue PDF-Ränder zunächst schwarz als künftiger Systemstandard, rechts 100 %; vorhandene Einstellungen erhalten. Zurückgenommene Autostiftfarbmeldung nicht erneut bearbeiten. Scrollruckler durch weniger Canvas-/Layoutarbeit reduzieren, Gerätewirkung separat abnehmen. Linienausrichtung wartet weiter auf Nutzerrückmeldung. [Umsetzung und Grenzen](history/EDITOR-FEEDBACK-30.md).

## Präzisierungen 29 – 18.10.2026

Nachgereichter Textablauf: zusätzliche Textformate und Ausrichtung als kompakte Icon-Menüs ohne sichtbare Namen; Accessibility-Beschriftung erhalten. Neue Felder/Textkörper 14 pt, Größe in Einerschritten. „Word“-Cursorformatierung gilt für folgende Zeichen, Textauswahl für markierte Zeichen; die freie-Feld-Ausnahme aus dem ersten Auftrag bleibt. Wechsel des Listentyps am Cursor betrifft die zusammenhängenden Einträge gleicher Einrückung; explizite Auswahl begrenzt den Bereich. Zitat-/Codeblöcke und gebündelte Inter-Schrift sind aus den optionalen Referenzanmerkungen noch nicht umgesetzt; keine optische Attrappe als volle Funktion ausgeben.

Checkboxbutton: offen einfügen → abhaken → entfernen; Pencil-Tipp auf das Kästchen schaltet offen/abgehakt. Diese Präzisierung ersetzt den Checkbox-Zweierschritt aus Build 28; Punkte/Nummerierung bleiben Zweierschritt. Keine zusätzliche stehende Stiftmarkierung. Gemischtes Lasso schützt seitengebundenen „Word“-Text und bewegt freie Textfelder/Ink/Bilder/Formen; natives Handschrift-Lasso bleibt auf Ebene zwei. Größenänderung im freien Textfeld ohne Wortauswahl betrifft dessen gesamten Inhalt; vorhandene Wortauswahl hat Vorrang.

Leistenwechsel nach links erweitern/verkürzen, rechter Umschaltpfeil bleibt stehen; größerer Griff. Formen direkt einzeln antippen. Seitenpfeile an echten Seitengrenzen grau/deaktiviert; virtuelle Schreibreserve weiter per Scrollen erreichbar. Neue PDF-Schreibränder rechts 100 %, vorhandene Ränder beim Öffnen erhalten. Grundseitenfit statt Verkleinern wegen zusätzlichem Rand; automatische Stiftfarbe nach tatsächlicher Ansatzfläche. Seitengebundener Text auf linierten Vorlagen soll an deren Grundlinien stehen; Halten begradigt Stift/Marker. Umsetzung und offene native Abnahme: [EDITOR-FEEDBACK-29](history/EDITOR-FEEDBACK-29.md).

## Präzisierungen 28 – 18.10.2026

Checkboxen-, Aufzählungs- und Nummerierungsbutton: einmal anwenden, erneut antippen entfernt den jeweiligen Listentyp. Kein schneller Doppeltipp nötig. Abhaken einer Aufgabe bleibt eine eigene Aktion. Bestehende Wortformatierungen erhalten.

Elastische Ganzblatt-Rückkehr und Seitenfokus müssen in derselben Bewegung enden; kein nachträglicher Seitensprung. Breiten-Snap behält die vertikale Leseposition. Handschrift beim Vergrößern mit passender Auflösung darstellen, dünne Außenkanten beseitigen und Eingabepfad entlasten. Umsetzung und noch offene native Abnahme in [EDITOR-FEEDBACK-28](history/EDITOR-FEEDBACK-28.md).

## Präzisierungen 27 – 18.10.2026

PDFs: freie Textfelder direkt an der Tippstelle. Papierseiten und zusätzlicher PDF-Schreibraum: eigener seitenbreiter Textanfang ohne Feldleisten, weiterlaufender Text. Nutzer bestätigt ausdrücklich automatischen Übergang zur nächsten Seite. Formatierungszeile direkt über dunkler Tastatur anhand IMG_0248–0251; keine zusätzliche Textleiste unter der Hauptwerkzeugleiste. Einfügen, Auswahl, Tastatur und Autosave dürfen nicht zwischen Seiten springen.

Unten immer genau eine unbenutzte Schreibseite bereitstellen. Sie bleibt außerhalb von realer Seitenzahl, Heftdaten und Export, bis Text, Handschrift oder anderer Inhalt entsteht. Nutzer bestätigt ausdrücklich auch Zeichnen mit dem Pencil als Auslöser. Danach neue leere Reserve. Echte Seiten nicht nachträglich anhand einer Leerheitsheuristik löschen/aus dem Export ausblenden. [Anforderung, Quellen und native Abnahme](history/TEXT-REBUILD-27.md).

Stand: 17.10.2026. Fortlaufendes Designgespräch mit dem Nutzer; beschlossene Ziele sind nicht automatisch Geräteprüfungen. Referenzen: Nutzerbilder IMG_0232 (Seitenraster) und IMG_0234 (Seite hinzufügen). Eigenständige noty-Gestaltung, keine vollständige Goodnotes-Kopie.

## Präzisierungen 26 – 18.10.2026

Leiste beim Öffnen der Seitenübersicht im gezeigten Querformat oben behalten; Kopfaktionen passend verdichten. Dasselbe Glas wie Undo/Redo. Größere Tastenbereiche bei kleinen Symbolen. Mindestzoom ganzes Blatt statt 70 %, elastisch weiterziehen und animiert zurückfedern; nahe Seitenbreite zusätzlich einrasten/zentrieren. Deutlicheres magnetisches 90°-Bilddrehen und Lift bei Pencil-Hover. [Details und offene Geräteprüfung](UI-REBUILD.md#kopfzeile-zoom-und-trefferflächen--build-26).

## Anzeige und Leisten 25 – 18.10.2026

Bestätigt: optional nur die Anzeige der PDF-/Papiergrundflächen angleichen, Originalformat/-inhalte erhalten. Grundblätter gleich breit, Schreibränder separat daneben; beim Einpassen Grundblatt statt Gesamtrand berücksichtigen. „PDFs einheitlich anzeigen“ unter Optionen. Beide neuen Referenzleisten erneut übertragen: flachere Fläche, feinere Konturen, kleinere Auswahl und dezente Gruppentrenner, bestätigte Noty-Funktionen beibehalten. [Details und Bilder](UI-REBUILD.md#anzeige-normalisieren-und-leistenreferenzen--build-25).

## Präzisierung 24 – 18.10.2026

Glas wieder zurückhaltend, leicht grau; blaue obere Linie entfernen. Kleine angehängte Werkzeugoptionen statt großem Popover. Rechter Ebenenpfeil bleibt rechts und dreht sich animiert; kein weiterer Zurück-Knopf links. Griff zwei Reihen mit je drei Punkten, längere Andockzonen. Standard nur vier Dockpunkte; freies Platzieren optional in Leisten-Einstellungen, kein Drehsymbol auf der weiteren Ebene. Im Blättermodus jede Seitengröße neu einpassen; Zoom-Untergrenze 70 % der Breitenanpassung. [Details](UI-REBUILD.md#präzisierung-von-leiste-und-blättern--build-24).

## Seitenansicht 23 – 18.10.2026

Seitenübersicht rechts öffnen, auf schmalem Fenster von rechts einblenden. Deutlich größerer dauerhafter horizontaler Bewegungsspielraum, Startansicht weiterhin zentriert/eingepasst. Teilweise sichtbare Nachbarseiten vollständig anzeigen. Umsetzung und offene Geräteprüfung in [UI-REBUILD](UI-REBUILD.md#korrektur-seitenansicht--build-23).

## Korrektur Werkzeugleiste 22 – 18.10.2026

Nach Rückmeldung zu Build 21: Leiste mittig und nur so lang wie ihre sichtbaren Werkzeuge; Pfeil wechselt Inhalt und Größe mit abgestimmter Animation. Referenznahe, helle Symbole und deutlicheres Glas. Vier beim Ziehen sichtbare Andockzonen reagieren bereits in ihrer Nähe; außerhalb freie Platzierung. Horizontal/vertikal auch schwebend explizit umschaltbar. Kurze, ruhige Animationen für weitere Bedienelemente mit Rücksicht auf reduzierte Bewegung; native Zeichenflächen erhalten. Details und noch offene Geräteprüfung in [UI-REBUILD](UI-REBUILD.md#korrektur-nach-gerätefeedback--build-22).

## Bestätigte Ergänzungen für UI-Rebuild 21

Am 18.10.2026 anhand der persönlichen Bildreferenzen und Rückfragen bestätigt: Werkzeugleiste mit Haupt-/weiterer Ebene und vier Ankern einschließlich unten; Notizbuchumschlag nur als Bibliotheksdarstellung plus Papierstandard; kompakter Editor mit gekürztem Titel; vertikale Seitenfolge und umschaltbares Blättern; Vorschauen folgen dem Editor, reines Vorschau-Scrollen ändert die Editorseite nicht. Neue freie Textfelder starten links/seitenbreit, bleiben veränderbar; gemischte Formatierung markierter Wörter/Abschnitte. Ausschneiden verschiebt erst beim Einfügen, immer hinter die ausgewählte Seite. Leeren entfernt eigene Ebenen und erhält PDF/Papier. Autostift nur für neue Striche nach Seitenhelligkeit; „Stiftschatten“ meint Hover-Vorschau. Konkrete bestätigte Werkzeugaufteilung und Umsetzungsnachweise in [UI-REBUILD.md](UI-REBUILD.md). Zielvorgaben sind keine Geräteabnahme.

## Seitenverwaltung – bestätigt

| Fragen | Entscheidung |
| --- | --- |
| Q16, für Build 23 präzisiert | Rechte Seitenleiste (ersetzt die frühere linke Position); zweispaltiges Vorschauraster nach Bildreferenz, Seitennummer/Seitenmenü darunter, aktuelle Seite deutlich markieren. Schlicht dunkel/schwarz mit nativen Apple-Glaseffekten. PDF-Farben erhalten. |
| Q17, später präzisiert für Build 14 | Keine manuelle Größenverstellung mehr. Seitenleiste mit fester Standardbreite, weiterhin vollständig einklappbar; in schmalen Fenstern automatisch angepasst und über dem Editor eingeblendet. Die frühere Freigabe für Verstellen per Ziehen ist damit aufgehoben. |
| Q18–20 | Bedienung an Goodnotes orientieren, im noty-Stil. „Seite hinzufügen“ mit Vor dieser/Nach dieser/Letzte Seite oben, Papierauswahl darunter, PDF-Import. Notizbuch-Explorer bleibt über den gespeicherten Editor-Rückweg erreichbar. |
| Q21 | Zusätzlicher PDF-Schreibplatz links/rechts/oben/unten vergrößert die Seite. Original-PDF bleibt in Originalgröße; bestehende Einträge behalten ihre Position relativ zur PDF. Mehrere Ränder kombinierbar. |
| Q22 | Neue Papierseiten in Weiß und Dunkel; Farbe unabhängig von der App-Oberfläche. |
| Q23 | Seiten und PDF-Inhaltsverzeichnis als Bereiche; Alle Seiten/Lesezeichen als Filter. Lesezeichen direkt an Vorschau setzen. Kein Audiobereich. |
| Q24 | Jeder Rand mit eigenem Regler, Vorschau und Schnellwerten Schmal/Mittel/Breit. |
| Q25 | Zusätzlicher PDF-Schreibplatz als Blanko/Linien/Karo und Weiß/Dunkel wählbar. Die PDF selbst nicht invertieren. |
| Q26 | Auf aktuelle Seite oder alle aktiven Seiten desselben PDF-Imports anwenden; Standard aktuelle Seite, später erneut über das Seitenmenü ändern. |
| Q27–29 | Vor Verkleinerung mit betroffener Handschrift warnen. Nutzer darf trotzdem entfernen. Wiederherstellung muss den früheren Schreibplatz samt Inhalt zurückbringen, nicht nur die Striche. |
| Q28 | PDF direkt importieren; Schreibplatz anschließend optional ergänzen. Kein verpflichtender Randdialog bei jedem Import. |

## Konkrete Umsetzung und Startwerte

- Editor bleibt dieselbe UIKit-Instanz; Leiste verändert den verfügbaren Viewport, nicht gespeicherte Koordinaten. Standardbreite 320 pt, automatisch auf verfügbaren Platz begrenzt; nur Sichtbarkeit am Gerät merken. Kein Ziehgriff oder Größenregler. Bei schmalem Fenster schließt eine Seitenwahl die Einblendung.
- Native Liquid-Glass-Bedienelemente ab iPadOS 26; Material-Fallback auf älteren unterstützten Versionen, deckende Flächen bei „Transparenz reduzieren“. Vorschauen/PDF-Inhalte erhalten ihre eigenen Papierfarben.
- Neue Papierseiten zunächst A4. Importierte PDF-Seiten behalten ihre Formate. Freie Vorlagen-/Formatverwaltung bleibt ein weiterer Schritt.
- Randregler relativ zur angezeigten Grundseite; gespeicherte Maße in Punkten. Schnellwerte auf ausdrücklichen Nutzerwunsch: Schmal 25 %, Mittel 60 %, Breit 100 %. Neue Ränder starten bei Mittel; vorhandene Randmaße behalten ihre Werte. Ab Build 15 gelten beim Anwenden auf den gesamten PDF-Import dieselben Prozentwerte pro Seitenformat: links/rechts relativ zur jeweiligen Breite, oben/unten zur Höhe, jeweils nach Crop/Rotation. Keine pauschale Übernahme gleicher Punktmaße auf kleinere Seiten. Bereits gespeicherte übergroße Ränder bleiben bis zur ausdrücklichen Änderung erhalten; Gelöschte Seiten bleiben unverändert.
- Vorschauen folgen den tatsächlichen Seitenproportionen einschließlich zusätzlicher Ränder. Kein weißes A4-Außenrechteck um verbreiterte Seiten; außerhalb der tatsächlichen Seite bleibt der App-Hintergrund sichtbar. Auswahlrahmen folgt dem angepassten Papierbild; Vorschauhöhe in der Seitenliste begrenzt.
- Bei bestätigter Verkleinerung betroffene Striche vollständig entfernen. Zuvor vollständigen Seitenstand mit früheren Rändern und neuer ID im Seitenpapierkorb ablegen. Nach ausdrücklicher Präzisierung für Build 16: Wiederherstellen setzt die bestehende Seite auf den gewählten vollständigen Stand zurück, behält deren ID/aktuelle Position und sichert den verdrängten aktuellen Stand vorher im Seitenpapierkorb. Auch dieser Stand ist wiederherstellbar. Nur wenn die ursprüngliche passende Seite fehlt, als zusätzliche Seite wiederherstellen; keine andere Seite anhand ihrer Position ersetzen.
- Mehrfach vorhandene Quellseiten (Duplikate) teilen unveränderliche PDF-Bytes, besitzen eigene Ink-/Textdaten. Inhaltsverzeichnis-Ziele öffnen die erste aktive passende Seite; gelöschte Ziele bleiben ohne Seitensprung.
- Stiftfarben bleiben wie gewählt. Getippter Text auf dunklen Papierseiten wird weiß dargestellt/exportiert; vorhandene Handschrift wird nicht umgefärbt.

## Weiteres Designgespräch

### Textfelder – technische Startwerte für Build 17

Der bestätigte Scope bleibt bestehen. Erstes umgesetztes Textpaket: Finger-Tipp mit Textwerkzeug erzeugt Feld, bestehendes Feld antippen bearbeitet; oberer linker Griff bewegt, unterer rechter ändert Breite, X löscht. Anfangsbreite höchstens 240 pt, an tatsächlich verbleibenden Platz angepasst; im schmalen rechten Schreibrand nicht zurück in die PDF schieben. Native Eingabe ohne automatische Tastatur im Ink-/Lassomodus.

Eigene Formatleiste an der Tastatur: drei Schriftfamilien, Größe, vier Farben, Fett/Kursiv/Unterstrichen und einfache Listenpräfixe. Für dieses erste Paket Stil pro vollständigem Feld, keine gemischten Formatruns oder interaktiven Aufgaben. Höhe automatisch bis Seitenende, Überlauf sichtbar. Neue Schrift auf dunklem Rand/Papier weiß, auf weißer PDF schwarz; gewählte Farbe beim Verschieben erhalten. Das sind reversible technische Startwerte, keine neuen Nutzerantworten/Q-Nummern und keine Streichung des bestätigten Umfangs. Details und Gerätetest in TEXT-FIELDS.md.

Nach Build 15 ausdrücklich bestätigt: „Bestehende Seite zurücksetzen und aktuellen Stand sichern“. Damit ist der frühere Kopie-Restore für vorhandene PDF-Seiten aufgehoben. UI nennt den Eintrag allgemein „Gesicherter Seitenstand“ und erklärt Zurücksetzen plus Sicherung, weil der Papierkorb sowohl Stände vor Verkleinerung als auch vor Wiederherstellung enthält.

Historische Bedienungskorrektur nach Build-12-Gerätetest: Scrollposition beim freien Blättern erhalten; Zentrierung in der Seitenleiste damals nur ausdrücklich über „Seite x von y“. Die neue bestätigte Rebuild-Vorgabe ersetzt diese Zentrierungsregel durch automatisches Mitführen beim Scrollen im Dokument. Randkarten behalten beim Ein-/Ausschalten ihre Bedienelemente/Größe, inaktive Regler ausgegraut. Vorschauen sind reine Anzeige und können keine Eingaben abfangen. Technische Korrekturen, keine neue offene Produktentscheidung.

Für dieses Paket sind keine Pflichtantworten offen. Neue Entscheidungen werden vor dem jeweiligen Feature geklärt, besonders freie Textobjekte/Bildbearbeitung, gemischtes Lasso und zwei Ansichten. Keine erneute Befragung bereits bestätigter Umfangsgrenzen.

Geprüfte technische Quellen: [Goodnotes-Seitenleiste](https://support.goodnotes.com/hc/en-us/articles/9497798035983-Use-the-Sidebar-to-navigate-your-document), [Apple glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)), [Apple PDFOutline](https://developer.apple.com/documentation/pdfkit/pdfoutline).
