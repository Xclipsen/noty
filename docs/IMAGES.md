# Bilder und Screenshots – Build 19

## Ergänzung nach Build 50 – Foto-Import mit Rückfallwegen

Nutzer zu Build 50 (Screenshot): Auch Build 50 lehnte ein iPhone-Foto ab, mit der Systemmeldung „ImportedStillImage kann nicht importiert werden … keine kompatiblen Darstellungen“. Die Übergabe über die konkreten Standbildtypen passte also nicht zu dem, was die Fotomediathek für dieses Foto anbot. Die genaue Typliste des Fotos ist unbekannt.

`ImageImport.photo` versucht jetzt nacheinander drei Wege:
1. konkrete Standbildtypen als Datei
2. allgemeines `.image` als Datei
3. die reinen Bytes (`Data`)

Beim dritten Weg werden nur Standbilder bis 20 MB angenommen; ein Video wird abgelehnt. Eigene Fehler (Größe, Video) brechen sofort ab. Erst wenn alle drei Wege scheitern, erscheint die Meldung mit dem ersten Systemfehler. Am iPad ungeprüft.

## Ergänzung nach Build 49 – iPhone-Fotos (HEIC/Live Photos) und dunkle Bildleiste

Nutzerrückmeldung zu Build 49: „kann keine importen die ich auf meinem iphone gemacht habe — screenshots gehen“ und „dass die leiste vom anpassen des bildes in der noty theme ist“.

**Wahrscheinliche Ursache (aus dem Code, am Gerät nicht reproduziert):** Der Fotowähler lud über einen einzigen `FileRepresentation(importedContentType: .image)` (`ImageImportModel.swift`, Zeile 12 in Build 49). Mit der iPhone-Kamera aufgenommene Fotos sind standardmäßig Live Photos und bieten neben dem HEIC-/JPEG-Foto ein Paket aus Foto und Video an. Die allgemeine `.image`-Anfrage kann dieses Paket statt des Fotos erhalten; `ImageImport.read` öffnete es als Datei (Verzeichnis) bzw. ImageIO erkannte kein Bild. Screenshots haben kein solches Paket und funktionierten deshalb. HEIC selbst wird von ImageIO gelesen; Formatgrenzen (20 MB, 200 MP) waren bei normalen iPhone-Fotos nicht die Ursache.

**Korrektur:** Fotos werden zuerst über konkrete Standbildtypen geladen (HEIC, HEIF, JPEG, PNG, TIFF, GIF, WebP, BMP, RAW), die nie zum Live-Photo-Paket passen; nur Objekte ohne einen dieser Typen nutzen den allgemeinen `.image`-Weg. Kommt dennoch ein Paket an, wird darin das Foto anhand der Dateisignatur (nicht des Namens) gewählt, das Video nie. `preferredItemEncoding: .current` bleibt: keine Umkodierung. iCloud-Originale lädt das System während der Übergabe; Übergabefehler erscheinen als verständliche Meldung samt Systemdetail, fehlende Standbilder nennen die angebotenen Formate (Diagnose für den nächsten Gerätebericht).

**Entscheidung: HEIC bleibt Original.** Editor, Seitenvorschau, PDF-Export und Validierung dekodieren ausschließlich über ImageIO (`ImageImport.thumbnail`), das HEIC/HEIF auf allen unterstützten iPadOS-Versionen liest; das PDF enthält wie bisher nur das gerasterte Bild. Backups und der Pythonprüfer behandeln Originalbytes formatneutral. Eine JPEG-Konvertierung würde Originalbytes ersetzen (AGENTS: Bildoriginale erhalten) und ist daher nicht vorgesehen. Auch für zu große Fotos gibt es **keine** stille Verkleinerung.

**Signaturen und Grenzen:** `ImageFileFormat` (Core) erkennt PNG, JPEG, GIF, TIFF/DNG, WebP, BMP, HEIF über die `ftyp`-Marken `heic`, `heix`, `heim`, `heis`, `hevc`, `hevx`, `hevm`, `hevs`, `mif1`, `mif2`, `msf1`, AVIF sowie QuickTime/MP4-Videos. Die Erkennung dient nur dem Import (Foto im Live-Photo-Paket, Video mit klarer Meldung ablehnen). Gespeicherte Hefte werden bewusst **nicht** auf diese Formate beschränkt, weil frühere Importe alles ImageIO-Lesbare angenommen haben; Swift-Validierung und Pythonprüfer bleiben daher unverändert gleich. Die dokumentierten Grenzen liegen jetzt als `ImageLimits` in Core und werden vor dem Dekodieren geprüft: über 20 MB (z. B. ProRAW), über 200 Megapixel, 50 Bilder je Seite und 40 MB Bildoriginale je Notizbuch einschließlich Seitenpapierkorb und duplizierter Seiten erhalten je eine eigene deutsche Meldung mit belegter und benötigter Größe.

**Zwischenablage:** Die Reihenfolge der Zwischenablage selbst (Originalkodierung zuerst) entscheidet, nicht mehr fest PNG zuerst. Eine kopierte Kamerafoto-Neukodierung als großes PNG verhindert das Einfügen nicht mehr, wenn das HEIC/JPEG innerhalb der Grenze liegt; es wird nichts neu kodiert.

**Bildleiste im noty-Stil:** Die Aktionsleiste des ausgewählten Bildes ist ausdrücklich dunkel wie die Lasso-Aktionsleiste (Build 31) und die Textformatleiste: dunkle Fläche mit feiner heller Kontur, weiße SF Symbols in 44-pt-Trefferflächen, dezente Gruppentrenner (Zuschneiden/90° | hinten/vorne | Sperre | Löschen), Löschen rot, gesperrter Zustand mit dezentem Akzent, deaktivierte Aktionen deutlich gedimmt. Deutsche Bedienungshilfen-Bezeichnungen, Gruppe „Bildaktionen“. Funktionen, Reihenfolge, Positionierung und Zoomkompensation unverändert.

**Nachweise:** implementiert; 502 Core-Tests (davon 6 neue in `ImageImportPolicyTests`: echte libheif-/ffmpeg-Kopfbytes, Live-Photo-Auswahl, Grenzen einschließlich Papierkorb) und Host-Roundtrip mit unabhängigen Prüfern bestanden; iPad-SDK-Build ohne Fehler und Warnungen. **Nicht installiert, am iPad ungeprüft.** Gebündelter Gerätetest: ein Live Photo, ein Nicht-Live-HEIC, ein nur in iCloud liegendes Foto und ein Screenshot über **Bild +** einfügen; ein über Universal Clipboard kopiertes iPhone-Foto einfügen; Fehlermeldung bei vollem Notizbuch (40 MB) ablesen; Bildleiste auf heller und dunkler Seite, gesperrt/entsperrt und bei starkem Zoom ansehen; PDF-Export mit HEIC-Bild.

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
