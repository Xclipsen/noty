# Native Gesetzessammlung in noty – bestätigter Umsetzungsplan

Stand: 20.10.2026. Vom Nutzer nach dem Umfangsinterview bestätigt; Umsetzung im separaten Worktree autorisiert. **Im Feature-Worktree implementiert und für iPad gebaut; nicht installiert und auf dem iPad ungeprüft.** Der persönliche Markierungs-/Lesezeichensync ist auf ausdrücklichen Nutzerwunsch standardmäßig an.

## Im Interview entschieden

- Die Funktionen von `law.xclipsen.de` werden nativ in SwiftUI/UIKit/PDFKit eingebaut, nicht als eingebettete Website. Quellprojekt: `/home/la/workspace/gesetzessammlung`.
- Die Kontoanmeldung gilt appweit für noty und steht unter **Einstellungen → Konto**. Dasselbe Konto wird auf der Website verwendet; kein getrenntes Gesetzessammlungs-Konto.
- Drei getrennte Schalter in den Einstellungen: **Gesetzessammlung aktivieren**, **Lesezeichen und Markierungen synchronisieren**, **Neue Gesetzesfassungen automatisch laden**. Lesen und Suchen bleiben ohne Anmeldung möglich. Der dritte Schalter steuert nur öffentliche Gesetzesupdates, nicht den persönlichen Kontoabgleich.
- Hauptmodus: innerhalb der App schwebendes Slide-over nach dem Vorbild des iPads. Alternativ Platz neben einem Notizbuch reservieren, ähnlich der vorhandenen zweiten Heftansicht.
- Über zwei offenen Notizbüchern darf die Gesetzessammlung zusätzlich schweben. Angedockt belegt sie die zweite Ansicht; das vorher dort sichtbare Heft bleibt erhalten und wieder erreichbar.
- Gesetzestexte vollständig offline herunterladen; Original-PDFs zusätzlich nach Bedarf. Ein erster erfolgreicher Download ist Voraussetzung der Offlineverfügbarkeit.
- Gesetz auswählen und Paragraph eingeben oder direkt `144 HGB` / `HGB 144` suchen. Eindeutige vollständige Eingaben öffnen nach kurzer Tipp-Pause automatisch die Fundstelle. Ungültige oder unvollständige Eingaben erzeugen keinen willkürlichen Sprung.
- Apples native Bildschirmtastatur verwenden: Nummerntastatur für Nummern, normale Tastatur für kombinierte Suche und Zusätze wie `4a`. Keine eigene nachgebaute Zifferntastatur. Die tatsächliche iPad-Tastaturgröße bestimmt das Betriebssystem.
- Lesezeichen und vorhandene Text-/PDF-Markierungsfunktionen nativ anbieten und mit der Website in beide Richtungen abgleichen. Offlineänderungen dauerhaft lokal speichern und später übertragen.
- Anmeldung mit **E-Mail und Passwort** am bestehenden IONOS-Backend. Apple-Anmeldung ist nicht Teil dieses Ausbaus; die vorhandene kostenlose Signierung bleibt möglich.
- E-Mail-Bestätigung und Passwortwiederherstellung im Backend einplanen. Mailtransport bleibt auf ausdrücklichen Nutzerwunsch beim Rollout ausgeschaltet. Neue E-Mail-Registrierung und Recovery sind bis zur späteren Einrichtung nicht verfügbar; bestehende Namenskonten bleiben verwendbar.
- Lokale Gastmarkierungen beim ersten erfolgreichen Login automatisch übernehmen, ohne zusätzlichen Übernahmedialog. Übernahme wiederholbar und gegen Duplikate geschützt ausführen.
- Nach dem Abmelden bleiben persönliche Markierungen lokal sichtbar und verfügbar.
- Das Konto synchronisiert ausschließlich Gesetzessammlung/Lesezeichen/Markierungen, keine Notizbücher.
- Neue Gesetzesfassungen zuerst auf dem Server prüfen und versionieren, dann bei eingeschalteten automatischen Gesetzesupdates an Geräte verteilen. Bei ausgeschaltetem Schalter erhaltene Offlinefassungen weiter nutzen und Updates manuell laden können. Markierte alte Fassungen erhalten; keine Markierungen still auf geänderte Texte übertragen.
- EStR, LStR und AEAO als vollständige Dokumente importieren und sowohl nativ offline als auch auf der Website les- und durchsuchbar machen. Die vollständigen Quellen wurden importiert und geprüft; bisherige externe Links gelten nicht als Umsetzung.

## Ausgangspunkt vor der Erweiterung (Build 49 / bisheriges Website-Release)

- Noty hat bislang weder ein Benutzerkonto noch eine Serveranbindung für diese Funktion. Der Editor hält genau zwei Notizbuchansichten; ein allgemeines Begleitpanel und internes Slide-over fehlen.
- Die Website besitzt bereits versionierte Gesetzesdaten, Katalog, Prüfsummen und Deep Links mit Gesetz/Fassung/Vorschriften-ID. Importupdates werden laut Repository bisher manuell angestoßen.
- Die bisher ausgelieferte Website verwendet Nutzername/Passwort, keine E-Mail; die Erweiterung ergänzt E-Mail additiv. Die bestehende Nutzer-ID sowie ihre Lesezeichen und Markierungen müssen bei der Umstellung erhalten bleiben.
- Website-API: Cookie-Sitzungen, UUIDs für Markierungen, fassungsgebundene Daten. Noch keine belastbare geräteübergreifende Offline-Synchronisierung mit Löschständen und Änderungscursor.
- Die bisher ausgelieferte Website kann die kombinierte Suche `144 HGB` noch nicht; im Feature-Worktree ist sie ergänzt. Der Alias `HBG` → `HGB` ist bereits vorhanden und soll erhalten bleiben.
- Neben den Gesetzen existiert ein lokaler UStAE-Bestand. **EStR, LStR und AEAO sind bislang nur externe Verweise**, keine vollständig importierten Offline-Dokumente. Ihr vollständiger Import für App und Website gehört jetzt zum geplanten Ausbau.
- Nach dem Interview am 20.10.2026 per autorisiertem SSH-Zugriff ausgerollt: `noty-integration-20261020-release`, 39 öffentliche Dokumente samt nativen Prüfsummen über HTTPS bestätigt. Bestehende Konten/Sitzungen/Markierungen/Lesezeichen nach Migration exakt erhalten. Mail bleibt aus; native Geräteabnahme offen.

## Gemessener Speicherbedarf

Lokaler Inhaltsbestand am 20.10.2026: 35 Gesetze/Verordnungen plus UStAE, jeweils eine gespeicherte Fassung. Summe der tatsächlichen Dateibytes, ohne App, Suchindex, Caches, persönliche Daten oder zusätzliche Releasekopien:

- Katalog und 36 Text-JSONs: **35.673.811 Bytes = 35,67 MB = 0,03567 GB**.
- Alle 36 Original-PDFs zusätzlich: **26.387.986 Bytes = 26,39 MB**.
- Texte und sämtliche PDFs zusammen: **62.061.797 Bytes = 62,06 MB = 0,06206 GB** vor Import der zusätzlichen Handbücher.
- Zusätzlich archivierte XML-Quelldateien: 19.143.261 Bytes. Gesamtes `public/data`: **81.205.058 Bytes = 81,21 MB**. XML muss für den nativen Lesebetrieb nicht zusätzlich heruntergeladen werden.

Nach dem zusätzlichen vollständigen Import von EStR/LStR/AEAO: **39 aktuelle Dokumente**, 41.158.063 Bytes Texte/Katalog und 26.387.986 Bytes PDFs, zusammen **67.546.049 Bytes ≈ 67,55 MB**. Original-HTML-Quellen sind für Provenienz verlustfrei komprimiert separat archiviert und werden von der App nicht heruntergeladen.

GB/MB hier dezimal. Alte weitere Fassungen vergrößern den Bestand; die erste Größenmessung oben enthielt EStR/LStR/AEAO noch nicht. Komprimierte Übertragung und Dateisystembelegung sind andere Größen als diese Inhaltsbytes.

## Technische Umsetzung

Die folgenden Grenzen sind im Feature-Worktree umgesetzt. Nachweise und verbleibende Geräte-/Serverabnahme stehen in [TESTING](TESTING.md#native-gesetzessammlung--feature-worktree).

### Bestätigte Startwerte der Schalter

- **Gesetzessammlung aktivieren:** zunächst aus; ausdrücklich einschalten und Erstdownload abwarten.
- **Lesezeichen und Markierungen synchronisieren:** zunächst an; Übertragung nur nach Anmeldung und solange der Schalter an ist. Der Schalter begrenzt Netzwerkabgleich, nicht lokale Lesbarkeit oder lokale Zuordnung zum Konto.
- **Neue Gesetzesfassungen automatisch laden:** nach Aktivierung der Gesetzessammlung zunächst an, unabhängig von Login/persönlichem Sync abschaltbar. Ein ausgeschalteter Update-Schalter verhindert keine ausdrücklich ausgelösten Erst-/manuellen Downloads.

### Daten und Downloads

- Eigenständiger Gesetzesstore außerhalb der Heftpakete mit einem seriellen Eigentümer. Keine Änderung am Notebook-Schema allein für die Gesetzessammlung.
- Plattformunabhängige Modelle, Referenzparser, Validierung und Sync-Regeln im Core; native Darstellung, PDFKit, Netzwerk-/Keychain-Anbindung in `Sources/Noty`.
- Katalog und Gesetz/Fassung/Dateiprüfsummen als gemeinsamen Vertrag für Backend, Website und App verwenden. Downloads zunächst separat prüfen, erst vollständige gültige Fassungen veröffentlichen; gültigen alten Stand bei Abbruch/Platzmangel erhalten.
- Bei eingeschaltetem separatem Gesetzesupdate-Schalter automatisch nach neuen Fassungen suchen und nur neue/geänderte Inhalte laden. Keine garantierte Aktualisierung bei beendeter App versprechen; beim nächsten geeigneten Appstart fortsetzen.
- Aktuellen Lesefokus, laufende Auswahl und Markierung beim Update erhalten. Auf neuere Fassung hinweisen, ohne gerade bearbeiteten Inhalt unter dem Nutzer auszutauschen.
- Lokale Datenmenge einschließlich alter Fassungen, optionaler PDFs und abgeleitetem Index in Einstellungen anzeigen. Alte markierte Fassungen nicht durch automatische Cachebereinigung entfernen.

### Konto, Übernahme und Abgleich

- Bestehenden Node-/SQLite-Dienst erweitern; kein zweites unabhängiges Kontosystem. Website und native App erhalten denselben fachlichen API-Vertrag.
- Bestehende Konten nach authentifizierter Anmeldung um eine bestätigte E-Mail ergänzen; keine E-Mail-Adressen erraten und keine Nutzer-ID ersetzen. Native Sitzung explizit definieren; Sitzungsschlüssel im Keychain, keine Zugangsdaten in Backups/Logs.
- App spricht HTTPS; SSH ist ausschließlich der Administrationsweg. Server-/Serviceänderungen und Mailkonfiguration erst im später autorisierten Ausrollschritt mit gesichertem Altbestand durchführen.
- Gastdaten und kontogebundene Daten trotz gemeinsamer Sichtbarkeit mit stabiler Herkunft/Eigentümer-ID speichern. Nur noch nicht zugeordnete Gastdaten automatisch übernehmen. Daten von Konto A niemals beim Anmelden von Konto B erneut als Gastbestand hochladen.
- Gastdaten beim ersten Login automatisch lokal zuordnen. Persönliche Daten erst bei eingeschaltetem Markierungs-/Lesezeichen-Sync übertragen; ein Login allein übergeht den ausgeschalteten Schalter nicht. Beim Abschalten ausstehende lokale Änderungen erhalten und deren Übertragung pausieren.
- Nach Logout am bisherigen Bestand offline weiterarbeiten können; Änderungen behalten ihre Kontozuordnung und warten auf erneute Anmeldung desselben Kontos. Keine Kontozugehörigkeit allein wegen Logout entfernen.
- Persistente lokale Warteschlange, idempotente Operationen, serverseitige Revisionen/Änderungscursor und Löschmarken ergänzen. Geräteuhr nicht als alleinige Konfliktordnung verwenden. Veraltete Offlineupdates dürfen gelöschte Einträge nicht unbemerkt wiederherstellen; konkurrierende Änderungen ohne stillen Datenverlust behandeln.
- Textanker kanonisch und mit dem Website-Vertrag kompatibel halten, insbesondere UTF-16-Offsets. PDF-Markierungen mit derselben normalisierten Geometrie/Fassung speichern. Keine angenommene Text-/PDF-Übertragung ohne eindeutige Zuordnung.
- Kontosync ist kein Backup. Lokale, noch nicht synchronisierte und Gastmarkierungen müssen bei Appupdates vollständig erhalten bleiben. Vor Lieferfreigabe eine geprüfte Sicherungs-/Wiederherstellungsmöglichkeit für diesen separaten persönlichen Bestand vorsehen, ohne Sitzungen mitzusichern oder herunterladbare Daten unnötig in jedes Heftarchiv zu kopieren.

### Oberfläche und Editor

- Native Gesetzesauswahl, Textleser, Original-PDF, Inhaltsverzeichnis, Fassungswahl, Suche, Lesezeichen und Markierungen. Externe Links ausdrücklich als solche behandeln.
- Schwebendes Panel mit Griff, erreichbarer Schließen-/Andockaktion und angepasster Breite. Im unverdeckten Notizbuch weiterschreiben; Panel nicht als blockierenden Dialog umsetzen.
- Beim Andocken native Canvas-/UITextView-Instanzen, Heftmodelle, Seite, Zoom, Undo und ungesicherte Änderungen erhalten. Kein konkurrierender Heftwriter.
- Suche lokal ausführen, verzögerte alte Ergebnisse verwerfen und schnellen Eingaben nicht mit veralteten Sprüngen folgen. Nummern, Buchstabenzusätze und Absätze sowie UStAE-Abschnitte berücksichtigen.
- Tastaturfokus zwischen Suchfeld und Notizbuch eindeutig wechseln. Das Panel bei Bildschirmtastatur, Rotation und schmalen Fenstern erreichbar halten; Notizbuch nicht durch Such-Tastaturereignisse ungewollt verschieben.

## Reihenfolge und Abnahme

1. **Verträge und Datenbasis:** Fassungs-/Downloadvertrag, native Kontositzung, Kontomigration, Text-/PDF-Anker und Sync-Löschregeln festlegen. Offlinebestand und Speicherbedarf anhand echter Daten prüfen.
2. **Offlinekern:** geprüfte Erstdownloads, Wiederaufnahme, persistente Gesetzesdaten, Referenzparser und Suche einschließlich `144 HGB`, `HGB 144`, `HBG`, `4a`, Absatz und UStAE. Flugmodus und Neustart mit echten Beständen prüfen.
3. **Native Leseoberfläche und Panel:** Text/PDF, Auswahl und Markierungen, schwebend/angedockt, zwei Hefte plus Panel. SDK-Build; Tastatur, Pencil, Fokus, Rotation und Undo gebündelt am iPad testen.
4. **Backend und beide Clients:** E-Mail-Migration/Passwortwiederherstellung, persistenter Offlineabgleich, automatische Gastübernahme und Logoutbestand. Wiederholungen, Netzwerkabbruch, zwei Geräte, Löschen gegen veralteten Stand, Kontowechsel und inkompatible Fassungen testen.
5. **Versionierte Updates und Sicherung:** Serverimport vor Katalogveröffentlichung prüfen; Client-Update, beschädigte Downloads, voller Speicher und alte markierte Fassungen prüfen. Gast-/Offlinebestand sichern und unabhängig wiederherstellen.
6. **Lieferung:** SCOPE/ACCEPTANCE und betroffene Architektur-/Testdokumente mit bestätigtem Umfang aktualisieren. Core-/Backend-/Websitechecks und Hostprüfer nach betroffener Änderung, SDK-Build für UI. Serverdeployment und iPadupdate separat ausführen; vor Geräteupdate vollständige Documents-Sicherung und danach Datenvergleich gemäß ENVIRONMENT. Implementiert, gebaut, ausgerollt, installiert und tatsächlich am Gerät getestet getrennt nachweisen.

## Bestätigung

Der Nutzer hat den Gesamtplan einschließlich separater Schalter bestätigt und die Umsetzung ausdrücklich in einem anderen Worktree beauftragt. Notizbücher bleiben lokal. Serverdeployment, Mailzugang und Geräteinstallation werden getrennt vorbereitet und nach den geltenden Projektregeln ausgeführt.
