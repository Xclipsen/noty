# Tastatur: Kürzel und Tastaturmodus

Stand: Build 67 auf `phase1/app`. **Implementiert, erfolgreich gebaut, Core-Tests bestanden. Nicht installiert, am iPad ungeprüft.** Linux hat keinen iOS-Simulator: Engine, Tastentabelle, Parser und Bereichsbearbeitung sind getestet (`HelixEngineTests`, `HelixKeymapTests`, `HelixParserTests`, `KeyboardCommandsTests`, `TextFlowRangeTests`), Tastenzustellung, Fokus, Anzeige und TextKit-Messung **nicht**. Der Zustellweg (`KeyPressGate`, Rückholen des Fokus) stammt aus Phase 0 und ist selbst noch ungeprüft.

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

**⌘A:** Im Text das ganze Feld; im Textdokument der ganze Text über alle Seiten (blau markiert; ⌘C/⌘X/⌘V, ⌫ und Formatierung wirken auf alles, beim Schreiben auch Tippen, ⌘Z als ein Schritt). Ohne Cursor im Textdokument dasselbe, dann in NOR, damit kein Buchstabe versehentlich alles ersetzt. Außerhalb von INS wirkt ⌘A wie `%`. Im Heft alles Auswählbare der Seite, mit jedem Werkzeug. Das Bearbeitungsmenü „Alles auswählen“ bleibt die native Auswahl dieser Seite.

Außerhalb von INS: ⌘V ersetzt eine breite Auswahl, sonst wie `P`; ⌘X schneidet eine breite Auswahl aus. Beides läuft über Engine und Register.

## Tastaturmodus

Einstellungen › Editor › „Tastaturmodus (wie Helix)“, Standard an. Wirkt nur auf Hardware-Tastaturen. Modell wie [Helix](https://helix-editor.com): **erst auswählen, dann handeln**. `w` wählt ein Wort, `d` löscht es.

**Modus:** `NOR` (Buchstaben sind Befehle), `INS` (natives Tippen), `SEL` (Bewegungen erweitern die Auswahl, `v` schaltet um). Auf Seite und Bibliothek steht `NOR` mit `SEITE`/`BIBLIOTHEK` als Kontext. Die Anzeige erscheint, sobald eine Taste gedrückt wurde: im Editor oben links unter der Zurück-Taste, in der Bibliothek unten links. Daneben stehen Zähler und angefangene Folge (`3g`), „n Auswahlen“ und kurze Hinweise (`Kein Treffer`, `Suche von vorn`, `Kein Paar gefunden`).

**Wege:** `i` führt von der Seite immer in den Text (Textdokument: Cursor auf der sichtbaren Seite; Heft: gewähltes Feld, sonst neues Feld). Esc führt Schritt für Schritt zurück: INS → NOR, SEL → NOR, breite Auswahl → Cursor, mehrere Auswahlen → Hauptauswahl, zuletzt Text verlassen; auf der Seite hebt es die Objektauswahl auf. ⌃[ und ⌃C wirken wie Esc (Tastaturen ohne Esc-Taste; alternativ iPadOS: Modifikatortasten › Feststelltaste → Escape). Antippen eines Texts schreibt immer, auch aus NOR und SEL heraus.

**Hilfe:** In jedem Kontext `Space h` und ⌘/ (Tastenübersicht, aktueller Kontext zuerst), `:` und ⇧⌘P (Befehlspalette: alle Befehle des Kontexts und die Menüfunktionen per Suche, dazu `:w`, `:q`, `:wq`, Seitenzahl). Bei offenem Menü (`g`, `m`, `z`, `t`, `Space` und Untermenüs) und bei Tasten, die ein Zeichen erwarten (`mi`, `f`), zeigt ein Popup unter der Modusanzeige sofort die nächsten Tasten; es nimmt keinen Fokus und geht bei Ausführung oder Esc.

Eine Zahl davor wiederholt: `5j`, `3w`, `2gn`. Auf der Seite meint sie bei `G`, `gg` und `ge` die Seite (`5G`).

### Bibliothek

| Taste | |
| --- | --- |
| `hjkl`, Pfeile, `gg`, `ge` | Eintrag wählen |
| Enter, `o` | Öffnen |
| `-`, ⌫ | Eine Ebene hoch: Namenssuche beenden, sonst übergeordneter Ordner, aus „Zuletzt verwendet“ zu „Alle Unterlagen“ |
| `/`, `Space f` | Alle Hefte durchsuchen |
| `?`, `Space h` | Tastenübersicht |
| `n`, `N`, `f` | Neues Heft, Textdokument, Ordner |
| `r`, `m`, `P` | Umbenennen, Verschieben, Anheften |
| `y`, `d` | Duplizieren, Papierkorb (mit Rückfrage) |
| `Space e p/m/t/n` | PDF, Markdown, Text, `.noty` des gewählten Eintrags |

### Seite

| Taste | |
| --- | --- |
| `hjkl`, Pfeile | Scrollen; bei Objektauswahl: Objekt um 1 pt schieben |
| ⌃d ⌃u, ⌃f ⌃b | Halbe/ganze Ansicht |
| `gn`, `gp` | Nächste/vorherige Seite |
| `gg`, `ge`, `G`, `5G` | Erste, letzte Seite, Seite eingeben, Seite 5 |
| `zz`, `z+ z-`, `+ = -` | Einpassen, Zoom |
| `tp tb tm te tE tl ts ti tt tL tr` | Stift, Bleistift, Marker, Radierer, genauer Radierer, Lasso, Formen, Bilder, Text, Laser, Lesen; dasselbe unter `Space t` |
| `i`, Enter | Gewähltes Feld bearbeiten, sonst schreiben |
| Tab, ⇧Tab | Nächstes/vorheriges Objekt der Seite |
| `d`, `y`, `p`, `D`, `%` | Löschen, Kopieren, Einfügen, Duplizieren, alles wählen |
| `u`, `U` | Rückgängig, Wiederholen |
| `/`, `Space f` | Im Heft suchen, alle Hefte suchen (schließt das Heft, die Suche über alles lebt in der Bibliothek) |
| `Space s o m q` | Seitenleiste, Gliederung, Lesezeichen, Schließen |
| `Space e p/c/m/t/n` | PDF, diese Seite als PDF, Markdown, Text, `.noty` |

### Text (NOR und SEL)

| Taste | |
| --- | --- |
| `h l`, `j k`, Pfeile | Zeichen, angezeigte Zeile (über Seitengrenzen) |
| `w b e`, `W B E` | Wort, Ende; groß: langes Wort bis Leerraum. Die Auswahl läuft mit |
| `f t F T` + Zeichen | Bis zum Zeichen, einschließlich oder davor, vorwärts oder zurück |
| `gg ge gh gl gs`, `5G` | Textanfang, letzte Zeile, Zeilenanfang, -ende, erstes Zeichen, Zeile 5 (im Textdokument: ganzes Dokument) |
| ⌃d ⌃u ⌃f ⌃b | Halbe/ganze Ansicht |
| `%`, `x`, `X` | Alles, Zeile (wiederholt erweitert), auf ganze Zeilen erweitern |
| `;`, `⌥;`, `,`, `v` | Zusammenziehen, Auswahl umdrehen, nur Hauptauswahl, SEL |
| `C`, `s` | Auswahl in die nächste Zeile kopieren, Treffer in der Auswahl wählen |
| `mi`, `ma` + Zeichen | Innerhalb, mitsamt: `w` Wort, `W` langes Wort, `p` Absatz, `m` nächstes Paar, sonst Klammer oder Anführungszeichen |
| `mm`, `ms`, `md`, `mr` | Passende Klammer, umschließen, Umschließung entfernen, ersetzen |
| `d c y` | Auswahl löschen, ändern, kopieren |
| `p P R`, `r` + Zeichen | Einfügen dahinter, davor, Auswahl durch Kopiertes ersetzen, jedes Zeichen ersetzen |
| `~`, `` ` ``, `J`, `> <` | Groß/klein tauschen, klein, Zeilen verbinden, ein-/ausrücken |
| `i a I A o O` | Schreiben vor, hinter der Auswahl, am Zeilenanfang, -ende, neue Zeile darunter, darüber |
| `/`, `?`, `n`, `N`, `*` | Suchen, rückwärts, nächster, vorheriger Treffer, Auswahl als Suchbegriff |
| `u`, `U` | Rückgängig, Wiederholen |
| `Space …` | Wie auf der Seite, Werkzeuge unter `Space t` (`t` ist im Text eine Bewegung), `zz z+ z-` ebenso |

Eine „Zeile“ reicht wie in Helix bis zum Zeilenumbruch; nur `j`/`k` folgen den angezeigten Zeilen.

**Suche:** `/`, `?` und `s` öffnen die Eingabezeile unter der Modusanzeige. Treffer erscheinen beim Tippen als Auswahl, Enter bestätigt, Esc stellt die Auswahl und den vorigen Suchbegriff wieder her. Der Suchbegriff ist ein regulärer Ausdruck (Kleinschreibung ignoriert Groß/klein), was keiner ist, gilt wörtlich. Auf Seite und Bibliothek öffnet `/` weiter die bestehende Suche, ⌘F ebenso überall.

**Zwischenablage:** `y`, `d`, `c` füllen Register und Systemzwischenablage. Beim Einfügen gewinnt, was seitdem woanders kopiert wurde; ein Text mit Zeilenumbruch am Ende gilt als ganze Zeilen.

## Grenzen

- Nicht per Tastenbelegung erreichbar: Inhalte von Sheets und Systemdialogen, Farbauswahl, Zeichnen. Die Palette öffnet die Sheets; darin hilft iPadOS: Bedienungshilfen › Tastaturen › „Voller Tastaturzugriff“ (Tab/Pfeile/Leertaste für jedes Element).
- Gesetzessammlung, Seitenleiste und Suchsheet haben keine eigene Belegung.
- Die App zeigt nur die Hauptauswahl (`C`, `s` bilden die übrigen in der Engine); Register nur als Klartext.
- Auf einer deutschen Tastatur sind `^`, `` ` `` und je nach Layout `~` Tottasten: Der Router sieht sie nicht als Zeichen, in der Eingabezeile gehen auch `é`-artige Kompositionen nicht. ⌥ tippt weiter, was es tippt (`[ ] { } | @`), nur `⌥;` ist ein Befehl.
- ⇧⌘7/8/9 sind zusätzlich als `/ ( )` hinterlegt (deutsche Belegung); welche Variante iPadOS meldet, ist ungeprüft.
- Die Formatleiste liegt im Fenster der Tastatur, kein App-Overlay kann über ihr liegen. Popup und Eingabezeile stehen deshalb oben links, wo sie nicht hinreicht.

## Gerätetest (gebündelt, alles **ungeprüft**)

1. **Tastenzustellung zuerst:** Heft öffnen, Stift aktiv, `j j j`, `k`, `tt`, `tp`, `gg`, `ge`; oben links steht `NOR SEITE`. `Space` zeigt das Popup, Esc schließt es. Text öffnen, tippen, Esc → `NOR` (breiter Cursor), `j` tippt nichts, `w` wählt, `d` löscht. Scheitert das, ist die Zustellung über `pressesBegan` falsch angenommen und alles Weitere hängt daran.
2. **Bibliothek:** direkt nach dem Start ohne Antippen `j`, `l`, `gg`, `ge`, Enter, Heft schließen, wieder `j`, `-`; `d` zeigt die Rückfrage; nach Suche und nach geschlossenem Sheet weiter steuerbar. `P` lässt nichts aufleuchten. `Space e m` am gewählten Eintrag.
3. **Modus überall gleich:** `i` im Textdokument (Cursor auf der sichtbaren Seite), im Heft mit gewähltem Feld, im Heft ohne Feld; dreimal Esc führt zurück bis zur Seite. Antippen aus NOR und SEL schreibt. Esc nach `i`, nach `a`, nach Antippen und Tippen.
4. **Text über Seiten:** Textdokument mit 3 Seiten: `j`/`k` über die Grenze (Spalte bleibt), `v` mit `j` bis auf die nächste Seite (Markierung auf beiden, Ansicht folgt), `d`, `u` als ein Schritt; `%`, `y`, `p`; `x` mehrfach über die Grenze; `o` auf der letzten Zeile einer Seite; `c` über die Grenze, dann tippen.
5. **Auswahl und Register:** `w b e f t`, `mi(`, `ms"`, `mr([`, `md(`; Format zwischen den Enden bleibt (fett im Inneren); `y`, dann in anderer App einfügen und umgekehrt; ⌘V, ⌘X, ⌘C aus NOR.
6. **Suche:** `/` tippen (Treffer wandern, auch auf andere Seiten), Enter, `n`, `N`; `?`; Esc stellt her; `*`; `s` in einer breiten Auswahl, „n Auswahlen“, `d` wirkt auf alle; ⌘V in der Eingabezeile.
7. **Undo:** `d`, `u`, `U` je ein Schritt; ⌘Z danach; Undo mit Fokus auf anderer Seite lässt den Modus stehen.
8. **Palette, Übersicht:** `:` und ⇧⌘P aus Text, Seite, Bibliothek; ein Textbefehl aus der Palette (`Alles wählen`) wirkt und der Cursor kommt zurück; `Space h`, ⌘/, `?`; `:w`, `:q`, `:12`; danach reagieren Tasten weiter.
9. **Seite:** Tab, Enter, `d`, `y`, `p`, `D`, `%`, `hjkl` schiebt, Esc; `5G`, `G`, `gn`, `gp`, `ge`; `Space e p`, `Space e c`; `Space f` schließt und öffnet die Suche.
10. **Layout:** `:`, `?`, `/`, `mi{`, `mi[`, `+`, `;`, `,`, `<`, `>`, `⌥;` mit der eigenen Tastatur; ⇧⌘7/8/9; ⌘+ ⌘-.
11. **Halten:** `j` gehalten fährt, auch über eine Seitengrenze, loslassen stoppt sofort; `n` gehalten.
12. **Zeilenumbruch am Seitenende:** Enter auf der letzten Zeile (kein roter Rahmen, Cursor auf der nächsten Seite, ⌫ zurück, PDF läuft); langes Einfügen (50 Seiten) ohne spürbares Hängen.
13. **Abschalten:** Einstellung aus → Esc beendet den Text sofort, keine Modusanzeige.

**Diagnose:** Mit Einstellungen › Diagnose (ab Neustart) protokolliert `KeyboardRouter` jede Taste mit Kontext, Ergebnis und First Responder: `idevicesyslog | rg noty.keys`. Getippter Text erscheint nur als `(typing)`, auch in der Eingabezeile. Kommt zu einer Taste keine Zeile, hat sie keinen unserer Responder erreicht.

## Helix-Modell

Die Engine ist in Core gegen das echte Helix geprüft, die App bildet sie ab.

- `TextEngine` ist reiner Zustand aus Text (UTF-16 auf Graphemgrenzen), mehreren Auswahlen (`anchor`, `head`, Hauptauswahl), Modus, Register und Suche. `perform` liefert Edits von hinten nach vorn in Versätzen des alten Texts, zusätzlich `combinedEdit` als eine Ersetzung. `sync` übernimmt natives Tippen, Antippen und Undo aus der App. Angezeigte Zeilen kommen über `TextEngineLayout`.
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
| `?` | rückwärts suchen | im Text ebenso, in Bibliothek und Seite Tastenübersicht | feste Übersicht in jedem Kontext: `Space h` und ⌘/; `Space ?` öffnet die Palette |
| `y` auf leerer Stelle | leert das Register | Register bleibt | Zwischenablage nicht versehentlich leeren |
| Eingabezeile von `/`, `?`, `s` | eigener Editor mit Cursor | Anzeige im Overlay, Tasten laufen weiter durch den Router: nur anhängen, ⌫, ⌘V, Enter, Esc; keine Tottasten | der Fokus bleibt in der Textansicht, sonst endet der Text (Formatleiste, Auswahl, Caret-Führung) |
| Mehrere Auswahlen | alle sichtbar | nur die Hauptauswahl sichtbar, die Modusanzeige nennt „n Auswahlen“; `C`, `s`, `d` wirken auf alle | Phase 1 |
| Esc nach einem Antippen | gibt es nicht | Cursor aufs zuletzt getippte Zeichen, ohne Tippen dorthin, wo der Tipp ihn setzte; hinter `i`, `a` usw. wie Helix (getippter Text gehört zur Auswahl) | ein Tipp hat keine Auswahl, die mitwachsen könnte |

Bewusst wie Helix, obwohl es überrascht: `w` wählt auch die Leerzeichen dahinter, `ge` geht an den Anfang der letzten Zeile, `G` ohne Zähler tut nichts, `5G` in SEL zieht die Auswahl zusammen, `r` ersetzt auch Zeilenumbrüche, `n` geht auch nach `?` vorwärts, `p` in SEL lässt die Auswahl stehen, `>` fügt einen Tab ein (`TextEngine.indentUnit`).

Nicht enthalten: benannte Register, `.`, Makros, Sprungliste, ⌥C, `S`, ⌥s, `[`/`]`.

## Aufbau

**Core:** `HelixKeymap`, `HelixParser`, `TextEngine`, `KeyPressGate` und `KeyPalette` (`KeyboardCommands.swift`), `TextLines`, `Notebook.editingTextFlow`/`restylingTextFlow` (`TextFlowRange.swift`).

**App:** `KeyboardRouter` nimmt die Tastendrücke entgegen (`pressesBegan` in `PageTextView`, `DrawingCanvasView`, `WorksheetView`, `KeyboardHostView`), ⌘-Kürzel bleiben bei Menü und Key Commands. Er hält Parser und Engine und bindet `HelixAction` an `ContentView.runKey`, `LibraryView.runKey` und `ObjectEditingLayer`. INS läuft am Parser vorbei, nur Esc geht an die Engine.

**Text** (`TextObjectLayer+Keyboard.swift`): Vor jedem Befehl übernimmt die Engine Text und Auswahl des Bildschirms (`keyboardSync`: ganzer Fluss oder Feld). Danach zeigt `keyboardShowSelection` die Hauptauswahl: innerhalb einer Seite native `selectedRange`, über Seiten `TextFlowSelection` mit dem Caret am Cursor, ein Cursor auf einem Zeichen als breiter Caret (`normalCaret`). Edits gehen auf einer Seite über `applyListEdits`, über Seiten über `TextFlowActions.edit`, beides ein Undo-Schritt; die einzelnen Edits statt `combinedEdit` erhalten Formate dazwischen. `j`/`k` messen im `NSLayoutManager` der Textansicht, auf anderen Seiten in `TextObjectLayout` (`KeyboardLineLayout`).

**Fallstricke, die der Code absichert:** Nach einem lokalen Edit im Fluss liegt noch eine Fokusanforderung des Edits an, eine neuere ersetzt sie (`moveCaret`). Wechselt der Cursor die Seite, erhält `handoff` den Modus; läuft eine Anforderung, ist die Ansicht hinter der Engine, also zählt deren Auswahl (die Anforderung läuft nach 1,5 s aus, falls sie nie ankommt). Ein Flussedit über Seiten ändert das Modell sofort, die Ansichten erst beim nächsten Update: Bis dahin setzt `viewIsCurrent` keine Auswahl und nimmt keinen lokalen Edit, sonst würde `textViewDidChangeSelection` den alten Text über den neuen schreiben. Die Palette nimmt den Fokus: `holdText`/`returnToHeldText` halten den Text so lange, damit ihre Textbefehle ihn finden; ein leeres freies Feld verschwindet dabei und beendet den Text. Undo setzt `TextFlowSelection` zurück (`textChangedElsewhere`), Offsets werden geklemmt.

Kein Formatwechsel; einzige Einstellung `noty.keyboard.mode` in UserDefaults.
