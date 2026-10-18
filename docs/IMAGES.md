# Bilder und Screenshots – Build 19

## Ergänzung Build 26 – Drehmagnet und bedienbare Griffe

Beim freien Drehen Eintritt bis 8° an 0/90/180/270°, Ziel bis 12° halten; außerhalb frei. Drehgriff zeigt das Einrasten farbig, Haptik einmal pro neuem Ziel. Knopf stellt den nächsten exakten Vierteldrehwinkel her, statt einen schiefen Ausgangswinkel mitzudrehen. Bildgriffe 44 pt und Bildaktionsleiste bleiben durch Kompensation von äußerem Zoom/Normalisierung in Bildschirmgröße bedienbar; Original und kanonische Objektparameter erhalten. Bildcache berücksichtigt effektiven Anzeigefaktor. Core-/SDK-Prüfungen bestanden; neue Dreh-/Zoom-/Hover-Bedienung noch ungeprüft, [TESTING](TESTING.md).

## Ergänzung Build 21

Freie Bilddrehung rastet innerhalb von 5° an 0/90/180/270° ein; vorhandener 90°-Knopf und unveränderte Originalbytes bleiben. Gemeinsame Leiste öffnet Bildeinfügen über „+“. Neue Core-Snappingtests und iPad-SDK-Build bestanden, neues Einrasten am Gerät ungeprüft. [UI-Rebuild](UI-REBUILD.md). Frühere Geräte-/Exportnachweise unten gelten für das damalige Bildpaket.

Implementiert, als signierte arm64-IPA gebaut und am 17.10.2026 als Update installiert. Nutzer bestätigt den angeleiteten Bedienungs-/Neustart-/Exportdurchlauf ohne Auffälligkeiten. Echte fünfseitige Geräte-PDF und Schema-5-Heftbackup am PC geprüft; isolierter Host-Restore weiterbearbeitbar. **Externer Schema-5-Geräterestore mit anschließendem Bildzuschnitt, Sperre, neuer Handschrift und Neustart vom Nutzer bestätigt.** Grundweg des Bildpakets belegt. Gerät bestätigt Build 19, alle 19 Hefte/117 vorherigen App-Dateien beim Update unverändert. 139 Core-Tests sowie Schema-5-Heft-/Bibliotheks-Roundtrip mit unabhängigen Pythonprüfern bestanden. Einzelne weitere Foto-/Clipboard-/Zuschnitt-/Sperrvarianten nicht pauschal daraus ableiten; Details in [TESTING.md](TESTING.md).

## Bedienung

- Werkzeug **Bilder** → **Bild +** → Fotos und Screenshots, Bilddatei oder Zwischenablage. Der System-Fotowähler gibt nur die ausgewählte Datei frei; keine pauschale Fotobibliotheksberechtigung. Originale lokal übernehmen, auch wenn sie aus einem Dateianbieter kommen. Nach Einfügen zur Bildposition scrollen.
- Bild antippen und direkt ziehen: verschieben. Griff unten rechts: proportional skalieren. Griff oben rechts: frei um den Mittelpunkt drehen. Die vollständige gedrehte Bildfläche bleibt innerhalb der Seite einschließlich zusätzlicher PDF-Schreibränder; bei Bedarf proportional verkleinern.
- Bildleiste: zuschneiden, 90° drehen, unter/über andere Bilder legen, sperren/entsperren, löschen. Gesperrte Bilder bleiben auswählbar; erst entsperren, bevor Verschieben/Skalieren/Drehen/Zuschneiden/Umordnen/Löschen möglich sind. Sperren ist eine Bearbeitungshilfe, kein Sicherheitsmerkmal.
- Zuschnitt mit vier Reglern und abgedunkelter Vorschau; **Ganzes Originalbild** stellt den vollständigen Ausschnitt wieder her. Abbrechen verändert nichts. Der Ausschnitt wird in der ursprünglichen Bildorientierung bearbeitet; die Drehung auf der Seite bleibt erhalten.
- Undo/Redo wirkt im Bildmodus auf Bildänderungen einschließlich Import, Zuschnitt, Ebenenfolge und Sperre. Eigenständige Seitenhistorie mit maximal 30 Schritten und konservativ 40 MB gehaltenen Snapshotdaten; beim Seiten-/Layout-/Restorewechsel zurücksetzen. Ink und Text behalten ihre eigenen Historien.
- Bilder liegen über dem Papier/PDF und unter Handschrift/Text. „Vorne/hinten“ ordnet derzeit die Bilder untereinander. Handschrift kann darüber schreiben und radieren, ohne das Bild zu beschädigen. Gemischtes Lasso und typübergreifende Ebenen bleiben eigene Pakete.

## Speicherung und Darstellung

Schema 5 ergänzt `Page.images`: stabile UUID, unveränderte ausgewählte Dateibytes, orientierte Pixelmaße, kanonische x/y/Breite/Höhe, Drehwinkel in Grad, normalisierter Zuschnitt und Sperrflag. Arrayreihenfolge ist hinten nach vorne. Negative Koordinaten für linke/obere PDF-Ränder; derselbe Seitenversatz wie bei Ink und Text. EXIF-Orientierung einschließlich Spiegelung über ImageIO vor Zuschnitt anwenden. Transparenz erhalten; mehrteilige/animierte Bilder als erstes Bild darstellen, vollständige importierte Datei speichern.

Bildimport/-änderung stellt das Heft auf Schema 5 um; bloßes Öffnen alter Hefte nicht. Alte Texte behalten ihre Glyphpositionen und dürfen auch nach einer Bildbearbeitung nicht auf Schema 4 zurückstufen. Vor Schemawechsel archiviert der Revisionsspeicher die exakten zuvor bestätigten Bytes. Alte App-Versionen müssen Schema 5 ablehnen. Werkzeugformat 2 ergänzt das Bildwerkzeug; Format 1 unter Erhalt der übrigen Reihenfolge/Präferenzen lesbar, neue Werkzeugdateien für alte Apps gesperrt.

Seiten duplizieren und Randstände sichern erzeugt unabhängige Bild-IDs. Papierkorb, lokale Revisionen, Heft- und Bibliotheksbackup übernehmen Originalbytes und alle Bildparameter. Dateiverknüpfungen/Fotobibliothek werden zum Wiederöffnen nicht benötigt. Randverkleinerung mit betroffenem Bild blockieren; Bild zuerst verschieben/verkleinern. Keine stille Abschneidung.

Editor, Seitenvorschau und PDF verwenden denselben Renderer für Bildorientierung, Zuschnitt, Drehung und Seitenversatz. Im PDF werden nur die Bilder gerastert; PDF-Quelltext und getippter Text bleiben wie bisher echte PDF-Inhalte. Nicht lesbare Bilder brechen Export ab. Originaldatei im editierbaren Backup unverändert; Renderauflösung separat begrenzt.

## Grenzen

Höchstens 50 Bilder je Seite, 20 MB je Datei und 200 Megapixel, 40 MB Bildoriginale je Heft **einschließlich Seitenpapierkorb und duplizierter Bildobjekte**. Ganze Revision/Archive weiter höchstens 200 MB. Fehlgeschlagene Kandidaten ersetzen den vorherigen Stand nicht. Keine Dateianbieter-Downloads ohne ausgewählte Datei; Systemanbieterfehler bleiben sichtbar.

Metadaten und verkleinerte Bitmaps via ImageIO, kein voller Kameraraster vor Größenprüfung. Editor nach benötigter Größe bis 2048 px, Vorschau 256 px, PDF bis 4096 px längste Kante. Gemeinsamer Bitmapcache 32 MiB/12 Einträge; Originalbytes in vollständigen JSON-Revisionen, noch keine Asset-Deduplizierung über Objekte/Revisionen. Große Heft-/Scanbestände und starker Zoom bleiben spätere Leistungsprüfungen.

## Ein gebündelter Gerätetest nach sicherem Update

1. In einem Testheft **Bilder → Bild +**: einen Screenshot aus Fotos und ein Bild aus Dateien oder Zwischenablage einfügen. Verschieben, skalieren, frei/90° drehen, zuschneiden und Originalausschnitt wieder erweitern. Ein Bild sperren; Verschieben bleibt blockiert, Entsperren funktioniert. Darüber einen Pencil-Strich setzen; Bild-Undo/Redo kurz prüfen.
2. „Lokal gespeichert“ abwarten, App beenden und erneut öffnen. Position, Ausschnitt, Drehung, Sperre und Strich erhalten. Seite duplizieren, ein Bild der Kopie verändern; Original bleibt gleich.
3. PDF und vollständiges Heftbackup als `noty-bild19` nach „Auf meinem iPad → noty“ exportieren. PC prüft Originalbytes/Parameter/CRC und rendert die tatsächliche Geräte-PDF. Kein nachgebautes Hostbild als PDF-Nachweis verwenden.
4. Geprüftes Heftbackup extern zurückübertragen und als neue Kopie importieren. Bild entsperren, Zuschnitt ändern, neue Handschrift, speichern/neustarten; Ausgangsheft erhalten. Bibliotheksbackup mit Bildern bei nächstem Bibliotheks-Speichertest bündeln.

Vor Installation vollständigen Gerätebestand gesichert und Update mit derselben installierten Identität ausgeführt; nicht deinstalliert. Sicherung unter `/home/la/Backups/noty-before-images19-2026-10-17T19-15-51Z/`, nach Update alle 19 Hefte/117 vorherigen Dateien unverändert. Danach separate Fixture als `Documents/noty-bild19-test.png` übertragen und bytegleich zurückgelesen. Nutzer bestätigt angeleiteten Durchlauf mit „passt mir ist nix auffälliges aufgefallen“. Tatsächliche Exporte unter `/home/la/Backups/noty-image-export19-2026-10-17T19-21-24Z/` gesichert und geprüft. `noty-bild19-geprueft.notybackup` bytegleich auf das iPad zurückübertragen; Import/Weiterbearbeitung/Neustart dieser neuen Kopie anschließend mit „ja passt auch weiterhin“ bestätigt. Keine neue AFC-Inventur nach der letzten Bearbeitung und keine erneute Abfrage jeder kleinen Bildvariante. Grundtest abgeschlossen.
