# Lokaler Revisionsspeicher – Format 1

## Ergänzung 19.10.2026 · Notebook-Schema 9 (Textfarben)

Zwei optionale Stilfelder, auch in UTF-16-Runs: `automaticColor` (Bool) und `highlightColor` (`yellow`, `green`, `blue`, `pink`, `orange`, `purple`; fehlend = bisheriges Gelb). `automaticColor = true` verlangt `ink == nil` und `color` Schwarz/Weiß; `color` hält nur den zuletzt aufgelösten Wert. Angezeigt und exportiert wird über `Page.resolvedTextBoxes`/`EditorInteractionPolicy.automaticTextIsLight`: Papierfarbe, Randfarbe neben PDFs, auf der PDF selbst Schwarz. Daher folgt automatischer Text späteren Papier-/Randumstellungen ohne Datenänderung; die Ganzes-Heft-Umstellung (`PaperInkInversion`) setzt den gespeicherten Wert zusätzlich passend und lässt das Flag stehen.

Schema 1–8 lehnt die neuen Felder ab (Swift `Notebook.validate`, Python `notebook_format.py` für alle drei Prüfer); unbekannte neuere Schemata (≥ 10) bleiben gesperrt. Bloßes Öffnen migriert nicht; erst ein Text mit einem der Felder (neue Texte sind standardmäßig automatisch gefärbt, Markerfarbe, „Formatierung entfernen“) hebt über `Notebook.raiseSchemaForTextColors` auf 9 – in `replaceTextBoxes`, `replaceContent`, `replaceContents` (Lasso über Seiten), `materializeWritingDraft` und `reflowText`. `RevisionStore` sichert vorher die exakten bestätigten Bytes unter `Migrations/<UUID>/notebook-v8.json`; scheitert das, wird nicht committet (Test). Text-Undo mit vollständigen Heftständen setzt das Schema nicht mehr herab (`NotebookUndoHistory.apply` vergleicht/stellt Inhalte bei gleichbleibendem oder höherem Schema wieder her). Papierkorb, Revisionen, Heft-/Bibliotheksbackup, Vorschau und PDF-Export tragen die Felder unverändert; Host-Roundtrip prüft `automaticColorAndHighlightSurviveLibraryRestore`. Manifest-, Archiv- und Werkzeugformat unverändert.

## Ergänzung Build 32 · Abgeleitete Randtext-Einheiten

Kein neues Schema, keine Migration bestehender Bytes. Gebundener PDF-Randtext nutzt beim Rendern/Layouten den aus der angezeigten Cropbreite abgeleiteten Faktor Breite/595; gespeicherte Schriftgröße 14 und Rich-Text-Runs bleiben unverändert. Native Editor-Container sowie gemeinsame Text-/Vorschau-/PDF-/Kapazitätsrenderer benutzen denselben lokalen Normalraum und kanonischen Transform. Freie PDF-Annotationen und Papiertext behalten bestehende Einheiten. Neue Randmaße wieder relativ zur PDF-Grundgröße; gespeicherte Maße nicht automatisch ändern. Überlauf bleibt sichtbar und darf Export nicht still abschneiden. [Details](EDITOR-FEEDBACK-32.md).

## Ergänzung Build 27 · Notebook-Schema 8

Textfelder können `flowID` (UUID) und `flowRegion` (`page`, `left`, `right`, `top`, `bottom`) gemeinsam enthalten; beide fehlen bei freien PDF-Feldern. Pro Seite höchstens ein Segment derselben Flow-ID. Ein Flow kann über mehrere echte Seiten laufen. Seitenkopien/Papierkorb-Sicherungen erhalten neue Flow-Identitäten, damit kopierte Abschnitte nicht unabsichtlich den ursprünglichen Text umverteilen. Ganzes unabhängiges Heft behält seine internen Verbindungen.

Optionale Stilfelder: `fontName` mit 1–200 UTF-8-Bytes, validierte RGBA-`ink`, boolesches `strikethrough`, `baseline` als -1/0/1. Sie gelten auch in UTF-16-Runs. Neue Daten unter Schema 1–7 abweisen; bloßes Öffnen migriert nicht. Erst tatsächliche Text-/Formatbearbeitung erhält Schema 8; alle anderen Mutationswege erhalten höhere Schemata. `RevisionStore` sichert exakte bestätigte Altbytes vor Commit unter `Migrations/<UUID>/notebook-v7.json`; aktiver Bestand und Papierkorb bleiben erhalten. Swift-/Pythonvalidierung gemeinsam erweitert. Manifest-/Heft-/Bibliotheksarchivformat und Werkzeugformat bleiben unverändert.

Reflow erstellt einen vollständig validierten Notebook-Kandidaten, übernimmt nur den bearbeiteten Text und seine verknüpften Folgeabschnitte und fügt bei Bedarf Papier ein. Keine automatische Entfernung bestehender Seiten. Gemeinsamer Renderer für Vorschau/PDF berücksichtigt dieselben Attribute. Virtuelle letzte Schreibseite ausschließlich im Editor: kein gespeichertes Draft-Flag, keine stillschweigende Filterung echter leerer Seiten im Export. Erste Ink/Text/Inhalt-Mutation materialisiert die vorbereitete ID über den vorhandenen Writer. 219 Core-Tests einschließlich exakter Schema-7-Migrationsbytes und unabhängiger Schema-8-Archiv-/Bibliotheksrestore bestanden. Native Geräteausgaben noch offen. [Textpaket](TEXT-REBUILD-27.md).

## Ergänzung Build 25 · Ansichtsoption in Werkzeugformat 7

Optionales boolesches `normalizePageWidths`, bei fehlendem Wert aus. Formate 1–6 bleiben lesbar, neuer Wert in älteren Formaten abgewiesen. Swift-Decoder, unabhängiger Bibliotheksprüfer und Roundtrip gemeinsam erweitert. Die Normalisierung verändert ausschließlich Viewport-Platzierungen; keine Änderung des Notebook-Schemas, der PDF-Originale, kanonischer Koordinaten, Papiergrößen, Revisionen, Backups oder Exporttransformationen. Die Ansichtsoption wird als Bereichspräferenz mit dem Bibliotheksbackup erhalten.

## Ergänzung Build 24 · Werkzeugformat 6

Optionales boolesches `dockOnly`, bei fehlendem Wert standardmäßig Dockbindung. Alte gespeicherte freie Position/Ausrichtung bleibt unverändert lesbar, `effectiveDock` zeigt sie bis zur Freischaltung oben. Drop außerhalb der Zonen kehrt bei Dockbindung zum aktuellen Dock zurück, sonst freies Platzieren. Formate 1–5 werden unter Erhalt der Werte gelesen; ein `dockOnly`-Wert in älteren Formaten wird abgewiesen. Decoder, unabhängiger Bibliotheksprüfer und Roundtrip mit expliziter Freischaltung gemeinsam erweitert. Notebook-Schema bleibt 7, Archiv-/Indexformate unverändert.

## Ergänzung Build 22 · Werkzeugformat 5

Optionale `floatingAxis` mit `horizontal`/`vertical` hält freie Ausrichtung unabhängig vom Andockrand. Formate 1–4 bleiben lesbar; Migration erhält bestehende Reihenfolge, Favoriten und Optionen. `floatingAxis` in älteren Formaten und unbekannte neuere Versionen ablehnen. Bestehender Writer/Revisionsschutz und Archivformatsnummern bleiben erhalten. Swift-Decoder und unabhängiger Bibliotheksprüfer gemeinsam erweitert; Host-Archivroundtrip mit gespeicherter vertikaler Ausrichtung bestanden. Notebook-Schema bleibt 7.

## Ergänzung Build 21 · Schema 7 und Werkzeugformat 4

Notebook-Schema 7 ergänzt optional `appearance` (Umschlag an/aus, Farbe, Papierformat A4/A5/A3/Letter, Querformat, Papierart/-farbe) und optionale UTF-16-`runs` je Textfeld. Ein Run enthält `location`, `length` und vollständigen Stil; nicht überlappend, höchstens 50.000 Runs/Feld, gültige Unicode-Surrogatgrenzen. Stil ergänzt optionale Hervorhebung, Ausrichtung, Einzug 0–240 pt und begrenzten HTTP(S)/mailto-Link. Bestehende Felder ohne Runs behalten ihren ganzen Feldstil und ihre Positionen. Erst neue Formatierung migriert das Heft; Text-/Bild-/Form-/Seitenwege erhalten höhere Schemata. Papierseiten dürfen ab Schema 7 andere validierte Geometrien als A4 besitzen; PDF-Geometrie/Originalbytes unverändert.

`PageTrashReason.cleared` kennzeichnet den vollständigen Stand vor „Seite leeren“. Zurücksetzen erhält die aktive Seiten-ID/Position und sichert den verdrängten Stand vorher ebenfalls. Kopieren regeneriert Seiten-/Objekt-IDs; ausgeschnittene Seiten werden anhand stabiler IDs erst beim Einfügen verschoben. Kein zusätzlicher Writer. Umschlag ist Metadatum, keine exportierte/zählbare Seite. Die Bibliotheksübersicht liest diese Metadaten aus dem Notebook; kein doppelter persistierter Umschlag im Index.

Werkzeugformat 4 ergänzt unten, Autostift, Pencil-Vorschau, Blättermodus und letzten Radiermodus; Formate 1–3 werden mit erhaltenen Einstellungen/individueller Reihenfolge übernommen. Alter Standard wird zur bestätigten neuen Hauptreihenfolge. Manifest-/Archiv-/Bibliotheksindexformate unverändert; bestätigte alte Notebook-Bytes vor höherem Schema dauerhaft im bestehenden Migrationsarchiv sichern. Swift und Pythonprüfer gemeinsam erweitert. 169 Core-Tests und unabhängiger Schema-7-Host-Roundtrip bestanden; native Speicherung/Formatierung/Export noch ungeprüft. [Details](UI-REBUILD.md).

## Ergänzung Build 20 · Schema 6

Optionale `Page.shapes` für aktive und gelöschte Seiten: stabile UUID, Art (Gerade/Pfeil/Rechteck/Ellipse), orientierte kanonische Start-/Endpunkte, RGBA, Breite, Muster und optionale Füllung. Maximal 500 Formen pro Seite, endliche Werte und vollständige Formbounds innerhalb der Seite einschließlich PDF-Rändern; IDs über alle Seiten eindeutig und disjunkt zu Bild-/Text-IDs. Erst Formen-/Gruppenänderung migriert auf 6, andere Editierwege erhalten das höhere Schema. Exakte bestätigte Altbytes werden durch den bestehenden Revisionsweg vor Commit unter `Migrations` gesichert.

`PageContent` ersetzt Ink/Text/Bilder/Formen als einen vollständig validierten Kandidaten für gemischtes Lasso/Undo. Duplikate und archivierte Seitenstände regenerieren Objekt-IDs. Formen gehören zu vollständigen Revisionen, Heft-/Bibliotheksarchiven, Wiederherstellung, Vorschau und PDF; Original-PDF/-Bildbytes bleiben erhalten. Archivcontainer-Versionen unverändert, unbekanntes Heftschema weiterhin sperren. Unabhängige Pythonprüfer akzeptieren/validieren Schema 6. Keine Deduplizierung der vollständigen JSON-Revisionen in diesem Schritt.

Werkzeugformat 3 ergänzt Formen und gemischtes Lasso unter Erhalt der alten individuellen Reihenfolge. Neue Form-/Lineal-/Erkennungseinstellungen optional für alte Bestände. Externe Ziele/Bookmarks/Versuchsstatus lokal je Bereich; WebDAV-Zugang ausschließlich Keychain und außerhalb der Archive. Details: [REST-FEATURES-20](REST-FEATURES-20.md).


Stand: Build 19, 17.10.2026. Manifestformat 1 unverändert, Notebook-Schema 1–5 lesbar. Schema-5-Bilder implementiert/gebaut, Host-Roundtrip und echte Geräte-PDF-/Backupprüfung bestanden; externer Geräte-Restore mit Bildzuschnitt/Sperre, neuer Handschrift und Neustart vom Nutzer bestätigt. Schema-4-Text und externer Geräte-Restore bestätigt. Lokale Speicherung; genaue Backup-/Gerätenachweise in TESTING.md. Noch keine V1-Gesamtfreigabe.

## Dateien und Identitäten

```text
Documents/Noty/
  notebook.json                  alte Prototypdatei, unverändert aufbewahrt
  recovery.json                  alte Prototyp-Wiederherstellung
  manifest.json                  aktueller Commit-Zeiger
  manifest-previous.json         voriger vollständiger Commit-Zeiger
  Revisions/<UUID>.json           unveränderliche vollständige Notizstände
  Archives/<UUID>/…              vollständiger Altbestand vor Import/Restore
  Migrations/…                   frühere Schema-1-Archive, erhalten
```

Paket-`formatVersion` ist unabhängig von `Notebook.schemaVersion`. Manifestformat 1 verlangt `checksumAlgorithm = "crc32-iso-hdlc"` und ein Array `revisions`, neuester Eintrag zuerst. Ein Eintrag enthält `file`, `byteCount` und numerisches `crc32`. Ab Build 8 optional `savedAtUnix` (UTC-Sekunden seit 1970); alte Einträge ohne Zeitangabe bleiben lesbar. Nur exakt `<UUID in Großbuchstaben>.json` ist als Blattname erlaubt; keine Unterpfade. Manifest maximal 128 kB, eine Revision maximal 200 MB. Verzeichnis/Datei-Symlinks für Revisionsinhalte werden abgelehnt.

Jede Revision enthält das vollständige Notebook-JSON: stabile Dokument-/Seiten-UUIDs, Titel, unveränderte PDF-Quelldaten, geordnete Seiten mit optionaler Geometrie, PencilKit-Daten und Tastaturtext. Eine Dateirevisions-UUID ersetzt keine Seiten-ID. Der Inhalt einer erfolgreich geschriebenen Revision wird nie nachträglich verändert.

## Notebook-Schema 5 ab Build 19

`Page.images` enthält ein geordnetes Array editierbarer Bildobjekte: `id`, `data` (unveränderte importierte Dateibytes, Base64), `pixelWidth/pixelHeight` in EXIF-korrigierter Orientierung, `x/y/width/height` in kanonischen Punkten, `rotation` −180…180 Grad um den Mittelpunkt, `crop` als normalisiertes Rechteck im orientierten Original und `locked`. Array von hinten nach vorne, gesamte Bildebene unter Ink/Text. Zuschnitt lässt mindestens 2 % jeder Originaldimension stehen (numerische Toleranz); niemals Originalbytes ersetzen. IDs über aktive/gelöschte Seiten eindeutig und disjunkt zu Textobjekten. Rotierte Bounds innerhalb der erweiterten Seite; Randänderungen dürfen Bilder nicht abschneiden. Höchstens 50 Objekte/Seite, 20 MB/Original, 200 Megapixel, zusammen 40 MB über aktive/gelöschte Seiten.

Erst Bildmutation migriert zur Quellenrepräsentation und Schema 5. Vorhandener Legacy-Text darf dabei virtuell bleiben; erste Textbearbeitung übernimmt alle alten Texte und erhält `max(4, schemaVersion)`. Seitenkopien/Randsnapshots regenerieren Bild-IDs, vollständige Originalbytes bleiben in allen Snapshots und Backups enthalten. Exakte Altbytes vor neuem Schema-Commit archivieren wie bisher. Kein Assetpfad oder externer Fotolink. Werkzeugformat separat auf Version 2 für das neue Bildwerkzeug; altes Format 1 unter Erhalt der individuellen Reihenfolge lesbar. [Darstellung und Grenzen](IMAGES.md).

## Notebook-Schema 4 ab Build 17

`Page.textBoxes` ergänzt Felder mit stabiler UUID, kanonischem `x/y/width/height`, Unicode-`text` und strukturiertem `style` (Schriftfamilie/System-Serif-Festbreite, Größe, Fett/Kursiv/Unterstrichen, definierte Farbe). Feldrahmen meint Glyph-Inhaltsrechteck ohne native Innenabstände; negative Koordinaten im linken/oberen PDF-Rand zulässig. Höchstens 200 Felder pro Seite, je 1 MB UTF-8, endliche Maße und Stilwerte. Feld-IDs über aktive und gelöschte Seiten eindeutig; Duplizieren und Sicherungskopien erzeugen neue Objekt-IDs.

Beim Öffnen alter Hefte bleiben gespeicherte Bytes unverändert. `effectiveTextBoxes` bildet alte Einzeltexte virtuell an ihrem exakten bisherigen Glyph-Ursprung ab; erst Textobjektänderung stellt das Heft samt Papierkorb auf Schema 4 um. Dann `textBoxes` gesetzt und altes `text` leer; beide parallelen Textebenen werden abgelehnt. Seitenoperationen allein erzeugen weiterhin Schema 3, wenn kein Schema 4 vorliegt. Exakte Altbytes vor neuem Commit im bestehenden Migrationsarchiv sichern, Fehler verhindern Commit. Details und noch offene Gerätekriterien in [TEXT-FIELDS.md](TEXT-FIELDS.md).

## Notebook-Schema 3 ab Build 12

- Legacy-Repräsentation mit einem `pdf` und positionsgebundener Quellenzuordnung bleibt lesbar; Schema-2-Hefte erst bei Seitenoperation/Lesezeichen/Randänderung umstellen. Neue Papierhefte explizit Schema 3, tatsächliches Blankopapier.
- `pdfSources: [{id, data, pageCount}]`: eine unveränderte Original-PDF je Quelle, `data` Base64. Aktive und gelöschte Seiten referenzieren `{sourceID, pageIndex}` (nullbasiert). Seitenreihenfolge unabhängig von Quellindex; Duplikate teilen Quelle, nicht editierbare Layer.
- Papierseiten statt Referenz: `paper=blank|lined|grid|legacyTest`, optionale `paperColor=white|dark`, Geometrie A4; `legacyTest` ohne Geometrie erhält alte Testseite/Koordinaten. Kein gleichzeitiger PDF-/Papierhintergrund.
- `bookmarked` optional, fehlend bedeutet false. `margins` nur an PDF-Seiten: `left/right/top/bottom` endliche nichtnegative Punktmaße, `style=blank|lined|grid`, `color=white|dark`. Kanonische Ink-/Textkoordinaten bleiben relativ zur Grundseite, Anzeige/Export verschieben um links/oben. Erweiterte Seite höchstens 14.400 Punkte je Dimension.
- `deletedPages`: vollständige Seite, Zeitpunkt, frühere Position und vorige/nächste Seiten-ID. IDs über aktive/gelöschte Seiten eindeutig. Reguläres Löschen behält Seiten-ID; Snapshot vor bestätigter Randverkleinerung erhält neue ID und Grund `marginReduction`. Ab Build 16 identifiziert `previousPageID` bei `marginReduction` die ursprüngliche aktive Seite. Nur bei passender PDF-Referenz und identischer Grundgeometrie deren vollständigen Stand zurücksetzen, stabile ID/aktuelle Position erhalten und den verdrängten Stand mit neuer ID und derselben Zielverknüpfung im Papierkorb sichern. Auswahlentfernung, Sicherung und Ersetzen gemeinsam in einer Revision. Kein zusätzliches Formatfeld; vorhandene Schema-3-Randsnapshots bleiben nutzbar. Fehlt das passende Original, zusätzliche Seite statt fremder Ersetzung. Reguläre gelöschte Seiten weiterhin einfügen.
- Höchstens 500 aktive/500 gelöschte Seiten, 500 Quellen mit je höchstens 500 Originalseiten/20 MB; Quellen zusammen höchstens 100 MB, vollständige JSON-Revision weiterhin höchstens 200 MB. Keine Quellen-GC/Endgültig-Löschen-Funktion in diesem Paket; keine Deduplizierung über Revisionen.
- Vor höherem Schema einer bereits paketierten Note archiviert `RevisionStore` die exakten zuletzt bestätigten Revisionsbytes dauerhaft unter `Migrations/<UUID>/notebook-v<alt>.json`, vor Manifeständerung und vor späterem Revisions-Cleanup. Fehler beim Archivieren bricht Save ab. Originale Prototypdateien bleiben ebenfalls erhalten. Kein stiller Rückfall auf ein altes Format bei unbekanntem Schema.

Aktive Seiten, Papierkorb, Quellen, Ränder und Lesezeichen gehören gemeinsam zum Snapshot und damit automatisch zum versionierten Heft-/Bibliotheksbackup. Ältere App-Versionen ohne Schema-3-Unterstützung können diese neuen Stände nicht lesen; kein Downgrade-/Rollback-Gerätenachweis.

## Commit und Wiederherstellung

1. Repository-Actor nimmt einen vollständigen UI-Snapshot mit monotoner Änderungsnummer entgegen. Ältere Nummern werden verworfen.
2. Notebook validieren, Revision unter neuem UUID-Dateinamen atomar schreiben, erneut lesen und Länge/CRC prüfen.
3. Voriges gültiges Manifest atomar nach `manifest-previous.json` schreiben.
4. Neues Manifest mit neuer Revision und höchstens zwei älteren Einträgen **zuletzt** atomar nach `manifest.json` schreiben. Erst jetzt darf „Lokal gespeichert“ erscheinen.
5. Nach Commit nicht mehr von einem der beiden Manifeste referenzierte reguläre UUID-Revisionsdateien best effort entfernen. Fremde Dateinamen, Verzeichnisse, Symlinks, Archive und Prototypdateien bleiben erhalten.

Drei reguläre Stände, normalerweise maximal vier physische Revisionen wegen des vorigen Manifests. Wenn Cleanup fehlschlägt, können mehr Dateien bleiben; erneute Bereinigung beim nächsten erfolgreichen Save. Keine physische Stromausfallgarantie durch Foundation `.atomic`; Hardwarefehler und abschließende Dateisystem-Dauerhaftigkeit sind nicht bewiesen.

Beim Lesen zuerst das aktuelle Manifest prüfen, dann dessen Revisionen in Reihenfolge; bei beschädigtem Manifest das vorige prüfen. Länge/CRC und Notebook-Schema/Geometrie müssen stimmen. Unreferenzierte Revisionen gelten nicht als Commit. Kein kompletter Stand: verständlicher Lesefehler, kein Überschreiben mit leerem Heft. Neuere unbekannte Paket- oder Dokumentschemata blockieren Fallback und Save ausdrücklich.

CRC-32/ISO-HDLC erkennt zufällige Beschädigung; kein Manipulationsschutz und keine Verschlüsselung. Implementierung ohne zusätzliche Paketabhängigkeit, mit bekannten Testvektoren geprüft. Zur standardmäßigen CRC-Verwendung siehe [zlib-Referenz](https://zlib.net/manual.html#Checksum).

## Migration und bewusster Restore

Ohne Manifeste vorhandene Prototypdateien über den alten validierenden Leser laden. Diese Dateien bleiben exakt erhalten. Beim ersten Paket-Commit zusätzlich eine Revision des geladenen Altstands anlegen und als voriges Manifest sichern, bevor der neue Commit-Zeiger geschrieben wird. Uncommittete Migrationsdateien ohne Manifest machen vorhandene gültige Prototypdateien nicht unlesbar.

Ein absichtlich gewählter Restore archiviert vor jedem Ersetzen vorhandene Prototypdateien, beide Manifeste und alle Revisionen sowie den aktuellen Speicherstand. Schlägt das Archivieren fehl, abbrechen. Danach darf der getrennte Restorepfad beschädigte Daten durch einen validierten Kandidaten ersetzen. Unbekannte neuere Formate bleiben auch dabei gesperrt. Noch kein bestandener externer Restore und noch keine Konfliktverwaltung einer Bibliothek.

## Grenzen / nächster Schritt

Vollständige JSON-Snapshots duplizieren PDF und Ink über Revisionen und benötigen Serialisierungs-/Prüfsummenspeicher. Noch keine deduplizierten Assets; vor großen Dokumenttests verbessern. Importarchive und Prototypkopien haben noch keine Retention. Ab Build 8 Browser älterer lokaler Stände in der UI, Öffnen immer als getrennte Kopie. Feste Revisions-UUID statt Listenposition; fehlende/ungültige Auswahl wird abgelehnt. Noch Geräteprüfung offen. Historie derzeit nur drei jüngste Commits, keine langfristigen Zeitfenster. Erneutes Speichern nach Fehler ist in der Oberfläche angeboten, sein tatsächliches Fehlerverhalten auf dem iPad noch offen.

Ab Build 7 eigenständiges versioniertes `.notybackup` für ein vollständiges aktuelles Heft, geprüfter Import über Staging und neue getrennte Kopie; Details in [BACKUPS.md](BACKUPS.md). Geräte-/PC-Roundtrip für ein Heft mit gespeicherter Textänderung und abgewiesenem beschädigtem Archiv belegt, siehe TESTING.md. Frühere reine JSON-Exporte bleiben lesbar. Gesamte Bibliothek und WebDAV/iCloud-Zielverwaltung folgen später.
