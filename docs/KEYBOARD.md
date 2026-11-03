# Tastatur: Kürzel und Tastaturmodus

Stand: Build 69 (`extras/build69`): Build 68 plus Helix-Erweiterungen, Tastatur in Seitenleiste, Suche, Gesetzen, Dialogen und Farbe, Textdokument-Extras und die Befunde des Reviews. **Implementiert, erfolgreich gebaut, Core-Tests bestanden, am iPad ungeprüft.** Linux hat keinen iOS-Simulator: Engine, Tastentabelle, Parser, Bereichsbearbeitung, Tastensperre und Fokusziele sind getestet, Tastenzustellung, Fokus, Anzeige und TextKit-Messung **nicht**. Ein Simulator-Lauf auf Stand Build 67 hat die Tastenzustellung einmal bestätigt, das ersetzt den Gerätetest nicht.

**Seit Build 71 experimentell und nur in Textdokumenten.** Die Helix-Bedienung ist standardmäßig aus und gilt, wenn eingeschaltet, nur solange ein Textdokument im aktiven Bereich offen ist, einschließlich der daraus geöffneten Bedienfelder (auch des Gesetzesfensters). Bibliothek, Hefte und deren Seiten kennen sie nicht mehr; die Abschnitte „Bibliothek“, „Seite“ und „Seitenleiste“ unten beschreiben den Stand bis Build 70. Der frühere Schalter `noty.keyboard.mode` wird nicht mehr gelesen.

**Gesetzessammlung mit normaler Tastatur (feat/gesetze-tastatur, 03.11.2026):** Menü „Gesetze“ und Gesetzfokus, siehe den eigenen Abschnitt unten. **Implementiert, erfolgreich gebaut (`xtool dev build`), Core-Tests bestanden, nicht installiert, am iPad ungeprüft.**

## ⌘-Kürzel (immer aktiv, auch ohne Tastaturmodus)

| Taste | Wirkung | Wo |
| --- | --- | --- |
| ⌘N / ⇧⌘N | Neues Heft / neues Textdokument | Bibliothek |
| ⌘F | Suchen; bei Gesetzfokus „Im Gesetz suchen“ | überall |
| ⌘S | Speichern | Editor |
| ⌘E / ⇧⌘E | PDF ganz / diese Seite | Editor |
| ⌘↑ / ⌘↓ | Vorherige / nächste Seite (im Text: Anfang/Ende dieses Texts, Systemverhalten; bei Gesetzfokus Anfang/Ende der Vorschrift) | Editor |
| ⌘G | Gehe zu Seite (bei Gesetzfokus: nächster Treffer) | Editor |
| ⌘W | Schließen | Editor |
| ⌘Z / ⇧⌘Z | Rückgängig / Wiederholen (bei Gesetzfokus: nur Markierungen) | Editor |
| ⇧⌘L, ⌥⌘L, ⌘L | Gesetzessammlung öffnen oder schließen, an den Rand schieben oder vom Rand holen, Fundstelle suchen (Menü „Gesetze“) | Editor, Sammlung eingeschaltet |
| ⌘A | Alles auswählen (siehe unten) | Editor |
| ⌘C ⌘X ⌘V ⌘D | Kopieren, Ausschneiden, Einfügen, Duplizieren | Text und Auswahl |
| ⌫, Pfeile, ⇧Pfeile | Auswahl löschen, um 1 pt / 10 pt schieben | Objektauswahl |
| ⌘B ⌘I ⌘U, ⇧⌘X | Fett, Kursiv, Unterstrichen, Durchgestrichen | Text |
| ⌘1–⌘4 | Titel, Überschrift, Unterüberschrift, Text | Text |
| ⌘+ ⌘- | Schrift größer / kleiner | Text |
| ⇧⌘7 ⇧⌘8 ⇧⌘9 | Aufzählung, Nummerierung, Checkliste | Text |
| ⌘K, ⇧⌘H | Link, Markieren | Text |
| ⌘↩ | Seitenumbruch (in NOR und SEL vor die Auswahl) | Textdokument |
| Tab | Nächster Tabstopp, ohne Ende bis zum Feldrand; in Listen eine Ebene tiefer; über mehrere markierte Zeilen rückt jede ein | Text |
| ⇧Tab | Tab vor dem Cursor zurücknehmen, sonst Tab am Zeilenanfang, sonst Einzug; in Listen eine Ebene höher; über mehrere markierte Zeilen rückt jede aus | Text |
| ⇧⌘P, ⌘/ | Befehlspalette, Tastenübersicht (ohne Tastaturmodus enthält die Palette keine Textbefehle und keine Eingabezeile, beides braucht die Engine) | überall |

**⌘A:** Im Text das ganze Feld; im Textdokument der ganze Text über alle Seiten (blau markiert; ⌘C/⌘X/⌘V, ⌫ und Formatierung wirken auf alles, beim Schreiben auch Tippen, ⌘Z als ein Schritt). Ohne Cursor im Textdokument dasselbe, dann in NOR, damit kein Buchstabe versehentlich alles ersetzt. Außerhalb von INS wirkt ⌘A wie `%`. Im Heft alles Auswählbare der Seite, mit jedem Werkzeug. Das Bearbeitungsmenü „Alles auswählen“ bleibt die native Auswahl dieser Seite.

Außerhalb von INS: ⌘V ersetzt eine breite Auswahl, sonst wie `P`; ⌘X schneidet eine breite Auswahl aus. Beides läuft über Engine und Register.

## Gesetzessammlung (normale Tastatur)

Gilt im geöffneten Heft oder Textdokument, solange Einstellungen › Gesetzessammlung eingeschaltet ist, mit und ohne Helix. Eine Tabelle für Menü, Key Commands und Hilfe: Core `LawShortcuts` (`LawShortcutsTests`: Eindeutigkeit je Kontext, Sperrliste, jede Überschneidung mit dem Heft benannt).

**Menü „Gesetze“** (Menüleiste und ⌘-Übersicht, im Editor; nicht vorhanden, solange die Sammlung in den Einstellungen abgeschaltet ist). Titel nach Apple-Konvention ohne Schrägstriche, je Zustand: „Gesetzessammlung öffnen“ / „Gesetzessammlung schließen“, „An den Rand schieben“ / „Vom Rand holen“; die Befehlspalette benutzt dieselben Wörter („… öffnen“, „… schließen“, „… vom Rand holen“).

| Taste | Wirkung |
| --- | --- |
| ⇧⌘L | Gesetzessammlung öffnen (mit Fokus) oder schließen, wenn sie sichtbar ist |
| ⌥⌘L | An den Rand schieben oder vom Rand holen (mit Fokus); bei geschlossenem Fenster deaktiviert |
| ⌘L | Fundstelle suchen: Fenster zeigen, Schnellsuche leeren und fokussieren (`144 HGB`) |
| – | Anordnen › Links, Rechts, Unten andocken, Über dem Heft schweben (ohne Kürzel, siehe unten) |

**Gesetzfokus:** ⇧⌘L, ⌥⌘L (beim Hervorholen), ⌘L, `Space l`, ein Feld des Fensters oder eine Auswahl im Gesetzestext setzen ihn. Sichtbar: Titel „Gesetze“ im Fensterkopf hell (sonst gedimmt) und eine 2-pt-Linie in der Akzentfarbe unter dem Kopf. Berührung der Heftseite mit Finger oder Stift, ein Text auf der Seite, Schließen und Parken nehmen ihn zurück. Mit Fokus wird der unsichtbare Tastenempfänger `LawKeyHostView` First Responder, solange kein Feld des Fensters tippt; der Seite gehören die Tasten danach wieder (`KeyboardRouter.reclaim`). Die Einträge des Fokus stehen im Menü „Gesetze“, sobald das Fenster sichtbar ist, und lassen sich dort auch ohne Fokus wählen (das Fenster nimmt dann den Fokus); ihre Kürzel gelten nur mit Fokus. Mit Fokus gilt zusätzlich:

| Taste | Wirkung | Weg |
| --- | --- | --- |
| Esc | Eine Ebene: Auswahl oder gewählte Markierung aufheben, sonst Eingabefeld verlassen, sonst offene Suchfläche schließen, sonst Fenster schließen | Key Command; im Feld über einen verborgenen `.cancelAction` |
| ⌘F | Im Gesetz suchen (Schnellsuche fokussieren); Menü „Heft“ heißt dann „Im Gesetz suchen“ | Menü |
| ⌘G, ↩ / ⇧⌘G, ⇧↩ | Nächster / vorheriger Volltexttreffer der Schnellsuche, ohne Suchbegriff in die Schnellsuche | Menü / Key Command |
| ← → | Vorherige / nächste Vorschrift | Key Command |
| ↑ ↓, ⌥↑ ⌥↓, Leertaste, ⇧Leertaste | Scrollen: Zeile, „Bildschirmseite weiter/zurück“ | Key Command |
| ⌘↑ / ⌘↓ | Anfang / Ende der Vorschrift | Menü |
| ⌘+ ⌘- ⌘0 | Schrift größer, kleiner, „Normale Schriftgröße“ (Fließtextgröße von Dynamic Type + 1 pt, 18 pt bei Standardgröße), nur im Lesetext | Menü |
| ⌘D | „Lesezeichen setzen“ bzw. „Lesezeichen entfernen“ (Titel je Zustand) | Menü |
| ⌘T, ⇧⌘T, ⌥⌘B | Gesetz wählen, Inhaltsverzeichnis, Lesezeichen und Markierungen | Menü |
| ⌥⌘P | „PDF zeigen“ bzw. „Lesetext zeigen“ (Titel je Zustand) | Menü |
| 1–5 | Auswahl in Gelb, Grün, Blau, Rosa, Orange markieren; gewählte Markierung umfärben. Nur bei Auswahl, sonst bleibt die Ziffer frei | Key Command |
| ⇧⌘H | Mit der zuletzt mit 1–5 gewählten Farbe markieren (sonst Stiftfarbe) | Menü |
| ⌫ | Markierung unter Auswahl bzw. gewählte Markierung entfernen; nur dann | Key Command |
| ⌘Z / ⇧⌘Z | „Markieren widerrufen“ / „Markieren wiederholen“, Vorrang vor dem Heft-Undo; ohne Schritt keine Wirkung, das Heft bleibt unberührt. Mit Touch: „…“ › Markieren widerrufen / Wiederholen | Key Command |

**Warum zwei Wege:** ⌘-Kürzel stehen im Menü „Gesetze“ und bekommen ihr Kürzel nur bei Fokus; so wirken sie aus jedem Teil des Fensters (Suchfeld, Gesetzestext, Tastenempfänger) und stehen in Menüleiste und ⌘-Übersicht. Tasten ohne ⌘ wären im Menü auch beim Tippen aktiv, und ⌘Z stieße dort mit „Bearbeiten › Widerrufen“ des Systems zusammen: beides sind `UIKeyCommand`s mit `discoverabilityTitle` am Tastenempfänger, nur bei Fokus und nicht unter einem Sheet. Mit eingeschaltetem Helix gehen die Tasten ohne ⌘ an `GESETZE` (unten), die ⌘-Kürzel gelten weiter.

**Konflikte, aufgelöst:** ⌘G (Gehe zu Seite) und ⌘↑/⌘↓ (Seite) verlieren bei Fokus ihr Kürzel an das Fenster; ⌘F behält das Kürzel und wechselt Titel und Ziel; ⌘+ ⌘- ⌘D ⇧⌘H ⌘Z gehören sonst Text, Objektauswahl oder Seite, die bei Fokus nicht First Responder sind. Nicht belegt: ⌘H, ⌘Leertaste, ⌘Tab, ⇧⌘3/4/5, ⌥⌘D, ⌘W (Heft schließen), ⌘, ⌘Q ⌘M ⌃⌘F ⌘`, ⇧⌘P, ⌘/ und 🌐-Kombinationen. **Andocken ohne Kürzel:** ⌃⌘Pfeil liegt neben der Fensteranordnung von iPadOS (🌐⌃Pfeil; auf Tastaturen ohne 🌐-Taste oft auf ⌃ umgelegt) und ließe sich hier nicht prüfen; die vier Einträge stehen deshalb nur im Menü „Gesetze › Anordnen“.

**Kürzelübersicht für die Hilfe im Leser** (Text; `LawShortcuts.overview()` liefert dasselbe):

> Fenster: ⇧⌘L öffnen oder schließen · ⌥⌘L an den Rand · ⌘L Fundstelle suchen
> Suchen: ⌘F im Gesetz suchen · ⌘G/↩ nächster, ⇧⌘G/⇧↩ vorheriger Treffer
> Lesen: ←/→ Vorschrift · ↑/↓ scrollen · ⌥↑/⌥↓ oder Leertaste Bildschirmseite · ⌘↑/⌘↓ Anfang/Ende · Esc zurück/schließen
> Ansicht: ⌘+/⌘-/⌘0 Schrift · ⌘D Lesezeichen · ⌘T Gesetz · ⇧⌘T Inhalt · ⌥⌘B Liste · ⌥⌘P Text/PDF
> Markieren (bei Auswahl): 1–5 Farbe · ⇧⌘H letzte Farbe · ⌫ entfernen · ⌘Z/⇧⌘Z widerrufen/wiederholen

## Tastaturmodus

Einstellungen › Editor › „Helix-Tastatur in Textdokumenten (experimentell)“, Standard aus. Wirkt nur auf Hardware-Tastaturen. Modell wie [Helix](https://helix-editor.com): **erst auswählen, dann handeln**. `w` wählt ein Wort, `d` löscht es.

**Modus:** `NOR` (Buchstaben sind Befehle), `INS` (natives Tippen), `SEL` (Bewegungen erweitern die Auswahl, `v` schaltet um). Auf Seite und Bibliothek steht `NOR` mit `SEITE`/`BIBLIOTHEK` als Kontext. Die Anzeige erscheint, sobald eine Taste gedrückt wurde: im Editor oben links unter der Zurück-Taste, in der Bibliothek unten links. Daneben stehen eine laufende Makroaufnahme (`REC @`, rot), Zähler und angefangene Folge (`3g`, `"a`), „n Auswahlen“ und kurze Hinweise (`Kein Treffer`, `Suche von vorn`, `Kein Paar gefunden`, `Nur Hauptauswahl`, `Register leer`, `Makro abgebrochen`, `Nicht im Makro`).

**Wege:** `i` führt von der Seite immer in den Text (Textdokument: Cursor auf der sichtbaren Seite; Heft: gewähltes Feld, sonst neues Feld). Esc führt Schritt für Schritt zurück: INS → NOR, SEL → NOR, breite Auswahl → Cursor, mehrere Auswahlen → Hauptauswahl, zuletzt Text verlassen (nach `i` und Tippen also dreimal, denn Getipptes bleibt wie in Helix ausgewählt; die Anzeige steht dabei zweimal auf `NOR`); auf der Seite hebt es die Objektauswahl auf. Ein Druck wirkt genau eine Ebene: Offene Übersicht, Eingabezeile oder angefangene Folge gehen zuerst, Marked Text wird vorher abgeschlossen. ⌃[ und ⌃C wirken wie Esc (Tastaturen ohne Esc-Taste; alternativ iPadOS: Modifikatortasten › Feststelltaste → Escape). Antippen eines Texts schreibt immer, auch aus NOR und SEL heraus; eine offene Eingabezeile geht dabei zu, die Auswahl bleibt, wie sie ist. Ein Fokuswechsel der App (⌘Z, Rückgängig-Knopf, ⌘+ oder ⌘1 mit Sprung auf eine andere Seite, Gliederung) lässt den Modus stehen. Öffnet Rückgängig einen Text von der Seite aus, steht er in NOR.

**Hilfe:** In jedem Kontext `Space h` und ⌘/ (Tastenübersicht, aktueller Kontext zuerst), `:` und ⇧⌘P (Befehlspalette: alle Befehle des Kontexts und die Menüfunktionen per Suche, im geöffneten Dokument dazu `:w`, `:q`, `:wq`, Seitenzahl; in der Bibliothek sind das Suchwörter). Bei offenem Menü (`g`, `m`, `z`, `t`, `[`, `]`, `Space` und Untermenüs) und bei Tasten, die ein Zeichen erwarten (`mi`, `f`, `"`), zeigt ein Popup unter der Modusanzeige sofort die nächsten Tasten; es nimmt keinen Fokus und geht bei Ausführung oder Esc.

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
| `]p`, `[p` | Nächster, vorheriger Absatz; `ü` und `+` gehen auch (deutsche Tastatur, siehe Grenzen) |
| ⌃s, ⌃o, ⌃i | Position merken, zurück, vor (Sprungliste, siehe unten) |
| ⌃d ⌃u ⌃f ⌃b | Halbe/ganze Ansicht |
| `%`, `x`, `X` | Alles, Zeile (wiederholt erweitert), auf ganze Zeilen erweitern |
| `;`, `⌥;`, `,`, `v` | Zusammenziehen, Auswahl umdrehen, nur Hauptauswahl, SEL |
| `C`, ⌥C | Auswahl in die nächste, vorige Zeile kopieren |
| `s`, `S`, ⌥s | Treffer in der Auswahl wählen, Auswahl an Treffern teilen, an Zeilenumbrüchen teilen |
| `mi`, `ma` + Zeichen | Innerhalb, mitsamt: `w` Wort, `W` langes Wort, `p` Absatz, `m` nächstes Paar, sonst Klammer oder Anführungszeichen |
| `mm`, `ms`, `md`, `mr` | Passende Klammer, umschließen, Umschließung entfernen, ersetzen |
| `d c y` | Auswahl löschen, ändern, kopieren |
| `"` + Zeichen davor | Register für `y d c p P R` (`"ay`, `"ap`) und für `Q q` |
| `p P R`, `r` + Zeichen | Einfügen dahinter, davor, Auswahl durch Kopiertes ersetzen, jedes Zeichen ersetzen |
| `~`, `` ` ``, `J`, `> <` | Groß/klein tauschen, klein, Zeilen verbinden, ein-/ausrücken |
| `i a I A o O` | Schreiben vor, hinter der Auswahl, am Zeilenanfang, -ende, neue Zeile darunter, darüber (siehe „Mehrere Auswahlen“) |
| `.` | Letzte Einfügung wiederholen (`3.` dreimal) |
| `Q`, `q` | Makro aufnehmen an/aus, abspielen (`"aQ`, `"aq`, `"a3q`) |
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

Seit Build 71 nur mit eingeschaltetem Helix in einem offenen Textdokument; in Heften gelten allein die normalen Kürzel (Abschnitt „Gesetzessammlung (normale Tastatur)“), die auch hier weiter wirken. `Space l` öffnet das Fenster, setzt den Gesetzfokus und gibt ihm die Tasten. Esc (ohne Auswahl) und `Space l` schließen es wie das ✕, `P` schiebt es an den Rand; die Tasten gehen an die Seite, der Text bleibt, wo er war. Kommt `Space l` aus einem Text in NOR, bleibt dessen Responder: Die Tasten laufen weiter über ihn zum Router. Sonst nimmt der Tastenempfänger des Fensters den Fokus und reicht die Tasten an den Router weiter.

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
| `m1`–`m5`, `mm` | Auswahl in Farbe 1–5 bzw. der letzten Farbe markieren, gewählte Markierung umfärben |
| `d`, `M` | Markierung unter der Auswahl bzw. gewählte Markierung entfernen |
| `u`, `U` | Markierung rückgängig, wiederholen |
| Esc, `Space l`, `P` | Auswahl aufheben, sonst schließen; schließen; an den Rand |

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

**Suche:** `/`, `?`, `s` und `S` öffnen die Eingabezeile unter der Modusanzeige. Treffer erscheinen beim Tippen als Auswahl, Enter bestätigt, Esc stellt die Auswahl und den vorigen Suchbegriff wieder her. Der Suchbegriff ist ein regulärer Ausdruck (Kleinschreibung ignoriert Groß/klein), was keiner ist, gilt wörtlich. Auf Seite und Bibliothek öffnet `/` weiter die bestehende Suche, ⌘F ebenso überall.

**Zwischenablage:** `y`, `d`, `c` füllen Register und Systemzwischenablage. Beim Einfügen gewinnt, was seitdem woanders kopiert wurde; ein Text mit Zeilenumbruch am Ende gilt als ganze Zeilen.

**Register:** `"a` vor `y`, `d`, `c`, `p`, `P`, `R` nimmt ein eigenes Register, jedes Zeichen geht. Es bleibt neben dem Standardregister stehen, berührt die Systemzwischenablage nicht und lebt nur im Speicher, also bis zum Beenden der App, über Texte hinweg. `"_` merkt nichts, `"+`, `"*` und `""` meinen das Standardregister. Ein Zähler gehört hinter das Register: `"a3p`; `3"ap` verliert ihn, wie in Helix.

**`.`** wiederholt den Befehl, der zuletzt in INS führte (`i a I A o O c`), mit dem dabei entstandenen Text. Grundlage ist das Ergebnis, nicht die Tasten: Autokorrektur, Diktat und Tottasten wirken mit, Pfeile und Tippen außerhalb des Laufs nicht. Der Zähler des ersten Befehls (`2o`) zählt nicht mit, Antippen startet keinen neuen Lauf. Das Ergebnis ist ein Undo-Schritt.

**Makros:** `Q` nimmt in Register `@` auf (`"aQ` in `a`), noch ein `Q` beendet, Verlassen des Texts auch. `q` spielt ab, `"a2q` zweimal. Aufgenommen wird, was den Text betrifft: Tasten in NOR und SEL, bestätigte Eingabezeilen, das Ergebnis von INS wie bei `.`. `u`, Paletten- und Menübefehle bleiben draußen, die Anzeige sagt `Nicht im Makro`. Abgespielt wird rein in der Engine: Ein Makro ist **ein** Undo-Schritt, `j`/`k` zählen darin Textzeilen statt angezeigter Zeilen, weil die Ansicht den neuen Stand noch nicht kennt. Ein Makro ruft sich nie selbst auf, auch nicht über ein anderes; ein `q` nach dem Muster bleibt wirkungslos. Insgesamt laufen je `q` höchstens 5000 Schritte und 2 Sekunden, danach `Makro abgebrochen`; was bis dahin geschah, bleibt als ein Undo-Schritt.

**Sprungliste:** `gg`, `ge`, `5G`, bestätigte `/`, `?`, `s`, `S` und ⌃s merken die Stelle davor, höchstens 30. ⌃o geht zurück und merkt beim ersten Mal die aktuelle Stelle, ⌃i wieder vor. Die Einträge wandern mit Änderungen mit, auch mit nativem Tippen; was gelöscht wurde, wird geklemmt. Die Liste gehört zum offenen Text, mit dem Verlassen des Texts ist sie weg. `n`, `N`, `*` tragen nichts ein. Die Gliederung auch nicht: Ihr Sprung läuft am Tastaturmodus vorbei, ein Eintrag davor wäre nicht einfach zu haben.

**Schreiben in INS:** `o`, `O` und Enter übernehmen den führenden Leerraum der Zeile (Tastaturmodus an). Listen gehen vor (`TextListEditing`). Esc auf einer neuen Zeile, auf der nichts entstand, nimmt den Einzug wieder weg. Einstellungen › Editor › „Klammern automatisch schließen“ (`noty.keyboard.autoPairs`, Standard aus): `( [ {` und `" '` schließen sich selbst, außer vor einem Wortzeichen, Anführungszeichen auch nicht dahinter (`don't`). Eine getippte schließende Hälfte läuft über die vorhandene, ⌫ zwischen beiden löscht beide. Nur ein getipptes Zeichen an einem einfachen Cursor zählt: Marked Text, Autokorrektur und Diktat ersetzen Bereiche oder bringen mehr als ein Zeichen und bleiben unberührt. Typografische Anführungszeichen (`„`, `“`) schließen nichts. Auf einer Seite sieht der bisherige Textweg nur den Text dieser Seite: Am Seitenrand gilt das Nachbarzeichen der nächsten Seite als nicht vorhanden.

## Grenzen

- Nicht per Tastenbelegung erreichbar: Systemdialoge (Dateiauswahl, Teilen, Fotos, Farbkreis des Systems) und Zeichnen; dazu Anmeldung und Zugangsdaten (Einstellungen › Konto, Backup › Weitere Optionen: nur Esc und natives Tippen, Passwörter laufen bewusst nicht über den Router), Menüs der Werkzeugoptionen außer Farbe, Strichstärke und Linienart, das Umordnen in „Werkzeugleiste anpassen“ und „Seiten anordnen“, Bereich entfernen. Das Gesetzesfenster andocken geht nur über Menü „Gesetze › Anordnen“, ohne Kürzel. Dort hilft iPadOS: Bedienungshilfen › Tastaturen › „Voller Tastaturzugriff“ (Tab/Pfeile/Leertaste für jedes Element).
- Systemalerts und `confirmationDialog` (Fehler, Touch-Rückfragen): OK und Speichern sind als Standardaktion hinterlegt, Abbrechen kommt vom System. Ob Enter und Esc dort wirken, ist ungeprüft.
- Felder, die Tasten über den Router füllen (Suchsheet, Titel, Paragraph, Namen), haben keinen Cursor und keine Tottasten, wie die Eingabezeile von `/`. Nach dem Antippen sind sie nativ. ⌘V geht im Sheet und über die Objektauswahl; mit Stiftwerkzeug fehlt es in der Eingabezeile der Gesetze.
- Markieren im Gesetzestext: nur eine Touch-Auswahl (1–5, ⇧⌘H, ⌫; Helix `m1`–`m5`, `mm`, `d`). Der Leser hat keinen Tastaturcursor; ihn zu bauen hieße, einen zweiten Texteditor in einem schreibgeschützten Text zu pflegen.
- Gesetzfokus: Solange der Gesetzestext oder das PDF nach einer Touch-Auswahl First Responder ist, fehlen ihm die Key Commands des Fensters (Esc, Pfeile, 1–5, ⌫, ⌘Z), bis `LawTextView`/`LawPDFView` sie übernehmen (`LawKeyboard.keyCommands()`, Zusammenführung des Markier-Pakets); die ⌘-Kürzel im Menü wirken trotzdem. Ein Tipp ins Fenster setzt den Fokus erst, wenn `LawPanelView` `.lawKeyFocusArea()` anwendet; bis dahin setzen ihn Felder, Auswahl, ⌘L, ⇧⌘L, ⌥⌘L und `Space l`. Aus einem Helix-Text in NOR bleiben ⌘Z und ⌘+/⌘- beim Text.
- Sehr lange Listen in Dialogen (Inhaltsverzeichnis) wandern nur durch sichtbare Zeilen und scrollen dann weiter; `ge` meint dort die letzte sichtbare Zeile.
- Die App zeigt nur die Hauptauswahl (`C`, ⌥C, `s`, `S`, ⌥s bilden die übrigen in der Engine); Register nur als Klartext. **Mehrere Auswahlen:** `d`, `y`, `~`, `r` usw. wirken auf alle. Getippt wird im bisherigen Weg nur an einem Cursor: `c`, `i`, `a`, `I`, `A`, `o`, `O` und ebenso `.` und dieselben Befehle in einem Makro behalten deshalb vorher nur die Hauptauswahl, die Anzeige meldet `Nur Hauptauswahl`. Texteditor 2 tippt an allen Cursorn und zeigt „n Auswahlen“ auch in INS.
- `~`, `` ` `` und `r` erhalten die Formatierung in der Auswahl, solange die Ersetzung gleich lang ist. Ändert sie die UTF-16-Länge (`ß` zu `SS`, `r` mit einem Emoji über einfachen Buchstaben), wird die Auswahl einheitlich im Format ihres Anfangs.
- Esc als Key Command wiederholt sich beim Halten womöglich (abschalten geht erst ab iOS 26); gehalten kann es also mehrere Ebenen wirken. Ungeprüft.
- Auf einer deutschen Tastatur sind `^`, `` ` `` und je nach Layout `~` Tottasten: Der Router sieht sie nicht als Zeichen, in der Eingabezeile gehen auch `é`-artige Kompositionen nicht. ⌥ tippt weiter, was es tippt (`[ ] { } | @`), Befehle sind nur ⌥;, in NOR und SEL außerdem ⌥C und ⌥s.
- **`[` und `]` auf einer deutschen Tastatur:** ⌥5 und ⌥6 ergeben dort `[` und `]`, und genau dieses Zeichen geht an den Parser: `⌥6 p` ist `]p`. Für Tastaturen, auf denen das unbequem ist oder das Layout anders meldet, sind `ü` und `+` gleichwertig (`üp`, `+p`): Sie liegen dort, wo auf der US-Tastatur `[` und `]` liegen, und sind im Text sonst unbelegt. Der Parser fragt sie nur am Befehlsanfang ab; hinter `f`, `r`, `ms` bleiben sie das Zeichen selbst. Sie stehen in `HelixKeymap.bindings` und im Which-Key, in der Übersicht nur `[p`, `]p`. Welche Variante iPadOS bei ⌥5 meldet, ist ungeprüft.
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
26. **Gesetze (Helix, Textdokument):** `Space l` geschlossen, am Rand, offen und ohne aktivierte Sammlung (Hinweis). `j k`, `n N`, `144G`, `p` 144 Enter, `/` `144 HGB`, `/` Wort Enter, Enter wandert zum nächsten Treffer; `t`, `o`, `B` je mit `j`, Enter, Esc; `v`; `+ -`. Auswahl per Touch, `m2` (grün), `mm`, `d`, `u`, `U`. Esc und `Space l` schließen (kein Pfeil am Rand), `P` parkt, `j` wirkt sofort auf der Seite, auch mit Stiftwerkzeug und aus einem Text in NOR. ⌫ in der Eingabezeile löscht kein gewähltes Objekt.
27. **Dialoge:** Neues Heft mit `n`: Titel tippen, Tab, `j`, Leertaste auf Umschlag, `h l` auf Papier, Enter erstellt, im neuen Heft wirken Tasten. Esc bricht ab, in der Bibliothek geht `j` weiter. `N`, `m` (Enter wählt Ordner), PDF importieren aus der Palette, Seite anpassen, Papier für neue Seiten, Lokale Wiederherstellungspunkte, zweite Ansicht. Rahmen läuft mit, auch nach unten scrollend. Einstellungen: `j`, Enter, Toggle per Leertaste, Esc eine Ebene, Esc schließt; aus Bibliothek und aus dem Heft.
28. **Rückfragen:** `d` in der Bibliothek, Enter; `d`, Esc; Einstellungen › Papierkorb: Enter auf Eintrag, Endgültig löschen: Enter allein bricht ab. `r` und `f`: Name, ⌫, Enter, Esc, in der Bibliothek geht es danach weiter. Fehleralert: Enter, Esc, danach Tasten. **Ohne Antippen:** nach jedem Punkt dieser Liste muss die nächste Taste wirken.
29. **Farbe:** `Space c` mit Stift, Marker, Formen (Linienart), genauem Radierer, Laser, Lasso (Hinweis), im Text (Farbe, Marker auf der Auswahl, `Aus`); `1`, `hjkl`, Enter, Esc ändert nichts. Tafel offen, Text antippen: Tippen schreibt.
30. **Ohne Tastatur:** Heft, Suche (Feld fokussiert, Softwaretastatur), Neues Heft (kein Rahmen, kein Autofokus), Einstellungen, Seitenleiste per Touch wie bisher. Tastaturmodus aus: Sheets wie bisher, Esc schließt.
31. **Register:** `w"ay`, `w"by`, `"ap`, `"bP`, `"aR`, dazwischen in einer anderen App kopieren: Die benannten Register bleiben, `p` nimmt die fremde Zwischenablage. `"_d` lässt `p` unverändert. `"zp` zeigt `Register leer`. `"a` zeigt die Anzeige, Esc nimmt es zurück, ohne dass etwas anderes passiert. Beide Textwege, auch über eine Seitengrenze.
32. **`.`:** `o`, tippen, Esc, `j`, `.`; `c`, tippen, Esc, `w`, `.`; `A`, tippen, Esc, `3.`. Je Schritt ein `u`, Formate daneben bleiben. Mit Autokorrektur (ein korrigiertes Wort tippen), Diktat und Tottaste: `.` wiederholt das Ergebnis. In einem Text am Seitenende: Der Text läuft auf die nächste Seite, Cursor stimmt.
33. **Makros:** `Q`, `REC @` erscheint, `A;`, Esc, `j`, `Q`, dann `5q` über eine Seitengrenze: alles ein `u`, fette Wörter dazwischen bleiben fett. `"aQ`/`"aq`. `Q`, `u`, `Nicht im Makro` erscheint. `q` im eigenen Makro: `Q`, `q`, `Q`, `q` endet sofort. `9999q` auf einem Makro: spürbar höchstens 2 s, `Makro abgebrochen`, `u` stellt alles her. Während der Aufnahme den Text per Antippen oder Esc verlassen: `REC` geht weg, das Makro ist da.
34. **Sprungliste:** `ge`, ⌃o, ⌃i; ⌃s, Wandern, ⌃o; über Seiten (Hand-off zur anderen Seite, Modus bleibt NOR); `/` Enter, ⌃o; tippen über der gemerkten Stelle, dann ⌃o; vom Text in ein anderes Feld: ⌃o tut dort nichts Fremdes. Kommt ⌃i als ⌃i an und nicht als Tab? Fängt iPadOS ⌃s oder ⌃o ab?
35. **Teilen:** `%`, `S`, `, `, Enter: „n Auswahlen“, Esc in der Zeile stellt her; ⌥s auf mehreren Zeilen; ⌥C und `C`; `d` wirkt auf alle; in Texteditor 2 alle sichtbar.
36. **`[` `]`:** `]p`, `[p`, `3]p` mit ⌥6/⌥5 und mit `+`/`ü`, Popup zeigt `p`; `v]p` erweitert. `fü`, `r+` tippen das Zeichen. ⌥s und ⌥C tippen in INS und in der Eingabezeile weiter ihr Zeichen.
37. **Klammerpaare:** Einstellung an: `(`, Cursor dazwischen, `x`, `)` läuft drüber; `(` `⌫` löscht beide; `(` vor einem Wort einzeln; `"` nach einem Wort einzeln; `(` am Seitenende (beide Textwege, Cursor springt nicht hinter die Klammer). Autokorrektur auf ein Wort direkt vor `)`, Marked Text mit `(` darin (japanische Eingabe), Diktat: nichts verdoppelt, nichts verschwindet. Einstellung aus: nichts davon. Tastaturmodus aus: nichts davon.
38. **Einzug:** Zeile mit Leerzeichen: Enter, `o`, `O`, je tippen; Enter, Esc nimmt den Einzug weg, `u`; Liste mit Enter und `o` wie bisher (kein doppeltes Listenzeichen); Marked Text und Enter; `o` auf der letzten Seitenzeile einer eingerückten Zeile.
39. **Texteditor 2:** `.`, `q`, `c` mit mehreren Cursorn, Klammerpaar an mehreren Cursorn, ⌫ dort; Undo je ein Schritt.
40. **Tasten bei gehaltenem Makro:** Während `REC` wiederholt gehaltenes `j` nicht (ein Schritt je Druck). `Q` in der Palette, `Makro abspielen` in der Palette.
41. **Gesetze, normale Tastatur (Heft, Helix aus):** Zustellung zuerst: ⇧⌘L öffnet, dann ↓ scrollt das Gesetz und nicht die Seite (sonst erreicht der Tastenempfänger die Tasten nicht). ⌘-Halten zeigt „Gesetze“ und die Key Commands; Menüleiste „Gesetze“ mit wechselnden Titeln. ⇧⌘L schließt (kein Pfeil), ⌥⌘L parkt und holt, ⌘L fokussiert die Schnellsuche, tippen, Esc verlässt das Feld, zweites Esc schließt. Mit Fokus: ⌘F (Titel im Menü „Heft“), ⌘G/⇧⌘G und ↩/⇧↩, ← →, ↑ ↓, ⌥↑ ⌥↓, Leertaste, ⌘↑ ⌘↓ (Seite wechselt nicht), ⌘+ ⌘- ⌘0, ⌘D, ⌘T, ⇧⌘T, ⌥⌘B, ⌥⌘P. Touch-Auswahl, 1–5, ⇧⌘H, ⌫ auf einer Markierung; ohne Auswahl tippen Ziffern und ⌫ nichts. ⌘Z nimmt die Markierung zurück, nicht den letzten Heftstrich; ohne Fokus wieder das Heft. Stift auf die Seite: ⌘G öffnet „Gehe zu Seite“, ⌘↑ blättert. Sheet über dem Fenster (Inhaltsverzeichnis): Esc schließt das Sheet, nicht das Fenster. **Vorrang:** Key Command ⌘Z am Responder gegen „Bearbeiten › Widerrufen“, Menü-⌘G gegen den Seitennavigator. Gleiches mit Helix im Textdokument: Tasten ohne ⌘ nach `GESETZE`, ⌘-Kürzel wie oben.

**Diagnose:** Mit Einstellungen › Diagnose (ab Neustart) protokolliert `KeyboardRouter` jede Taste mit Kontext, Ergebnis und First Responder: `idevicesyslog | rg noty.keys`. Dazu Zustandszeilen `textBegan`, `textEnded` (auch `waits`, `kept`), `applyTextFocus refused` und `second-way` bei abgewiesenem Key Command, je mit Modus, `editing`, `handoff` und Responder. Der Esc-Weg nennt sein Ergebnis (`one level`, `leaves text`, `text gone`). Getippter Text erscheint nur als `(typing)`, auch in der Eingabezeile, im Suchsheet und in Dialogfeldern. Kommt zu einer Taste keine Zeile, hat sie keinen unserer Responder erreicht.

## Helix-Modell

Die Engine ist in Core gegen das echte Helix geprüft, die App bildet sie ab.

- `TextEngine` ist reiner Zustand aus Text (UTF-16 auf Graphemgrenzen), mehreren Auswahlen (`anchor`, `head`, Hauptauswahl), Modus, Registern, Suche, Sprungliste, letzter Einfügung und Makros. `perform` liefert Edits von hinten nach vorn in Versätzen des alten Texts, zusätzlich `combinedEdit` als eine Ersetzung. `sync` übernimmt natives Tippen, Antippen und Undo aus der App. Angezeigte Zeilen kommen über `TextEngineLayout`.
- `HelixKeymap.bindings` ist die einzige Tabelle für Parser, Übersicht (`groups`), Palette (`commands`) und Which-Key (`menu`). `HelixParser.feed` liefert `.pending(menu:)` mit dem aktuellen Knoten.
- Geprüft gegen das echte Helix 25.07.1 im PTY: rund 3600 Abläufe (Zufall und Randfälle) inklusive Auswahl, Cursor und Hauptauswahl, abgeglichen mit dessen Quelltext; für die Erweiterungen im Schlusslauf 2400 Zufallsabläufe mit neuen Folgen (300 je Gruppe: Register, Absätze, Teilen, Sprünge, `.`, Makros, gemischt, Paare), 37 Differenzen, jede einer Zeile der Tabelle zugeordnet, Sprünge und Teilen 0. Zusammen 911 Zeilen stehen als `HelixGoldenCases` in den Tests, 106 mit `auto-pairs = true` in `pairRows`.

**Abweichungen von Helix**, alle wegen der App:

| Fall | Helix | noty | Grund |
| --- | --- | --- | --- |
| Text endet ohne Zeilenumbruch (Normalfall bei Notizen): `xd`, `xy` auf der letzten Zeile | lässt `"a\n"` stehen, Register ohne Umbruch, `p` hängt ans Zeilenende | Zeile samt Umbruch davor weg (`"a"`), Register als Zeile, `p` setzt sie als eigene Zeile | Dateien enden dort immer mit Umbruch, Notizen nicht |
| Zeilen-`p` hinter der letzten Zeile ohne Umbruch, oder in leeren Text | klebt an die Zeile (`"abcx\n"`) | eigene Zeile, kein Umbruch am Textende | wie oben |
| `xxc` über alle Zeilen ohne Schlussumbruch | lässt `"\n"` | leerer Text | wie oben |
| `a` mit Auswahl bis zum Textende | fügt einen Umbruch ein | fügt nichts ein | kein Platzhalter nötig, Caret darf am Ende stehen |
| `mi(`, `md(` usw. mit Auswahl am Textende | Fehler `RangeExceedsText` | funktioniert | wie oben |
| Einzug bei `o`, `O`, Enter, `xc` | rundet auf die erkannte Einzugbreite und schreibt sie im erkannten Stil (6 Leerzeichen bei Breite 4 werden 4, bei Tabs 1 Tab) | übernimmt den Leerraum der Zeile genau | proportionale Schrift, Notizen haben keinen Einzugsstil |
| Enter hinter Leerzeichen auf einer Zeile ohne Einzug | entfernt sie | bleiben stehen, natives Tippen | Enter nach einem Wort mit Leerzeichen ist alltäglich, kein Eingriff in Autokorrektur; auf eingerückten Zeilen wie Helix |
| ⌫ im Einzug | löscht bis zum Tabstopp | löscht ein Zeichen | natives Löschen |
| Paare für `` ` `` | schließt | nicht | Auftrag: nur `( [ {` und Anführungszeichen |
| Auswahl nach `i(`, Esc mit automatischem Paar | nur die schließende Hälfte | an einem Cursor bleibt auch die alte Auswahl dahinter gewählt; mehrere Cursor wie Helix | natives Tippen meldet nur Text und Cursor |
| `.` nach wirkungslosen Tasten (⌫ am Textanfang), nach Pfeilen in INS | spielt die Tasten | wiederholt das Ergebnis | natives Tippen liefert keine Tasten, dafür gehen Autokorrektur und Diktat |
| Makro in Register und Text in Register | dasselbe Register: `"ap` fügt die Tasten ein, Text läuft als Tasten | getrennte Speicher je Zeichen | Notizen sollen nie als Tasten laufen |
| Undo nach einem Makro | je Befehl ein Schritt | ein Schritt | Engine läuft allein, die Ansichten folgen danach |
| `u` und Menüs im Makro, `j`/`k` im Makro | alles läuft | nur Textbefehle, logische Zeilen | Engine kennt kein Undo und keine Ansicht |
| Unbegrenzte Zähler im Makro | laufen | 5000 Schritte, 2 s | Hauptthread |
| `]g`, `[g` und die übrigen `[`/`]`-Einträge | Git, Syntaxbaum, Diagnosen | nicht belegt | Notizen haben nichts davon |
| Sonderregister `# . % : /` | Lesewerte | gewöhnliche Register | in Notizen ohne Nutzen |
| `"+`, `"*` | eigene Register der Zwischenablage, getrennt vom Standard `"` | dasselbe wie `"` | das Standardregister folgt hier ohnehin der Systemzwischenablage |
| `xc` mit mehreren Auswahlen auf direkt benachbarten Zeilen | eine neue Zeile | je Auswahl eine | vorhandenes Verhalten der Engine, nur Texteditor 2 kann daran tippen |
| ⌃i, Tab | beide vor in der Sprungliste | nur ⌃i | Tab bleibt Listenebene |
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

Bewusst wie Helix, ebenso überraschend: `.` ohne vorherige Einfügung verlässt nur SEL; `S` ohne Treffer richtet die Auswahlen vorwärts; `S` setzt wie `s` die Suche für `n`; ⌃o bleibt am Listenanfang stehen, ohne die aktuelle Stelle zu verlieren.

## Aufbau

**Core:** `LawShortcuts` (Gesetzeskürzel der normalen Tastatur, `LawShortcutsTests`), `HelixKeymap`, `HelixParser`, `TextEngine` (Sprungliste, `.`, Makros und `EditComposer` in `TextEngine+Macros.swift`), `TextTyping` (Einzug und Paare, für Engine und beide Textwege), `KeyPressGate`, `KeyDeliveryLatch` und `KeyPalette` (`KeyboardCommands.swift`), `TextLines`, `Notebook.editingTextFlow`/`restylingTextFlow` (`TextFlowRange.swift`). `KeyboardPanels.swift`: `KeyList`, `KeyOptionRing`, `KeyChoice`, `KeyChoiceCursor`, `KeyInputLine`, `KeyPanelStack`, `KeyFocusTarget` (`KeyboardPanelsTests`).


**App:** `KeyboardRouter` nimmt die Tastendrücke entgegen (`pressesBegan` in `PageTextView`, `DrawingCanvasView`, `WorksheetView`, `KeyboardHostView`), ⌘-Kürzel bleiben bei Menü und Key Commands. Er hält Parser und Engine und bindet `HelixAction` an `ContentView.runKey`, `LibraryView.runKey` und `ObjectEditingLayer`. INS läuft am Parser vorbei, nur Esc geht an die Engine.

**Gesetze** (`LawKeyCommands.swift`): `LawKeyboard` hält Gesetzfokus, Fenstermodell und die Aktionen des Lesers (`LawReaderKeyboard.swift`, registriert über `laws.keyFocus`); `LawKeyAnchor` im Editor verbindet den aktiven Bereich und trägt den Tastenempfänger `LawKeyHostView`; `NotyCommands` baut das Menü „Gesetze“ aus `LawShortcuts`. `KeyboardRouter.claimResponder` lässt bei Fokus die Seite in Ruhe, `textBegan`, `tappedText` und Berührungen der Seite nehmen den Fokus zurück.

**Panels** (`KeyboardPanels.swift`): Alles außer Seite, Text und Bibliothek ist ein `KeyPanel` mit eigenem `HelixContext` auf einem Stapel; das neueste hat die Tasten, sein `run` bindet die Aktionen. Seitenleiste, Gesetze, Rückfragen und Farbe nehmen keinen Fokus, die Tasten kommen weiter über den bisherigen Responder. Nur Sheets bringen mit `KeyPanelHostView` einen eigenen mit; er hält auch Esc, Tab, Enter, Leertaste und Pfeile als Key Commands, weil das Fokussystem einer Liste sie sonst nehmen könnte. Wer den Fokus zu holen hat, entscheidet `KeyFocusTarget`, ausgeführt von `reclaim()`: jedes Schließen eines Panels läuft über `leave` und holt zurück, auch was nicht durch `presenting` geht (Sheets der Seitenleiste und des Lesers). Eine neue Option braucht nur `keyOption`; die Reihenfolge ergibt sich aus der Lage (`KeyOptionRing`). Ein neuer Dialog braucht `keyboardSheet()`. Sheets legen ihre Overlays selbst darüber (`KeyboardOverlay(panel:)`), die der Bibliothek lägen darunter. Ohne Tastatur (`hasKeyboard`) übernimmt nichts den Fokus, es erscheint kein Rahmen.

**Esc und Tab** können auf beiden Wegen kommen: über `pressesBegan` oder als Key Command, wenn das System die Taste sonst nähme (`PageTextView`, `DocumentTextSurface`, `WorksheetView`, `ObjectEditingLayer`; die Übersicht hat dazu eine `cancelAction`). Welcher Weg kommt oder ob beide, ist nicht festgestellt. Beide enden in `KeyboardRouter.dispatch`, der Key-Command-Weg über `handle(token:text:)`. `KeyPressGate` trennt nur Zustellungen desselben Tastendrucks über `pressesBegan`; ein Key Command hat keine Druckzeit, deshalb sperrt `KeyDeliveryLatch` eine Taste, die der eine Weg benutzt hat, für 0,12 s einmal für den anderen. Eine unbenutzte Taste bleibt frei, so kommt Tab in INS beim Listeneinzug an. `handle(token:)` gibt false zurück, wenn der Aufrufer die Taste selbst behandeln soll (Tab einfügen, Text verlassen). Neue Key Commands für Router-Tasten laufen über diese Funktion.

**Text** (`TextObjectLayer+Keyboard.swift`): Vor jedem Befehl übernimmt die Engine Text und Auswahl des Bildschirms (`keyboardSync`: ganzer Fluss oder Feld). Danach zeigt `keyboardShowSelection` die Hauptauswahl: innerhalb einer Seite native `selectedRange`, über Seiten `TextFlowSelection` mit dem Caret am Cursor, ein Cursor auf einem Zeichen als breiter Caret (`normalCaret`). Edits gehen auf einer Seite über `applyListEdits`, über Seiten über `TextFlowActions.edit`, beides ein Undo-Schritt; die einzelnen Edits statt `combinedEdit` erhalten Formate dazwischen, `Outcome.textEdits(in:)` teilt `~`, `` ` ``, `r` zusätzlich an den Formatwechseln (`keepsFormat`). `j`/`k` messen im `NSLayoutManager` der Textansicht, auf anderen Seiten in `TextObjectLayout` (`KeyboardLineLayout`).

**`.` und Makros** schreiben in der Engine und geben ein zusammengesetztes `Outcome` ab: `EditComposer` führt die Edits aller Schritte auf den Text vor dem ersten zurück, Unberührtes bleibt außerhalb und behält sein Format, die gleich langen Ersetzungen laufen wie `keepsFormat`. Die Ansichten dazwischen sind deshalb egal (`viewIsCurrent`, Hand-off), `apply`/`applyEngine` sehen einen normalen Befehl. Das Getippte eines Laufs kommt aus `sync`: `InsertRun` merkt Text und Cursor beim Eintritt, `typedText` bildet beim Esc die Differenz. Mehrere Cursor tippen über die Engine, dort protokolliert `logTyping`. Ein `sync` mit `mode` (Antippen, Fokus von außen) beendet den Lauf. `KeyboardRouter.feed` meldet jede Taste per `engine.record`, die Eingabezeile `recordPrompt`.

**Fallstricke, die der Code absichert:** Nach einem lokalen Edit im Fluss liegt noch eine Fokusanforderung des Edits an, eine neuere ersetzt sie (`moveCaret`). Wechselt der Cursor die Seite, erhält `handoff` den Modus: `applyTextFocus` und `DocumentTextSurface.show` setzen es vor jedem programmatischen Fokus, Undo nur, wenn es wirklich einen Fokus anfordert (`undoRequestedFocus`), und `textEnded` wartet eine laufende Anforderung ab. Nur `writingRequested` (Tipp unter den Text, `i`) geht ausdrücklich nach INS. Läuft eine Anforderung, ist die Ansicht hinter der Engine, also zählt deren Auswahl (die Anforderung läuft nach 1,5 s aus, falls sie nie ankommt). Auf einer neuen leeren letzten Zeile (`o` am Dokumentende) kennt nur der Reflow die Seite: `moveCaret` geht vom geschriebenen Text aus, `apply` schickt den Cursor deshalb mit dem Flussedit und überschreibt dessen Fokus nicht. Ein Flussedit über Seiten ändert das Modell sofort, die Ansichten erst beim nächsten Update: Bis dahin setzt `viewIsCurrent` keine Auswahl und nimmt keinen lokalen Edit, sonst würde `textViewDidChangeSelection` den alten Text über den neuen schreiben. Die Palette nimmt den Fokus: `holdText`/`returnToHeldText` halten den Text so lange, damit ihre Textbefehle ihn finden; ein leeres freies Feld verschwindet dabei und beendet den Text. Undo setzt `TextFlowSelection` zurück (`textChangedElsewhere`), Offsets werden geklemmt.

Kein Formatwechsel; Einstellungen `noty.keyboard.mode` und `noty.keyboard.autoPairs` in UserDefaults. Register, Makros und Sprungliste leben nur im Speicher.
