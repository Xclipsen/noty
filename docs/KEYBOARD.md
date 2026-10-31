# Tastatur: Kürzel und Tastaturmodus

Stand: Build 68 auf `phase1/fixes` (Review-Befunde zu Build 67). **Implementiert, erfolgreich gebaut, Core-Tests bestanden, installiert, am iPad ungeprüft.** Darauf aufbauend Branch `extras/tastatur-ui` (Seitenleiste, Suchsheet, Gesetze, Dialoge, Farbe): **implementiert, erfolgreich gebaut, Core-Tests bestanden, nicht installiert, am iPad ungeprüft.** Linux hat keinen iOS-Simulator: Engine, Tastentabelle, Parser, Bereichsbearbeitung und die Tastensperre sind getestet (`HelixEngineTests`, `HelixKeymapTests`, `HelixParserTests`, `KeyboardCommandsTests`, `TextFlowRangeTests`), Tastenzustellung, Fokus, Anzeige und TextKit-Messung **nicht**. Der Zustellweg (`KeyPressGate`, `KeyDeliveryLatch`, Rückholen des Fokus) ist selbst noch ungeprüft.

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
| ⌘↩ | Seitenumbruch (in NOR und SEL vor die Auswahl) | Textdokument |
| Tab, ⇧Tab | Listenebene | Text |
| ⇧⌘P, ⌘/ | Befehlspalette, Tastenübersicht (ohne Tastaturmodus enthält die Palette keine Textbefehle und keine Eingabezeile, beides braucht die Engine) | überall |

**⌘A:** Im Text das ganze Feld; im Textdokument der ganze Text über alle Seiten (blau markiert; ⌘C/⌘X/⌘V, ⌫ und Formatierung wirken auf alles, beim Schreiben auch Tippen, ⌘Z als ein Schritt). Ohne Cursor im Textdokument dasselbe, dann in NOR, damit kein Buchstabe versehentlich alles ersetzt. Außerhalb von INS wirkt ⌘A wie `%`. Im Heft alles Auswählbare der Seite, mit jedem Werkzeug. Das Bearbeitungsmenü „Alles auswählen“ bleibt die native Auswahl dieser Seite.

Außerhalb von INS: ⌘V ersetzt eine breite Auswahl, sonst wie `P`; ⌘X schneidet eine breite Auswahl aus. Beides läuft über Engine und Register.

## Tastaturmodus

Einstellungen › Editor › „Tastaturmodus (wie Helix)“, Standard an. Wirkt nur auf Hardware-Tastaturen. Modell wie [Helix](https://helix-editor.com): **erst auswählen, dann handeln**. `w` wählt ein Wort, `d` löscht es.

**Modus:** `NOR` (Buchstaben sind Befehle), `INS` (natives Tippen), `SEL` (Bewegungen erweitern die Auswahl, `v` schaltet um). Auf Seite und Bibliothek steht `NOR` mit `SEITE`/`BIBLIOTHEK` als Kontext. Die Anzeige erscheint, sobald eine Taste gedrückt wurde: im Editor oben links unter der Zurück-Taste, in der Bibliothek unten links. Daneben stehen Zähler und angefangene Folge (`3g`), „n Auswahlen“ und kurze Hinweise (`Kein Treffer`, `Suche von vorn`, `Kein Paar gefunden`, `Nur Hauptauswahl`).

**Wege:** `i` führt von der Seite immer in den Text (Textdokument: Cursor auf der sichtbaren Seite; Heft: gewähltes Feld, sonst neues Feld). Esc führt Schritt für Schritt zurück: INS → NOR, SEL → NOR, breite Auswahl → Cursor, mehrere Auswahlen → Hauptauswahl, zuletzt Text verlassen; auf der Seite hebt es die Objektauswahl auf. Ein Druck wirkt genau eine Ebene: Offene Übersicht, Eingabezeile oder angefangene Folge gehen zuerst, Marked Text wird vorher abgeschlossen. ⌃[ und ⌃C wirken wie Esc (Tastaturen ohne Esc-Taste; alternativ iPadOS: Modifikatortasten › Feststelltaste → Escape). Antippen eines Texts schreibt immer, auch aus NOR und SEL heraus; eine offene Eingabezeile geht dabei zu, die Auswahl bleibt, wie sie ist. Ein Fokuswechsel der App (⌘Z, Rückgängig-Knopf, ⌘+ oder ⌘1 mit Sprung auf eine andere Seite, Gliederung) lässt den Modus stehen. Öffnet Rückgängig einen Text von der Seite aus, steht er in NOR.

**Hilfe:** In jedem Kontext `Space h` und ⌘/ (Tastenübersicht, aktueller Kontext zuerst), `:` und ⇧⌘P (Befehlspalette: alle Befehle des Kontexts und die Menüfunktionen per Suche, im geöffneten Dokument dazu `:w`, `:q`, `:wq`, Seitenzahl; in der Bibliothek sind das Suchwörter). Bei offenem Menü (`g`, `m`, `z`, `t`, `Space` und Untermenüs) und bei Tasten, die ein Zeichen erwarten (`mi`, `f`), zeigt ein Popup unter der Modusanzeige sofort die nächsten Tasten; es nimmt keinen Fokus und geht bei Ausführung oder Esc.

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
| `Space e p/m/t/n/w/r` | PDF, Markdown, Text, `.noty`, Word, RTF des gewählten Eintrags |

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
| `Space s o m` | Seitenleiste, Gliederung, Lesezeichen: zeigen und Tasten dorthin |
| `Space M` | Lesezeichen dieser Seite setzen oder entfernen |
| `Space l`, `Space c` | Gesetzessammlung, Farbe und Strich |
| `Space q` | Schließen |
| `Space e p/c/m/t/n/w/r` | PDF, diese Seite als PDF, Markdown, Text, `.noty`, Word, RTF |

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
| `i a I A o O` | Schreiben vor, hinter der Auswahl, am Zeilenanfang, -ende, neue Zeile darunter, darüber (siehe „Mehrere Auswahlen“) |
| `/`, `?`, `n`, `N`, `*` | Suchen (über Seiten, ein manueller Umbruch liest sich wie ein Leerzeichen), rückwärts, nächster, vorheriger Treffer, Auswahl als Suchbegriff |
| `Space b` | Seitenumbruch vor der Auswahl (Textdokument) |
| `u`, `U` | Rückgängig, Wiederholen |
| `Space …` | Wie auf der Seite, Werkzeuge unter `Space t` (`t` ist im Text eine Bewegung), `zz z+ z-` ebenso |

Eine „Zeile“ reicht wie in Helix bis zum Zeilenumbruch; nur `j`/`k` folgen den angezeigten Zeilen.

### Seitenleiste (`SEITENLEISTE`)

`Space s` zeigt die Seitenleiste und gibt ihr die Tasten, `Space o` die Gliederung (Textdokument) oder das PDF-Inhaltsverzeichnis, `Space m` die Lesezeichen. Der Rahmen zeigt die gewählte Seite. Die Tasten gehen zurück bei Esc, Enter, Antippen eines Texts sowie Schreiben auf der Seite.

| Taste | |
| --- | --- |
| `hjkl`, Pfeile, ⌃n ⌃p, ⌃d ⌃u, `gg`, `ge` | Eintrag wählen |
| Enter | Seite öffnen, Tasten zurück auf die Seite |
| Esc, `Space s` | Zurück auf die Seite; `Space s` klappt die Leiste dazu ein |
| Tab, ⇧Tab, `f` | Seiten oder Inhalt, alle Seiten oder Lesezeichen |
| `b` | Lesezeichen setzen oder entfernen |
| `y`, `x`, `p`, `D` | Seite kopieren, ausschneiden, dahinter einfügen, duplizieren |
| `a`, `r`, `t` | Seite hinzufügen, anpassen, Seitenpapierkorb |
| `K`, `J` | Seite nach oben, nach unten |
| `d`, `X` | In den Seitenpapierkorb, Seite leeren (beide mit Rückfrage) |

Textdokumente haben davon nur `b` und `t`: ihre Seiten entstehen aus dem Text.

### Trefferliste (`SUCHE`)

Gilt für die Heftsuche und die Suche über alle Hefte. Mit Tastatur bleiben die Tasten beim Router, das Suchfeld wird nur befüllt; so kann dieselbe Taste tippen oder wandern, und es entsteht kein Fokuswechsel, von dem Tasten zurückkommen müssten.

| Taste | |
| --- | --- |
| Tippen, ⌫, ⌘V | Suchbegriff; `j`/`k` sind dabei Buchstaben |
| ↓ ↑, ⌃n ⌃p, Tab | In die Liste wechseln und wandern |
| `j k`, Pfeile, ⌃n ⌃p, ⌃d ⌃u, `gg`, `ge` | In der Liste wandern |
| Enter | Zum gewählten Treffer, ohne Wahl zum ersten |
| Esc | Schließen |
| `/` oder jeder andere Buchstabe, jede Ziffer, ⌫ | Zurück ins Suchfeld, das Zeichen zählt mit |
| Tab in der Liste | Alle Inhalte oder offene Aufgaben |

Ein angetippter Text im Suchfeld bleibt nativ (Tottasten gehen dort), dann wirken nur Esc und das normale Tippen. Wandern geht erst wieder, wenn das Feld den Fokus abgibt.

### Gesetzessammlung (`GESETZE`)

`Space l` öffnet das Fenster und gibt ihm die Tasten. Esc oder `Space l` schiebt es wie das ✕ an den Rand, die Tasten gehen an die Seite, der Text bleibt, wo er war. Fokus wandert dabei nie: Die Tasten kommen weiter über den Responder der Seite.

| Taste | |
| --- | --- |
| `j k`, Pfeile, ⌃d ⌃u ⌃f ⌃b | Scrollen |
| `gg`, `ge` | Anfang, Ende der Vorschrift |
| `n`, `N` | Nächste, vorherige Vorschrift |
| `p`, `144G` | Paragraph eingeben (Eingabezeile `§`), Paragraph direkt |
| `/` | Schnellsuche: `144 HGB` oder Volltext; die Felder des Lesers zeigen mit und suchen wie beim Tippen |
| Enter | In der Eingabezeile suchen, danach nächster Volltexttreffer |
| `t`, `o`, `B` | Gesetz wählen, Inhaltsverzeichnis, Lesezeichen und Markierungen |
| `b`, `v`, `+ = -` | Lesezeichen, Lesetext oder PDF, Schrift |
| `m`, `M` | Touch-Auswahl markieren, Markierung darin entfernen |

### Dialoge (`DIALOG`)

Gilt für die Sheets der App und jede Seite der Einstellungen, gemeinsam über `keyboardSheet()` und `keyOption()`. Der Rahmen erscheint erst mit dem ersten Tastendruck.

| Taste | |
| --- | --- |
| Tab, ⇧Tab, `j k`, ↑ ↓, ⌃n ⌃p | Zur nächsten, vorherigen Option, reihum; `gg`, `ge` Anfang, Ende |
| `h l`, ← → | Wert ändern (Auswahl, Regler) |
| Leertaste | Schalten oder auslösen |
| Enter | Gewählte Aktion, sonst Standardaktion (`Erstellen`, `Übernehmen`, `Anwenden`) |
| Esc | Abbrechen; auf einer Einstellungsseite eine Ebene zurück |
| `?`, `:` | Übersicht, Palette, im Sheet selbst |

Ein Titelfeld ist eine Option wie jede andere: Steht der Rahmen darauf, tippen alle Zeichen hinein (mit ⌫ und ⌘V, ohne Cursor und Tottasten), Tab verlässt es. Dialoge, die mit einem Feld beginnen, stehen mit Tastatur sofort darin.

**Rückfragen:** Was eine Taste auslöst (`d` in der Bibliothek, Seite löschen), fragt in der App: `j k` oder Tab wählen, Enter bestätigt, Esc bricht ab. Bei Endgültigem (Seite oder Eintrag endgültig löschen, Papierkorb leeren) steht die Wahl auf `Abbrechen`, Enter allein löscht nichts. **Namen** (`r`, `f`) laufen in der Eingabezeile. Touch behält die Systemdialoge.

### Farbe und Strich (`FARBE`)

`Space c` zeigt die Tafel unter der Modusanzeige: im Text Textfarben und Marker, sonst Farben, Strichstärke, beim Formwerkzeug Linienart, beim genauen Radierer die Breite, beim Laser die Farben. `hjkl` oder Pfeile wandern, Tab wechselt die Reihe, `1`–`9` wählen in der Reihe sofort, Enter wählt, Esc bricht ab. Bis zur Wahl ändert sich nichts.

**Suche:** `/`, `?` und `s` öffnen die Eingabezeile unter der Modusanzeige. Treffer erscheinen beim Tippen als Auswahl, Enter bestätigt, Esc stellt die Auswahl und den vorigen Suchbegriff wieder her. Der Suchbegriff ist ein regulärer Ausdruck (Kleinschreibung ignoriert Groß/klein), was keiner ist, gilt wörtlich. Auf Seite und Bibliothek öffnet `/` weiter die bestehende Suche, ⌘F ebenso überall.

**Zwischenablage:** `y`, `d`, `c` füllen Register und Systemzwischenablage. Beim Einfügen gewinnt, was seitdem woanders kopiert wurde; ein Text mit Zeilenumbruch am Ende gilt als ganze Zeilen.

## Grenzen

- Nicht per Tastenbelegung erreichbar: Systemdialoge (Dateiauswahl, Teilen, Fotos, Farbkreis des Systems) und Zeichnen; dazu Anmeldung und Zugangsdaten (Einstellungen › Konto, Backup › Weitere Optionen: nur Esc und natives Tippen, Passwörter laufen bewusst nicht über den Router), Menüs der Werkzeugoptionen außer Farbe, Strichstärke und Linienart, das Umordnen in „Werkzeugleiste anpassen“ und „Seiten anordnen“, Bereich entfernen, Gesetzesfenster andocken. Dort hilft iPadOS: Bedienungshilfen › Tastaturen › „Voller Tastaturzugriff“ (Tab/Pfeile/Leertaste für jedes Element).
- Systemalerts und `confirmationDialog` (Fehler, Touch-Rückfragen): OK und Speichern sind als Standardaktion hinterlegt, Abbrechen kommt vom System. Ob Enter und Esc dort wirken, ist ungeprüft.
- Felder, die Tasten über den Router füllen (Suchsheet, Titel, Paragraph, Namen), haben keinen Cursor und keine Tottasten, wie die Eingabezeile von `/`. Nach dem Antippen sind sie nativ. ⌘V geht im Sheet und über die Objektauswahl; mit Stiftwerkzeug fehlt es in der Eingabezeile der Gesetze.
- Markieren im Gesetzestext: nur eine Touch-Auswahl (`m`, `M`). Der Leser hat keinen Tastaturcursor; ihn zu bauen hieße, einen zweiten Texteditor in einem schreibgeschützten Text zu pflegen.
- Sehr lange Listen in Dialogen (Inhaltsverzeichnis) wandern nur durch sichtbare Zeilen und scrollen dann weiter; `ge` meint dort die letzte sichtbare Zeile.
- Die App zeigt nur die Hauptauswahl (`C`, `s` bilden die übrigen in der Engine); Register nur als Klartext. **Mehrere Auswahlen:** `d`, `y`, `~`, `r` usw. wirken auf alle. Getippt wird im bisherigen Weg nur an einem Cursor: `c`, `i`, `a`, `I`, `A`, `o`, `O` behalten deshalb vorher nur die Hauptauswahl, die Anzeige meldet `Nur Hauptauswahl`. Texteditor 2 tippt an allen Cursorn und zeigt „n Auswahlen“ auch in INS.
- `~`, `` ` `` und `r` erhalten die Formatierung in der Auswahl, solange die Ersetzung gleich lang ist. Ändert sie die UTF-16-Länge (`ß` zu `SS`, `r` mit einem Emoji über einfachen Buchstaben), wird die Auswahl einheitlich im Format ihres Anfangs.
- Esc als Key Command wiederholt sich beim Halten womöglich (abschalten geht erst ab iOS 26); gehalten kann es also mehrere Ebenen wirken. Ungeprüft.
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
7. **Undo:** `d`, `u`, `U` je ein Schritt; ⌘Z danach; `d`, `i`, tippen unter 1,5 s, `u` nimmt nur das Getippte zurück; `c`, tippen, `u` nimmt beides zurück. Undo mit Fokus auf anderer Seite lässt den Modus stehen, per `u`, ⌘Z, ⇧⌘Z und Rückgängig-Knopf: in NOR danach `j` tippen, es darf kein Text entstehen. Dasselbe mit ⌘+ und ⌘1, wenn der Cursor dadurch auf eine andere Seite rückt. `u` ohne Textfokus (kein Textwerkzeug): der nächste Tipp in einen Text schreibt sofort.
8. **Palette, Übersicht:** `:` und ⇧⌘P aus Text, Seite, Bibliothek; ein Textbefehl aus der Palette (`Alles wählen`) wirkt und der Cursor kommt zurück; `Space h`, ⌘/, `?`; `:w`, `:q`, `:12`; danach reagieren Tasten weiter.
9. **Seite:** Tab, Enter, `d`, `y`, `p`, `D`, `%`, `hjkl` schiebt, Esc; `5G`, `G`, `gn`, `gp`, `ge`; `Space e p`, `Space e c`; `Space f` schließt und öffnet die Suche.
10. **Layout:** `:`, `?`, `/`, `mi{`, `mi[`, `+`, `;`, `,`, `<`, `>`, `⌥;` mit der eigenen Tastatur; ⇧⌘7/8/9; ⌘+ ⌘-.
11. **Halten:** `j` gehalten fährt, auch über eine Seitengrenze, loslassen stoppt sofort; `n` gehalten.
12. **Zeilenumbruch am Seitenende:** Enter auf der letzten Zeile (kein roter Rahmen, Cursor auf der nächsten Seite, ⌫ zurück, PDF läuft); langes Einfügen (50 Seiten) ohne spürbares Hängen.
13. **Abschalten:** Einstellung aus → Esc beendet den Text sofort, keine Modusanzeige. ⇧⌘P und ⌘/ zeigen Palette und Übersicht, aus Text und Seite, danach läuft das Schreiben weiter; Esc schließt beide; in der Palette stehen keine Textbefehle.
14. **Mehrere Auswahlen (bisheriger Weg):** `%`, `s` foo Enter, `c`, tippen, Esc: nur die Hauptauswahl geändert, `Nur Hauptauswahl` erscheint, alle anderen foo unberührt. `%`, `s` foo Enter, `o` setzt genau eine Leerzeile.
15. **Formate:** `%`, dann `~`, `` ` `` und `r` x in einem Text mit fettem Wort, kursivem Wort und Markierung, auf einer Seite und über eine Seitengrenze: alle Formate bleiben, `u` ist ein Schritt.
16. **Eingabezeile und Fokus:** `/` öffnen, im selben Text und in einem anderen Feld tippen: Eingabezeile weg, Tasten schreiben, die Auswahl springt nicht zurück.
17. **Marked Text:** Tottaste `^` oder japanische Eingabe anfangen, Esc: der Text ist übernommen und NOR steht, kein Zeichen doppelt.
18. **Esc und Tab, ein Druck eine Ebene:** Heft, Stift aktiv: `g` (Popup), einmal Esc schließt nur das Popup; Objekt gewählt, `Space`, Esc lässt die Auswahl stehen, zweites Esc hebt sie auf. Dasselbe mit Textwerkzeug zwischen den Feldern. `Space h`, einmal Esc schließt nur die Übersicht, im Text und auf der Seite. Text mit zwei Auswahlen: je Druck eine Ebene bis zum Verlassen, auch schnell hintereinander. Tab auf der Seite wählt genau ein Objekt weiter, in einer Liste rückt Tab genau einmal ein. Mit Diagnose zeigt `noty.keys`, welcher Weg kam: `command token=…` ist der Key Command, `second-way` die abgewiesene Zweitzustellung.
19. **Which-Key beim Wechsel:** `g`, dann Heft per Touch schließen; `Space`, dann ⇧⌘P: das Popup ist jeweils weg, die nächste Taste beginnt neu.
20. **Letzte Seitenzeile:** Dokument, dessen Text genau mit der letzten Zeile einer Seite endet: `o` dort, von Zeilenmitte und von der letzten Stelle: Cursor steht auf der nächsten Seite, kein roter Rahmen; tippen, Esc, `u`.
21. **Palette in der Bibliothek:** ⇧⌘P, `q` oder `12` und Enter führt den Treffer der Suche aus, nichts schließt.
22. **`Space f` bei Fehler:** Nur mit Testheft und provoziertem Speicherfehler prüfbar: Heft bleibt offen, ein späteres normales Schließen öffnet keine Suche.

23. **Seitenleiste:** `Space s`, `j k h l`, `gg`, `ge`, Enter öffnet und `j` scrollt sofort die Seite; `Space s`, Esc; `Space s` zweimal klappt ein. `b`, `y`, `p`, `D`, `K`, `J`, `a` (Sheet, Esc, Tasten stehen wieder in der Leiste), `d` und `X` fragen, Enter und Esc. Dasselbe aus einem Text in NOR: Esc lässt ihn weiterlaufen. Während die Leiste die Tasten hat, schreibt `p` nichts in den Text, `⌫` und Pfeile lassen ein gewähltes Objekt stehen. Schreiben mit dem Stift gibt die Tasten an die Seite zurück.
24. **Gliederung, Lesezeichen:** `Space o` im Textdokument und in einem Heft mit PDF-Inhalt (geschlossene Zweige öffnen sich beim Wandern), `Space m`, Enter springt; `Space M` setzt; leere Listen: Esc führt zurück.
25. **Suchsheet:** ⌘F und `/` im Heft, `Space f` und `/` in der Bibliothek, auch als allererste Taste nach dem Start. Tippen füllt das Feld, ⌫, ⌘V; ↓ wählt, `j k`, ⌃n ⌃p, `gg`, `ge`, ein Buchstabe oder eine Ziffer geht zurück ins Feld; Enter springt, danach `j` auf der Seite; Esc schließt, danach `j`. Feld antippen, tippen, Esc schließt.
26. **Gesetze:** `Space l` geschlossen, am Rand, offen und ohne aktivierte Sammlung (Hinweis). `j k`, `n N`, `144G`, `p` 144 Enter, `/` `144 HGB`, `/` Wort Enter, Enter wandert zum nächsten Treffer; `t`, `o`, `B` je mit `j`, Enter, Esc; `v`; `+ -`. Esc und `Space l` schließen, `j` wirkt sofort auf der Seite, auch mit Stiftwerkzeug und aus einem Text in NOR. ⌫ in der Eingabezeile löscht kein gewähltes Objekt.
27. **Dialoge:** Neues Heft mit `n`: Titel tippen, Tab, `j`, Leertaste auf Umschlag, `h l` auf Papier, Enter erstellt, im neuen Heft wirken Tasten. Esc bricht ab, in der Bibliothek geht `j` weiter. `N`, `m` (Enter wählt Ordner), PDF importieren aus der Palette, Seite anpassen, Papier für neue Seiten, Lokale Wiederherstellungspunkte, zweite Ansicht. Rahmen läuft mit, auch nach unten scrollend. Einstellungen: `j`, Enter, Toggle per Leertaste, Esc eine Ebene, Esc schließt; aus Bibliothek und aus dem Heft.
28. **Rückfragen:** `d` in der Bibliothek, Enter; `d`, Esc; Einstellungen › Papierkorb: Enter auf Eintrag, Endgültig löschen: Enter allein bricht ab. `r` und `f`: Name, ⌫, Enter, Esc, in der Bibliothek geht es danach weiter. Fehleralert: Enter, Esc, danach Tasten. **Ohne Antippen:** nach jedem Punkt dieser Liste muss die nächste Taste wirken.
29. **Farbe:** `Space c` mit Stift, Marker, Formen (Linienart), genauem Radierer, Laser, Lasso (Hinweis), im Text (Farbe, Marker auf der Auswahl, `Aus`); `1`, `hjkl`, Enter, Esc ändert nichts. Tafel offen, Text antippen: Tippen schreibt.
30. **Ohne Tastatur:** Heft, Suche (Feld fokussiert, Softwaretastatur), Neues Heft (kein Rahmen, kein Autofokus), Einstellungen, Seitenleiste per Touch wie bisher. Tastaturmodus aus: Sheets wie bisher, Esc schließt.

**Diagnose:** Mit Einstellungen › Diagnose (ab Neustart) protokolliert `KeyboardRouter` jede Taste mit Kontext, Ergebnis und First Responder: `idevicesyslog | rg noty.keys`. Getippter Text erscheint nur als `(typing)`, auch in der Eingabezeile, im Suchsheet und in Dialogfeldern. Kommt zu einer Taste keine Zeile, hat sie keinen unserer Responder erreicht.

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
| Mehrere Auswahlen | alle sichtbar, Tippen an allen | nur die Hauptauswahl sichtbar, die Modusanzeige nennt „n Auswahlen“; `C`, `s`, `d` wirken auf alle, `c`, `i`, `a`, `o` usw. nur noch auf die Hauptauswahl (`performAtPrimary`) | eine Seite tippt an einem Cursor; Texteditor 2 verhält sich wie Helix |
| Esc nach einem Antippen | gibt es nicht | Cursor aufs zuletzt getippte Zeichen, ohne Tippen dorthin, wo der Tipp ihn setzte; hinter `i`, `a` usw. wie Helix (getippter Text gehört zur Auswahl) | ein Tipp hat keine Auswahl, die mitwachsen könnte |

Bewusst wie Helix, obwohl es überrascht: `w` wählt auch die Leerzeichen dahinter, `ge` geht an den Anfang der letzten Zeile, `G` ohne Zähler tut nichts, `5G` in SEL zieht die Auswahl zusammen, `r` ersetzt auch Zeilenumbrüche, `n` geht auch nach `?` vorwärts, `p` in SEL lässt die Auswahl stehen, `>` fügt einen Tab ein (`TextEngine.indentUnit`).

Bewusst anders als bisher: `Space m` zeigt jetzt die Lesezeichen (setzen: `Space M`, in der Leiste `b`), `Space s` gibt der Leiste die Tasten statt sie umzuschalten (einklappen: `Space s` in der Leiste).

Nicht enthalten: benannte Register, `.`, Makros, Sprungliste, ⌥C, `S`, ⌥s, `[`/`]`.

## Aufbau

**Core:** `HelixKeymap`, `HelixParser`, `TextEngine`, `KeyPressGate`, `KeyDeliveryLatch` und `KeyPalette` (`KeyboardCommands.swift`), `TextLines`, `Notebook.editingTextFlow`/`restylingTextFlow` (`TextFlowRange.swift`). `KeyboardPanels.swift`: `KeyList`, `KeyOptionRing`, `KeyChoice`, `KeyChoiceCursor`, `KeyInputLine`, `KeyPanelStack`, `KeyFocusTarget` (`KeyboardPanelsTests`).

**App:** `KeyboardRouter` nimmt die Tastendrücke entgegen (`pressesBegan` in `PageTextView`, `DrawingCanvasView`, `WorksheetView`, `KeyboardHostView`), ⌘-Kürzel bleiben bei Menü und Key Commands. Er hält Parser und Engine und bindet `HelixAction` an `ContentView.runKey`, `LibraryView.runKey` und `ObjectEditingLayer`. INS läuft am Parser vorbei, nur Esc geht an die Engine.

**Panels** (`KeyboardPanels.swift`): Alles außer Seite, Text und Bibliothek ist ein `KeyPanel` mit eigenem `HelixContext` auf einem Stapel; das neueste hat die Tasten, sein `run` bindet die Aktionen. Seitenleiste, Gesetze, Rückfragen und Farbe nehmen keinen Fokus, die Tasten kommen weiter über den bisherigen Responder. Nur Sheets bringen mit `KeyPanelHostView` einen eigenen mit; er hält auch Esc, Tab, Enter, Leertaste und Pfeile als Key Commands, weil das Fokussystem einer Liste sie sonst nehmen könnte. Wer den Fokus zu holen hat, entscheidet `KeyFocusTarget`, ausgeführt von `reclaim()`: jedes Schließen eines Panels läuft über `leave` und holt zurück, auch was nicht durch `presenting` geht (Sheets der Seitenleiste und des Lesers). Eine neue Option braucht nur `keyOption`; die Reihenfolge ergibt sich aus der Lage (`KeyOptionRing`). Ein neuer Dialog braucht `keyboardSheet()`. Sheets legen ihre Overlays selbst darüber (`KeyboardOverlay(panel:)`), die der Bibliothek lägen darunter. Ohne Tastatur (`hasKeyboard`) übernimmt nichts den Fokus, es erscheint kein Rahmen.

**Esc und Tab** können auf beiden Wegen kommen: über `pressesBegan` oder als Key Command, wenn das System die Taste sonst nähme (`PageTextView`, `DocumentTextSurface`, `WorksheetView`, `ObjectEditingLayer`; die Übersicht hat dazu eine `cancelAction`). Welcher Weg kommt oder ob beide, ist nicht festgestellt. Beide enden in `KeyboardRouter.dispatch`, der Key-Command-Weg über `handle(token:text:)`. `KeyPressGate` trennt nur Zustellungen desselben Tastendrucks über `pressesBegan`; ein Key Command hat keine Druckzeit, deshalb sperrt `KeyDeliveryLatch` eine Taste, die der eine Weg benutzt hat, für 0,12 s einmal für den anderen. Eine unbenutzte Taste bleibt frei, so kommt Tab in INS beim Listeneinzug an. `handle(token:)` gibt false zurück, wenn der Aufrufer die Taste selbst behandeln soll (Tab einfügen, Text verlassen). Neue Key Commands für Router-Tasten laufen über diese Funktion.

**Text** (`TextObjectLayer+Keyboard.swift`): Vor jedem Befehl übernimmt die Engine Text und Auswahl des Bildschirms (`keyboardSync`: ganzer Fluss oder Feld). Danach zeigt `keyboardShowSelection` die Hauptauswahl: innerhalb einer Seite native `selectedRange`, über Seiten `TextFlowSelection` mit dem Caret am Cursor, ein Cursor auf einem Zeichen als breiter Caret (`normalCaret`). Edits gehen auf einer Seite über `applyListEdits`, über Seiten über `TextFlowActions.edit`, beides ein Undo-Schritt; die einzelnen Edits statt `combinedEdit` erhalten Formate dazwischen, `Outcome.textEdits(in:)` teilt `~`, `` ` ``, `r` zusätzlich an den Formatwechseln (`keepsFormat`). `j`/`k` messen im `NSLayoutManager` der Textansicht, auf anderen Seiten in `TextObjectLayout` (`KeyboardLineLayout`).

**Fallstricke, die der Code absichert:** Nach einem lokalen Edit im Fluss liegt noch eine Fokusanforderung des Edits an, eine neuere ersetzt sie (`moveCaret`). Wechselt der Cursor die Seite, erhält `handoff` den Modus: `applyTextFocus` und `DocumentTextSurface.show` setzen es vor jedem programmatischen Fokus, Undo nur, wenn es wirklich einen Fokus anfordert (`undoRequestedFocus`), und `textEnded` wartet eine laufende Anforderung ab. Nur `writingRequested` (Tipp unter den Text, `i`) geht ausdrücklich nach INS. Läuft eine Anforderung, ist die Ansicht hinter der Engine, also zählt deren Auswahl (die Anforderung läuft nach 1,5 s aus, falls sie nie ankommt). Auf einer neuen leeren letzten Zeile (`o` am Dokumentende) kennt nur der Reflow die Seite: `moveCaret` geht vom geschriebenen Text aus, `apply` schickt den Cursor deshalb mit dem Flussedit und überschreibt dessen Fokus nicht. Ein Flussedit über Seiten ändert das Modell sofort, die Ansichten erst beim nächsten Update: Bis dahin setzt `viewIsCurrent` keine Auswahl und nimmt keinen lokalen Edit, sonst würde `textViewDidChangeSelection` den alten Text über den neuen schreiben. Die Palette nimmt den Fokus: `holdText`/`returnToHeldText` halten den Text so lange, damit ihre Textbefehle ihn finden; ein leeres freies Feld verschwindet dabei und beendet den Text. Undo setzt `TextFlowSelection` zurück (`textChangedElsewhere`), Offsets werden geklemmt.

Kein Formatwechsel; einzige Einstellung `noty.keyboard.mode` in UserDefaults.
