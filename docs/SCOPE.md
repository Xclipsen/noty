# Verbindlicher Produktumfang

Stand: 16.10.2026. Persönliche native iPad-Notiz-App **noty** für den Schulalltag auf dem eigenen iPad Pro 11 Zoll mit Pencil Pro und Tastatur. Deutsche Oberfläche, Hoch-/Querformat, dunkle Bedienelemente und unabhängig davon weiße PDF-Seiten. Kernfunktionen offline; kein noty-Konto, kein eigener App-Server. Der Nutzer hat den Gesamtumfang samt Abnahmekriterien am 16.10.2026 ausdrücklich bestätigt („Ja, genau so festhalten und weiterbauen“). Einzelentscheidungen Q1–Q15 sind abgeschlossen. Umfang beschreibt Ziele, keine vorhandenen Features.

## Ergänzung UI-Rebuild vom 18.10.2026

Die in [UI-REBUILD.md](UI-REBUILD.md) beschriebenen und anschließend präzisierten Vorgaben einschließlich Werkzeugaufteilung sind bestätigt: zusätzlich unten andockbare Leiste; vertikale Seitenfolge mit alternativem Blättermodus; Notizbuchumschlag ausschließlich in der Bibliothek und wählbarer Papierstandard; freie Textfelder mit anfangs voller Seitenbreite sowie unterschiedlicher Formatierung einzelner Wörter/Abschnitte. Seiten kopieren/einfügen, Ausschneiden erst beim Einfügen verschieben, Einfügen immer hinter der gewählten Seite; Leeren erhält PDF/Papier. Optionaler Schreibplatz schon beim PDF-Import, Autostift für neue Striche und abschaltbare Pencil-Hover-Vorschau ergänzen die bisherigen Ziele. Ergänzung Build 25: optional gemischte Seitenbreiten ausschließlich in der Anzeige angleichen, Arbeitsblatt lesbar einpassen und Schreibränder daneben erhalten; PDF-Originale und gespeicherte Inhalte/Export bleiben unverändert. Die Gesetzessammlung bleibt eine spätere Erweiterung. Diese Ziele sind kein Implementierungs-/Abnahmenachweis.

## Bestätigte Entscheidungen

### Bibliothek und Dokumente

- Frei verschachtelbare Ordner; Notizbücher und importierte Arbeitsblätter darin.
- Seitenleiste; Ordner und Einträge frei anordnen und verschieben.
- Favoriten, Zuletzt verwendet, Namenssuche und Papierkorb gemäß bestätigter Explorer-Empfehlung.
- PDFs und Bilder vollständig lokal importieren, Originaldateien unverändert erhalten.
- Blanko-, linierte und karierte Seiten an beliebiger Stelle einfügen; Seiten umordnen, unabhängig duplizieren, löschen und wiederherstellen; weitere PDFs einfügen. Seitenübersicht mit Vorschaubildern.
- Konkretisierung vom 17.10.2026, Position am 18.10.2026 korrigiert: Seitenverwaltung als echte, einklappbare rechte Seitenleiste im Editor, ähnlich der Goodnotes-Navigation und passend zum Notizbuch-Explorer. Sichtbare Vorschaubilder mit Seitennummer und aktueller Auswahl; Umordnen durch Ziehen, „+“ zum Einfügen und Seitenmenüs für Duplizieren/Verschieben/Löschen sowie Zugang zu gelöschten Seiten. Direkter Rückweg zur Notizbuchübersicht; kein separates Übersichtsfenster als zentraler Einstieg.
- Designgespräch Q16–29, Präzisierung für Build 14: zweispaltiges dunkles Raster mit nativen Glaseffekten, feste automatisch angepasste Breite ohne manuelle Größenverstellung und Einblendung bei schmalem Fenster. Proportionale Seitenvorschauen ohne weißen Außenfüller, Auswahlrahmen an tatsächlicher Seite. Lesezeichenfilter und PDF-Inhaltsverzeichnis; Einfügefenster mit Vor/Nach/Letzte Seite, weißem/dunklem Blanko-/Linien-/Karopapier. Details und technische Startwerte in [DESIGN.md](DESIGN.md).
- Zusätzlichen Schreibplatz an allen vier PDF-Rändern mit Reglern/Vorschau ergänzen; Seite vergrößern, Original-PDF unverändert in Originalgröße. Papierart/Farbe wählbar; aktuelle oder alle aktiven Seiten desselben Imports; später änderbar. Schnellwerte Schmal 25 %/Mittel 60 %/Breit 100 % der jeweiligen Grundseitendimension. Bei gefährdeter Handschrift vor Verkleinerung warnen, bestätigte Entfernung mit wiederherstellbarem vollständigem Seitenstand einschließlich früherer Ränder im Seitenpapierkorb sichern. Präzisierung Build 16: Rand-Restore setzt die bestehende Seite zurück und sichert den aktuellen Stand vorher im Papierkorb; nur bei fehlender passender Originalseite eine zusätzliche Seite anlegen.
- PDF-Text auswählen/kopieren; eigener sichtbarer PDF-Export einzelner Seiten oder ganzer Notizbücher mit Handschrift, Formen, Bildern und Text. PDF-Export und editierbares Backup bleiben getrennte Funktionen.
- Gemischte Seitenformate, CropBox, Rotation, Zoom und Fenstergrößenänderung dürfen keine Inhalte verschieben. Alle Inhalte bleiben offline lokal verfügbar.

### Schreiben und Werkzeuge

- **Eigene Werkzeugleiste**, keine direkt sichtbare Apple-Palette im fertigen Editor. PencilKit darf die native Zeichen-/Radierbasis bleiben.
- Leiste oben/unten/links/rechts andockbar und optional frei schwebend. Präzisierung Build 24: standardmäßig nur Dockpunkte, freies Platzieren in Leisten-Einstellungen aktivieren; angehängte kompakte Werkzeugoptionen und rechter drehender Ebenenpfeil. Reihenfolge frei anpassbar; Lieblingsstifte speichern Farbe und Breite. Werkzeug wählen durch Tippen, Einstellungen bei erneutem Tippen (bestätigte Empfehlung).
- Ganze Striche und präzises Teilradieren; Stifte/Marker mit Farbe und Breite.
- Präzisionsradierer verändert Handschrift/Marker. Ganzstrichradierer entfernt zusätzlich komplette Linien/Formen. Textfelder und Bilder bleiben vor dem Radierer geschützt; Löschen über Auswahl/Lasso.
- Durchgezogene, gestrichelte und gepunktete **Linien, Pfeile und Formen**. Gestrichelte freie Handschrift gehört nicht zum aktuellen Ziel.
- Gerade, Pfeil, Rechteck, Kreis/Ellipse; Farbe, Breite, optionale Füllung und nachträgliche Bearbeitung über Griffe. Zeichnen und kurzes Halten zum Begradigen bzw. Erkennen einfacher Formen ist enthalten.
- Lasso für gemischte Auswahl aus Handschrift, Text, Bildern und Formen, mit Inhaltstypfiltern; gemeinsam bewegen, kopieren, skalieren.
- Frei platzierbare Textfelder, Bilder/Screenshots einfügen, Lineal/Formen.
- Apple Pencil schreibt; Finger navigieren standardmäßig. Ein optionaler Fingermalmodus ist ausdrücklich umschaltbar. Pencil-Pro-Gesten nach Hardwareprüfung an die gewählten Werkzeuge anbinden.
- Undo/Redo für die aktive Bearbeitung; Auswahl und Fokus müssen bei Autosave erhalten bleiben. Tastatur-Shortcuts und Esc zum Beenden der Textbearbeitung gemäß Master-Prompt.

### Text und Bilder

- Textfelder frei bewegen und skalieren; Schriftart, Größe, Farbe, Fett, Kursiv, Unterstrichen, Aufzählungen, Nummerierung und Checkboxen.
- Text bleibt auf festen Seiten. Breitenänderung führt zu Umbruch innerhalb des Feldes; Inhalt nicht still abschneiden. Höhe innerhalb der Seite anpassen bzw. Platzmangel sichtbar machen. Kein automatischer Fließtext über mehrere Seiten.
- Bilder und Screenshots einfügen, zuschneiden, drehen, skalieren, nach vorne/hinten legen und gegen Verschieben sperren. Keine Bildretusche oder pixelweise Bildradierung.

### Ansichten und Suche

- Zwei unabhängige Ansichten innerhalb von noty: gleiche oder unterschiedliche Dokumente, jeweils eigene Seite und Zoom. Werkzeugleiste steuert aktive Ansicht.
- Suche in PDF-Text und Handschrift ausdrücklich gewünscht; getippter Text ebenfalls Teil des bestätigten Vorschlags.
- Globale Suche erfasst auch Scan-PDFs und eingefügte Bilder per lokaler OCR; zunächst Deutsch und Englisch. Fundstellen mit Dokument, Seite und Position verknüpfen.
- Handschrifterkennung erfordert einen eigenen Machbarkeitstest mit repräsentativer Schrift; noch keine Aussage zur Erkennungsqualität.

### Backups

- **Ein aktives externes Backupziel**, wechselbar zwischen WebDAV und iCloud Drive. Kein paralleler automatischer Betrieb beider Ziele.
- Vollständige editierbare Backups **unverschlüsselt**, ausdrücklich so vom Nutzer gewählt. Normale PDF-Exporte bleiben eine eigenständige Funktion.
- Täglicher Sicherungsversuch während aktiver Nutzung; zusätzlich manueller Export und mehrere ältere vollständige Stände. Fehlendes Ziel sichtbar melden, alte Backups erhalten, später erneut versuchen.
- WebDAV direkt in noty konfigurierbar; iCloud Drive über einen gewählten Ordner der Dateien-App. Zugriffsrechte und tatsächliche Schreibmöglichkeiten auf dem iPad testen. Zugangsdaten im Keychain, nicht im Archiv oder Quellcode.
- iCloud-Zieldatei erfolgreich geschrieben ist kein Beleg des abgeschlossenen Cloud-Uploads. Beide Wege sind Backups, keine Live-Synchronisierung.

### Persönlicher Betrieb

- Ausschließlich persönliche Nutzung, zunächst auf dem eigenen iPad; keine App-Store-Veröffentlichung oder weitere Plattform als Lieferumfang.
- Wöchentliche Erneuerung am Omarchy-PC mit derselben Signierungsidentität und installierten App-ID ist akzeptiert. Ablauf dokumentieren und eine Erinnerung vorsehen. App-Daten **müssen** bei Updates/Erneuerung erhalten bleiben; die App nicht vorher löschen.
- Die kostenlose Signierung und ihre Gültigkeit bleiben eine Betriebsanforderung. Offline-Schreiben erfordert nach der Installation keine Netzwerkverbindung; Erneuerung/externes Backup benötigen die jeweils nötige Verbindung.

## Bewusst außerhalb der ersten vollständigen Version

Audioaufnahme, eigener Kamerascanner, automatische Umwandlung von Handschrift in bearbeitbaren Tastaturtext, Fließtext mit automatischem Umbruch über Seiten, Tabelleneditor, KI-Funktionen, Live-Synchronisierung zwischen Geräten und Zusammenarbeit. Gestrichelte freie Handschrift ist ebenfalls ausgeschlossen. Scans können über die Dateien-App als PDF importiert werden; lokale OCR dient der Suche.

## Qualitätsgrenze für die persönliche Alltagsfreigabe

Der vollständige Funktionsumfang oben gehört zur Zielversion. Er wird in überprüfbaren Zwischenständen entwickelt; ein Zwischenstand mit weniger Funktionen ist keine stillschweigend verkleinerte Zielversion.

Eine Freigabe erfolgt erst, wenn die Kriterien in [ACCEPTANCE.md](ACCEPTANCE.md) tatsächlich nachgewiesen sind. Besonders wichtig: konsistente Speicherung, externer Restore in leeren Testbestand, vollständiger PDF-Export, gleiche Dokumente in zwei Ansichten ohne Rücksprünge und ein echter Probetag. Handschrift-/OCR-Suche verlangt einen eigenen Qualitätstest; bei unzureichenden Ergebnissen bleibt die Freigabe offen, bis eine Einschränkung gemeinsam beschlossen wird.

## Technische und Bedienungs-Startwerte

- Favoriten/Toolleiste merken sich Anordnung, Andock-/Schwebemodus und Werkzeugeinstellungen. Die Palette bleibt nach Rotation/Fensteränderung erreichbar.
- Gemeinsamer Dokumenteigentümer für zwei Ansichten; keine getrennten konkurrierenden Speicherstände. Stabile Objekt-/Seiten-IDs, einheitliche Koordinaten und Undo-Verhalten.
- Autosave zunächst mit höchstens ungefähr einer Sekunde Verzögerung nach abgeschlossener Eingabe; tatsächlichen Wert auf dem iPad messen. „Gespeichert“ erst nach Commit, Retry bei Fehlern.
- Begrenzte lokale Historie und konfigurierbare Aufbewahrung automatischer Backups. Konkrete Speicher-/Cachegrenzen anhand repräsentativer Dateien messen und dokumentieren. Neuester gültiger Stand wird nicht zur Bereinigung geopfert; manuelle Exporte nicht automatisch löschen.
- Papierkorb wird zunächst nur ausdrücklich vom Nutzer endgültig geleert. Ältere Sicherungen beim Zielwechsel erhalten. Erst neue Sicherung vollständig schreiben und validieren, dann gegebenenfalls gemäß Aufbewahrung bereinigen.
- PDF-Text und getippter Text nach Möglichkeit als echter durchsuchbarer PDF-Text exportieren; Handschrift darf gerendert werden, Qualität am Export prüfen. Keine pauschalen Screenshots aller Seiten.
- Zugangsdaten für WebDAV im Keychain; keine Zugangsdaten im unverschlüsselten Backup. Status zeigt lokale Zieldatei und Fehler, keinen unbelegten Cloud-Upload.
- Laufzeit-/Speichervorgaben sind überprüfbare technische Entscheidungen, keine versprochenen FPS-/Latenzwerte. Die normale Stifteingabe bleibt auf PencilKit aufgebaut.

## Bestätigung und weitere Umsetzung

Das Umfangsinterview ist abgeschlossen. Weitere Umsetzung ist autorisiert. Normale technische Entscheidungen selbstständig treffen, Änderungen am bestätigten Funktionsumfang ausdrücklich abstimmen.

## Technische Machbarkeit aus der Recherche

- PencilKit: native Schreibwerkzeuge, Farben/Breiten, ganzer Strich (`vector`) und Teilradieren (`bitmap`), Handschrift-Lasso, Lineal. Eigene Leiste kann die Werkzeuge direkt ansteuern.
- Gestrichelte/gepunktete Geometrie: eigene Linien-/Formobjekte; kein entsprechender öffentlicher PKInkingTool-Strichmusterschalter gefunden.
- Gemischte Auswahl und eigener Formen-/Text-/Bildeditor brauchen eine gemeinsame Objektebene zusätzlich zu PKDrawing. Das native Lasso allein genügt dafür nicht.
- Zwei Ansichten, Explorer und Volltextindex sind eigene App-Funktionen. Beim gleichen Dokument darf es nur einen gemeinsamen Daten-/Speichereigentümer geben.
- OCR kann lokal mit Apple Vision erfolgen. Handschrifterkennungsqualität muss separat auf dem Zielgerät geprüft werden.

Quellen und Vergleich: [COMPETITOR_RESEARCH.md](COMPETITOR_RESEARCH.md).
