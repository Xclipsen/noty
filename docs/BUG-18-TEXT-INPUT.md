# Build 18 – Textfeld lässt sich nicht anlegen

## Gerätebefund

Erster Build-17-Texttest nicht bestanden: „ich kann nix machen mit den text feldern“. Präzisierung nach Auswahl des Textwerkzeugs und Fingertipp auf freie Seite: „Es erscheint gar kein Textfeld“. Keine Geräteabnahme der Textfunktionen/Migration. Bestehende Notizen nicht löschen oder zurücksetzen.

Vollständiger AFC-Abzug zur Untersuchung unter `/home/la/Backups/noty-text-input-18-2026-10-17T18-45-59Z/Documents/`: 18 Hefte, 32 referenzierte Revisionen gültig, 107 Dateien. Drei Hefte Schema 3, 15 Schema 2, null gespeicherte Textobjekte; 20 aktive Seiten mit altem Einzeltext. Kein Indiz für eine erfolgreich gespeicherte neue Box. Das allein erklärt noch nicht, welches UIKit-Ereignis ausbleibt.

## Codebefund und Änderung

Read-only-Review mit dem vorhandenen autorisierten Subagenten. Ebenenreihenfolge, Flächengröße und `active = editable && tool == .text` im Code plausibel. Vor der eigentlichen Einfügeaktion liegen jedoch enge Eingabegates: exakte `touch.view === self`-Prüfung und ausschließliche `.direct`-Touchtypen. UIKit kann Unteransichten als Hit-Test-Ziel liefern; Trackpad-Klicks sind keine direkten Fingertouches. Zudem schließt ein Tipp auf den dunklen Hintergrund der kompakten Seitenleiste erst deren Einblendung.

Build 18:

- Leere Nachfahren der Textebene zulassen, während vorhandene Textfelder, UITextViews und UIControls ausdrücklich ihre eigenen Eingaben behalten. Kein leeres Tippen über native Textauswahl erzwingen.
- Direkte Touches und `.indirectPointer` erlauben. ScrollView leitet Inhaltsberührung ohne die bisherige standardmäßige Verzögerung weiter; Pan-/Pinchlogik bleibt erhalten.
- Beim gewählten Textwerkzeug erscheint direkt daneben **„Textfeld +“**. Dieser Knopf fügt über den vorhandenen UIKit-/Modellweg in der sichtbaren Seitenmitte ein und ist unabhängig vom Leere-Fläche-Tapfilter.
- Begrenzte Ereignisdiagnose über OSLog-Kategorie `text-input`, Subsystem `de.la.noty`: Aktivzustand, Flächenmaße, akzeptierter Touchtyp und Einfügezähler/Position. Keine Textinhalte, Notiznamen oder Zugangsdaten loggen. Keine technischen Diagnosefelder im normalen Schreibfluss.

Die tatsächliche auslösende UIKit-Ursache auf dem Gerät ist noch nicht mit Trace bewiesen. Änderungen sind implementiert und gebaut, keine aus dem Quelltext erfundene erfolgreiche Gerätetestbehauptung.

Geprüfte Apple-Referenzen: [Hit-Testing](https://developer.apple.com/documentation/uikit/uiview/hittest(_:with:)), [Gesture-Delegate-Touchfilter](https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate/gesturerecognizer(_:shouldreceive:)-16fuh), [UIScrollView-Touchverzögerung](https://developer.apple.com/documentation/uikit/uiscrollview/delayscontenttouches).

## Prüfungen und nächster Schritt

`xtool dev build --sign --ipa`: Build 18 erfolgreich, zuerst 12,57 s; nach einheitlichem Diagnosepräfix final 7,06 s, signiert/verpackt, keine gemeldeten Warnungen/Fehler. `.tools/ios-build-text-input-18-final.log`, `.tools/Noty-build-18.sha256`. `git diff --check` bestanden. Core/Speicherung/Schema unverändert, daher letzter sinnvoller Core-Nachweis die 131 Tests und Schema-4-Hostprüfungen aus Build 17; nicht für reine UIKit-Anpassung wiederholt. Unter Linux keine UIKit-Gesten ausgeführt.

Nach Installation nur kurzer Eingangstest: Textwerkzeug wählen, „Textfeld +“ drücken und „TEXT-18“ tippen; zusätzlich einmal in freie Seitenfläche tippen. Erst wenn das funktioniert, frühere Verschieben-/Format-/Neustartprüfung fortsetzen. Wenn weiterhin kein Feld erscheint, App-Log gezielt mit `idevicesyslog --process Noty --match text-input --no-colors` erfassen (installierte Hilfe geprüft; keine Fremdprozesslogs sammeln). Unterschied Knopf/Tipp und angezeigte Meldung benennen. Kein pauschaler kompletter Wiederholungstest.

Installation inzwischen erfolgreich: Geräteabfrage bestätigt Build 18. Vor-/Nach-Sicherung unter `/home/la/Backups/noty-before-input-fix18-2026-10-17T18-49-01Z/`: alle 18 Hefte/107 vorherigen Dateien unverändert. 180 Sekunden Prozess-/Präfix-gefilterte Diagnose gestartet; Gerätetest noch offen, siehe TESTING.md.

## Ergebnis des engen Build-18-Retests

Nutzer bestätigt „ja passt und funktioniert“. Log zeigt Textmodus aktiv, Fläche 1030×742 pt, erstes eingefügtes Feld, später `Insertion touch type=0 accepted=true` und zweites eingefügtes Feld. Kein Notiztext protokolliert. Aktueller Knopf-/Fingertipp-/Eingabeweg bestätigt; die ursprüngliche Build-17-Ursache damit nicht rückwirkend einzeln bewiesen. Weiterer Text-/Neustart-/Export-/Restoretest bleibt getrennt offen.

Weiterer Gerätetest bestätigt Verschieben/Breite, Fett/Farbe/Kursiv/Unterstrichen/Größe sowie Erhalt nach Schließen/Öffnen. Echte PDF-/Backupausgabe geprüft, Schema-4-Migrationsarchiv am Gerät belegt, Host-Restore erfolgreich. Neuer externer Schema-4-Geräte-Restore einschließlich Textbearbeitung/Neustart inzwischen mit „jo hat geklappt“ bestätigt; Einzelheiten in TESTING.md.
