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

## App-Wechsel zieht die Ansicht zum Cursor (03.11.2026)

Nutzerbefund: Textfeld angelegt oder bearbeitet, App über Umschalter/Home verlassen, zurück: die Ansicht springt zum Textfeld bzw. Cursor. Erwartet: Zoom und Scrollposition wie verlassen; nur echte Eingabe holt den Cursor.

Codebefund (`Sources/Noty/NotebookEditor.swift`, Stand vor der Änderung): Alle Wege laufen in `revealCaret()`, das bisher nicht wusste, ob die App gerade zurückkam.

- iPadOS verkleinert/dreht das Fenster im Hintergrund für die Umschalter-Snapshots (alle vier Orientierungen in `Info.plist`). `layoutSubviews` rechnet bei jeder Größenänderung Zoom relativ zur Fitbreite und Offset um die Mitte um (L. 343–357, mit Begrenzung auf den Zoombereich der anderen Größe) und ruft danach `revealCaret()` auf (L. 378). Im schmaleren Snapshot liegt der Cursor oft „verdeckt“ und wird hereingeholt; die Rückkehr zur Originalgröße rechnet von dort weiter: Ansicht und Zoom sind verschoben.
- Die Tastatur verschwindet beim Verlassen und erscheint (bzw. die Formatleiste bei Hardwaretastatur) beim Zurückkommen: `keyboardChanged`/`keyboardSettled` (L. 657–669) rufen `revealCaret()` ohne Eingabeart auf. Liegt der Cursor dann unter Tastatur/Formatleiste und hatte der Nutzer nicht *gezogen*, scrollt noty zu ihm. Ein Pinch setzte `scrolledFromCaret` nicht (nur `scrollViewWillBeginDragging`, L. 951–952), ein nur gezoomter Cursor außerhalb des Bilds wurde deshalb immer zurückgeholt.
- Von UIKit selbst ausgelöste Cursor-/Textrückmeldungen (`textViewDidBeginEditing`, `textViewDidChangeSelection`, abgeschlossene Markierung in `TextObjectLayer.swift` L. 754/1062/796, `DocumentTextSurface.becomeFirstResponder`) gelten als `.navigation` bzw. `.typing`, setzen `scrolledFromCaret` zurück und dürfen scrollen. Ob iPadOS sie beim Zurückkommen tatsächlich sendet, ist ohne Gerätetrace **unbewiesen**; abgefangen werden sie trotzdem.

Welcher Weg am Gerät überwiegt, ist nicht per Trace belegt; die Snapshot-Größenänderung und die Tastaturrückkehr sind im Code eindeutige Wege zum Sprung.

Änderung:

- `CaretRevealGate` (Core, `CaretRevealGateTests`): Ab `UIScene.willDeactivate` bis `didActivate` kein Reveal. Danach *hält* das Tor: Tastatur-, Layout- und Seitenereignisse ohne Eingabeart verschieben nicht; eine Cursorbewegung nur, wenn seit der Rückkehr eine Berührung im App-Fenster oder ein Tastendruck kam oder das Beruhigungsfenster (1,5 s) vorbei ist; Tippen immer. Die erste solche echte Anforderung beendet das Halten. Abgelehnte Anforderungen sind verbraucht.
- `ViewportResumePoint`: Beim Deaktivieren merkt sich jeder `NotebookViewport` Größe, Zoom, Offset und Seite (nicht während Pinch, Einrasten, Wurf, Sprung). Kehrt die Größe zurück, setzt `layoutSubviews` genau diese Werte statt der Umrechnung; dasselbe beim Aktivieren und bei den Tastaturereignissen im Beruhigungsfenster, solange der Nutzer nichts berührt hat und dieselbe Seite gewählt ist.
- `UserInputClock`: passiver Fenster-Recognizer, der bei der ersten Berührung nur die Zeit notiert und sofort scheitert (kein Verzögern/Abbrechen anderer Gesten, auch nicht PencilKit/Scribble); Tastendrücke über `KeyboardRouter.handle`. Keine Positionen oder Inhalte.
- Pinch setzt `scrolledFromCaret` wie Ziehen: Wegzoomen ist Wegscrollen.

Gilt für beide Ansichten (jede Ansicht ihr eigenes Tor) und den Textdokument-Modus (gleicher `revealCaret`-Weg). Kein Schema-/Speicherwechsel. Geräteprüfung siehe TESTING.md „Ansicht bleibt nach App-Wechsel stehen“.
