# Verifikation

Aktuelle Prüfwege und Nachweise ab Build 47/48. Der vollständige frühere Verlauf (Phase 0 bis Build 46, Gerätechecks, Exportartefakte, Installationsbelege) liegt unverändert im [Archiv](history/TESTING-ARCHIV.md). Ergebnisse immer als **implementiert**, **erfolgreich gebaut**, **installiert** und **auf dem iPad getestet** trennen.

## Ansicht bleibt nach App-Wechsel stehen (03.11.2026, Release-Kandidat 1)

**Implementiert und erfolgreich gebaut (`xtool dev build`, unsigniert), nicht installiert, am iPad ungeprüft.** Nutzerbefund: Textfeld angelegt/bearbeitet, App gewechselt, zurück: noty zieht die Ansicht zum Cursor. Ursachen im Code, Ablauf und Lösung: [BUG-18](BUG-18-TEXT-INPUT.md#app-wechsel-zieht-die-ansicht-zum-cursor-03112026). Core-Tests 1187 (3 übersprungen, 0 Fehler; neu `CaretRevealGateTests`, 12 Tests). Die UIKit-Ereignisfolge beim Wechsel (Tastatur, Snapshot-Größen, Ersthelfer) ist unter Linux nicht ausführbar.

Gerätetest (gebündelt, Testheft): jeweils Textfeld anlegen bzw. bearbeiten, Cursor im Feld, App über App-Umschalter und über Home verlassen, zurückkehren. Zoom und Scrollposition müssen exakt gleich bleiben, auch wenn die Tastatur jetzt etwas verdeckt. Varianten: (1) Bildschirmtastatur, Feld im unteren Drittel; (2) Hardwaretastatur (nur Formatleiste); (3) stark gezoomt und so gescrollt, dass der Cursor außerhalb liegt; (4) nur gezoomt (Pinch, ohne Ziehen); (5) zweite Ansicht offen, Text in der linken und in der rechten; (6) Textdokument-Modus; (7) Querformat verlassen, im Hochformat zurück (darf wie eine Drehung umrechnen, aber nicht zum Cursor springen). Danach: ein Zeichen tippen holt den Cursor sichtbar; Antippen einer verdeckten Stelle bzw. Pfeiltaste ebenso; Control Center herunterziehen und zurück verändert nichts; Scribble mit dem Pencil in ein Feld und normales Schreiben fühlen sich unverändert an.

## PDFs und Bilder aus dem Teilen-Menü (03.11.2026, Release-Kandidat 1)

**Implementiert und erfolgreich gebaut (`xtool dev build`, unsigniert), nicht installiert, am iPad ungeprüft.** Core-Tests 1132 (3 übersprungen, neu `IncomingFilesTests`: Typ nach Inhalt, Warteschlange, Namensvorschlag, Ziellisten, Einfügeposition mit neuen IDs und unveränderter Quelle, Eingangsordner inkl. Neustart und Reste, Anhängen an ein geschlossenes Heft mit Fehlerfällen), `check_page_workflow.sh` bestanden. Nicht belegt: ob „noty dev“ im Teilen-Menü (App-Reihe) überhaupt erscheint, für welche Quell-Apps (Dateien, Safari, Mail; Fotos zeigt erfahrungsgemäß nur Apps mit Share-Extension), Security-Scope/iCloud-Download, Präsentation über offenem Heft und Dialog, Fokus, Stift und Tastatur dabei, Kaltstart.

Gerätetest (gebündelt, Testbereich): PDF aus Dateien und aus Safari teilen → „noty dev“ in der App-Reihe? Als neues Heft in einen Unterordner, mit neuem Ordner und umbenannt; Bild (HEIC aus Dateien) als neues Heft; bei offenem Heft mit aktivem Textfeld bzw. Stift ein PDF „Hinter aktuelle Seite“ anhängen, Rückgängig, Neustart; an ein geschlossenes Heft „Ans Ende“; zwei Dateien kurz nacheinander; passwortgeschütztes PDF und Video teilen; App während des Fensters beenden → Kopie nach Neustart wieder angeboten; Abbrechen → Kopie weg.

## Texteditor 2, Prototyp (31.10.2026, Branch `phase2/spike`)

**Implementiert, Core-Tests (neu `DocumentTextLayoutTests`), `check_page_workflow.sh` und `xtool dev build` bestanden. In Build 68 installiert, am iPad ungeprüft.** Belegt sind die reinen Regeln gegen einen Festbreiten-Ersatz; **nicht** belegt sind TextKit über mehrere Container, `UITextInteraction`, Eingabesystem, Zeichnen und alles Sichtbare. Mit dem Schalter aus nur Typänderungen im Router und `TextRuling.lineBaseline` statt der gleichen Formel in `RuledTextLayout`. Gerätetest: [TEXT-EDITOR-2](TEXT-EDITOR-2.md#gono-go-am-gerät).

## Rückgängig für alle Operationen (31.10.2026, Branch `phase0/undo`)

**Implementiert, Core-Tests (neu `UndoReliabilityTests`), `check_page_workflow.sh` und `xtool dev build` bestanden. In Build 68 installiert, am iPad ungeprüft.** Die Tests belegen Verlauf, Stände und Hinweisdaten; **nicht** belegt sind Ansichtsaktualisierung, Canvas und Gesten. Der Fall des Nutzers ist nicht am Gerät nachgestellt.

Gerätetest (gebündelt, Testheft): Text mit dem Lasso auf der Seite, auf eine andere Seite und auf die Reserveseite verschieben, je Rückgängig und Wiederholen, Auswahl dabei aktiv lassen; dasselbe mit Handschrift und gemischter Auswahl; im Textdokument ein freies Feld; Text mit dem Finger bei aktivem Stift. Mit dem Textwerkzeug tippen, in die Seite tippen und leer verlassen, danach Rückgängig: der echte Schritt davor kommt zurück. Rückgängig während eines Bildimports: Hinweis.

## Build 69 · Helix-Erweiterungen, Tastatur in Panels, Textdokument-Extras (31.10.2026, Branch `extras/build69`)

**Implementiert und erfolgreich gebaut, am iPad ungeprüft.** Core-Tests (1014, 3 übersprungen), `check_page_workflow.sh`, `check_verifiers.sh` und `xtool dev build` bestanden. Vergleich gegen echtes Helix 25.07.1: 2400 Zufallsabläufe, 37 Differenzen, alle in der Abweichungstabelle von [KEYBOARD](KEYBOARD.md) oder bekannte Fälle am Textende. `.docx` und `.rtf` strukturell und in LibreOffice geprüft, **nicht** in Word oder Pages. Unabhängiges Review ohne Datenverlust-Befund, seine Befunde sind behoben; `SettingsView`, `NotebookCreationView`, `NotebookDefaultsView`, `RestoredCopiesView`, `LocalHistoryView` und `ExternalBackupView` wurden dabei nicht im Detail geprüft.

**Offener Gerätebefund aus Build 68:** Esc im Text führte am iPad laut Nutzer nicht zu `NOR SEITE`. Heft oder Textdokument und Anzahl der Drücke sind unbekannt. Aus dem Code bewiesen sind drei Dinge: Der Weg braucht nach `i` und Tippen drei Drücke, zweimal bleibt die Anzeige `NOR`. Ein hängender `handoff` hielt `editing` bis rund 1,75 s, Esc lief dann ins Leere. Texteditor 2 mit fixiertem Textwerkzeug hielt danach keinen Fokus. Beide Lücken sind behoben, ob das der Befund war, ist **ungeprüft**. Zuerst testen, mit Diagnose: `idevicesyslog | rg noty.keys`.

Gerätetest: [KEYBOARD](KEYBOARD.md#gerätetest-gebündelt-alles-ungeprüft) und [TEXT-REBUILD-62](TEXT-REBUILD-62.md), Abschnitt „Extras Textdokument“.

## Build 68 · Tastaturmodus, Review-Korrekturen (31.10.2026, Branch `feat/tastatur`)

**Implementiert, erfolgreich gebaut und installiert, am iPad ungeprüft.** Rücklesen nach dem Update: installierte App-ID unverändert, alle 28 Dokumente und 256 Dateien unverändert. Der Simulator-Lauf 41216955235 hat alle sechs Smoke-Tests bestanden (wiederholte Tasten, `gg`, `ge`, Which-Key, Esc-Ebenen), rot nur durch das 20-Minuten-Limit des Schritts; er prüfte den Stand von Build 67, **nicht** Build 68 und **nicht** echte Tastatur und Fokus am iPad. Gerätetest: [KEYBOARD](KEYBOARD.md#gerätetest-gebündelt-alles-ungeprüft), Editor 2: [TEXT-EDITOR-2](TEXT-EDITOR-2.md).

## Build 67 · Tastaturmodus wie Helix (31.10.2026, Branch `phase1/app`)

**Implementiert, Core-Tests und `xtool dev build` bestanden. Nicht installiert, am iPad ungeprüft.** Die App läuft vollständig auf `HelixKeymap`, `HelixParser` und `TextEngine`, der Vim-Modus ist entfernt (`KeyMap`, `KeySequenceParser`, `TextMotions`). Getestet sind Engine (gegen echtes Helix, siehe [KEYBOARD](KEYBOARD.md#helix-modell)), Tastentabelle, Parser, `KeyPressGate`, mehrere Edits über Seiten; **nicht** getestet sind Tastenzustellung, Fokus, Palette über Text, Eingabezeile, Which-Key, TextKit-Messung von `j`/`k` und alles Sichtbare. Gerätetest: [KEYBOARD](KEYBOARD.md#gerätetest-gebündelt-alles-ungeprüft).

## Build 65 · Textdokument, ⌘A, Tastaturmodus (31.10.2026)

**Implementiert, erfolgreich gebaut und installiert, am iPad ungeprüft.** Rücklesen nach dem Update: alle 28 Dokumente und 248 Dateien unverändert. Core-Tests (neu `TextFlowRangeTests`, `KeyboardCommandsTests`, `TextMotionsTests`), `check_page_workflow.sh`, `check_verifiers.sh` und `xtool dev build` bestanden. Getestet sind Keymap, Parser, Motions und Bereichsbearbeitung; **nicht** getestet sind Tastenzustellung, Fokus, TextKit-Messung und alles Sichtbare. Gerätetest: [KEYBOARD](KEYBOARD.md#gerätetest-gebündelt-alles-ungeprüft).

## Build 90 · Zweite App „noty dev“ (02.11.2026)

**Implementiert, Core-Tests und `xtool dev build` bestanden, an „noty dev“ veröffentlicht. Installation und alles am iPad ungeprüft.** Ab jetzt gehen Builds an „noty dev“ (`de.la.noty.dev`, eigene Daten, oranges Icon, eigene Installationsseite). Die normale noty (`de.la.noty.prototype`) bleibt auf Build 89 und bekommt einen Build nur mit `NOTY_CHANNEL=stable`. Inhaltlich neu ist nur der richtige Seitenname in der Meldung des Backup-Knopfs. Weiter Debug-Build, Release ist zurückgestellt. Beide Apps melden dieselben Dateitypen `.noty`, `.notybackup`, `.notylibrary`; welche beim Öffnen einer Datei angeboten wird, entscheidet iPadOS (ungeprüft).

## Build 89 · Lineal wie ein echtes Lineal, Backup-Knopf (02.11.2026)

**Implementiert, Core-Tests und `xtool dev build` bestanden, veröffentlicht. Installation und alles am iPad ungeprüft.**

Nutzer zu Build 88: Man konnte durch das Lineal malen, der Strich sollte an der Linie weitergehen. Ursache: Nur Striche, die nahe der Kante begannen, liefen über den eigenen Weg, alle anderen über PencilKit, das einen laufenden Strich nicht aufhalten kann. Jetzt läuft bei eingeblendetem Lineal jeder Strich mit Stift, Bleistift und Marker über den eigenen Weg: Er gehört zu der Seite des Lineals, auf der er beginnt (`NotebookRuler.side`), bleibt dort frei und gleitet an der Kante entlang (`NotebookRuler.kept`). Mit Lineal entfallen dafür die PencilKit-Livedarstellung, Halten-für-Form und gerader Marker. Die Vorschau ist eine einfache Linie, der fertige Strich ist PencilKit-Tinte aus den echten Stiftpunkten mit gleichmäßiger Breite. Ohne Lineal ändert sich nichts.

Neu: Knopf „Backup jetzt speichern“ oben rechts in der Bibliothek, nur in Prototyp-Builds, derselbe Weg wie das manuelle Backup in den Einstellungen. Autosave und Backup bleiben getrennt. Der neue WebDAV-Dienst liegt auf dem Server, nicht im Repo.

Gerätetest: von weit weg gegen die Kante und an ihr entlang zeichnen, an beiden Seiten und schräg, mit allen drei Werkzeugen; auf dem Lineal beginnen; Text neben dem Lineal schreiben und das Schriftbild mit dem Ergebnis vergleichen; Rückgängig; ein Strich über den Seitenrand; erstes echtes Backup auf den Server.

## Build 88 · Eigenes Lineal (02.11.2026)

**Implementiert, Core-Tests (neu `NotebookRulerTests`) und `xtool dev build` bestanden, veröffentlicht. Installation und alles am iPad ungeprüft.**

Nutzer zu Build 87: Lineal nicht verschiebbar, es verkleinert sich mit dem Zoom. Ursache der Größe ist belegt: Das PencilKit-Lineal liegt in der Zeichenfläche, die noty beim Zoomen skaliert, und PencilKit bietet dafür keine Schnittstelle. Warum es sich nicht verschieben ließ, ist nicht geklärt. Die Erkennung lief über private Klassennamen und ging ohnehin nur bei aktivem Stift oder Radierer.

Das Lineal ist jetzt eine eigene Ansicht über den Seiten (`NotebookRuler`, `RulerOverlay.swift`), fest in Viewport-Punkten. Ein Finger verschiebt es, zwei drehen es, nahe an Vielfachen von 15° rastet es ein. Das geht mit jedem Werkzeug, auch während einer Sperre. Ein Finger auf dem Lineal scrollt deshalb nicht mehr. Ein Strich, der nahe einer Kante beginnt, folgt ihr live und wird beim Abheben zu einem normalen PencilKit-Strich mit einem Rückgängig-Schritt (`WorksheetView+Ruler.swift`, in Build 89 auf alle Striche erweitert). Er hat die Breite des Werkzeugs ohne Druckverlauf und endet am Seitenrand. Das erfüllt zugleich den Wunsch aus [DEVICE-FEEDBACK-20](history/DEVICE-FEEDBACK-20.md), am Lineal zu gleiten. Die privaten `require(toFail:)`-Abhängigkeiten von Scrollen und Zoom sind entfernt. Position und Winkel liegen in `UserDefaults`, nicht in Heft oder Backup.

Gerätetest: Lineal einblenden, zoomen (Größe bleibt), mit einem Finger verschieben, mit zwei drehen, mit Stift, Bleistift und Marker an beiden Kanten zeichnen, Rückgängig, ein Strich über den Seitenrand, normales Schreiben daneben ohne spürbare Verzögerung, Finger-Zeichnen, Neustart (Position bleibt). Die Annahme, dass die Canvas ohne Wartezeit startet, wenn beide neuen Recognizer sofort scheitern, ist nur am Gerät prüfbar.

## Build 87 · Fehler aus der Logik-Prüfung (02.11.2026)

**Implementiert, Core-Tests und `xtool dev build` bestanden, veröffentlicht. Installation und alles am iPad ungeprüft.**

- **Rechner:** `0.125*8` ist 1, `-2^2` ist -4, `2^3^2` ist 512, `.5+1` ist 1,5. Mit Variablen, Einheiten oder Funktionen vor der Rechnung (`2x + 3 + 4`, `x^2+3`, `a - 2 - 3`, `sin(30+60)`, `10 € + 5 + 3`, `2 (3+4)`) entsteht kein Ergebnis mehr. Von oben nach unten: `+10%` ist Prozent der Zahl darüber, `x + 3` ist kein Name. `1.234` bleibt die deutsche Schreibweise für 1234. Das Ergebnis ist ein eigener Rückgängig-Schritt, und die Sonderregel für die Ziffer hinter dem Ergebnis endet, sobald der Cursor geht.
- **PDF-Export:** Beim Zusammensetzen bleibt das Dokument der Einzelseite am Leben. Der Absturz war nie beobachtet, der Fehler nur aus dem Code bewiesen. Export mit `pdfinfo`, `pdftoppm`, `pdftotext` am Gerätestand ungeprüft.
- **Neuer Texteditor:** `DocumentTextStore.capacity` kennt den Seitenanfang nun aus der Seite, nicht aus der Textlänge, weil Build 81 nur noch einen Teil misst. Stimmt der Text nicht, misst wie bisher das Modell.
- **Listennummern:** Beim Tippen über mehrere Seiten wird nur noch die wirklich geänderte Stelle verglichen. Vorher galt alles hinter der Seite als geändert, weit entfernte Nummern änderten sich still. `3. Mai` / `10. Juni` bleiben stehen (Monatsnamen, Heuristik), Return bei `1. |abc` teilt den Punkt.
- **Hängen:** Eine vom System abgebrochene Griff-Bewegung (etwa durch eine Sperre beim Sichern) räumt sich auf, die Werkzeugoptionen kommen zurück. Bei Sperre und „Auch mit dem Finger zeichnen“ sowie im Lesewerkzeug scrollt ein Finger. Ein Seitenwechsel während einer Sperre wird nachgeholt statt vergessen. Das Verkleinern beim Bildimport hat das Zeitlimit von 120 s. Ob einer dieser Punkte der Hänger des Nutzers war, ist **unbewiesen**.
- **Speichern:** Ein beschädigtes oder fehlendes Bildoriginal blockiert den Commit weiter (bewusst, Tests), wird aber nicht mehr endlos wiederholt. Beim Schließen bietet noty „Ohne Speichern schließen“ an, der letzte Stand bleibt. Das gilt für alle dauerhaften Speicherfehler. Werkzeugeinstellungen blockieren das Schließen nicht mehr. Ein spät gemeldeter Stiftstrich während eines Backup-Commits wird nachgetragen. `closeAll` wartet auf laufendes Bildlesen.
- **iCloud-Backups:** Noch nicht hochgeladene Archive ersetzen nichts: `keep` hochgeladene bleiben daneben, von den wartenden nur die `keep` neuesten. Bewertet über `ubiquitousItemIsUploaded`, andere Anbieter melden nichts und bereinigen wie bisher. Verhalten mit vollem iCloud ungeprüft.
- **Bild als Seite:** Durchsichtige Bilder werden nicht mehr zu JPEG. Sehr lange Bilder bekommen eine schmalere Seite (PDF-Grenze 14.400 pt). Das Original bleibt bewusst nicht im Heft, das widerspricht weiter der Regel in `AGENTS.md`; der Dialog sagt es.
- **Sonst:** Einfügen und Ausschneiden im Neuen Texteditor beenden zuerst eine laufende Komposition. `keyboardScrolling` bleibt am Seitenende nicht mehr stehen.

**Nicht behoben:** Abhängigkeit des Scrollens von den Lineal-Gesten (entfällt mit Build 88). Pfeil oder Rückgängig, während das Blatt noch nachgleitet, nutzen die alte Seite. `elasticMinimum` bei Abbruch des Zooms, Tippen während eines Feld-Zugs, `pdfSources` mit `deletedPages` nil (nur Fremddateien), AirDrop-Inbox beim Abbrechen, `selectedPageID` nach Papierwechsel auf dem Entwurf.

Gerätetest: Rechentabelle oben; ein Griff-Zug der Leiste während eines Backups; ein Export mit Bild und PDF-Seite; Textdokument mit mehr als 8192 Zeichen über mehrere Seiten; Liste über eine Seitengrenze.

## Build 86 · Zeitlimit für PDF- und Bild-Import (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** Core unverändert, `ota_check` ohne Befund. Nutzer zu Build 85: Ein Finger scrollte nicht mehr und die Werkzeugleiste ließ sich nicht öffnen; nach dem Neustart der App ging alles wieder, vermutlich nach einem Bild-Import. **Ursache nicht belegt.** Eine hängende Bearbeitungssperre erklärt die Leiste, das Ein-Finger-Scrollen aber nur zusammen mit „Auch mit dem Finger zeichnen“. Das Einfügen und Importieren von PDFs und Bildern als Seite endet jetzt wie das Bild-Einfügen nach 120 s mit Meldung und gibt die Sperre frei. Gerätetest: Bild und PDF aus iCloud importieren, die noch nicht geladen sind, auch ohne Netz.

## Build 85 · Neue Textfelder in automatischer Farbe (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** Core unverändert, `ota_check` ohne Befund. Nutzer: Text soll standardmäßig automatisch gefärbt sein, abschaltbar. Neue Felder starten in der automatischen Farbe, auch wenn zuletzt eine Farbe gewählt war; Schrift und Größe werden weiter übernommen. Schalter in Einstellungen › Editor, Standard an; aus: Die zuletzt benutzte Farbe wird wie bisher übernommen. Eine Farbwahl gilt für das Feld, bestehender Text bleibt unverändert. Gerätetest: Weiß wählen, neues Feld auf einem PDF ist schwarz; Schalter aus, neues Feld übernimmt die Farbe.

## Build 84 · Textfelder mit dem Trackpad verschieben (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** Core unverändert, `ota_check` ohne Befund. Nutzer: Felder sollen sich leichter mit dem Zeiger verschieben lassen. Rahmenzone und Breitengriffe hatten nur die plattformabhängige Vorgabe für Berührungsarten; sie erlauben jetzt ausdrücklich auch den Zeiger. Ein nicht geöffnetes freies Feld zieht der Zeiger direkt am Text (`FieldPointerDrag`), über der Rahmenzone eines geöffneten Felds zeigt er Verschiebepfeile. Gerätetest: mit Textwerkzeug nicht geöffnetes Feld am Text ziehen, geöffnetes am Rahmen ziehen, Breitengriffe, Text im geöffneten Feld mit dem Zeiger markieren, Klick öffnet weiter, Zwei-Finger-Scrollen über Feldern, Fluss-Text bewegt sich nicht.

## Build 83 · Ergebnis in der Schreibweise der Rechnung (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** 0 Fehler in den Core-Tests. Nutzer zu Build 82: `2+5=` wird `2+5=7`, `2 + 5 =` wird `2 + 5 = 7`. Abstände stehen, wenn die Rechnung oder das Gleichheitszeichen welche hat. Von oben nach unten bleibt `= 7`.

## Build 82 · Eigener Rechner, Bilder als Seite (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** 1044 Core-Tests, 3 übersprungen, 0 Fehler; `ota_check` ohne Befund. Enthält Build 81, der nie installiert wurde.

- **Rechner (`TextCalculator`):** Ersetzt die Rechenhilfe von iPadOS, `MathResultSpacing` entfällt. `2+3=` wird zu `2+3=5` (seit Build 83), nur am Zeilenende und nur bei einer echten Rechnung. Von oben nach unten: Zahlen untereinander, `=` allein in einer neuen Zeile; ohne Zeichen wird addiert, Zeilen zählen der Reihe nach wie am Taschenrechner, Trennlinien werden übersprungen, Text vor der Zahl ist Bezeichnung, ein früheres Ergebnis rechnet weiter. Direkt hinter dem Ergebnis ersetzt eine Ziffer es, Backspace nimmt die ganze Zahl weg (nicht im neuen Texteditor). Schalter in Einstellungen › Editor, Standard an. Dezimalzahlen, höchstens zehn Nachkommastellen, deutsche Schreibweise. Gerätetest: Ergebnis erscheint, kein Vorschlag von iPadOS mehr, Undo, Leerzeichen hinter dem Ergebnis, Textdokument mit Seitenwechsel.
- **Bild als Seite (`ImagePagePDF`):** Beim PDF-Import in Bibliothek, Seitenleiste und „Neue Seite“ lassen sich auch Bilder wählen. Sie werden zu einem einseitigen PDF in Seitenbreite 595, kein Formatwechsel; JPEG und HEIC werden mit Qualität 0,9 neu kodiert, das Original bleibt also nicht bytegleich erhalten, PNG bleibt verlustfrei, höchstens 4096 Pixel. Das Bild wird nur auf dem Gerät erzeugt und ist nicht getestet. Gerätetest: Screenshot, Hochkant-Foto mit Drehung, PNG mit Transparenz; Schreibplatz, Vorschau, Backup und PDF-Export.

## Build 81 · Importe, PDF-Export und lange Texte (02.11.2026)

**Implementiert und gebaut, nicht installiert, am iPad ungeprüft.** 1035 Core-Tests, 3 übersprungen, 0 Fehler. Die übrigen Punkte der Durchsicht vom 02.11.2026.

- `TopAlert`: Ein stillschweigend gescheitertes `present` wird wiederholt, sonst antwortet die Rückfrage mit Abbrechen statt ewig zu warten. `dismiss` wartet das Einblenden ab und hat eine Obergrenze von 2 s.
- Bild einfügen: Das Holen von Zwischenablage, Fotos oder Datei läuft vor der Bearbeitungssperre und endet nach 120 s mit Meldung. Schließen wartet solange. PDF-Einfügen und Bibliotheksimport bleiben ohne Zeitlimit.
- PDF-Export: Seiten und Ergebnis liegen als Dateien im temporären Ordner, das Ergebnis wird gemappt. **Geräte-PDF mit `pdfinfo`, `pdftoppm` und `pdftotext` prüfen: ungeprüft.** Der Speicherbedarf ist nicht gemessen.
- Textfluss: Je Seite wird nur ein Anfangsstück gemessen und bei Bedarf verdoppelt (`TextFlowMeasure`, Tests für gleiche Aufteilung). Die Annahme, dass Text hinter dem Schnitt die vollen Zeilen nicht ändert, gilt ab einem Viertel Abstand; TextKit wurde dafür nicht am Gerät verglichen.

Gerätetest: `.noty` mit gleichem Titel importieren; sehr kleine `.noty` öffnen; Bild aus Zwischenablage bei getrenntem zweiten Gerät; Heft mit vielen Fotos als PDF exportieren, Seitenzahl, Links, Text und Bilder gegen Build 80 vergleichen; langes Textdokument bearbeiten, Seitenumbrüche gegen Build 80 vergleichen.

## Build 80 · Keine Eingabesperre beim Backup, Absicherungen (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** 1032 Core-Tests, 3 übersprungen, 0 Fehler; `ota_check` ohne Befund. Aus der Durchsicht vom 02.11.2026; Nutzer hat ein iCloud-Backup eingerichtet, die Sperre ist damit als Ursache des Einfrierens wahrscheinlich, aber nicht belegt.

- Während des Backup-Speicherns deckte die Aktivierungsebene den ganzen Editor ab. Sie erscheint jetzt nur noch über einer anderen Ansicht als der aktiven (`isPaneSelected`). Die Leisten bleiben in dieser Zeit gesperrt, Eingaben ebenso (`canEdit`, Zeichenfläche und Textebene aus), Scrollen geht.
- Das Scrollen hängt nicht mehr an `enabled`: Beim Textwerkzeug blieb der Stift sonst in dieser Zeit ohne Scrollen.
- „Seite anpassen“: Der Reglerbereich bleibt gültig, wenn Inhalt über den Schreibplatz hinausragt (`minimum` größer als die Größe).
- Hänger-Diagnose: Der Stapelpuffer wird beim Start angelegt statt bei angehaltenem Hauptthread, und Leerlauf zählt nicht mehr als Hänger.

Gerätetest: Während eines Backups das Blatt verschieben, dafür „Jetzt sichern“ auslösen und ins offene Heft wechseln; „Seite anpassen“ auf einer Seite mit Inhalt am äußeren Rand des Schreibplatzes; `haenger.txt` enthält im Leerlauf nur die Startzeile.

## Build 79 · Seitenwechsel erst, wenn die Ansicht ruht (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** 1032 Core-Tests, 3 übersprungen, 0 Fehler; `ota_check` ohne Befund. Nutzer zu Build 78: kleiner Ruckler beim Scrollen zwischen den Seiten. Beim Überqueren der Naht wechselte die Auswahl sofort; das rechnet den Editor neu und richtet zwei Seiten vollständig neu ein, weil sich `focused` ändert. Die Ursache ist aus dem Code abgeleitet, nicht am Gerät gemessen. Jetzt wechselt die Auswahl erst 0,18 s nach der letzten Bewegung, überflogene Seiten werden nicht ausgewählt. Dadurch folgen Seitenzahl und Seitenleiste erst beim Anhalten. Gerätetest: zwischen zwei Seiten hin und her scrollen, Seitenzahl nach dem Anhalten, sofort nach dem Anhalten schreiben, Seite über Seitenleiste wählen.

Nutzer zu Build 78: „Über noty“ friert nicht mehr ein. Warum, ist nicht belegt; geändert wurde nur, dass die Diagnose-Schalter dort entfernt wurden.

## Build 78 · Diagnose für das Einfrieren (02.11.2026)

**Implementiert, Fehler nicht behoben.** Nutzer: Nach dem Umschalten des Schreibscrollens reagierten Blatt und Icons nicht mehr, früher auch mit anderem Auslöser; „Einstellungen › Über noty“ friert reproduzierbar ein. **Ursache offen.** In den Seiten-Bausteinen ist beim Lesen keine Schleife zu finden. Die Hänger-Diagnose schreibt jetzt auch nach `Documents/Diagnose/haenger.txt` (nur Adressen und Zähler, höchstens 2 MB, danach neu begonnen) und nimmt eine vierte Probe nach 10 s. Ihre Schalter stehen auf einer eigenen Seite „Einstellungen › Diagnose“. Offener Kandidat aus der Durchsicht vom 02.11.2026: Während `EditorWorkspace.closing` (Backup-Commit, zweite Ansicht) ist `isPaneActive()` falsch, die durchsichtige Ebene in `ContentView` deckt dann Blatt und Leisten ab. Das blockiert Berührungen ohne Hänger; ob es der beobachtete Fehler ist, ist nicht belegt. Gerätetest: Hänger-Diagnose an, App neu starten, einfrieren lassen, 15 s warten, App beenden, Datei schicken. Bleibt „Über noty“ ohne die Diagnose-Schalter frei, lag es an diesen.

## Build 77 · Schneller Wisch zieht nicht mehr seitlich (02.11.2026)

**Implementiert, gebaut, erstmals auf dem eigenen Server signiert und über den Link installiert. Nutzerbestätigung 02.11.2026: „viel besser“; das Haken und die Einzelfälle des Gerätetests sind damit nicht einzeln bestätigt.** 1032 Core-Tests, 3 übersprungen, 0 Fehler; `ota_check` ohne Befund. Nutzerbilder IMG_0356–0358: Build 76 behob den Sprung nicht. **Ursache belegt:** Beim Loslassen begrenzte noty das seitliche Ziel mit dem Bereich am Zielort des Wischs (`scrollViewWillEndDragging`). Die leere Seite am Heftende hat keinen Schreibplatz und erlaubt nur die PDF-Mitte; landete der Wisch dort, glitt die Ansicht vom ersten Bild an dorthin und blieb bei gestopptem Wisch auf halbem Weg stehen. Jetzt gilt der Bereich am aktuellen Ort, ein überwiegend senkrechter Wisch bewegt nicht seitlich (`flickTargetX`, neue Tests). Beim Erreichen der schmalen Seite gleitet die Ansicht weiterhin zu ihr. Das Haken beim Seitenwechsel ist nicht geklärt. Gerätetest: im Schreibplatz schnell nach unten wischen und anhalten, Blatt bleibt seitlich stehen; bis auf die leere Seite scrollen und zurück.

## Build 76 · Kein Sprung beim schnellen Scrollen (02.11.2026)

**Implementiert, gebaut und über den Link installiert (Nutzerbestätigung 02.11.2026). Der Sprung blieb, siehe Build 77.** 1030 Core-Tests, 3 übersprungen, 0 Fehler; SDK-Build erfolgreich, erstmals auf dem eigenen Server. Nutzerbild IMG_0349: Beim schnellen Scrollen über den Schreibplatz sprang die Ansicht an der Naht zweier Seiten nach links zur Mitte. **Ursache nicht bestätigt.** Behoben sind zwei belegte Wege: Eine verspätete Antwort auf eine eigene Seitenmeldung galt als Seitenwechsel von außen und setzte das PDF per Sprung in die Bildschirmmitte (`ScrollSelectionEchoes`, neue Tests in `NotebookViewportGeometryTests`). Und Tastatur-, Layout- und Seitenereignisse holten die Ansicht nach dem Scrollen zum Cursor eines offenen Textfelds zurück; das tun jetzt nur noch Tippen und Cursorbewegung. Gerätetest: im Heft mit Schreibplatz mehrfach schnell über die Seitennaht hin und zurück, einmal ohne und einmal mit offenem Textfeld; Tippen nach dem Wegscrollen holt die Ansicht zurück; Seite über Seitenleiste und Seitenzahl springt weiter.

**Gleiche Schriftgröße auf PDFs, im selben Build.** Nutzer: Text soll auf eingefügten PDFs so groß sein wie auf normalen Seiten und auf dem Schreibplatz. Freie Felder auf PDFs speichern ihre Größe in PDF-Einheiten, auf breiten Scans erschien 14 deshalb winzig (Nutzerbild: 43). Formatleiste, A−/A+, Absatzstile, „Formatierung entfernen“ und neue Felder rechnen jetzt in Normalseitenpunkten (`TextSizeUnits`, Faktor PDF-Breite/595). Kein Formatwechsel: Gespeichert bleibt 8–96 in PDF-Einheiten, bestehende Felder sehen unverändert aus, nur die angezeigte Zahl ändert sich. Grenzen: Auf breiten Scans endet die sichtbare Größe bei 96 geteilt durch den Faktor, auf sehr kleinen PDFs beginnt sie bei 8 geteilt durch den Faktor. Text behält beim Einfügen und beim Verschieben zwischen Seiten sein bisheriges Verhalten. Gerätetest: neues Feld auf Scan und Normalseite gleich groß, 43er-Feld zeigt etwa 14, A+/A− ein Schritt, Titel, „Formatierung entfernen“, Vorschau und PDF-Export.

## Build 75 · Ein Tab-Raster je Feld (02.11.2026)

**Implementiert, gebaut und über den Link installiert (Nutzerbestätigung 02.11.2026), Tab-Raster am iPad ungeprüft.** Nutzerbild IMG_0343: Zeilen mit Tab am Anfang standen auf einem anderen Raster als Zeilen mit Text davor. Der Abstand hing an der Schriftgröße des ersten Zeichens der Zeile, und eine Größenänderung ließ im offenen Feld den alten Abstand stehen. Jetzt gilt je Feld ein Raster nach der größten Schrift (`TextTabs.interval(_:)`), in Editor, Vorschau und PDF. Im Textdokument gilt es je Seitenabschnitt. Gerätetest: Zeile mit Tab am Anfang und Zeile mit Text und Tab auf denselben Stopp, Schriftgröße ändern, Feld verlassen und wieder öffnen.

## Build 74 · Mehrzeilige Textauswahl (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** Nutzerbilder IMG_0341/0342: Bei einer Auswahl über mehrere Zeilen waren nur erste, letzte und eine mittlere Zeile markiert. Ursache: UIKit meldet die Zeilen dazwischen als ein Rechteck, `selectionRects` kürzte es auf die Zeile in seiner Mitte. Jetzt je Zeile ein Band. Kein Core-Test möglich (UIKit). Gerätetest: Auswahl über drei und mehr Zeilen mit Leerzeilen, Griffe ziehen, im Heft und im Textdokument.

## Build 73 · Leerzeichen vor dem Rechenergebnis (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** Das Rechnen nach „=“ kommt von iPadOS, die App kann es nur ein- oder ausschalten. `MathResultSpacing` erkennt die Einfügung nach der Textänderung und ergänzt das Leerzeichen; von Hand getippte Ergebnisse gelten mit. Ungeprüft ist, ob iPadOS das Ergebnis über den normalen Änderungsweg einfügt und ob die Rechnung danach weiterläuft. Gerätetest: `2+3=` mit angenommenem Vorschlag im Heft und im Textdokument, danach Undo; der neue Texteditor (Test) ist nicht angebunden.

## Build 72 · Tabstopps ohne Ende (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** Nutzer: Tab kam im Textfeld nur bis etwa zur Mitte und brach dann um. Ursache: Ohne eigene Stopps gelten die zwölf Stopps von iOS bis 336 pt. Jetzt ein gleichmäßiges Raster von 2,5 Schriftgrößen ab linker Textkante (14 pt: 35 pt), gemeinsam für Editor, Vorschau und PDF, kein Formatwechsel; der Bestand vom 31.10.2026 enthielt keine Tabs. Automatische Feldbreite wächst bis zum Stopp mit. Gerätetest: Tab bis zum rechten Rand im Heft und im Textdokument, zwei Zeilen mit Tabs stehen in einer Spalte, ⇧Tab, mehrere Zeilen markieren und Tab, PDF-Export gleich wie Editor.

## Build 71 · Helix experimentell, nur in Textdokumenten (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** Ein Schalter in Einstellungen › Editor, Standard aus. Gerätetest: Schalter aus, im Textdokument und im Heft normal tippen, kein INS-Hinweis; Schalter an, im Textdokument Esc und `i`, im Heft und in der Bibliothek keine Helix-Tasten; zwei Ansichten mit Textdokument und Heft, beim Wechsel der aktiven Ansicht tippt das Heft normal.

## Build 70 · Textfelder erreichbar, Update unterwegs (02.11.2026)

**Implementiert, gebaut und auf dem Server bereitgestellt, nicht installiert, am iPad ungeprüft.** 1014 Core-Tests, 3 übersprungen, 0 Fehler; SDK-Build erfolgreich; IPA-ID und Profil geprüft (`scripts/ota_check.py`), Download über HTTPS geprüft. Enthält Build 69 und die Bedienfluss-Durchsicht.

Nutzer: Felder rechts unten auf einer Scan-Seite lassen sich weder antippen noch per Zeiger erreichen, die übrigen schon. **Ursache nicht bestätigt.** Behoben sind drei belegte Mechanismen: gespeicherte leere Felder fingen Berührungen im ganzen Rahmen ab (im Geräteabzug vorhanden, teils seitengroß), ein nicht endender Zeiger-Touch sperrte die Tipp-Erkennung eines Felds dauerhaft, die Griffzone des bearbeiteten Felds verdeckte Text daneben. Zur Klärung: Einstellungen › Über noty › Tipp-Diagnose nennt nach jedem Tipp Fenster, getroffene Ansicht und die Felder an der Stelle.

**Nutzerbestätigung 02.11.2026:** Mit Build 70 lassen sich wieder alle Felder antippen. Welcher der drei Mechanismen die Ursache war, ist nicht belegt; die Tipp-Diagnose wurde dafür nicht gebraucht und bleibt als Schalter erhalten.

Offener Gerätetest: Vergleich des Bestands gegen eine USB-Sicherung nach der Rückkehr, weil die Installation über den Link ohne Vorher-Sicherung per USB lief.

## Bedienfluss-Durchsicht (31.10.2026, Branch `audit/flow-2026-10-31`)

Basis: `feat/textneubau` afe37fe, ohne die uncommitteten Arbeiten dort und auf `feat/tastatur`. Implementiert, Core-Tests, Host-Roundtrip und SDK-Build bestanden. **Nicht installiert, am iPad ungeprüft.** Gezielt am Gerät prüfen: aufgelegter Finger beim Halten und Radieren, Bild einfügen mit Stift und Universal Clipboard, Zuschneiden eines großen HEIC, `.noty` per AirDrop bei offenem Heft, Gesetzesfenster mit Leiste am selben Rand, PDF-Import eines gesperrten PDFs (Prüfung läuft jetzt über CoreGraphics statt PDFKit), Screenshot über 5 MB. WebDAV-Änderungen sind nicht gegen einen echten Server geprüft.

## Nutzungsfeedback Tag 1 (22.10.2026)

Lasso-Kontur (`SelectionContour`) sowie Fingertipp-Auswahl bei aktivem Stift und Doppeltipp „Textfeld hinzufügen“ (`PageObjectHitTest`, `FingerObjectGestures`) als zwei Merge-Commits nach `main`. Bedienung: [DESIGN](DESIGN.md), Technik: [ARCHITECTURE](ARCHITECTURE.md).

- **Implementiert**, kein Notebook-/Archivformatwechsel, Buildnummer unverändert 61.
- **Erfolgreich gebaut:** `swift test --package-path Core` mit **648 Tests, 3 übersprungen, 0 Fehler** (inkl. `PageObjectHitTestTests`, Lasso-Konturfall in `LassoTouchAndHighZoomTests`); `xtool dev build` in PTY ohne Warnungen gegen das iPad-SDK. Kein signiertes IPA.
- **Nicht installiert, auf dem iPad ungeprüft.** Core-Tests und SDK-Build belegen weder Gesten noch PencilKit-Verhalten.

Gerätetests (gebündelt, isolierter Bereich/Testheft):

1. Lasso: reine Handschrift, gemischte Auswahl (Strich + Form + Textfeld + Bild) und weit entfernte Teile – Kontur mit Abstand, Inseln getrennt; bei hohem und niedrigem Zoom gleich breiter Abstand; Verschieben, Skalieren, Drehen bewegen die Kontur flüssig mit; Griffe/Leiste am Konturrahmen; laufendes Lasso gestrichelt; Bewegung reduzieren.
2. Fingertipp mit Stift, Bleistift, Marker und Radierer auf Textfeld, Bild, Form: Auswahl mit Griffen und Leiste, Werkzeug bleibt; Tipp ins Leere, Pencil-Schreiben, „Auswahl aufheben“ und Werkzeugwechsel heben auf.
3. Fingerziehen auf der Auswahl verschiebt (auch über Seitengrenzen im fortlaufenden Heft), außerhalb scrollt/zoomt der Finger unverändert; Seitentext und gesperrte Bilder werden nicht gewählt; Checkboxen bleiben antippbar; mit „Auch mit dem Finger zeichnen“ keine Fingerauswahl.
4. Doppeltipp auf freie Fläche (Papier- und PDF-Seite): nur „Textfeld hinzufügen“, kein „Platz einfügen“; neues freies Textfeld an der Tippstelle mit Tastatur; Doppeltipp auf ein Objekt zeigt kein Menü.
5. Undo/Redo nach Fingerverschiebung, Neustart der App: Stand erhalten.

## KI-Assistent

Ein experimenteller KI-Assistent existiert separat auf dem Branch exp/ki und ist nicht Teil dieses Release-Kandidaten.

## Native Gesetzessammlung – Feature-Worktree

Implementiert in `noty-law-integration` / `feat/native-law-library`, getrennt vom laufenden anderen Featurestrang. Die Website-/Backendseite liegt in `gesetzessammlung-noty` / `feat/noty-law-integration`. **Website/Backend am 20.10.2026 produktiv auf IONOS ausgerollt. Native Erweiterung als Build 54 installiert; Bedienung noch nicht auf dem iPad getestet. Mail auf Nutzerwunsch deaktiviert.**

Nachweise am 20.10.2026:

- **509 Core-Tests einschließlich des realen Fixture-Roundtrips erfolgreich** (mit `NOTY_LAW_FIXTURE_ROOT`). Geprüft: beide Suchreihenfolgen und HBG-Alias, Buchstaben/Absätze, unsichere Pfade, falsche Identitäten, unveränderliche Fassungen, fehlende Downloads, neuere gesperrte Formate, automatische Gastübernahme ohne Kontovermischung, spätes ACK gegen Offline-Löschung, persistente Tombstones/Cursor und persönliche Sicherung/Restore.
- `bash scripts/check_law_workflow.sh ../gesetzessammlung-noty/public/data`: alle **39 echten aktuellen Texte und 36 Original-PDFs** in einen neuen isolierten Store schreiben, veröffentlichen und nach neuem Storestart lesen. PDF-Originalbytes bleiben gleich; HGB/EStR/LStR/AEAO-Fundstellen passen. Ohne `NOTY_LAW_FIXTURE_ROOT` wird nur diese externe Fixture-Prüfung in der gewöhnlichen Core-Suite ausdrücklich übersprungen.
- `bash scripts/check_page_workflow.sh`: bestehende Heft-/Bibliotheksarchive inklusive Schema 11, unabhängiger Prüfer und Prüfer-Negativtests weiterhin erfolgreich. Keine Änderung des Notebook-/Archivformats durch die Gesetzessammlung.
- `xtool dev build` in PTY erfolgreich gegen das iPad-SDK. Das beweist keinen ausgeführten PDFKit-/Pencil-/Tastaturfall.
- Website `npm run check` (**50 Node-Tests, 10 Python-Tests**, Typecheck, Lint, Datenprüfung) und `npm run build` erfolgreich. Reale Daten: **9.262 Vorschriften**, **8.625 geprüfte PDF-Zuordnungen**. Die drei HTML-Handbücher haben bewusst keine vorgetäuschten PDF-Zuordnungen.
- Backendtests: bestehende Konten/Besitzrechte, native Bearer-Sitzungen und Widerruf, E-Mail-Migration mit gleichbleibender Nutzer-ID, Einmalcodes, Passwort-Reset/Sitzungswiderruf, ungültige alte Codes nach E-Mail-Wechsel, Sync nach Neustart und gelöschte UUID gegen verspäteten Create. SMTP mit **eigenem temporären TLS-Testserver** geprüft (mehrzeilige Antworten, MIME, Ablehnung), kein echter Mailversand.
- Lokaler Browser bei 1280 und 380 CSS-Pixeln: `144 HGB` öffnet automatisch § 144, EStR-Lesetext, Anmeldung/Registrierung und schmale Kontooberfläche ohne horizontalen Überlauf. Konto dabei isolierte Testdaten und Test-Mailfunktion; kein Produktionskonto und kein IONOS-Mailnachweis. Zusätzlich einen Markierungs-POST im Browser gezielt als offline simuliert: IndexedDB enthält vor dem Neustart einen ausstehenden Auftrag; nach bestätigtem Seitenneustart werden genau eine Servermarkierung und eine lokale Markierung bei leerer Warteschlange angezeigt. Das native Gegenstück und echte Netzwechsel bleiben am iPad abzunehmen.

Produktivnachweis am 20.10.2026: Release `noty-integration-20261020-release`, beide Container gesund. Konsistenter SQLite-Snapshot vor Migration; Migration zunächst auf Kopie geprüft. Danach alle vorherigen Spalten/Zeilen von Konten einschließlich Zugangsdaten, Sitzungen, Lesezeichen und Markierungen exakt verglichen, SQLite-Integrität erfolgreich. 39 JSON-Dokumente über öffentliches HTTPS mit nativen SHA-256-Prüfsummen und Bytezahlen identisch; PDF-Byte-Range 206, nicht angemeldeter Sync 401. SMTP-Konfiguration fehlt ausdrücklich; E-Mail-Registrierung und Recovery geben 503 zurück. Produktiver Browser öffnet `144 HGB` automatisch auf § 144. Kein echtes Konto zum Test neu angelegt und keine Mail versandt. Lokale Sicherung: `/home/la/Backups/20261020T203248Z-noty-law/`.

### Installation Build 54 · 20.10.2026

- Featurestand mit `main` Build 53 (`8bbf078`) im eigenen Worktree zusammengeführt, ohne den Haupt-Checkout oder dessen parallele Änderungen anzufassen. Neue Buildnummer in `Info.plist`: **54**. Die neuen Bild-, Pencil- und Editorfunktionen aus Build 53 sind enthalten.
- **560 Core-Tests** einschließlich echter Gesetzes-Fixtures ohne Fehler (`.tools/law-build54-core.log`); Host-Roundtrip mit unabhängigen Archivprüfern und Negativtests erfolgreich (`.tools/law-build54-page.log`).
- `xtool dev build --sign --ipa` in PTY erfolgreich, ohne Warnungen (`.tools/law-build54-sign.log`). IPA-ID `XTL-BAFXLQ964V.de.la.noty.prototype`, Team und Zertifikat wie bei der bisherigen Lieferung, gleiches provisioniertes Gerät. Profil bis **27.10.2026 20:43:31 UTC**, IPA-SHA-256 `84d7a6bef9a1dbb5a46aa73fca7b2f815cc336da418e76ce13954e47ca2358fa`.
- Vollständige stabile `/Documents`-Sicherung bei geschlossener App unter `/home/la/Backups/noty-before-build54-20261020T204350Z/`: 60 Dateien, 588.684.030 Byte, 14 Hefte und 26 geprüfte Revisionen. Keine persönlichen Inhalte im Repository.
- **Installiert** über `xtool install --usb xtool/Noty.ipa`, ohne Deinstallation. InstallationProxy bestätigt Build **54** unter unveränderter tatsächlicher ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`.
- Frisch zurückgelesene Daten unter `after-update/Documents`: alle **14 Hefte und 60 Dateien unverändert**, keine neuen Dateien. Zusätzlich alle Bereichsroots einzeln mit `verify_device_store.py --compare` geprüft; keine Quarantäne.
- **Bedienung noch ungeprüft.** Nutzer startet die App manuell und aktiviert Einstellungen → Gesetzessammlung. Mail bleibt serverseitig deaktiviert; E-Mail-Registrierung/Recovery noch nicht verfügbar.

### Build 55 · Gesetzesfenster ziehen und am Rand parken · 20.10.2026

Nutzerrückmeldung zu Build 54 (Screenshot): Das Gesetzesfenster ließ sich nicht vernünftig ziehen; es soll sich wie Apples Slide-over über den Bildschirmrand schieben lassen und dort einen Pfeil hinterlassen. Ursachen im Code: Das Fenster bewegte sich beim Ziehen nicht mit, sondern sprang erst beim Loslassen; nur der kleine Griff reagierte; der Breitengriff maß im mitwandernden lokalen Raum. Zusätzlich nahm das Paragraphfeld (`UITextField`) jede angebotene Höhe an und erzeugte den leeren Kasten unter der Schnellsuche. Umsetzung siehe [DESIGN](DESIGN.md#gesetzessammlung--bestätigte-bedienung-20102026).

- **Implementiert**: Live-Ziehen über die ganze Kopfleiste, Parken über den Rand mit Pfeil-Lasche (Tippen/Hereinziehen/Menü holt zurück), Seitenwechsel, Andocken/Schweben per senkrechtem Zug; Gesetzestastatur schließt beim Parken/Schließen; Breitengriff im festen Arbeitsflächenraum; Paragraphfeld mit fester Höhe. Keine Core-, Speicher- oder Formatänderung.
- **Erfolgreich gebaut**: `xtool dev build` und `xtool dev build --sign --ipa` in PTY ohne Warnungen (`.tools/law-build55-build.log`, `.tools/law-build55-sign.log`). IPA-ID `XTL-BAFXLQ964V.de.la.noty.prototype`, Build **55**, Team wie bisher, ein provisioniertes Gerät, Profil bis **27.10.2026 21:03:05 UTC**, IPA-SHA-256 `b4f170efddc5d8cba07a19fe5b75edeb90290e5dcfcb7aa41fcfbf6432f7e65d`.
- Vollständige stabile `/Documents`-Sicherung bei geschlossener App unter `/home/la/Backups/noty-before-build55-2026-10-20T21-03-22-141286596Z/`: 100 Dateien, 629.833.658 Byte, 14 Hefte, 26 geprüfte Revisionen; beide Bereichsroots ohne Quarantäne.
- **Installiert** über `xtool install --usb`, ohne Deinstallation. InstallationProxy bestätigt Build **55** unter unveränderter tatsächlicher ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`.
- Frisch zurückgelesen (`after-update/Documents`): alle **14 Hefte und 100 Dateien unverändert**, keine neuen Dateien; `verify_device_store.py --compare` für beide Bereichsroots ohne Abweichung.
- **Auf dem iPad ungeprüft**: Ziehen, Parken, Lasche, Seitenwechsel, Andocken per Zug, Breitengriff und Tastaturverhalten sind nur gebaut und installiert, nicht am Gerät bedient.

### Build 56 · Gesetzessammlung überarbeitet · 20.10.2026

Nutzerrückmeldung zu Build 55: Pfeil zur nächsten Vorschrift fehlt, Pfeile links/rechts funktionieren nicht, Markierungen gehen gar nicht, Andocken/Schweben per Drag & Drop gewünscht, ein Tippen oben soll nicht an den Anfang führen. Umsetzung siehe [DESIGN](DESIGN.md#gesetzessammlung--bestätigte-bedienung-20102026). Befunde im Code: Die Fußleiste hatte nur kleine Chevron-Symbole ohne Beschriftung neben einem langen Fassungstext; jede neue Markierung ersetzte den ganzen Text der Ansicht (Scrollsprung, Auswahl blieb über der Hervorhebung); der Stift wurde im Lesetext gar nicht ausgewertet und im PDF über eine Trefferprüfung erkannt, die Stiftberührungen nicht zuverlässig sieht; das Gesetzmenü öffnete immer den Anfang, auch für das bereits offene Gesetz, und jedes Öffnen eines Hefts begann wieder beim ersten Gesetz.

- **Implementiert**: Drag & Drop mit Zielvorschau (Andocken am Rand, Schweben, Parken), eigenständige größere Lasche, Website-artige Blätterleiste, Markieren über Auswahlmenü/Leiste/Pencil-Strich, Markierung entfernen per Antippen oder Auswahl, Hervorhebungen ohne Textersatz, Stift-Geste fürs PDF, „Markieren“ im PDF nur bei Auswahl, gemerkte Lesestelle je Gesetz, Lesezeichen-Umschalter. Keine Core-, Speicher- oder Formatänderung; Markierungen nutzen das bestehende Anker-/Syncformat.
- **Erfolgreich gebaut**: `xtool dev build` und `xtool dev build --sign --ipa` in PTY ohne Warnungen (`.tools/law-build56-build.log`, `.tools/law-build56-sign.log`). IPA-ID `XTL-BAFXLQ964V.de.la.noty.prototype`, Build **56**, Profil bis **27.10.2026 21:35:14 UTC**, IPA-SHA-256 `df4a38b0e919981971b8f74813b50cdfc0eb823beb676331f8b62c4402a97d29`.
- Vollständige stabile Sicherung bei geschlossener App unter `/home/la/Backups/noty-before-build56-2026-10-20T21-35-33-437546257Z/`: 102 Dateien, 630.885.580 Byte, 14 Hefte, 26 geprüfte Revisionen; beide Bereichsroots ohne Quarantäne.
- **Installiert** über `xtool install --usb`, ohne Deinstallation; InstallationProxy bestätigt Build **56** unter unveränderter ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`.
- Das erste Zurücklesen (`after-update/`, 24 Dateien) wurde nach der Installation durch einen versehentlichen Abbruch des Skripts unterbrochen und ist unvollständig. Danach bei geschlossener App vollständig neu zurückgelesen (`after-update-complete/Documents`): alle **14 Hefte und 102 Dateien unverändert**, keine neuen Dateien; `verify_device_store.py --compare` für beide Bereichsroots ohne Abweichung.
- **Auf dem iPad ungeprüft**: Drag & Drop, Lasche, Blättern, Markieren (Auswahl, Menü, Stift, PDF), Entfernen, Lesestelle und Synchronisierung neuer Markierungen sind gebaut und installiert, aber nicht am Gerät bedient.

### Build 57 · Schriftgröße direkt · 20.10.2026

Nutzerrückmeldung zu Build 56: Schriftgröße geht nicht, dafür soll sich kein Menü öffnen. Umsetzung siehe [DESIGN](DESIGN.md#gesetzessammlung--bestätigte-bedienung-20102026).

- **Implementiert**: Knöpfe „Schrift kleiner/größer“ direkt in der Leserleiste; HTML-Text einmal je Vorschrift importiert und pro Stufe skaliert; oberste sichtbare Textstelle bleibt; Größe gemerkt.
- **Erfolgreich gebaut**: `xtool dev build` und `--sign --ipa` in PTY ohne Warnungen (`.tools/law-build57-build.log`, `.tools/law-build57-sign.log`). Build **57**, Profil bis **27.10.2026 21:43:46 UTC**, IPA-SHA-256 `4e1b99682592090d7ad6877a0a3d8dc91b950e76e964e50d2ec6fc858b3beddd`.
- Sicherung bei geschlossener App: `/home/la/Backups/noty-before-build57-2026-10-20T21-44-07-582410158Z/` (102 Dateien, 640.321.859 Byte, 14 Hefte, 26 Revisionen, ohne Quarantäne).
- **Installiert**, InstallationProxy bestätigt Build **57** unter unveränderter ID. Zurückgelesen: alle **14 Hefte und 102 Dateien unverändert**, keine neuen Dateien, beide Bereichsroots ohne Abweichung.
- **Auf dem iPad ungeprüft.**

### Build 58 · Markierstift mit Pencil · 21.10.2026

Nutzerrückmeldung zu Build 56/57: Markieren funktioniert nicht zuverlässig; mit dem Stift in die Gesetzessammlung, bei ausgewähltem Markierstift markieren, speichern, Strich gerade wie im Heft. Umsetzung siehe [DESIGN](DESIGN.md#gesetzessammlung--bestätigte-bedienung-20102026). Befund im Code: Die Stiftgeste war ein Schwenk mit Mindestbewegung und verlor dadurch oft gegen die Stift-Textauswahl der Textansicht.

- **Implementiert**: Stiftgeste beginnt beim Aufsetzen; Stift folgt dem Werkzeug der aktiven Heftansicht (Markierstift markiert in seiner Farbe, Radierer entfernt, sonst scrollt/wählt der Stift); Text-Striche auf ganze Wörter; PDF begradigt nach „Immer gerade“/„nach Halten“; Farbe `color` im lokalen Markierungsbestand, bei Bestätigung und Abgleich erhalten.
- **Core-Tests**: volle Suite **562 Tests ohne Fehler** (2 Opt-in-Tests übersprungen); neuer Test `testHighlighterColourSurvivesAcknowledgementAndPull`. Mit echtem Gesetzesbestand (`NOTY_LAW_FIXTURE_ROOT`, 39 Dokumente) neuer Test `testEveryRealWordAnchorsAndMapsBack`: in jeder Vorschrift erstes, letztes und mittlere Wörter sowie ein Bereich bis 40 Wörter lassen sich verankern und wiederfinden (über 10.000 Anker). Das prüft die Ankerrechnung auf dem Klartext, nicht den HTML-Lesetext am Gerät.
- **Erfolgreich gebaut**: `xtool dev build` und `--sign --ipa` in PTY ohne Warnungen (`.tools/law-build58-build.log`, `.tools/law-build58-sign.log`). Build **58**, Profil bis **27.10.2026 22:24:13 UTC**, IPA-SHA-256 `01105f6954b774383823094615b439c9a282a198dbf84f663058ae22a54e4ce0`.
- Sicherung bei geschlossener App: `/home/la/Backups/noty-before-build58-2026-10-20T22-45-18-280691792Z/` (102 Dateien, 649.729.361 Byte, 14 Hefte, 26 Revisionen, ohne Quarantäne).
- **Installiert**, InstallationProxy bestätigt Build **58** unter unveränderter ID. Zurückgelesen: alle **14 Hefte und 102 Dateien unverändert**, keine neuen Dateien, beide Bereichsroots ohne Abweichung.
- **Auf dem iPad ungeprüft**: Stift mit Markierstift/Radierer/anderen Werkzeugen in Text und PDF, Begradigen, Farben nach Abgleich.

### Build 59 · TextKit 1, Stiftschalter, Registrierung · 21.10.2026

Nutzerrückmeldung zu Build 58 (iPadOS 27): Markierungen erscheinen nicht sofort, Entfernen entfernt nichts; Stiftmodus nicht auffindbar; Registrieren ohne E-Mail-Versand; muss man für Markierungen angemeldet sein? Umsetzung siehe [DESIGN](DESIGN.md#gesetzessammlung--bestätigte-bedienung-20102026). Befund im Code: Hervorhebungen werden als Textattribute an Ort und Stelle geändert; die Textansicht nutzte TextKit 2 (Standard seit iOS 16), das solche Änderungen nicht zuverlässig neu zeichnete. Speicherfehler meldete nur eine App-Meldung, die über einem geöffneten Heft nicht erscheinen kann. Die App verlangte für neue Konten eine E-Mail-Adresse, obwohl der Server Benutzername-Konten ohne Mail bereits anlegt.

- **Implementiert**: Lesetext mit `UITextView(usingTextLayoutManager: false)` (TextKit 1) und ausdrücklicher Neuzeichnung nach jeder Markierungsänderung; Stiftschalter „Lesen | Markieren | Radieren“ mit Markierfarbe im Gesetzesfenster, gespeichert, Markierstift/Radierer im aktiven Heft schalten mit; Fehler und Kontostatus im Leser; Registrierung mit Benutzername und Passwort ab 12 Zeichen ohne E-Mail. Keine Core-, Speicher-, Format- oder Serveränderung.
- **Erfolgreich gebaut**: `xtool dev build` und `--sign --ipa` in PTY ohne Warnungen (`.tools/law-build59-build.log`, `.tools/law-build59-sign.log`). Build **59**, Profil bis **27.10.2026 23:22:51 UTC**, IPA-SHA-256 `a2a281b4359a819f1cd82cad491858c0fadb70f15786384b2d01377254f6f7a9`.
- Sicherung bei geschlossener App: `/home/la/Backups/noty-before-build59-2026-10-20T23-23-23-368443212Z/` (102 Dateien, 649.752.849 Byte, 14 Hefte, 26 Revisionen, ohne Quarantäne).
- **Installiert**, InstallationProxy bestätigt Build **59** unter unveränderter ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`.
- Das erste Zurücklesen (`after-update/`) brach mit „File changed while reading“ ab: noty war direkt nach der Installation wieder geöffnet. Danach bei geschlossener App vollständig neu zurückgelesen (`after-update-complete/Documents`): `verify_device_store.py --compare` für beide Bereichsroots gültig, **alle 14 Hefte unverändert**, keine Quarantäne. 102 ↔ 102 Dateien, nichts hinzugefügt oder entfernt; geändert nur `Noty/Library/index.json`, `Noty/Library/index-previous.json` (Bibliotheksindex, ändert sich bei jedem App-Start) und `NotyLaws/catalog.json` (automatische Gesetzesaktualisierung bei laufender App). `audit_device_copy25.py` meldet deshalb „Non-library file changed“; betroffen ist der Gesetzeskatalog, keine Heftdaten.
- **Auf dem iPad ungeprüft**: sofortiges Erscheinen/Entfernen von Markierungen, Stiftschalter und Farben, Mitschalten mit dem Heftwerkzeug, Benutzername-Registrierung gegen den produktiven Server.

### Build 60 · Fensterposition, Schließen an den Rand, Paragraphfeld · 21.10.2026

Nutzerrückmeldung zu Build 59: Position der Gesetzessammlung merken, wo sie aktiv war; komplett geschlossen soll sie mit dem Pfeil zur Seite verschwinden; nach den Pfeilen unten aktualisiert sich der Text im Paragraphfeld nicht. Umsetzung siehe [DESIGN](DESIGN.md#gesetzessammlung--bestätigte-bedienung-20102026). Befund im Code: Angedockt/Seite/geöffnet/geparkt lagen nur im Speicher, die Breite sogar nur pro geöffnetem Heft; ✕ setzte `panelOpen = false` und entfernte damit auch die Lasche; Blättern änderte nur die Vorschrift, nie die Eingabefelder. Zusätzlich galt die Leseransicht der Einstellungen als geschlossenes Fenster, sodass ihr Paragraphfeld die Tastatur nach jeder Eingabe schloss.

- **Implementiert**: Fensterzustand (offen, geparkt, angedockt, Seite) und Breite in UserDefaults, Breite beim Ende des Ziehens; ✕ und der Heft-Menüpunkt parken mit Lasche, „Ganz schließen (ohne Pfeil)“ im Anordnungsmenü; Paragraphfeld zeigt nach Blättern/Inhaltsverzeichnis/Lesezeichen/Gesetz-, Fassungswechsel und Schnellsuche die Nummer der angezeigten Vorschrift, nicht mehr zutreffende Fundstelle in der Schnellsuche wird geleert, eigene Feldeingaben bleiben, die gespiegelte Nummer löst keine Suche aus, Antippen markiert die Nummer; Verdeckt-Regel nur im Gesetzesfenster. Keine Core-, Speicher-, Format- oder Serveränderung.
- **Erfolgreich gebaut**: `xtool dev build` und `--sign --ipa` in PTY ohne Warnungen (`.tools/law-build60-build.log`, `.tools/law-build60-sign.log`). Build **60**, IPA-ID `XTL-BAFXLQ964V.de.la.noty.prototype`, Profil bis **28.10.2026 10:22:21 UTC**, IPA-SHA-256 `23556b6a964215c5e408934f2243a0227864c3d0c580af88f94f533b26c87d5e`.
- Sicherung bei geschlossener App: `/home/la/Backups/noty-before-build60-2026-10-21T10-23-49-113226015Z/` (101 Dateien, 633.859.063 Byte, 14 Hefte, 25 Revisionen, ohne Quarantäne). Ein erster Versuch brach ab, weil sich Documents während des Lesens noch änderten (`…T10-23-06-…-abgebrochen`, unvollständig, nicht verwenden); vor dem Abbruch wurde nichts installiert.
- **Installiert**, InstallationProxy bestätigt Build **60** unter unveränderter ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`. Bei geschlossener App zurückgelesen (`after-update/Documents`): `verify_device_store.py --compare` für beide Bereichsroots gültig, **alle 14 Hefte und 101 Dateien unverändert**, keine neuen Dateien, keine Quarantäne.
- **Auf dem iPad ungeprüft**: Wiederherstellen von Seite/Andocken/Breite/Lasche nach Heftwechsel und Neustart, ✕ und Menüpunkt mit Lasche, „Ganz schließen“, Paragraphfeld nach Pfeilen/Inhaltsverzeichnis/Lesezeichen, Ersetzen der markierten Nummer beim Tippen, Paragraphfeld in der Leseransicht der Einstellungen.

Geräteabnahme gebündelt:

1. Einschalten und kompletten Erstdownload abwarten, dann Flugmodus/Neustart; Text/PDF und Direktfundstellen prüfen. Sync- und Updateschalter unabhängig schalten, lokale Daten bei deaktiviertem Netzwerkabgleich erhalten.
2. In einem/zwei Heften schreiben, Gesetzesfenster öffnen, per Drag & Drop andocken/schweben/parken und per Lasche zurückholen, Vorschriften blättern, Stiftschalter „Lesen | Markieren | Radieren“ und Farbe wählen, Text per Auswahl und Stift markieren und wieder entfernen (Text und PDF, sofort sichtbar), schweben/andocken, Seiten/Breite wechseln, Rotation/kleines Fenster, native Zahlen-/Texttastatur, Eingabewechsel und Undo. Verdecktes zweites Heft mit Seite/Zoom und Entwurf wieder einblenden.
3. Text auswählen/markieren, Pencil-PDF markieren, Lesezeichen und PDF-Seiten wechseln, Neustart und separate persönliche Sicherung/Restore. Notizbuch-Undo darf keine fremde Fundstelle bearbeiten.
4. Konto mit Benutzername ohne E-Mail registrieren und anmelden. Website↔iPad bei Netzwechsel, Löschkonflikt, Logout und Kontowechsel. Gastdaten automatisch übernehmen; Datensätze von Konto A nicht unter B hochladen. E-Mail-Konto/Bestätigung/Reset erst nach späterer Mailfreigabe prüfen.
5. Neue/fehlerhafte/unterbrochene Fassungsdownloads und Platzmangel: alter Bestand bleibt gültig, markierte alte Fassung erreichbar, aktive Lesestelle erhalten. Automatische Aktualisierung bei beendeter App ist nicht zugesichert.

Deployment, SMTP-Einrichtung und Geräteupdate folgen den Freigabe-/Sicherungsregeln in AGENTS/ENVIRONMENT. Ein lokales Releasepaket und eine erfolgreiche Installation sind kein Laufzeitnachweis.

## Prüfungen auf diesem Rechner

```bash
cd /home/la/workspace/noty
. ./scripts/env.sh
swift test --package-path Core                      # Core-Tests (Linux, XCTest)
swift test --package-path Core --filter Klassenname # einzelne Testklasse
bash scripts/check_page_workflow.sh                 # Host-Roundtrip unter .tools/
bash scripts/check_verifiers.sh                     # Negativtests der Python-Prüfer (auch im Roundtrip)
script -qec "xtool dev build" .tools/build.log      # unsignierter iPad-Build mit SDK
```

- **Core-Tests** prüfen Datenmodell, Revisionen, Migration, Archive, Geometrie, Textfluss und Backup-Regeln mit echten Dateisystemfehlern in temporären Verzeichnissen. Sie führen weder PDFKit noch PencilKit, Vision oder UIKit aus. Testklassen heißen seit Build 47 nach ihrer Funktion statt nach Build-Nummern (`git log -p 78a60c9` zeigt die Umbenennung).
- **Host-Roundtrip** erzeugt ein Heft und eine Bibliothek, exportiert, prüft unabhängig mit `verify_backup.py`/`verify_library_backup.py` und weist beschädigte `.notybackup`/`.notylibrary` zurück. Die Prüfer verwenden keine `assert`-Anweisungen und wirken deshalb auch unter `python3 -O`.
- **`xtool dev build`** ist die Typprüfung gegen das iPad-SDK. Eine reine Swift-Syntaxprüfung ersetzt ihn nicht. Gesten, Schreibgefühl und Laufzeitverhalten belegt nur das Gerät.

Archivprüfer einzeln: `python3 -B scripts/verify_backup.py ARCHIV --compare REVISION.json`, `python3 -B scripts/verify_library_backup.py ARCHIV`. Geräteabzüge: `python3 -B scripts/verify_device_store.py BEREICHSROOT --compare VORHER_ROOT` je Root (`Documents/Noty` und jedes `NotyWorkspaces/Areas/*/Data`), nicht für `Documents` insgesamt.

## Update auf das iPad

Apple-Anmeldung, 2FA, Vertrauen und Entwicklermodus übernimmt der Nutzer (`xtool auth` im eigenen Terminal). Identität und Profil: [ENVIRONMENT](ENVIRONMENT.md).

1. `xtool dev build --sign --ipa` in einer PTY (`script -qec "…" LOG`). IPA prüfen: Bundle-ID `XTL-BAFXLQ964V.de.la.noty.prototype`, Team `BAFXLQ964V`, gleiches Zertifikat wie zuvor, erwarteter `CFBundleVersion`.
2. iPad entsperrt, noty geschlossen (`idevicesyslog pidlist | grep -i noty` leer). Läuft noty, nicht installieren.
3. Vollständige App-`/Documents` per AFC mit der installierten ID `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype` nach `/home/la/Backups/<eindeutiger Zeitstempel>/Documents/` sichern. Jeden Bereichsroot mit `verify_device_store.py` prüfen.
4. `xtool install --usb xtool/Noty.ipa` in einer PTY. Nicht deinstallieren, nicht auf `xtool dev run` wechseln. 100 % oder Exitcode 0 allein sind kein Beleg. Installierte Version per InstallationProxy lesen.
5. `/Documents` frisch zurücklesen und je Root mit `--compare` gegen den Vorher-Stand vergleichen.

Automatischer Start scheitert am fehlenden Developer-Disk-Image. Der Nutzer startet manuell.

## Bild-Assets (Schema 12) – Nachweise

Branch `feat/image-assets`, Schritte C1–C8 ([IMAGE-ASSETS](IMAGE-ASSETS.md)). **Implementiert und erfolgreich gebaut; nicht installiert, auf dem iPad ungeprüft.**

- **Core-Tests:** `swift test --package-path Core`: 625 Tests, 1 übersprungen (exakter Bytevergleich der Golden-Archive nur unter `SWIFT_DETERMINISTIC_HASHING=1`, dort grün), 0 Fehler; zweimal hintereinander. Neu für Schema 12 und Archivformat 2 u. a. `SHA256Tests`, `ImageAssetStoreTests`, `ImageAssetProviderTests`, `ImageAssetMigrationTests`, `ImageAssetCommitRecoveryTests`, `ImageAssetGarbageCollectionTests`, `ArchiveFormat2Tests`, `RecordArchiveCompatibilityTests`, `AcceleratedHashingTests`.
- **GC- und Absturzmatrix:** Asset nur von Checkpoint, vorigem Manifest, Seitenpapierkorb, Quarantäne, unlesbarer Revision, Migrationsdatei oder `Archives/` referenziert → bleibt; unreferenziert und alt → weg, jung → bleibt; Teildateien nach 1 h; fremde Einträge unberührt; Lesefehler bricht ohne Löschen ab; Backup- und Restore-Sperre vor und während des Laufs; nur der Writer, nur beim Öffnen vor dem ersten Commit bzw. beim Schließen mit bestätigtem Stand; Undo nach Löschen und zwölf Commits in derselben Sitzung findet sein Asset; Absturzabbilder nach jeder Commit-Stufe und während des Asset-Schreibens verlieren nie den bestätigten Stand.
- **Host-Roundtrip** (`bash scripts/check_page_workflow.sh`): Bild über den Asset-Bestand, genau eine Datei `Assets/<sha>` trotz duplizierter, kopierter und gelöschter Seiten; Heft- und Bibliotheksbackup im Format 2 mit echtem Asset-Datensatz, von Python unabhängig geprüft; Format 1 als Schema-11-Bytes; beschädigtes Asset im Archiv abgelehnt; Restore-Kopien mit Assets (`verify_device_store.py`); handgeschriebenes Schema-11-Paket: Öffnen samt unverändertem Speichern und Öffnungs-GC ändert kein Byte, die erste Bearbeitung legt die exakten Altbytes unter `Migrations/` ab, der Schließ-GC behält das migrierte Original. `check_verifiers.sh` mit allen Negativfällen aus Plan Abschnitt 10, auch unter `python3 -O`.
- **SDK-Build:** `script -q -e -c "xtool dev build" LOG` ohne Fehler und ohne Warnungen.
- **Messung** (Host, synthetisch, 500 MB): Werte und Grenzen in [IMAGE-ASSETS](IMAGE-ASSETS.md#c8-feinschliff). Kurz: kleiner Commit bei 500 MB Assets 0,07–0,14 s, Laden 0,15 s, Heftbackup schreiben und zurücklesen 8–10 s, Spitzenspeicher ≤ 163 MB; wiederholtes Laden eines nicht migrierten 52-MB-Althefts 0,12–0,14 s statt 1,2 s (`-O`). Am iPad nicht gemessen; dort übernimmt CryptoKit das Hashen.
- **Geräteprüfung nach einem Update** (noch offen, gebündelt): Sicherung wie oben; danach mit `verify_device_store.py --compare` gegen den Vorher-Stand (ohne Bearbeitung bleiben alle Hefte bytegleich, Althefte schreiben beim Öffnen nichts). Nach einer Bearbeitung meldet `--compare` für dieses Heft bewusst „A previous document changed“; dann ohne `--compare` prüfen (Assets vorhanden, Größe und SHA-256 richtig, unreferenzierte Assets und Teildateien gezählt). Am iPad: Altheft mit Bildern öffnen, bearbeiten, Neustart; zwei 5-MB-Bilder ziehen (Ruckeln?), Seite duplizieren, Papierkorb endgültig leeren, Heft schließen und wieder öffnen; Heft- und Bibliotheksbackup exportieren, am PC prüfen, als Kopie zurückspielen und bearbeiten; PDF-Export mit HEIC; ein großes Heft (etwa 300–500 MB) öffnen und die Zeit messen.

## Build 54 und 61 · Bild-Assets und Zusammenführung mit der Gesetzessammlung (21.10.2026)

- **Build 54:** Bild-Assets, Notebook-Schema 12, Archivformat 2; Nachweise im Abschnitt „Bild-Assets (Schema 12) – Nachweise“.
  - Installiert am 21.10.2026 um 12:24 über einen parallel installierten Build 59 aus `feat/native-law-library`.
  - Der erste Sicherungsversuch brach ab, weil sich die Dokumente während der Sicherung änderten. Danach Sicherung unter `/home/la/Backups/noty-before-build54-2026-10-21T10-23-52-574301164Z/`.
  - Das direkte Zurücklesen scheiterte an einem AFC-Lesefehler. Um 12:25 hat der Gesetzes-Strang Build 60 darüber installiert.
  - Eine spätere Rücklesung (`after-update2`) bestätigt: kein `Assets/`, höchstes Schema 11, `verify_device_store.py --compare` meldet 6 + 8 unveränderte Dokumente. Build 54 hat also nichts migriert.
- **Build 61:** `ui/menu-polish` und `feat/native-law-library` (bis Build 60) zusammengeführt.
  - `swift test --package-path Core`: 640 Tests, 3 übersprungen, 0 Fehler. Host-Roundtrip grün. Signiert ohne Warnungen.
  - IPA: `CFBundleVersion` 61, gleiche App-ID, Team und Zertifikat (`50f3e096…`), Profil bis 28.10.2026, SHA-256 `a0b969bb…`.
  - **Nicht installiert:** noty war zwei Stunden geöffnet, das Installationsskript hat nur gewartet.
- **Regel ab jetzt:** Weitere Stränge starten von `main` (enthält Schema 12) mit Build-Nummern ab 62. Ein Build ohne Schema 12 sperrt migrierte Notizbücher.

## Build 53 · Rückmeldung zu Build 52

**Implementiert** auf `ui/menu-polish`. Nutzer zu Build 52:
- Ruckeln beim Ziehen nach zwei 20-MB-Bildern: Neue Bilder werden beim Import auf höchstens 5 MB verkleinert. Die eigentliche Ursache, Bildbytes als Base64 in jeder vollständigen Revision, wird mit einem eigenen Asset-Format behoben (Schema 12, inzwischen auf `feat/image-assets` umgesetzt, siehe oben).
- Bilder ließen sich nicht über Seiten ziehen. Umgesetzt nach dem Lasso-Vorbild, siehe [IMAGES](IMAGES.md).
- Der Wunsch nach 500 MB pro Notizbuch kommt erst mit dem Asset-Format; bis dahin bleiben es 40 MB (Schema 12 erlaubt 500 MB, siehe oben).

Nachweise:
- `swift test --package-path Core`: 547 Tests, 0 Fehler. Host-Roundtrip mit Prüfer-Negativtests bestanden.
- **Erfolgreich gebaut:** `--sign --ipa` ohne Warnungen. IPA: `CFBundleVersion` 53, gleiche App-ID, Team und Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `6df603e7…`.
- **Installiert am 20.10.2026 um 22:39** über Build 52.
  - Sicherung unter `/home/la/Backups/noty-before-build53-2026-10-20T20-38-41-577854343Z/`.
  - Zurückgelesen: 14 Dokumente und 60 Dateien unverändert, 6 Dokumente laut `--compare` unverändert, keine Quarantäne.
- **Auf dem iPad ungeprüft.**

## Build 52 · Rückmeldung zu Build 51

**Implementiert** auf `ui/menu-polish`. Nutzer zu Build 51:
- Geschnittene Formen wurden zu einem sehr dünnen Strich. Behoben: Die Punktgröße wird an der gemessenen PencilKit-Breite ausgerichtet.
- Bilder über 20 MB sollen verkleinert importiert werden. Umgesetzt mit `ImageCompression`, siehe [IMAGES](IMAGES.md#ergänzung-nach-build-51--große-bilder-werden-verkleinert).
- Das Bild-Werkzeug soll zum noty-Stil passen. Umgesetzt: Optionszeile, Auswahlrahmen und Anfasser in Akzentfarbe, Aktionsleiste, Zuschneiden; siehe [DESIGN](DESIGN.md).

Nachweise:
- `swift test --package-path Core`: 543 Tests, 0 Fehler.
- **Erfolgreich gebaut:** `--sign --ipa` ohne Warnungen. IPA: `CFBundleVersion` 52, gleiche App-ID, Team und Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `ad609c8f…`.
- **Installiert am 20.10.2026 um 22:20** über Build 51 (danach meldet InstallationProxy 52).
  - Sicherung unter `/home/la/Backups/noty-before-build52-2026-10-20T20-20-21-279539027Z/`.
  - Frisch zurückgelesen: 14 Dokumente und 60 Dateien unverändert. `--compare` meldet 6 unveränderte Dokumente, keine Quarantäne.
- **Auf dem iPad ungeprüft:** alle drei Änderungen; Foto-Import und PDF-Export aus Build 51 weiterhin ohne Rückmeldung.

## Build 51 · Rückmeldung zu Build 50

**Implementiert** auf `ui/menu-polish` (66f3c90, auf Build 50). Nutzertest von Build 50:
- Am iPad bestätigt: Werkzeugleiste, Schnellmenü (scrollen, Start, 10 s), Formen mit dem Stift, Halten über den Rand, Schreibscrollen, PDF-Schreibplatz-Linien, „Seite anpassen“, Bibliothek.
- Offen gemeldet:
  - Foto-Import scheitert weiter (Systemmeldung zu `ImportedStillImage`).
  - Der Präzisionsradierer soll Formen nur teilweise radieren.
  - Wiederholen soll vor Rückgängig stehen, aber erst nach Scrollen sichtbar sein.
- Der PDF-Export (Bilder und Text) ist ohne Rückmeldung, also weiter ungeprüft.

Umgesetzt:
- Präzisionsradierer schneidet Formen ([DESIGN](DESIGN.md#präzisionsradierer-und-formen--20102026)).
- Foto-Import mit Rückfallwegen ([IMAGES](IMAGES.md#ergänzung-nach-build-50--foto-import-mit-rückfallwegen)).
- Schnellmenü-Reihenfolge angepasst.

Nachweise:
- `swift test --package-path Core`: 543 Tests, 0 Fehler, davon 6 neue in `ShapeEraseMaskTests`. Format unverändert.
- **Erfolgreich gebaut:** `xtool dev build` und `--sign --ipa` ohne Warnungen. IPA geprüft: `CFBundleVersion` 51, gleiche App-ID, Team und Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `cc4bf964…`.
- **Installiert am 20.10.2026 um 21:57** über Build 50 (danach meldet InstallationProxy 51).
  - Sicherung unter `/home/la/Backups/noty-before-build51-2026-10-20T19-57-17-975437957Z/`.
  - Frisch zurückgelesen: 14 Dokumente und 60 Dateien unverändert. `verify_device_store.py --compare` meldet 6 unveränderte Dokumente, keine Quarantäne.
- **Auf dem iPad ungeprüft:** Foto-Import, Formen schneiden, Wiederholen im Schnellmenü, PDF-Export.

## Build 50 · Rückmeldung zu Build 49

**Implementiert** auf `ui/menu-polish` und auf Basis von Build 49. Details in [DESIGN](DESIGN.md#rückmeldung-zu-build-49--20102026) (Werkzeugleiste, Schreibscrollen, PDF-Linien, „Seite anpassen“, Pencil-Schnellmenü) und [IMAGES](IMAGES.md) (HEIC und Live Photos, Bildleiste).

Weitere Änderungen:
- PDF-Export zeichnet Bilder und Text wieder (UIKit-Seitenrenderer, `Page.exportLayers`).
- Bibliothek: Zahnrad oben rechts, Bereiche entfernen. „Meine Bibliothek“, der geöffnete und der letzte Bereich bleiben immer erhalten (`WorkspaceRemoval`).
- Halten zum Begradigen über den Seitenrand: Linien und Pfeile werden an der Kante abgeschnitten, geschlossene Formen auf die Seite geschoben (`HeldShapeFitting`).
- Der Präzisionsradierer entfernt berührte Formen ganz, zusammen mit der Tinte in einem Undo-Schritt.
- Der Textmarker hat einen eigenen Halten-Schalter (`markerHoldStraighten`). Vorher hat sein Schalter auch die Formerkennung von Stift und Bleistift abgeschaltet.

Eine eindeutige Ursache für „Formen mit dem Stift gehen nicht mehr“ ist nicht gefunden: Der Halte-Code ist seit Build 46 gleich. Behoben sind nur die beiden passenden Auslöser, die Randablehnung und der gemeinsame Schalter. Notebook-Schema unverändert (11).

- `swift test --package-path Core`: 537 Tests, 0 Fehler. Host-Roundtrip mit Prüfer-Negativtests vor dem letzten Merge bestanden; der letzte Merge ändert kein Format.
- **Erfolgreich gebaut:** `xtool dev build --sign --ipa` ohne Warnungen. IPA geprüft: `CFBundleVersion` 50, `XTL-BAFXLQ964V.de.la.noty.prototype`, Team BAFXLQ964V, gleiches Zertifikat (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `417123c4…`.
- **Installiert am 20.10.2026 um 21:13** über Build 49. InstallationProxy meldet danach 50, die ID ist unverändert.
  - Sicherung unter `/home/la/Backups/noty-before-build50-2026-10-20T19-13-03-803036796Z/`.
  - Frisch zurückgelesen: 13 Dokumente und alle 56 Dateien unverändert, keine neuen Dateien. `verify_device_store.py --compare` meldet 5 unveränderte Dokumente in `Documents/Noty`, keine Quarantäne.
  - Ein erster Lauf brach vor der Installation an einem veralteten lokalen Prüfhelfer ab. Am Gerät wurde dabei nichts verändert.
- **Auf dem iPad ungeprüft.**

## Build 49 · Editor-Korrekturen

**Implementiert.** Sechs restliche Review-Funde im Editor (Commits 23102fb, e65ba49, d3d9c56, b866e35, 444a1b6 auf Build 48). Die Regel für das Zurücksetzen des Canvas steht als `EditorInteractionPolicy.canvasNeedsReset` in Core und hat einen eigenen Test. Den UIKit-Ablauf selbst prüft nur das Gerät.

- `swift test --package-path Core`: 496 Tests, 0 Fehler (`.tools/core-build49.log`). Host-Roundtrip mit Prüfer-Negativtests bestanden (`.tools/roundtrip-build49.log`).
- **Erfolgreich gebaut:** `xtool dev build --sign --ipa` ohne Warnungen (`.tools/build-build49.log`). IPA geprüft: `CFBundleVersion` 49, `XTL-BAFXLQ964V.de.la.noty.prototype`, Team BAFXLQ964V, gleiches Zertifikat wie Build 46/48 (`50f3e096…`), Profil bis 27.10.2026, SHA-256 `66bf1889…`.
- **Installiert am 20.10.2026 um 16:11** über Build 48 (InstallationProxy danach: 49, ID unverändert `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`). Sicherung vorher: `/home/la/Backups/noty-before-build49-2026-10-20T14-10-51-566363586Z/`. Rücklesen danach: 3 Hefte, 26 Dateien unverändert, keine neuen Dateien. `verify_device_store.py --compare` meldet `previous_documents_unchanged: 3`, 1 Zwischenstand aus Build 48 erhalten, keine Quarantäne. Ein erster Lauf brach vor der Installation ab, weil das Audit-Hilfsskript den neuen Rückgabewert von `load_store` nicht kannte (Teilsicherung `…T14-10-10-808481660Z`, keine Installation).
- **Auf dem iPad ungeprüft.**

### Gerätetest Build 49

1. Tinte mit dem Lasso auswählen und über den Seitenrand ziehen. Währenddessen per Squeeze oder Doppeltipp das Werkzeug wechseln, dann einen Strich zeichnen. Die ausgewählten Striche bleiben an ihrem Platz, auch nach Schließen und erneutem Öffnen des Hefts. Dasselbe beim Ziehen innerhalb der Seite und beim Abbruch mit zwei Fingern.
2. Eine Form halten und kurz nach dem Abheben das Werkzeug wechseln: Die Freihandlinie darf nicht verschwinden.
3. Heft mit 5–10 großen Fotos zoomen und scrollen: kaum graues Aufblitzen, kein ständiges Neuladen.
4. Ein Bild unter ein anderes schieben: Das vordere bleibt vorne. Wieder wegziehen läuft flüssig.
5. Präzisionsradierer benutzen, danach mit dem Stift eine gehaltene Form zeichnen: Die Vorschau hat die richtige Breite.
6. Einen Werkzeugregler bewegen, sofort die App wechseln und die App beenden: Die Einstellung bleibt erhalten.

## Review-Überarbeitung (Build 47, ausgeliefert mit Build 48)

**Implementiert und erfolgreich gebaut.** Build 47 wurde nie separat installiert; der Stand ist vollständig in Build 48 (`ui/menu-polish`) enthalten. Umfang: [README](../README.md#aktueller-stand), Formatdetails in [STORAGE](STORAGE.md) und [LIBRARY-BACKUP](LIBRARY-BACKUP.md), Architektur in [ARCHITECTURE](ARCHITECTURE.md#build-47--review-überarbeitung).

Nachweise auf diesem Rechner (Stand `fix/review-2026-10` @ 39281fa, vor dem UI-Merge):

- `swift test --package-path Core`: 486 Tests, 0 Fehler. Neu u. a. Quarantäne nur nach Rückfall, Build-46-kompatibles Manifest, `checkpoints.json`, Schema 10 für Quellen über 20 MB, Migrationsarchiv-Wiederverwendung, Streaming-Bibliotheksarchiv, Backup-Status/Backoff, persistenter Suchindex, Textfluss ohne unnötiges Neumessen.
- Host-Roundtrip einschließlich beschädigtem `.notylibrary` und Prüfer-Negativtests bestanden.
- `xtool dev build` vollständig, 0 Warnungen.

Zusammen mit dem UI-Strang: 495 Core-Tests, Roundtrip und SDK-Build ohne Warnungen ([PAGE-ADJUST](PAGE-ADJUST.md#nachweise)). Installation von Build 48 und deren Belege: [UI-POLISH](UI-POLISH.md#stand-und-nachweise). **Auf dem iPad ungeprüft.**

### Gerätetest Review-Überarbeitung (nach Risiko gebündelt)

1. **Bestand:** alle Hefte öffnen. Lokale Historie eines oft bearbeiteten Hefts öffnen und einen älteren Stand als Kopie öffnen. Neue Änderung → „Lokal gespeichert“.
2. **Schreiben:** Stift, Marker, beide Radierer, Lasso über mehrere Seiten, schneller Seitenwechsel. Achten auf Ruckler, verlorene Striche, falsches Werkzeug nach Stift-Heben und Werkzeugwechsel. Autostift auf dunklen und hellen PDF-Seiten.
3. **Objekte:** Text-, Bild- und Formobjekte ziehen und skalieren, danach Undo/Redo. Mehrere große Bilder auf einer Seite, hinein- und herauszoomen: Bilder dürfen nicht dauerhaft grau bleiben.
4. **Undo und Tastatur:** Undo in Text-, Lese- und Lassomodus. Mit Hardwaretastatur ⌘N, ⌘F, ⌘S, ⌘E, ⇧⌘E, ⌘↑/⌘↓ und ⌘X/⌘D/⌘A/Pfeile bei Auswahl. ⌘↑/⌘↓ im Textfeld: Cursor oder Seitenwechsel?
5. **Pencil-Doppeltipp:** folgt der Systemeinstellung unter Einstellungen → Apple Pencil.
6. **Seitenleiste und Suche:** Vorschauen nach Bearbeitung aktualisiert. Suche zweimal ausführen (zweiter Lauf schneller). Treffer springt zur markierten Stelle.
7. **PDF:** Export des ganzen Hefts mit Fortschritt, einmal abbrechen. Export mit `pdfinfo`/`pdftoppm`/`pdftotext` prüfen. Import eines PDF über 20 MB.
8. **Seitenpapierkorb:** Seite löschen, wiederherstellen, endgültig löschen, Papierkorb leeren.
9. **Externes Backup:** Ordnerziel „Jetzt sichern“ und dabei weiterschreiben. Ziel entfernen bzw. offline → verständlicher Fehler ohne Wiederholschleife. `.notybackup`/`.notylibrary` aus der Dateien-App öffnen → Importdialog.
10. **Neustart:** während „Speichert …“ in den Hintergrund wechseln, App beenden, wieder öffnen: letzter bestätigter Stand vorhanden.

Ohne Gerätezugriff **ungeprüft** bleiben: automatische Speicher-Wiederholung nach Schreibfehler, Rückfall/Quarantäne auf dem Gerät, Speicherwarnung, Signierprofil-Hinweis 24 h vor Ablauf, WebDAV gegen einen echten Server.

## Offene Abnahme

Verbindliche Kriterien in [ACCEPTANCE](ACCEPTANCE.md). Weiterhin nicht durchgeführt: vollständiger externer Restore in einen leeren Bestand, 30 Minuten Mischbetrieb, 100-Seiten-Text-PDF und hochauflösender Scan, Platzmangel, Flugmodus, Probetag. Keine Latenz- oder FPS-Versprechen.
