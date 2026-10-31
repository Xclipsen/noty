# Tastatur: Kürzel und Tastaturmodus

Stand: Build 65 auf `feat/tastatur` (gestapelt auf `feat/textneubau`). **Implementiert, erfolgreich gebaut, Core-Tests bestanden.** **Installiert** am 31.10.2026 (`XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`, InstallationProxy meldet 65), **am iPad ungeprüft**. Linux hat keinen iOS-Simulator: Parser, Motions und Bereichsbearbeitung sind getestet (`KeyboardCommandsTests`, `TextMotionsTests`, `TextFlowRangeTests`), die Tastenzustellung durch UIKit nicht. Nach dem Feedback zu Build 65 (Tasten nur einmal, `gg`/`dd` tot): `KeyPressGate` entprellt nach Taste und Zeitstempel statt nach `UIPress`-Objekt, gebaut auf `phase0/keys`, am iPad ungeprüft.

## ⌘-Kürzel (immer aktiv, auch ohne Tastaturmodus)

| Taste | Wirkung | Wo |
| --- | --- | --- |
| ⌘N / ⇧⌘N | Neues Heft / neues Textdokument | Bibliothek |
| ⌘F | Suchen | überall |
| ⌘S | Speichern | Editor |
| ⌘E / ⇧⌘E | PDF ganz / diese Seite | Editor |
| ⌘↑ / ⌘↓ | Vorherige / nächste Seite (im Text: Anfang/Ende dieses Texts, Systemverhalten) | Editor |
| ⌘G | Gehe zu Seite | Editor |
| ⌘W | Schließen | Editor |
| ⌘Z / ⇧⌘Z | Rückgängig / Wiederholen | Editor |
| ⌘A | Alles auswählen (siehe unten) | Editor |
| ⌘C ⌘X ⌘V ⌘D | Kopieren, Ausschneiden, Einfügen, Duplizieren | Text und Auswahl |
| ⌫, Pfeile, ⇧Pfeile | Auswahl löschen, um 1 pt / 10 pt schieben | Objektauswahl |
| ⌘B ⌘I ⌘U, ⇧⌘X | Fett, Kursiv, Unterstrichen, Durchgestrichen | Text |
| ⌘1–⌘4 | Titel, Überschrift, Unterüberschrift, Text | Text |
| ⌘+ ⌘- | Schrift größer / kleiner | Text |
| ⇧⌘7 ⇧⌘8 ⇧⌘9 | Aufzählung, Nummerierung, Checkliste | Text |
| ⌘K, ⇧⌘H | Link, Markieren | Text |
| Tab, ⇧Tab | Listenebene | Text |
| ⇧⌘P, ⌘/ | Befehlspalette, Tastenübersicht | überall |

**⌘A:** Im Text das ganze Feld; im Textdokument der ganze Text über alle Seiten (blau markiert; ⌘C/⌘X/⌘V, ⌫ und Formatierung wirken auf alles, beim Schreiben auch Tippen, ⌘Z als ein Schritt). Ohne Cursor im Textdokument dasselbe, dann im Modus MARKIEREN, damit kein Buchstabe versehentlich alles ersetzt. Im Heft alles Auswählbare der Seite, jetzt mit jedem Werkzeug (vorher nur mit Lasso, Formen, Bild oder bestehender Fingerauswahl). Das Bearbeitungsmenü „Alles auswählen“ bleibt die native Auswahl dieser Seite.

## Tastaturmodus

Einstellungen › Editor › „Tastaturmodus (wie vim)“, Standard an. Wirkt nur auf Hardware-Tastaturen. `?` zeigt alle Tasten, `:` öffnet die Befehlspalette (alle Tastenbefehle und Menüfunktionen per Suche, dazu `:w`, `:q`, `:wq`, Seitenzahl). Der Modus erscheint, sobald eine Taste gedrückt wurde: im Editor oben links unter der Zurück-Taste (dort reichen weder Tastatur noch Formatleiste hin), in der Bibliothek unten links.

Modi: **BIBLIOTHEK**, **SEITE** (Editor ohne Cursor), **SCHREIBEN** (normales Tippen), **NORMAL** (Cursor im Text, Buchstaben sind Befehle, breiter Cursor), **MARKIEREN**/**ZEILEN** (visuell). Antippen eines Texts schreibt immer, auch aus NORMAL heraus. Esc: SCHREIBEN → NORMAL → Text verlassen. ⌃[ und ⌃C wirken wie Esc (Tastaturen ohne Esc-Taste; alternativ iPadOS: Modifikatortasten › Feststelltaste → Escape). Eine Zahl davor wiederholt: `5j`, `3dd`, `d2w`.

| Bibliothek | |
| --- | --- |
| `hjkl`, Pfeile, `gg`, `G` | Eintrag wählen |
| Enter, `o` | Öffnen |
| `-`, ⌫ | Eine Ebene hoch: Namenssuche beenden, sonst übergeordneter Ordner, aus „Zuletzt verwendet“ zu „Alle Unterlagen“ |
| `/` | Alle Hefte durchsuchen (Cursor steht sofort im Feld, Treffer erscheinen beim Tippen) |
| `n`, `N`, `f` | Neues Heft, Textdokument, Ordner |
| `r`, `m`, `P` | Umbenennen, Verschieben, Anheften |
| `yy`, `dd` | Duplizieren, Papierkorb (mit Rückfrage) |
| `e`, `s` | PDF, Teilen als .noty |

| SEITE | |
| --- | --- |
| `jk hl`, Pfeile | Scrollen; bei Objektauswahl: Objekt um 1 pt schieben |
| ⌃d ⌃u, ⌃f ⌃b, Leer, ⇧Leer | Halbe/ganze Ansicht |
| `J K`, `] [` | Nächste/vorherige Seite |
| `gg`, `G`, `5G`, `gp` | Erste, letzte, fünfte Seite, Seite eingeben |
| `zz`, `+ = -` | Einpassen, Zoom |
| `tp tb tm te tE tl ts ti tt tL tr` | Stift, Bleistift, Marker, Radierer, genauer Radierer, Lasso, Formen, Bilder, Text, Laser, Lesen |
| `i`, `a` | Schreiben (Textdokument: auf dieser Seite/am Textende; Heft: neues Feld) |
| Tab, ⇧Tab | Nächstes/vorheriges Objekt der Seite |
| Enter | Ausgewähltes Feld bearbeiten |
| `x`/`dd`, `yy`, `X`, `p`, `D`, `A` | Löschen, Kopieren, Ausschneiden, Einfügen, Duplizieren, alles wählen |
| `u`, ⌃r | Rückgängig, Wiederholen |
| `gs`, `go`, `m` | Seitenleiste, Gliederung/Inhalt, Lesezeichen |
| `gq`, `ZZ` | Schließen |
| `/` | Suchen |

| NORMAL (Text) | |
| --- | --- |
| `h l`, `j k` | Zeichen, angezeigte Zeile (über Seitengrenzen) |
| `w b e`, `0 ^ $`, `{ }`, `gg G`, `12G` | Wort, Zeile, Absatz, Text, Zeile 12 (im Textdokument: ganzes Dokument) |
| `i a I A o O` | Schreiben: am Cursor, dahinter, Zeilenanfang/-ende, neue Zeile unten/oben |
| `x X`, `J` | Zeichen löschen, Zeilen verbinden |
| `d c y` + Bewegung | Löschen, Ändern, Kopieren: `dw`, `d$`, `dG`, `ciw`, `y2w`, `dj` … |
| `dd cc yy`, `D C S Y` | Ganze Zeilen bzw. bis Zeilenende |
| `p P` | Einfügen dahinter/davor (kopierte Zeilen als eigene Zeile) |
| `v V`, dann `d c y x ⌫` | Markieren, auch über Seiten |
| `u`, ⌃r | Rückgängig, Wiederholen |

Eine „Zeile“ ist wie in vim ein Absatz bis zum Zeilenumbruch; nur `j`/`k` folgen den angezeigten Zeilen.

## Grenzen

- Nicht per Tastenbelegung erreichbar: Inhalte von Sheets und Systemdialogen, Farbauswahl, Zeichnen. Die Palette öffnet die Sheets; darin hilft iPadOS: Bedienungshilfen › Tastaturen › „Voller Tastaturzugriff“ (Tab/Pfeile/Leertaste für jedes Element).
- Gesetzessammlung, Seitenleiste und Suchsheet haben keine eigene Vim-Belegung.
- Nur Klartext in Registern; `.` (Wiederholen), Makros und `:s` fehlen.
- Auf einer deutschen Tastatur ist `^` eine Tottaste: dafür `0` oder `w` nutzen.
- ⇧⌘7/8/9 sind zusätzlich als `/ ( )` hinterlegt (deutsche Belegung); welche Variante iPadOS meldet, ist ungeprüft.

## Gerätetest (gebündelt, alles **ungeprüft**)

1. **Tastenzustellung zuerst:** Heft öffnen, Stift aktiv, `j j j`, `k`, `tt`, `tp`, `gg`, `G`; oben links steht SEITE. Text öffnen, tippen, Esc → NORMAL (breiter Cursor), `j` tippt nichts. Scheitert das, ist die Zustellung über `pressesBegan` falsch angenommen und alles Weitere hängt daran.
2. **Bibliothek:** direkt nach dem Start ohne Antippen `j`, `l`, `gg`, `G`, Enter, Heft schließen, wieder `j`, `-`; `dd` zeigt die Rückfrage; `-` aus „Zuletzt verwendet“; nach Suche und nach geschlossenem Sheet weiter steuerbar. `P` lässt nichts aufleuchten.
3. **⌘A:** Textdokument über 3 Seiten mit Cursor, mit Stift, mit Textwerkzeug ohne Cursor; danach ⌘C (Einfügen in anderer App), Tippen, ⌫, ⌘B, ⌘Z. Heft mit Stift, Lasso, Text, Laser.
4. **Text-Normalmodus:** `w b e 0 $ gg G`, `dd`, `dw`, `ciw`, `yy`, `p`, `v`, `V` auch über Seitengrenzen; `5j`, `3dd`; Undo je Befehl.
5. **Objekte:** Tab, Enter, `x`, `yy`, `p`, `D`, `hjkl` schiebt; Esc.
6. **Palette und Hilfe:** `:`, `?`, ⇧⌘P, ⌘/; Pfeile, Enter, Esc; `:w`, `:q`, `:12`; danach reagieren Tasten weiter.
7. **Zeilenumbruch am Seitenende:** Enter auf der letzten Zeile (kein roter Rahmen, Cursor auf der nächsten Seite, ⌫ zurück, PDF läuft); Überschrift über einen Seitenwechsel; langes Einfügen (50 Seiten) ohne spürbares Hängen.
8. **Layouts:** `:`, `?`, `/`, `{`, `[`, `$`, `+` mit der eigenen Tastatur; ⇧⌘7/8/9; ⌘+ ⌘-.
9. **Halten:** `j` gehalten scrollt, loslassen stoppt sofort.
10. **Abschalten:** Einstellung aus → alles wie vor Build 65, Esc beendet den Text sofort.

**Diagnose:** Mit Einstellungen › Diagnose (ab Neustart) protokolliert `KeyboardRouter` jede Taste mit Kontext, Ergebnis und First Responder: `idevicesyslog | rg noty.keys`. Getippter Text erscheint nur als `(typing)`. Kommt zu einer Taste keine Zeile, hat sie keinen unserer Responder erreicht.

## Helix-Modell (Core, App noch nicht angebunden)

Der Vim-Modus wird durch ein Helix-Modell ersetzt: Auswahl zuerst, dann Aktion, Modi NOR/INS/SEL. **Implementiert und getestet in Core** (`TextEngine`, `HelixKeymap`, `HelixParser`), **in der App noch nicht angebunden**: Bis dahin gelten die Tabellen oben, die alte Core-API (`KeyMap`, `KeySequenceParser`, `TextMotions`) bleibt bis zur Umstellung bestehen.

- `TextEngine` ist reiner Zustand aus Text (UTF-16 auf Graphemgrenzen), mehreren Auswahlen (`anchor`, `head`, Hauptauswahl), Modus, Register und Suche. `perform` liefert Edits von hinten nach vorn in Versätzen des alten Texts, zusätzlich `combinedEdit` als eine Ersetzung für einen Undo-Schritt. `sync` übernimmt natives Tippen, Antippen und Undo aus der App. Angezeigte Zeilen kommen über `TextEngineLayout`.
- `HelixKeymap.bindings` ist die einzige Tabelle für Parser, Übersicht (`groups`), Palette (`commands`) und Which-Key (`menu`). `HelixParser.feed` liefert `.pending(menu:)` mit dem aktuellen Knoten.
- Geprüft gegen das echte Helix 25.07.1 im PTY: rund 3600 Abläufe (Zufall und Randfälle) inklusive Auswahl, Cursor und Hauptauswahl, abgeglichen mit dessen Quelltext; 389 davon stehen als `HelixGoldenCases` in den Tests.

**Abweichungen von Helix**, alle wegen der App:

| Fall | Helix | noty | Grund |
| --- | --- | --- | --- |
| Text endet ohne Zeilenumbruch (Normalfall bei Notizen): `xd`, `xy` auf der letzten Zeile | lässt `"a\n"` stehen, Register ohne Umbruch, `p` hängt ans Zeilenende | Zeile samt Umbruch davor weg (`"a"`), Register als Zeile, `p` setzt sie als eigene Zeile | Dateien enden dort immer mit Umbruch, Notizen nicht |
| Zeilen-`p` hinter der letzten Zeile ohne Umbruch, oder in leeren Text | klebt an die Zeile (`"abcx\n"`) | eigene Zeile, kein Umbruch am Textende | wie oben |
| `xxc` über alle Zeilen ohne Schlussumbruch | lässt `"\n"` | leerer Text | wie oben |
| `a` mit Auswahl bis zum Textende | fügt einen Umbruch ein | fügt nichts ein | kein Platzhalter nötig, Caret darf am Ende stehen |
| `mi(`, `md(` usw. mit Auswahl am Textende | Fehler `RangeExceedsText` | funktioniert | wie oben |
| `o`, `O`, Enter, `c` auf Zeilen | rücken automatisch ein, Paare schließen selbst | kein Auto-Einzug, keine Auto-Paare | INS ist natives Tippen; Listen regelt `TextListEditing` |
| Spalten bei `C` und im logischen `j`/`k` | Terminalzellen (Tab 4, Emoji 2) | Grapheme; in der App entscheidet das Layout | proportionale Schrift |
| Wortklassen, `f`/`t`, `r` | Unicode-Zeichen | Grapheme | „Grapheme respektieren“ |
| ⌃f ⌃b | Ansicht blättert, Cursor bleibt möglichst | Cursor bewegt sich eine Ansicht (wie ⌃d ⌃u) | Engine kennt keine Ansicht |
| Ungültiger regulärer Ausdruck bei `/`, `s` | Fehlermeldung | wörtlich gesucht | Notizen enthalten einzelne Klammern |
| `mr(` ohne Treffer | zweite Taste geht in den Normalmodus | Parser nimmt beide Zeichen, nichts passiert | Parser kennt den Text nicht |
| Esc in NOR | tut nichts | geht eine Ebene zurück: Auswahl zusammenziehen, nur Hauptauswahl, Text verlassen | Bedienmodell der App |
| `?` | rückwärts suchen | im Text ebenso, in Bibliothek und Seite Tastenübersicht | im Text bleibt die Übersicht über `Space ?` und ⌘/ erreichbar |
| `y` auf leerer Stelle | leert das Register | Register bleibt | Zwischenablage nicht versehentlich leeren |

Bewusst wie Helix, obwohl es überrascht: `w` wählt auch die Leerzeichen dahinter, `ge` geht an den Anfang der letzten Zeile, `G` ohne Zähler tut nichts, `5G` in SEL zieht die Auswahl zusammen, `r` ersetzt auch Zeilenumbrüche, `n` geht auch nach `?` vorwärts, `p` in SEL lässt die Auswahl stehen, `>` fügt einen Tab ein (`TextEngine.indentUnit`).

Nicht enthalten: benannte Register, `.`, Makros, Sprungliste, ⌥C, `S`, ⌥s, `[`/`]`.

## Aufbau

Reine Logik in Core: `KeyMap` (einzige Tastentabelle, speist Hilfe und Palette), `KeySequenceParser`, `TextMotions`, `Notebook.editingTextFlow`/`restylingTextFlow` (`TextFlowRange.swift`). In der App nimmt `KeyboardRouter` die Tastendrücke entgegen (`pressesBegan` in `PageTextView`, `DrawingCanvasView`, `WorksheetView`, `KeyboardHostView`), ⌘-Kürzel bleiben bei Menü und Key Commands. `TextFlowSelection` hält Auswahlen über Seiten, die jede `TextObjectLayer` für ihren Teil markiert; Text innerhalb einer Seite bleibt native Auswahl. Kein Formatwechsel; einzige neue Einstellung `noty.keyboard.mode` in UserDefaults.
