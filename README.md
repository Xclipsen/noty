# noty

Native iPad-App für Schulnotizen, entwickelt auf `la@lab` unter Omarchy.
Auftrag: Master-Prompt „Schulnotizen auf dem iPad“, 16.10.2026; Name vom Nutzer auf **noty** geändert.

## KI-Assistent

Ein experimenteller KI-Assistent existiert separat auf dem Branch exp/ki und ist nicht Teil dieses Release-Kandidaten.

## Kalender – Featurebranch `feat/kalender` (Test-App „noty calendar“)

Stufe A: Kalenderdesign und Navigation ([Plan und Umsetzungsstand](docs/CALENDAR-PLAN.md#umsetzungsstand-stufe-a-03112026)): Einstieg „Kalender“ in der Bibliotheksleiste, Woche (Mo–Fr/7 Tage), Monat mit „+ n weitere“, Tag, Jahr, Termindetails mit direkt beschreibbarer Entwurfsseite, Vergrößern/Rückkehr, Terminformular. Designabnahme offen.

Meilenstein B1 (Build 101, [Umsetzungsstand](docs/CALENDAR-PLAN.md#umsetzungsstand-b1-04112026)): WebUntis-Stundenplan und -Ferien über den **inoffiziellen Zugang per Untis-Mobile-Freigabe** (QR-Code oder Handeingabe, Zugangsdaten nur im Schlüsselbund), schreibgeschützt und offline mit „Stand“; eigene Einzeltermine gespeichert im Kalenderpaket des Bereichs (`Calendar/`); Beispieldaten nur noch als Schalter. Terminnotizen weiterhin nur im Speicher; keine Wiederholungen, Erinnerungen, kein Kalender im Backup. Implementiert, erfolgreich gebaut und veröffentlicht, am iPad ungeprüft.

Meilenstein B2 (Build 102, [Umsetzungsstand](docs/CALENDAR-PLAN.md#umsetzungsstand-b2-04112026)): Terminnotizen als gewöhnliche Hefte in „Kalendernotizen“, Zuordnung verschobener Stunden, Wiederholungen, Ziehen/Dauer, Fachfarben. Meilenstein B3 (Build 103, [Umsetzungsstand](docs/CALENDAR-PLAN.md#umsetzungsstand-b3-04112026)): Kalender im Bibliotheksbackup (Format 3) mit Restore in einen neuen Bereich ohne Zugangsdaten, „Gelöschte Termine“ mit Wiederherstellen, Erinnerungen für eigene Termine und Unterricht. Beide implementiert, erfolgreich gebaut und veröffentlicht, am iPad ungeprüft.

## Native Gesetzessammlung

Seit Build 97 Teil von `dev` (vorher Feature-Worktree `feat/native-law-library`): optionale native Gesetzessammlung als internes Slide-over oder angedockte zweite Ansicht, lokale Texte/optionale PDFs, Direktfundstellen wie `144 HGB`, Apples Tastaturen und appweites E-Mail-Konto. Drei getrennte Schalter (Aktivierung aus, persönlicher Sync an, automatische Gesetzesupdates an). Notizbücher bleiben lokal; Gesetzesmarkierungen haben eine eigene dauerhafte Warteschlange und Sicherungsdatei.

Core-Tests, echter Host-Offlineroundtrip und iPad-SDK-Build sind geprüft. Website und Backend sind seit 20.10.2026 auf IONOS ausgerollt und öffentlich geprüft. Mail bleibt auf Nutzerwunsch aus; E-Mail-Registrierung/Recovery sind deshalb noch nicht verfügbar, bestehende Namenslogins bleiben unterstützt. **Build 60 ist seit 21.10.2026 auf dem iPad installiert** (Gesetzesfenster per Drag & Drop andocken/schweben/parken, Position/Breite gemerkt, ✕ parkt als Pfeil-Lasche am Rand, Blätterleiste mit mitlaufendem Paragraphfeld, Markieren per Auswahl und mit Pencil über den Stiftschalter „Lesen | Markieren | Radieren“, Markierungen sofort sichtbar, gemerkte Lesestelle, direkte Schriftgröße, Registrieren mit Benutzername ohne E-Mail), einschließlich der Funktionen aus Build 53. Vorher-/Nachhervergleich: alle 14 Hefte und 101 Dateien unverändert. Bedienung am iPad weiterhin ungeprüft. Aktivierung unter Einstellungen → Gesetzessammlung. [Umfang und Architektur](docs/LAW-INTEGRATION-PLAN.md), [Prüfungen](docs/TESTING.md#native-gesetzessammlung--feature-worktree).

## Aktueller Stand der bisherigen Lieferung

**Freigabe 11.11.2026 · normale noty Build 158 (`main`):** Auf Wunsch des Nutzers („direkt auf main“) der Stand von noty dev Build 157 (Lernfeld groß, Inhalt mit Überschriften und Material), am iPad ungeprüft.

**Lernfeld groß und Material im Heft, noty dev Build 157 (`feat/lernfeld-gross`, 11.11.2026):** Lernfeld-Stunden öffnen wie Fach-Hefte das ganze Heft groß; die Seitenleiste „Inhalt“ zeigt Überschriften der Textfelder und bei Lernfeld-Heften „Skripte und Videos“ des Lernfelds ([LERNFELDER](docs/LERNFELDER.md)). Core-Tests und iPad-Build bestanden, am iPad ungeprüft.

**Freigabe 11.11.2026 · normale noty Build 156 (`main`):** Auf Wunsch des Nutzers („dev auf main“) kommt der Stand von noty dev Build 155 in die normale noty: Umschlagfarben und „Umschlag ändern“ (Heftschema 17), Scrollen nach Import/Rückkehr in die App nicht mehr blockiert, Fach-Hefte (Kalenderformat 6), „Lernfeld-Heft wählen“, Ordner exportieren und importieren, Spiegel im Hintergrund; dazu auf seinen Wunsch („alles zu dev“) `feat/audit-fixes` (die zehn Behebungen aus dem Audit vom 10.11.2026) und `feat/wiederherstellen-2` (Wiederherstellen Phasen 2–4: Zeitleiste je Heft, Backup-Zusammenfassungen, gestaffelte Aufbewahrung, ganze Bibliothek ohne Bereich). Eine aus Dateien geöffnete `.notylibrary` bietet jetzt „Alles in diese Bibliothek übernehmen“, „Inhalt ansehen und Hefte zurückholen“ und nur in den Test-Apps „Als neuen Bereich“. Nachweise der Zusammenführung: Core-Tests 1753 (0 Fehler, 7 übersprungen), Host-Roundtrip mit Prüfer-Negativtests, Diagnose-Python-Tests, `xtool dev build`. Nicht zusammengeführt: `exp/ki` (KI bleibt eigene App), `ci/simulator` (kein CI gewünscht), `feat/diagnose-test` (alter Testzweig, Inhalt schon enthalten). Heftschema 17 und Kalenderformat 6 sperren ältere Builds (normale noty ≤ 149, noty calendar ≤ 148); vor der Installation ein Bibliotheksbackup anlegen. Die Einzelteile sind am iPad weiterhin **ungeprüft**, Core-Tests, Host-Roundtrip und iPad-Build bestanden.

**Spiegel im Hintergrund, noty dev Build 155 (11.11.2026):** Die Übernahme eines neuen Abzugs der normalen noty sperrt die Bibliothek von noty dev nicht mehr ([APP-SYNC](docs/APP-SYNC.md)). iPad-Build bestanden, am iPad ungeprüft.

**Ordner exportieren und importieren, noty dev Build 154 (`feat/ordner-export`, 11.11.2026):** Ein Ordner lässt sich mit Unterordnern und Heften als `.notylibrary` teilen; eine solche Datei kommt wahlweise in die aktuelle Bibliothek (fehlende Ordner entstehen, gleichnamige werden benutzt, Hefte als neue Hefte) statt nur als getrennter Bereich ([LIBRARY](docs/LIBRARY.md)). Kein Formatwechsel. Core-Tests, Host-Roundtrip, Archivprüfer und iPad-Build bestanden, am iPad ungeprüft.

**Lernfeld-Heft wählen, noty dev Build 153 (`feat/lernfeld-heft`, 11.11.2026):** Ein Lernfeld kann in ein vorhandenes Heft der Bibliothek schreiben (Einstellungen › Kalender › Lernfelder › „…“ › „Heft wählen …“), z. B. in ein importiertes Heft mit den bisherigen Unterlagen; neue Stunden kommen dort ans Ende ([LERNFELDER](docs/LERNFELDER.md)). Kein Formatwechsel. Core-Tests und iPad-Build bestanden, am iPad ungeprüft.

**Fach-Hefte, noty dev Build 150 (`feat/fachheft`, 09.11.2026):** Ein Fach ohne Lernfeld bekommt ein bestehendes Heft der Bibliothek; die Stunde im Kalender legt dort eine Seite mit Überschrift an und öffnet das Heft groß (Kalenderformat 6, [LERNFELDER](docs/LERNFELDER.md)). Core-Tests, Host-Roundtrip und iPad-Build bestanden, am iPad ungeprüft.

**Fehlerkorrekturen aus dem Audit (11.11.2026, `feat/audit-fixes`, ohne Buildnummer):** Zehn Fix-Branches ohne Konflikte zusammengeführt. Tastaturmodus (Esc nimmt nur den Einzug des gerade beendeten Einfügelaufs zurück, getrennte Tastatur in NOR/SEL schreibt wieder) und Auswahl bündig am Seitenrand; Speicher, Bibliothek und Backup (fehlgeschlagener erster Commit eines neuen Hefts hinterlässt kein Paket ohne Manifest, Entpackfehler beim Restore ist kein „ungültiges Backup“, Titel einer `.noty`-Datei, Aufbewahrung der iCloud-Ablage bei jedem Durchgang, WebDAV-Passwort nur für denselben Server, Suchindex gelöschter Hefte und entfernter Bereiche, Startanlass vor „Zuletzt geöffnetes Heft“, Ablage-Fenster, Anzeige „Abgleich wird geprüft …“); Editor und Start („Ohne Speichern schließen“ bei jedem Speicherfehler und auf jedem Weg aus dem Heft; ein Hintergrundstart für die Kalenderaktualisierung zählt nicht als unterbrochener Start); Kalender (Monatsserie verschieben, Thema am Lernfeld-Block, „Schnell anlegen“ mit Zeitraum, Laden nach Bereichswechsel, Glocken-Verlauf, Widget-Texte und Kanal der Widget-Extension, Tageswechsel, Zeitraster nach Ziehen); Gesetze (Schnellsuche, Klammer im Verweis, Katalogabgleich); Diagnose (Server prüft jedes Feld, Auswertung traut der Ablage nicht). Kein Formatwechsel. **Implementiert**; 1738 Core-Tests (8 übersprungen, 0 Fehler), Diagnose-Python-Tests 35 (1 übersprungen) OK; **erfolgreich gebaut** mit `xtool dev build` samt der für den Kanal `stable` vorbereiteten Widget-Extension (`NotyCalendarWidgets.appex` mit `NotyChannel = stable`, Anzeigename „noty“), unsigniert. Keine Buildnummer, nichts veröffentlicht, **nicht installiert, am iPad ungeprüft**: die gesamte App-Schicht (Schließen bei Speicherfehler, Start-Absturzschutz, Kalender laden/Glocke/Widget/Heute/Ziehen, Ablage-Fenster, WebDAV-Meldung, Entfernen des Suchindex, Abgleichsanzeige, getrennte Tastatur). Der Diagnose-Dienst auf dem Server läuft bis zu einem `sudo bash diagnostics/install.sh` mit dem alten Code. Offen geblieben: Reste mit Inhalt nach einem abgebrochenen ersten Commit blockieren das Bibliotheksbackup weiter; das Terminformular verschiebt eine Monatsserie um die Tage der geöffneten Durchführung; Upload-Quote je Diagnose-Schlüssel fehlt. Achtung iCloud-Ablage: Beim ersten Durchgang nach dem Update verlieren lange nicht geänderte Hefte einmalig und endgültig ihre älteren Stände in iCloud ([ICLOUD](docs/ICLOUD.md)). [Nachweise und gebündelter Gerätetest](docs/TESTING.md#fehlerkorrekturen-aus-dem-audit-11112026-feataudit-fixes-ohne-buildnummer).

**Zusammenführung 09.11.2026 (dev und main, Build 149, noch nicht veröffentlicht):** `feat/paragraphen` (Gesetzesverweise im Heft, Schutzrand für den Stift, ⌘F/⌘L-Zustellung), `feat/feinschliff` (Absturzschutz beim Start; seit 11.11.2026 auf `feat/audit-fixes` ohne Hintergrundstarts der Kalenderaktualisierung, siehe oben; Gesetzesleser-Fix) und `feat/diagnose` (Fehler- und Ruckler-Diagnose) sind in `dev` und `main`. Nachweise: 1617 Core-Tests, Host-Roundtrip, Diagnose-Servertests und `xtool dev build`; die zusammengeführte Fassung ist **am iPad ungeprüft**. Die Veröffentlichung der normalen noty wartet auf den iCloud-Container im Apple-Entwicklerportal ([ICLOUD](docs/ICLOUD.md)).

**Fehler- und Ruckler-Diagnose (`feat/diagnose`, 08.11.2026; seit 09.11.2026 in `main`):** Abstürze, Hänger, langsame Vorgänge und Fehler aus noty dev, noty AI und noty calendar gehen automatisch als einheitlicher Bericht an den eigenen Server, ohne Heftinhalte; die normale noty sendet nur auf Wunsch. Auswertung mit `scripts/diag_report.py`. Core- und Servertests sowie iPad-SDK-Build bestanden, Server installiert; nicht installiert, am iPad ungeprüft ([DIAGNOSE](docs/DIAGNOSE.md)).

**noty dev Build 128 (`feat/paragraphen`, 07.11.2026):** Gesetzesverweise P2/P3 (Gesetzesbezug pro Heft, Querverweise im Gesetzesleser mit Hover-Karte, Absatz-Sprung mit Hervorhebung, Als Zitat einfügen, Tippvorschlag, Texteditor 2, Handschrift), Schutzrand gegen Striche an Bedienleisten, ⌘F/⌘L über zentrale Befehlsstelle, Lasche ohne ✕, Bibliothek ohne Backup-Knopf. Implementiert, gebaut, zwei Review-Runden, 1386 Core-Tests und Host-Roundtrip bestanden; am iPad ungeprüft. [Details](docs/PARAGRAPH-LINKS.md).

**Gesetzesverweise im Heft, noty dev Build 125 (`feat/paragraphen`, 06.11.2026):** In Textfeldern, Fließtext und PDF-Text werden „§ 35a EStG“, „R 9.1 LStR“, „AEAO zu § 122 AO“ usw. dezent unterstrichen. Hover mit Apple Pencil oder Trackpad zeigt eine Vorschau aus dem lokalen Bestand, Antippen oder Klicken öffnet das Gesetzesfenster dort, „Zurück zur Notiz“ führt zurück. Kein Formatwechsel. Implementiert und gebaut, 1365 Core-Tests und Host-Roundtrip bestanden, am iPad ungeprüft. [Details](docs/PARAGRAPH-LINKS.md), [Plan Merker/Steuerkanzlei](docs/MERKER-PLAN.md).

**noty 1.0, Build 121 (05.11.2026):** Release-Kandidat 2 (Build 120) als normale noty, vom Nutzer freigegeben. Dazu kommt der Abgleich jetzt auch mit der vierten App „noty calendar“ ([APP-SYNC](docs/APP-SYNC.md)). Veröffentlicht für noty, noty dev, noty AI und noty calendar. Am iPad ungeprüft.

**Release-Kandidat 2, Build 120 (`feat/rc2` → `dev`, 05.11.2026):** Stand von Build 118 (inkl. Abgleich zwischen den noty-Apps) plus Korrekturen aus einer vollständigen Code-Prüfung in acht Bereichen: Stifte, Lasso/Objekte, Text, Speichern, Backup/PDF, Oberfläche, Gesetzessammlung, Release. Kein Formatwechsel gegenüber Build 110–117. Korrigiert:
- **Stift:** Ein spät gemeldeter Strich geht nicht mehr verloren, wenn der nächste Strich zur gehaltenen Form wird. Eine abgebrochene Haltegeste veröffentlicht ihren Strich. Der Wechsel zum Radierer „Ganz“ bricht einen laufenden Strich nicht mehr ab. Ein wartender Lineal-Strich wird vor Rückgängig, Ansichtswechsel und Schließen übernommen.
- **Bilder:** Ein gesperrtes Bild lässt sich auch mit dem Finger nicht mehr verschieben, eingefügte Kopien sind entsperrt. Ein seitenübergreifendes Verschieben während einer Sicherung meldet sich statt still zurückzuspringen.
- **Text:** Im Textdokument stimmt die Anzeige nach Tab, Return und ⌫ in Absätzen mit altem Einzug. Tab ersetzt keine Tottaste (^, `) mehr. Ein negativer Cursor-Versatz kann nicht mehr abstürzen.
- **Oberfläche:** Geteilte Dateien bekommen die aktuelle Papiervorgabe. Eine unlesbare Werkzeug-Einstellungsdatei sperrt die Werkzeugleiste nicht mehr. Nach dem Schließen einer wiederhergestellten Kopie springen Seite und Suchtreffer nicht zurück.
- **PDF:** Das Hintergrund-Raster hält sein PDF-Dokument fest, was einen möglichen Absturz beim Schließen oder Seitenwechsel verhindert.
- **Gesetze:** Der HTML-Import läuft nie verschachtelt, ist für die letzten 12 Abschnitte zwischengespeichert, und `url(`/`@import` sind gesperrt.
- **Diagnose:** Die Eingabe-Diagnose hat einen Schalter (Einstellungen › Diagnose); in noty dev und noty AI ist sie standardmäßig an, in noty aus. `haenger.txt` wird rotiert statt überschrieben.

1327 Core-Tests (Stand Build 117, Core seither nur Kommentar) und iPad-SDK-Build bestanden. Am iPad ungeprüft. Offen aus der Prüfung (nicht behoben): iCloud-Ordner meldet Erfolg vor dem eigentlichen Upload; Tab über mehrere Absätze im Seitentext hebt die Auswahl auf; ⌘Z bei Gesetzfokus mit Helix im Textdokument trifft das Dokument; Vorschau/„Zuletzt verwendet“ für Hefte der zweiten Ansicht.

**Achtung Schema 16 (seit Build 110):** Das erste neue Textfeld an Linien hebt ein Heft auf Schema 16. Builds ≤ 96 (Release-Kandidat 1) öffnen solche Hefte nicht. Vor dem Update der normalen noty deshalb ein Bibliotheksbackup machen; ein Rückweg geht nur damit oder über die je Heft gesicherten Altbytes unter `Migrations/`.

**Einzug und Listen neu (`feat/einzug2`, 05.11.2026):** Ebenen sind führende Tabs; Tab im Präfix rückt den Absatz ein, sonst tippt er einen Tab (beide Tastaturen gleich), ⇧Tab löscht nie einen Tab mitten in der Zeile; Return und ⌫ nach festen Regeln, „- “ bleibt „- “; hängender Einzug für Listen, Pfeile, Etiketten („Bsp.:\t\t…“) und Tab-Absätze in Textfeldern; `->` wird beim Tippen `→` (abschaltbar). Kein Formatwechsel. Implementiert und gebaut, nicht installiert, am iPad ungeprüft ([Regeln](docs/TEXT-FIELDS.md), [Gerätetest](docs/TESTING.md)).

**Build 69 (`extras/build69`):** Helix-Erweiterungen (Register, `.`, Makros, Sprungliste, Teilen, Absätze, Klammerpaare, Einzug), [Tastatur](docs/KEYBOARD.md) in Seitenleiste, Suche, Gesetzen, eigenen Dialogen und Farbauswahl, im Textdokument manueller Seitenumbruch, Papierwechsel, Word- und RTF-Export, Suche über Seitenwechsel und Zurückrücken beim Kürzen. Kein Formatwechsel. Implementiert und gebaut, am iPad ungeprüft.

**Build 68 (`phase1/fixes`):** Korrekturen aus dem Review des Tastaturmodus für beide Textwege: `c`, `i`, `o` nur noch an sichtbaren Stellen, `~`, `` ` ``, `r` erhalten Formate, Modus bleibt bei programmatischem Fokus, ein Esc oder Tab wirkt genau einmal; Texteditor 2 verliert bei fehlendem Platz keine Eingabe. Implementiert, gebaut und installiert (alle 28 Dokumente unverändert), am iPad ungeprüft ([Gerätetest](docs/KEYBOARD.md#gerätetest-gebündelt-alles-ungeprüft)).

**Build 67 (`phase1/app`):** [Tastaturmodus](docs/KEYBOARD.md) wie Helix statt vim: erst auswählen, dann handeln, Which-Key-Popup, Suche mit Live-Treffern, `Space`-Menü, eine Belegung für Bibliothek, Seite und Text. Implementiert und gebaut, nicht installiert, am iPad ungeprüft.

**Build 65 (`feat/tastatur`, gestapelt auf `feat/textneubau`):** ⌘A über das ganze Textdokument und in jedem Werkzeug, Absatzstile über Seitenwechsel, Zeilenumbruch am Seitenende ohne Überlauf, vim-artiger [Tastaturmodus](docs/KEYBOARD.md). Implementiert, gebaut und installiert (alle 28 Dokumente unverändert), am iPad ungeprüft.

**Nutzungsfeedback Tag 1 (22.10.2026) – auf `main`, implementiert und erfolgreich gebaut, nicht installiert, auf dem iPad ungeprüft:**

- **Lasso-Kontur:** Auswahlen werden wieder wie beim frühen nativen Lasso mit Abstand umrandet (`SelectionContour`); nahe Inhalte verschmelzen, entfernte bleiben Inseln, Griffe und Leiste sitzen am Konturrahmen.
- **Fingertipp bei aktivem Stift:** Mit Stift/Bleistift/Marker/Radierer wählt ein Fingertipp ein Textfeld, Bild oder eine Form, ohne Werkzeugwechsel; ziehen auf der Auswahl verschiebt, Tipp ins Leere, Schreiben oder Werkzeugwechsel hebt auf.
- **Doppeltipp:** Statt PencilKits „Platz einfügen“ nur noch „Textfeld hinzufügen“ an der getippten Stelle.

Kein Formatwechsel, Buildnummer unverändert 61. Nachweise und offene Gerätetests: [TESTING](docs/TESTING.md#nutzungsfeedback-tag-1-22102026). Formen (Polylinien/Vielecke, Ankerpunkte, Notebook-Schema 13) liegen getrennt auf `feat/formen-schema13`, nicht in `main`.

**Branch `feat/image-assets` (21.10.2026, nicht installiert, am iPad ungeprüft):** Bildoriginale liegen als unveränderliche Dateien `Assets/<sha256>` im Heftpaket statt als Base64 in jeder Revision (Notebook-Schema 12). Je Notizbuch bis 500 MB eindeutige Bildoriginale (Mehrfachverwendung zählt einmal), Import höchstens 5 MB je Bild. Alte Hefte werden erst mit der ersten Änderung umgestellt; die exakten Altbytes bleiben unter `Migrations/`. Ein Aufräumen (Asset-GC) beim Öffnen und Schließen entfernt nicht mehr benötigte Originale verzögert, nie während eines Backups. Heft- und Bibliotheksbackup im Format 2 (Datensatzstrom mit SHA-256 je Bild, Heftbackup bis 800 MB), Format 1 bleibt lesbar. Nachweise: [TESTING](docs/TESTING.md#bild-assets-schema-12--nachweise), Plan: [IMAGE-ASSETS](docs/IMAGE-ASSETS.md).

**Achtung:** Builds ≤ 53 sperren Schema-12-Hefte und lehnen Backups im Format 2 ab; ein Rückweg auf Build 53 ist nur mit einer vorher erstellten vollständigen Sicherung möglich.

**Build 49 (20.10.2026)** = Build 48 plus sechs Editor-Korrekturen aus dem Review: Nach einem abgebrochenen Anheben mit Werkzeugwechsel zeigt der Canvas wieder die gespeicherte Tinte, statt Striche beim nächsten Zeichnen zu verlieren. Der Bild-Cache fasst 160 MB/48 Einträge und zeigt bei Fehltreffern die nächstbeste Auflösung statt Grau. Dekodierfehler werden erneut versucht. Gezogene Bilder bleiben in der richtigen Reihenfolge. Werkzeugeinstellungen werden auch beim Wechsel in den Hintergrund fertig geschrieben. Die Strichbreite lernt nur noch von Stift, Bleistift und Marker. Nachweise: [TESTING](docs/TESTING.md#build-49--editor-korrekturen).

**Build 48 (20.10.2026, installiert)** fasst zwei Arbeitsstränge zusammen: die Review-Überarbeitung (intern Build 47, nie separat installiert) und UI-Feinschliff mit „Seite anpassen“ für Papierseiten. Stand und Nachweise der Installation: [TESTING](docs/TESTING.md), [UI](docs/UI-POLISH.md), [Schreibplatz](docs/PAGE-ADJUST.md).

- **UI (Build 48):** aufgeräumtes Optionenmenü, gruppierte Seiten- und Bibliotheksmenüs, ruhiger Statushinweis, neue Werkzeug-Icons und App-Icon nach Nutzerentwurf. Papierseiten lassen sich rechts/unten mit nahtlos weiterlaufenden Linien erweitern, Papier je Seite (Notebook-Schema 11).
- **Daten (Review):** Ein Rückfall auf einen älteren Stand verschiebt neuere Revisionen in eine Quarantäne (höchstens drei Sätze), statt sie zu löschen. Nach einem Rückfall kein automatisches Speichern. Lokale Historie mit Zwischenständen im Abstand von mindestens 10 Minuten (`checkpoints.json`). Das Manifest bleibt im Build-46-Format. Fehlgeschlagenes Speichern wird nach 2/5/15/60 s erneut versucht. PDF-Originale bis 100 MB; Hefte mit Quellen über 20 MB nutzen Schema 10.
- **Backups (Review):** Das Bibliotheksbackup wird gestreamt, statt im Speicher aufgebaut (Format 1 unverändert). Externes Ziel wird vor dem Erstellen geprüft. Backoff bei Fehlern. Der Editor pausiert nur noch für den Commit. `.notybackup`/`.notylibrary` lassen sich aus Dateien direkt öffnen. Hinweis 24 h vor Ablauf des Signierprofils.
- **Editor (Review):** weniger Arbeit im Stiftpfad, beim Ziehen und beim Seitenwechsel. Vorschaubilder und PDF-Helligkeit werden außerhalb des Hauptthreads berechnet. Bilder werden im Hintergrund dekodiert. Bei Speicherwarnungen werden Caches freigegeben. Undo in allen Modi. Tastenkürzel ⌘N/F/S/E/⇧E/↑/↓ und für Auswahlen. Doppeltipp folgt der Pencil-Systemeinstellung. Seitenpapierkorb mit endgültigem Löschen. Bedienhilfen-Bezeichnungen.
- **Suche/Export (Review):** persistenter, abgeleiteter Suchindex in `Library/Caches`, der nur Geändertes neu erkennt. PDF-Export seitenweise mit Fortschritt und Abbrechen.
- **Aufgeräumt (Review):** toter Code entfernt (u. a. `ZoomingWorksheet`), große Editor-Dateien aufgeteilt, Diagnose standardmäßig aus, Python-Prüfer ohne `assert` mit Negativtests (`scripts/check_verifiers.sh`), Build-Protokolle nach `docs/history/`.

**Achtung bei Rückkehr zu einem älteren Build:** Build 46 sperrt Hefte mit PDF-Quellen über 20 MB (Schema 10) und löscht Zwischenstände der Historie. Build 46 und 47 sperren Hefte mit erweitertem Papier-Schreibplatz (Schema 11). Gesperrt heißt: nicht geöffnet und nicht verändert. Vorher vollständig sichern.

Bestätigt bis Build 46 („passt alles“). Verlauf aller früheren Stände: [CHANGELOG](CHANGELOG.md). Offene Punkte: [PLAN](docs/PLAN.md).

## Befehle auf diesem Rechner

```bash
cd /home/la/workspace/noty
. ./scripts/env.sh
swift --version
xtool --version
swift test --package-path Core
bash scripts/check_page_workflow.sh   # Host-Roundtrip inkl. Prüfer-Negativtests
xtool sdk status
# Nach vollständigem Xcode-Download:
xtool sdk install /home/la/Downloads/Xcode_27.1.xip
xtool dev build
```

Apple-Anmeldung übernimmt der Nutzer selbst: `xtool auth` im eigenen Terminal.
Danach iPad anschließen, entsperren und Vertrauen bestätigen:

```bash
xtool devices --no-wait
xtool dev build --sign --ipa
xtool install --usb xtool/Noty.ipa
```

Für Updates den nachgewiesenen IPA-Weg mit derselben Signierungsidentität beibehalten. Basis-Bundle-ID: `de.la.noty.prototype`; tatsächlich installiert: `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`. xtool fügt bei Build-Signierung und erneuter Signierung durch `install` jeweils ein Präfix hinzu. `xtool dev run` würde hier eine andere App-ID erzeugen; daher vorerst den konsistenten IPA-Weg verwenden. App **nicht vorher löschen**. Vor jedem Update vollständige App-Documents sichern und danach zurücklesen und vergleichen ([TESTING](docs/TESTING.md#update-auf-das-ipad)).

Details: [Plan](docs/PLAN.md), [Architektur](docs/ARCHITECTURE.md), [Prüfungen und Gerätetest](docs/TESTING.md), [Speicherformat](docs/STORAGE.md), [Bibliotheksbackup](docs/LIBRARY-BACKUP.md), [Umgebung](docs/ENVIRONMENT.md), [Auftragsumfang](docs/REQUIREMENTS.md), [Verlauf](CHANGELOG.md).
