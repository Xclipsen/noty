# Offenes Gerätefeedback · Build 20

Stand: 18.10.2026. Rückmeldungen aus dem häppchenweisen iPad-Test. Die offenen Punkte auf ausdrücklichen Nutzerwunsch für die spätere Korrektur festhalten. Ein anderer Agent arbeitet parallel am UI; hierfür keine Codeänderungen, neuen Builds oder Installationen durchführen.

## 1. Zeichnen und Halten erkennt keine bearbeitbare Form

**Status: offen, Gerätetest fehlgeschlagen.**

Ablauf: normalen Stift wählen, ungefähr gerade Linie zeichnen, Pencil am Ende etwa eine Sekunde ruhig auf dem Display halten und erst dann abheben. Danach Formenwerkzeug wählen und die Linie antippen.

Erwartet: gerade Linie als eigenständige Form mit blauen, bearbeitbaren Griffen. Nutzer meldet: „nein geht nicht...“. Halteerkennung damit nicht abgenommen; nicht als funktionierend dokumentieren.

Bisher nur Quelltext/Apple-Dokumentation gelesen, keine Fehlerkorrektur gebaut oder installiert. Ursache noch nicht am Gerät nachgewiesen. Bei späterer Untersuchung insbesondere Touch-/Halteereignis, Zeitpunkt des fertigen PencilKit-Strichs und Zahl/Abtastung seiner Pfadpunkte prüfen. Das sind Prüfansätze, keine bestätigte Diagnose.

Späterer Retest: derselbe kurze Ablauf, danach Griffe verändern sowie Undo/Redo und Erhalt nach Speichern prüfen. Zunächst nur die Gerade; keine Wiederholung aller Formvarianten nötig.

## 2. Lineal: Stift entlangführen statt Abschneiden

**Status: offen, gewünschtes Verhalten noch nicht erfüllt.**

Lineal ein-/ausblenden und grundsätzlich daran zeichnen wurde getestet. Nutzerpräzisierung: „ich möchte dass der stift an dem linial so slidet und nicht abcuttet“.

Gewünscht: Der Strich soll an der Linealkante entlanggleiten und dadurch geführt werden. Die Eingabe bzw. der Strich soll dabei nicht abgeschnitten oder abgebrochen wirken. Die bisherige native Linealfunktion erfüllt dieses gewünschte Schreibgefühl noch nicht. Nicht als vollständig abgenommen markieren.

Die genaue Ursache des Abschneidens ist noch ungeklärt. Vor einer späteren Korrektur das beobachtete Verhalten und die gewünschte Führung kurz am Gerät abgleichen; kein geratenes Zielverhalten als bereits bestätigte technische Anforderung ausgeben.

Späterer Retest: mit dem Pencil entlang der Linealkante zeichnen und vom Nutzer bestätigen lassen, dass sich die Linie wie gewünscht geführt anfühlt und nicht abschneidet. Anschließend Lineal ausblenden und freies Schreiben kurz prüfen.

## 3. Gemischtes Lasso: unvollständige Auswahl und verzögerte Vorschau

**Status: offen, Gerätetest nicht bestanden.**

Nutzerbeobachtung: Formen werden mitgenommen, Handschrift dagegen gar nicht; auch Textmarkerstriche fehlen. Das Lasso nimmt nicht zuverlässig alle erwarteten Inhalte auf. Die Verschiebung wird erst nach dem Loslassen sichtbar, statt unmittelbar während des Ziehens.

Ausdrücklich gewünschtes Verhalten:

- Schon eine kleine Überlappung soll genügen: Auch wenn nur eine kleine Ecke eines Bildes im Lassobereich liegt, soll das gesamte Bild zur Auswahl gehören. Vollständiges Einkreisen oder das Erfassen bestimmter Mittelpunkt-/Eckpositionen darf dafür nicht erforderlich sein. Bei der späteren Umsetzung diese Auswahlregel für die gemischten Inhaltstypen berücksichtigen.
- Handschrift und Textmarker gehören genauso zur gemischten Auswahl wie Formen, Textfelder und Bilder. Beide fehlenden Ink-Arten gesondert prüfen; der erfolgreiche Formtest belegt ihre Auswahl nicht.
- Beim Verschieben soll die gesamte ausgewählte Gruppe sofort sichtbar mitwandern. Ein bewegter Rahmen oder eine Aktualisierung erst beim Loslassen reicht nicht. Auch Skalierung anschließend auf konsistente Vorschau prüfen.

Die bestehende Bildsperre und explizite Auswahlfilter sind von dieser Überlappungsregel zu unterscheiden. Keine Nutzerentscheidung zur Aufhebung von Sperren oder Filtern liegt vor. Die Ursache der fehlenden Ink-Auswahl wurde noch nicht am Gerät nachgewiesen.

Späterer Retest: In einer Testkopie Form, Handschrift, Marker, Textfeld und ungesperrtes Bild anlegen; aktive Auswahlfilter prüfen. Alle Inhaltstypen gemeinsam auswählen und bewegen. Danach nur eine kleine Bildecke mit dem Lasso überlappen: vollständiges Bild muss ausgewählt werden. Während des gesamten Ziehens müssen die ausgewählten Inhalte mitwandern und ihre relativen Positionen behalten. Anschließend Undo/Redo, Skalierung und Erhalt nach Speichern prüfen. Fehlende Handschrift/Marker und verzögerte Vorschau bleiben bis dahin ausdrücklich offen.

## 4. Zwei Ansichten: direkt schreiben ohne Aktivierungstipp

**Status: offen, Bedienung vom Nutzer als nicht nahtlos genug beanstandet.**

Der aktuelle Wechsel verlangt einen zusätzlichen Tipp zum Aktivieren der jeweiligen Ansicht. Nutzer möchte unmittelbar abwechselnd links und rechts schreiben können: „kein extra tipp für die jeweiligen seiten“.

Gewünscht:

- Der erste Pencilkontakt in einer Ansicht beginnt dort unmittelbar den Strich. Er darf nicht nur zum Aktivieren verbraucht werden.
- Wechsel zwischen links und rechts erfolgt durch die eigentliche Eingabe. Kein vorheriges Antippen und kein gesonderter Umschaltmodus.
- Fokus und Werkzeugleiste folgen der gerade bedienten Ansicht automatisch. Entsprechend soll die eigentliche Bediengeste zum richtigen Bereich gelangen, ohne vorgeschalteten Aktivierungstipp.
- Eigene Seite/Zoom pro Ansicht und der gemeinsame Speicherbesitzer desselben Hefts bleiben erhalten; beim direkten Wechsel dürfen keine Strichanfänge fehlen oder Änderungen in der falschen Ansicht landen.

Keine Korrektur am Code/Build durchgeführt; der parallele UI-Agent bleibt unberührt. Unabhängige Seite/Zoom und Strichabgleich sind durch diese Rückmeldung nicht gesondert bestätigt.

Späterer Retest: gleiches Heft in beiden Ansichten öffnen, direkt mit dem Pencil links, rechts und wieder links schreiben, jeweils ohne vorherigen Tipp. Jeder Strich muss einschließlich Anfang sofort in der richtigen Ansicht erscheinen. Anschließend unterschiedliche Seiten/Zoom und zwei verschiedene Hefte prüfen; Werkzeugzuordnung und Speicherung kontrollieren.

## 5. Seitenverwaltung: beide Seitenleisten öffnen gemeinsam

**Status: offen, Ansichten ungewollt gekoppelt.**

Nutzer fragt beim Test der zwei Ansichten nach der gleichzeitig auf beiden Seiten geöffneten Seitenverwaltung. Quelltextbefund: Beide `ContentView`-Instanzen nutzen `@AppStorage("noty.sidebar.visible")` für `showingPages`. Damit ist der Sichtbarkeitszustand geteilt; Öffnen/Schließen wirkt auf beide Ansichten.

Für die spätere Korrektur: Jede Ansicht soll ihre Seitenverwaltung unabhängig öffnen und schließen können. Der Schalter links darf die rechte Seitenleiste nicht mit umschalten und umgekehrt. Das betrifft die Darstellung je Ansicht, nicht die gemeinsam gespeicherten Seiten desselben Hefts. Keine Codeänderung und kein Build in diesem Schritt.

Späterer Retest: beide Seitenleisten schließen, nur links öffnen, rechts muss geschlossen bleiben. Danach rechts unabhängig öffnen und links schließen. Gleiche und unterschiedliche Hefte sowie Fenster-/Ausrichtungswechsel prüfen.

## Bereits vom Nutzer bestätigt

- Rechteck zeichnen und über blaue Griffe verändern.
- Gestrichelter/gepunkteter Stil und Füllung am Rechteck.
- Ganze Form mit Ganzstrichradierer entfernen sowie Undo/Redo.

Das sind Nutzerbestätigungen der jeweiligen Bedienung, keine gesonderte Artefakt-/Neustartprüfung. Weitere Testblöcke bleiben offen.
