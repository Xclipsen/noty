# Abnahme der persönlichen Zielversion

Stand: 16.10.2026, zusammen mit SCOPE.md vom Nutzer ausdrücklich bestätigt. Dies sind **notwendige Nachweise**, keine bereits bestandenen Prüfungen. Die aktuelle App ist ein auf dem iPad bestätigter Grundprototyp; ein Teil der weiteren Funktionen existiert noch nicht.

## 1. Vollständiger Arbeitsablauf

Mit Testdaten: Ordner anlegen und umsortieren, PDF/Bild importieren, Seiten und Text/Bilder/Formen ergänzen, mit Pencil schreiben, Seiten umordnen/duplizieren, Dokument schließen und App neu starten. Alle Inhalte bleiben dem richtigen Dokument und den stabilen Seiten-IDs zugeordnet. Löschen/Papierkorb/Wiederherstellung prüfen. Lokale Quellen auch im Flugmodus verarbeiten.

PDF mit gerader und gedrehter Seite, abweichender CropBox und unterschiedlichen Seitengrößen bearbeiten. Nach Zoom, Rotation, Fensteränderung und Export liegen alle Ebenen an denselben Stellen. Ein Export enthält sämtliche sichtbaren Ebenen; Original-PDF-Text und Tastaturtext bleiben soweit technisch möglich durchsuchbar. Längere Texte werden nicht still abgeschnitten.

## 2. Schreiben und Bearbeitung

Mindestens 30 Minuten gemischtes Schreiben, Radieren, Textbearbeitung, Lasso, Formen, Bilder, Zoomen und Seitenwechsel auf dem tatsächlichen iPad. Dabei keine reproduzierbaren störenden Fokus-, Gesten- oder Darstellungsfehler. Handballen/Finger erzeugen keine ungewollten Striche; subjektives Schreibgefühl durch den Nutzer beurteilen.

Eigene Werkzeugleiste in Andock-/Schwebemodi, Umordnung und Favoriten prüfen. Strichmuster und Formen nach Speichern/Neustart unverändert und bearbeitbar. Präzisionsradierer/Ganzstrichradierer verhalten sich wie im Scope festgelegt; Text/Bilder bleiben geschützt. Gemischtes Lasso mit Filtern, Verschieben/Kopieren/Skalieren und Undo/Redo prüfen.

Externe und Bildschirmtastatur, Umlaute, Auswahl/Zwischenablage, Formatierung, Listen/Checkboxen sowie Cmd+Z/Redo/Esc testen. Breitenänderung und Platzmangel bleiben sichtbar und erhalten alle Textinhalte.

## 3. Zwei Ansichten und Suche

Gleiche und unterschiedliche Dokumente nebeneinander, jeweils unabhängiger Zoom/Seitenwechsel und eindeutiger Fokus. Änderungen im gleichen Dokument konsistent in beiden Ansichten; kein älterer Stand überschreibt den neuen. Aktive Werkzeuge bearbeiten nur die richtige Ansicht.

Suche über Namen, PDF-Text, getippten Text, eigene Handschrift, Scan-PDFs und Bilder mit repräsentativen deutsch-/englischsprachigen Testbeispielen einschließlich Fachbegriffen. Erwartete Begriffe/Fundstellen vorher notieren, tatsächliche Treffer und Erkennungsfehler vergleichen; Springen zur richtigen Seite/Position prüfen. Handschrift-/OCR-Qualität vom Nutzer am eigenen Testbestand abnehmen. Keine vollständige Erkennung beliebiger Schrift versprechen und keine stillschweigende Streichung dieser Zielfunktion.

## 4. Speicherung und Fehlerfälle

Abgeschlossene, als gespeichert bestätigte Änderungen nach erzwungenem App-Ende wieder laden. Hintergrundwechsel und Dokumentwechsel zusätzlich prüfen. Ältere asynchrone Schreibvorgänge dürfen nie neuere Änderungen ersetzen.

Mit Testdaten: Abbruch während Commit und simulierte Schreibfehler/Platzmangel. Vorheriger vollständiger gültiger Stand bleibt lesbar, keine falsche Speichermeldung, ungesicherte Daten möglichst im Speicher und Retry verfügbar. Unvollständige Revisionen erkennen. Neuere unbekannte Formate nicht überschreiben. Migration mit gesichertem Altstand und Rückweg testen.

## 5. Externes Backup und Restore

WebDAV und iCloud Drive **jeweils separat** als einziges aktives Ziel prüfen: Einrichtung/Zugriffsrechte, manueller Export, aktiver täglicher Sicherungsversuch, Zielwechsel, Fehler/Offline-Fall und Wiederholung. Mehrere ältere vollständige Stände erhalten; nicht erreichbares Ziel beschädigt keine vorhandene Sicherung. Keine feste Ausführung bei geschlossener App und keinen abgeschlossenen iCloud-Upload aus lokalem Schreiben ableiten.

Von jedem Ziel ein vollständiges **unverschlüsseltes** Backup in einen leeren isolierten Testbestand zurückholen. Ordnerstruktur, Dokumente, Quellen, Seiten, editierbare Striche, Text/Bilder/Formen und Metadaten prüfen; Inhalte anschließend weiterbearbeiten. Originalbestand bis zur erfolgreichen Validierung schützen, Konflikte als Kopie erhalten. Beschädigte Archive, unbekannte Formate, Prüfsummenfehler, übergroße Daten und unsichere Pfade ablehnen. Keine WebDAV-Zugangsdaten im Archiv.

## 6. Betrieb und Umfang

Wöchentlichen Signierungs-/Installationsweg auf Omarchy dokumentieren und mit derselben App-Identität über vorhandene Testnotizen ausführen; vorher/nachher vergleichen. Erneuerung darf keine Deinstallation des Arbeitsbestands erfordern. Erinnerung/Ablaufdatum und Offline-Verhalten prüfen.

Mit einem repräsentativen 100-Seiten-Text-PDF und einem mehrseitigen hochauflösenden Scan testen. Dateigröße, Seitengrößen, verwendetes Gerät und beobachtete Speicher-/Bedienprobleme protokollieren. Nur sichtbare/nahe Canvas-Ansichten aktiv halten und Caches begrenzen; Inhalte vor Freigabe speichern.

Danach einen Probetag mit Testnotizen durchführen und anschließend einen externen Restore nachweisen. Freigabe für den persönlichen Alltag erst bei erfülltem Scope, bestandenen Pflichtprüfungen und geklärten verbleibenden Einschränkungen. Aussagen immer nach **implementiert**, **erfolgreich gebaut**, **auf dem iPad getestet** und ggf. **vom Nutzer bestätigt** unterscheiden.


## Ergänzung 20.10.2026: native Gesetzessammlung

Diese Kriterien gehören zum bestätigten Ausbau, sind keine bestandene Geräteabnahme:

- Aktivierung aus, persönlicher Sync an, Fassungsupdates an; jeder Schalter wirkt unabhängig. Kein Loginzwang für Offline-Lesen/Markieren, keine Übertragung von Heften.
- Alle 39 aktuellen Dokumente nach Erstdownload und App-Neustart im Flugmodus lesen; optionale PDFs erhalten Originalbytes. `144 HGB`, `HGB 144`, `144 HBG`, Buchstabenzusätze/Absätze, EStR/LStR und AEAO treffen die richtige Fassung/Fundstelle.
- Slide-over über einem und zwei Heften; andocken, Breite ändern, Seiten tauschen, Rotation und schmale Fenster. Beide Hefte behalten Seiten/Zoom/Ink/Textentwürfe/Undo. Im freien Heft weiterschreiben; keine Such-Tastatur verschiebt einen fremden Cursor.
- Text-/Pencil-PDF-Markierung und Lesezeichen nach Neustart erhalten. App-/Website-Abgleich mit zwei Clients, Offlineänderungen, Wiederholungen, Logout/Kontowechsel und Löschung gegen späten Offline-Create prüfen. Lokale Daten werden beim ersten Login automatisch übernommen, fremde Kontodaten niemals neu zugeordnet.
- Ein bestätigtes E-Mail-Konto, echter Mailversand, einmalige Bestätigung und Passwortwiederherstellung auf dem produktiven Backend. Vorhandene Benutzer-IDs und Daten bleiben bei Migration erhalten.
- Gesetzesupdate zuerst serverseitig validiert/versioniert, anschließend Clientdownload. Abbruch, Prüfsummenfehler und Platzmangel erhalten den vollständigen alten Bestand; alte markierte Fassungen bleiben erreichbar. Separate persönliche Sicherung in frischen Bestand ergänzen, ohne spätere Löschungen zu überschreiben.
