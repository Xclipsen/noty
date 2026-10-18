# Designentscheidungen für noty

## Präzisierungen 28 – 18.10.2026

Checkboxen-, Aufzählungs- und Nummerierungsbutton: einmal anwenden, erneut antippen entfernt den jeweiligen Listentyp. Kein schneller Doppeltipp nötig. Abhaken einer Aufgabe bleibt eine eigene Aktion. Bestehende Wortformatierungen erhalten.

Elastische Ganzblatt-Rückkehr und Seitenfokus müssen in derselben Bewegung enden; kein nachträglicher Seitensprung. Breiten-Snap behält die vertikale Leseposition. Handschrift beim Vergrößern mit passender Auflösung darstellen, dünne Außenkanten beseitigen und Eingabepfad entlasten. Umsetzung und noch offene native Abnahme in [EDITOR-FEEDBACK-28](EDITOR-FEEDBACK-28.md).

## Präzisierungen 27 – 18.10.2026

PDFs: freie Textfelder direkt an der Tippstelle. Papierseiten und zusätzlicher PDF-Schreibraum: eigener seitenbreiter Textanfang ohne Feldleisten, weiterlaufender Text. Nutzer bestätigt ausdrücklich automatischen Übergang zur nächsten Seite. Formatierungszeile direkt über dunkler Tastatur anhand IMG_0248–0251; keine zusätzliche Textleiste unter der Hauptwerkzeugleiste. Einfügen, Auswahl, Tastatur und Autosave dürfen nicht zwischen Seiten springen.

Unten immer genau eine unbenutzte Schreibseite bereitstellen. Sie bleibt außerhalb von realer Seitenzahl, Heftdaten und Export, bis Text, Handschrift oder anderer Inhalt entsteht. Nutzer bestätigt ausdrücklich auch Zeichnen mit dem Pencil als Auslöser. Danach neue leere Reserve. Echte Seiten nicht nachträglich anhand einer Leerheitsheuristik löschen/aus dem Export ausblenden. [Anforderung, Quellen und native Abnahme](TEXT-REBUILD-27.md).

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
