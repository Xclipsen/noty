# Editor-Korrekturen · Build 28

Rückmeldung vom 18.10.2026: Checkboxen, Aufzählungen und Nummerierung sollen beim erneuten Antippen ausgeschaltet werden. Herauszoomen soll in einer Bewegung zurückfedern und die aktuelle Seite ausrichten. Handschrift soll beim Vergrößern schärfer werden, dünne Außenkanten sollen verschwinden und kurze Eingabeblockaden untersucht werden.

**Implementiert, erfolgreich signiert gebaut und installiert. Neue native Bedienung noch ungeprüft.** 230 Core-Tests bestanden; vollständiger Updatevergleich: alle 22 Hefte und 153 Dateien unverändert. [Prüfnachweise](TESTING.md).

## Listen

Einmal antippen aktiviert den gewählten Listentyp, erneutes Antippen entfernt ihn aus den betroffenen Zeilen. Das gilt für Checkboxen, Punkte und Nummerierung; kein zeitkritischer Doppeltipp erforderlich. Ein anderer Listentyp ersetzt die bisherigen Zeichen. Bei einer gemischten Auswahl wird der gewählte Typ angewendet; ausgeschaltet wird erst, wenn alle betroffenen Zeilen diesen Typ haben. Abgehakte Checkboxen gehören ebenfalls zum Checkbox-Listentyp. Die getrennte Aktion zum Abhaken einer Aufgabe bleibt erhalten.

`TextListEditing.toggle` liefert ausschließlich Änderungen der Präfixe in UTF-16-Koordinaten. `TextObjectLayer` verändert diese Bereiche in der vorhandenen Attributed-String-Speicherung; unterschiedliche Wortformatierungen und Einrückungen bleiben erhalten. Auswahl/Caret werden nachgeführt, der aktive Listentyp in der Formatzeile hervorgehoben. Freie Textfelder und mehrseitiger Text verwenden ihre bestehenden abgesicherten Undo-Wege.

## Zoom und Darstellung

Die frühere Kombination aus nativer Zoom-Rückfederung und anschließender Seitenausrichtung entfällt. Während der Geste darf der Maßstab bis auf 65 % der eigentlichen Ganzblatt-Untergrenze sinken. Beim Loslassen werden Zielmaßstab und Zielposition gemeinsam berechnet und mit einem `CADisplayLink` über 0,34 Sekunden gemeinsam interpoliert. Die Seite unter dem Gestenmittelpunkt wird vorher festgehalten; automatische Seitenauswahl während Zoom und Rückkehr pausiert. Eine neue Geste unterbricht die Rückkehr am aktuellen Stand. Bei reduzierter Bewegung gilt das Ziel sofort. Nahe Seitenbreite wird horizontal ausgerichtet, die vertikale Leseposition bleibt erhalten.

PencilKit erhält den tatsächlichen Anzeigemaßstab als nativen Zoom mit ausgleichender äußerer Transformation. Ein begrenzter sichtbarer Canvas-Ausschnitt mit Reserve ersetzt eine hochauflösende Bitmap der ganzen großen Seite. Auflösung und Ausschnitt wechseln in Stufen, damit kleine Scrollbewegungen keine dauernden Neuaufbauten auslösen. Papier wird ebenfalls im sichtbaren Ausschnitt gezeichnet; Text-/Bild-/Formebenen bekommen einen angepassten Auflösungsfaktor mit einer Grenze von 16 Millionen Pixeln pro ganzer Ebene. Leere Bild-/Objektebenen bleiben verborgen. Aktive Pencil-Striche werden nicht durch eine neue Viewport-Konfiguration unterbrochen.

Papierhintergrund und Worksheet-Außenfarbe stimmen überein; normale Papierseiten zeichnen keine zusätzliche synthetische PDF-Seite mehr. Der alte Geometrietest behält seine PDF-Testbeschriftung. Echte Quell-PDFs verwenden weiter PDFKit. Äußere Kanten-Antialiasingflächen sind deaktiviert. Der Sichtnachweis für die gemeldeten dünnen Ränder bleibt am Gerät erforderlich.

Gespeicherte PencilKit-Daten werden für diesen Darstellungswechsel nicht skaliert. Kanonische Koordinaten einschließlich negativer Schreibränder, Originale, Save, Vorschau und Export bleiben im vorhandenen Format. Kein neues Notebook-, Werkzeug- oder Archivschema.

## Kurze Blockaden

Im Quellcode gefundene unnötige Arbeit reduziert:

- Native Worksheet-Konfiguration nur bei geänderter Konfigurationsrevision; bestehende Canvas-/Textinstanzen bleiben erhalten. Neue PDF-/Worksheet-Ansichten gestaffelt anlegen, ausgewählte und tatsächlich sichtbare Seiten bevorzugen.
- Unveränderte Text-/Bildebenen aktualisieren nur Rückmeldungen; keine erneute Formatierungs-/Layoutarbeit bei jedem Scrollcallback. Inaktive Objektauswahl dekodiert nicht mehr die komplette Handschrift bei jedem Layout.
- PDF-Katalog/Inhaltsverzeichnis beim Textfluss nur bei geänderten Seiten oder Quellen neu aufbauen. Helligkeitsvorschau nur bei tatsächlich eingeschaltetem Autostift berechnen und je Seite merken.
- Auflösung großer Ebenen begrenzen, leere Ebenen verbergen und Papier/PencilKit auf den sichtbaren Ausschnitt begrenzen.

Das sind konkrete Entlastungen, **kein Nachweis der genauen Ursache der beobachteten Blockade**. Noch kein Geräte-Trace oder Langzeittest. Langsame Viewport-Aktualisierungen über 25 ms werden höchstens einmal je Sekunde unter `de.la.noty` / `editor-performance` mit Dauer und Anzahl protokolliert; keine Notizinhalte.

## Gebündelte Geräteprüfung – noch offen

1. Checkboxen, Punkte und Nummerierung jeweils zweimal antippen, auch bei markiertem mehrzeiligem Text mit gemischter Formatierung. Undo/Redo und Weiterlaufen über eine Seitengrenze prüfen.
2. Neue und vorhandene Handschrift stark vergrößern; danach herausziehen und loslassen. Gemeinsame Rückkehr ohne zweiten Seitensprung, Breiten-Snap und Unterbrechen durch erneutes Zoomen prüfen. Gemischte PDF-/Papiergrößen und Normalisierung einschließen.
3. Dunkles/weißes Papier und PDF-Ränder auf Außenlinien prüfen. Am Rand schreiben, radieren, Lasso/Undo nutzen und nach Speichern/App-Neustart Positionen vergleichen. Anschließend echten PDF-Export prüfen.
4. Gemischt schreiben, tippen, blättern und zoomen; falls die App erneut kurz blockiert, Zeitpunkt und gerade benutztes Werkzeug für einen gezielten Geräte-Trace festhalten.

Diese Laufzeit-, Schärfe-, Gesten- und Exportprüfungen sind durch SDK-Build, Core-Geometrie oder unveränderten Updatebestand nicht ersetzt.
