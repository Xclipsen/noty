# Entwicklungsplan

Frühere Planstände (Phase 0 bis Build 46) unverändert im [Archiv](history/PLAN-ARCHIV.md). Verbindlicher Umfang: [SCOPE](SCOPE.md), Abnahme: [ACCEPTANCE](ACCEPTANCE.md).

## Eigener Worktree – native Gesetzessammlung

Bestätigter [Umsetzungsplan](LAW-INTEGRATION-PLAN.md), Branch `feat/native-law-library`. Native Offlinefunktion, Panel, Konto und Kontoabgleich implementiert; Website-/Backend-Erweiterung im isolierten Schwester-Worktree `gesetzessammlung-noty` (`feat/noty-law-integration`). EStR/LStR/AEAO importiert. Checks: [TESTING](TESTING.md#native-gesetzessammlung--feature-worktree). Website/Backend am 20.10.2026 auf IONOS ausgerollt, Bestandsdaten unverändert nachgewiesen. Mail auf Nutzerwunsch deaktiviert. Build 54 im Feature-Worktree mit aktuellem Build 53 zusammengeführt, signiert und installiert; 14 Hefte und alle 60 Dateien beim Rücklesevergleich unverändert. Build 55 nach Nutzerrückmeldung: Gesetzesfenster live ziehen, über den Rand parken mit Pfeil-Lasche; installiert, 14 Hefte und alle 100 Dateien unverändert, Bedienung am iPad ungeprüft. Build 56 nach weiterer Rückmeldung: Drag & Drop mit Zielvorschau, Blätterleiste, Markieren per Auswahl/Stift, Lesestelle je Gesetz; installiert, 14 Hefte und alle 102 Dateien unverändert, Bedienung am iPad ungeprüft. Build 57: Schriftgröße direkt in der Leiste; installiert, Daten unverändert, ungeprüft. Noch offen: Geräteabnahme und spätere Mailfreigabe. Haupt-Checkout und parallele Änderungen nicht überschrieben.

## Bisheriger Stand – Build 48: Review-Überarbeitung und UI-Feinschliff

Projektweites Review vom 20.10.2026 umgesetzt: Datensicherheit (Quarantäne statt Löschen nach Rückfall, gestufte Historie, Speicher-Wiederholung, Schema 10 für große PDFs), Backups (Streaming, Zielprüfung, Backoff, Öffnen aus Dateien), Editorleistung (Stiftpfad, Ziehen, Vorschauen, Bilder, Speicherwarnungen), Undo/Tastenkürzel, persistenter Suchindex, seitenweiser PDF-Export und Aufräumen. Dazu aus dem UI-Strang: aufgeräumte Menüs, Werkzeug-Icons, App-Icon und „Seite anpassen“ für Papierseiten (Schema 11, [PAGE-ADJUST](PAGE-ADJUST.md)). Build 47 wurde nie separat installiert. Implementiert und gebaut; **auf dem iPad ungeprüft**. Gerätetest: [TESTING](TESTING.md#gerätetest-review-überarbeitung-nach-risiko-gebündelt), [UI-POLISH](UI-POLISH.md).

## Build 49 – Editor-Korrekturen

Sechs restliche Review-Funde im Editor (Anheben mit Werkzeugwechsel, Bild-Cache, Dekodier-Wiederholung, Bildreihenfolge beim Ziehen, Werkzeugeinstellungen im Hintergrund, Strichbreite). Gerätetest: [TESTING](TESTING.md#gerätetest-build-49).

## Offen

1. Geräteabnahme Build 48/49 nach den gebündelten Listen. Fehler daraus vor neuen Funktionen beheben.
2. Abnahmekriterien aus ACCEPTANCE: externer Restore in leeren Bestand, 30 Minuten Mischbetrieb, große PDFs/Scans, Platzmangel, Flugmodus, Probetag.
3. WebDAV gegen einen echten Server prüfen. Bisher nur Host-Tests der Regeln und Antworten.
4. Effiziente Speicherung großer PDF-Quellen: jede Revision enthält die Quellen weiterhin vollständig (keine Deduplizierung über Revisionen).

Cloud-Synchronisierung von Notizbüchern, Zusammenarbeit, eigener Scanner, Audio, Handschrift-zu-Text, Tabelleneditor und KI bleiben ausdrücklich für später.

## Entscheidungen

- Name noty, Basis-Bundle-ID `de.la.noty.prototype` dauerhaft. Installierte ID und Updateweg in [ENVIRONMENT](ENVIRONMENT.md).
- SwiftUI für die App, UIKit-Brücke für PDF, Pencil und Text. Keine externen App-Abhängigkeiten. Optionales appweites Konto/Gesetzesbackend gemäß bestätigtem Ausbau; die Notizfunktionen benötigen beides nicht.
- iPadOS 17 als Minimum (xtool-Template, verwendete SwiftUI-APIs). Testgerät iPad17,1 mit iPadOS 27.
- PencilKit bleibt die native Ink-Grundlage, die Werkzeugleiste ist app-eigen.
- **Pencil-Doppeltipp/Barrel-Roll nativ (20.10.2026):** keine eigene Belegung. Der Doppeltipp folgt der Systemeinstellung (`preferredTapAction`).
- **Rückwärtskompatibilität zu Build 46:** Manifest bleibt im Build-46-Format (höchstens drei Einträge), Zwischenstände liegen getrennt in `checkpoints.json`. Ein neues Schema nur, wo ein älterer Build sonst Daten verlieren würde (Schema 10 für PDF-Quellen über 20 MB, Schema 11 für den Papier-Schreibplatz). Details: [STORAGE](STORAGE.md).
- WebDAV und iCloud Drive als wechselbare Backupziele, genau eines aktiv, Archive unverschlüsselt. Zugangsdaten im Keychain, nicht im Backup.
- Wöchentliche Signierung am PC akzeptiert. Datenerhalt ist Pflicht: vor jedem Update vollständige Sicherung und Vergleich.
