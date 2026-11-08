# noty Kalender – Produkt- und Entwicklungsplan

Stand: 08.11.2026, Branch `feat/kalender`. Zuletzt veröffentlicht: **noty calendar Build 139** (OTA-Seite: `feat/kalender · b8a2f0a`). Danach Commit `0fb2951` (Review-Befunde, Emil-Feinschliff, Trackpad-Wischen, Aufteilung der Dateien): implementiert und gebaut, nicht veröffentlicht, nicht installiert, am iPad ungeprüft; nur der Server-Teil ist auf dem VPS in Betrieb.

Dieser Plan beschreibt jedes Thema **einmal**: Stand je Funktion, Ziel und Entscheidungen, Funktionsumfang, Regeln, Datenformat und offene Punkte. Was wann gebaut, veröffentlicht, installiert und am iPad geprüft wurde, steht **je Build** mit den wörtlichen Nachweisen in [CALENDAR-LOG](CALENDAR-LOG.md). Eigene Dokumente: Push-Dienst [PUSH](PUSH.md), Schultag-Kachel und Widget [LIVE-ACTIVITY-PLAN](LIVE-ACTIVITY-PLAN.md), nicht beauftragte Ideen [CALENDAR-IDEAS](CALENDAR-IDEAS.md). Der Plan erweitert [SCOPE](SCOPE.md). Die frühere, nach Datum gewachsene Fassung mit allen Umsetzungsabschnitten: `git show 0fb2951:docs/CALENDAR-PLAN.md`.

## Stand je Funktion

Lesart (AGENTS.md): **implementiert** = Code vorhanden; **gebaut** = erster noty-calendar-Build, der die Funktion enthält (spätere Änderungen in Klammern; „nach 139“ = Commit `0fb2951`, gebaut, noch ohne Buildnummer auf der OTA-Seite); **installiert** = „ja (139)“ heißt: im Build 139 enthalten, dessen Installation der Nutzer am 08.11.2026 bestätigt hat – eine eigene Installationsprüfung (Sicherung, Rücklesen per USB) gibt es für noty calendar nicht; **am iPad getestet** = ein Gerätetest mit Ergebnis liegt vor (bisher nur durch den Nutzer); **Nutzerbestätigung** = Aussage des Nutzers, getrennt von eigener Prüfung. Einzelheiten und Quellen: [CALENDAR-LOG](CALENDAR-LOG.md).

| Funktion | implementiert | gebaut (Build) | installiert | am iPad getestet | Nutzerbestätigung |
| --- | --- | --- | --- | --- | --- |
| Ansichten Jahr · Monat · Woche · Tag, Kopf, Kalenderleiste, Suche | ja | 99 (Stufe A; 100, 127 überarbeitet) | ja (139) | ungeprüft | Rückmeldungen zu Build 99 und vor 127 eingearbeitet; Designabnahme offen |
| Navigation ‹ Heute ›, ⌘-Tasten, Blättern | ja | 99 (129 Animation, 134 leeres Raster behoben; Tasten ohne Bewegung nach 139) | ja (139) | nur ‹ › nach dem Fix in 134, durch den Nutzer | Build 134: „jetzt passt es“ |
| Umschalter Hefte · Kalender, ⇧⌘K | ja | 133 (Fixes nach 139) | ja (139) | ungeprüft | – |
| Zoom zwischen Ansichten (Pinch, ⌘+ / ⌘−) | ja | 133 (Fixes nach 139) | ja (139) | ungeprüft | – |
| Trackpad-Wischen | ja | nach 139 | nein | ungeprüft | – |
| Termin per Halten und Ziehen anlegen; Monat senkrecht blättern; Jahr beim Monat des Ankers; Kalenderleisten-Knopf links vom Umschalter | ja | nach 140 (iPad-Build erfolgreich, nicht committet, ohne Buildnummer) | nein | ungeprüft | – |
| Bewegung und Animationen | ja | 129 (Emil-Feinschliff nach 139) | Stand 129 ja (139); Feinschliff nein | ungeprüft | – |
| Terminfenster | ja | 127 (129 wächst aus der Karte, 133 überarbeitet, Zeiten nach 139) | ja (139) | ungeprüft | – (Anlass 133: altes Fenster gefiel nicht) |
| Terminnotizen als noty-Hefte („Kalendernotizen“) | ja | 102 (Entwurf ohne Speicherung seit 99) | ja (139) | ungeprüft | – |
| Eigene Termine, Serien, Ziehen/Dauer, Rückgängig, „Gelöschte Termine“ | ja | 101 (102 Serien/Ziehen, 103 Gelöschte, 104 Korrekturen) | ja (139) | ungeprüft | – |
| Schnell anlegen (⌥⌘N) | ja | 127 | ja (139) | ungeprüft | – |
| WebUntis über Untis-Mobile-Freigabe | ja | 101 (105 Zeiten tolerant, 106 Handeingabe) | ja (139) | teilweise: erster Gerätelauf 04.11. (Anmeldung ja, Stundenplan abgelehnt → 105); danach kein dokumentierter Test | Freigabe am 04.11. vom Nutzer einmalig erprobt (außerhalb der App) |
| Stundenzuordnung („ungeklärt“), Fachfarben | ja | 102 | ja (139) | ungeprüft | – |
| Apple Kalender und Outlook (EventKit, lesen und schreiben) | ja | 127 | ja (139) | ungeprüft | – |
| Ferien und Feiertage (WebUntis, Rückfall NRW) | ja | 101 (127 Rückfall NRW) | ja (139) | ungeprüft | – |
| Hausaufgaben aus WebUntis | ja | 127 (136: Übernahme im Abruf behoben) | ja (139) | ungeprüft | – |
| Erinnerungen (Termin, Unterricht, allgemein) | ja | 103 (136 allgemeine Erinnerung) | ja (139) | ungeprüft | – |
| Benachrichtigungen: Änderungen, Morgen-Überblick, Glocke, Ruhezeiten, Hintergrundabruf | ja | 136 (135 war vergeben; Fixes nach 139) | ja (139) | nur Darstellung der Mitteilungsarten über `demo-push` | alle 9 Beispielmitteilungen angekommen (08.11.) |
| Push-Dienst noty-push (Server) | ja | seit 08.11. in Betrieb; Review-Stand deployt 08.11. 12:49 UTC | VPS: läuft | Test-Push und `demo-push` zugestellt; echte Änderung ungeprüft | Test-Push angekommen |
| Push-Anbindung der App | ja | 137 (Fixes nach 139) | ja (139) | Registrierung aus 137, Test-Push | Test-Push angekommen |
| Live Activity „Schultag“ (lokal) | ja | 138 (139 Nachsignierung, Test-Kachel; Fixes nach 139) | ja (139) | Test-Kachel (139); echter Schultag ungeprüft | 138 installierbar; 139 „das passt“ (Installation und Test-Kachel) |
| Widget „Heute“ | ja | 138 | ja (139) | ungeprüft | – |
| Live Activity per Push (Schritt 2) | nein | – | – | – | – |
| Bibliotheksbackup und Restore mit Kalender | ja | 103 (127 Kalenderformat 4) | ja (139) | ungeprüft (Host-Roundtrip unter Linux bestanden) | – |
| Kalenderpaket (ein Schreiber, Revisionen, Formate 1–4, Migration) | ja | 101 (Format 2: 102, 3: 103, 4: 127) | ja (139) | ungeprüft | – |
| Backend-Synchronisierung (Stufe D) | nein | – | – | – | – |
| Durchgehendes Fachheft aus Stundennotizen | nein (bestätigt für später) | – | – | – | – |

## 1. Ziel und bestätigte Entscheidungen

Ein nativer Kalender für den Schulalltag, mit der vertrauten Bedienlogik von Apple Kalender und Outlook und der Gestaltung von noty. Schule und Mitschriften haben Vorrang, private Termine sind ebenfalls möglich. Kalenderbeschriftungen und Termine verwenden normale Schrift und Tastatureingabe. Das Kalenderraster selbst ist keine Handschriftfläche; zu einem angeklickten Termin erscheint jedoch eine eigene, direkt beschreibbare Notizseite.

**Bestätigt im Entscheidungsinterview vom 03.11.2026:**

- WebUntis mit Stundennotizen zuerst; eigene lokale Termine ebenfalls bereits in der ersten nutzbaren Version.
- WebUntis soll Unterricht, Fächer, Räume, Lehrkräfte, Vertretungen, Ausfälle und verfügbare Prüfungen liefern. Unterrichtszeiten werden aus WebUntis übernommen; eigene Ergänzungen bleiben Notizen oder separate Termine, keine persönlichen Überschreibungen des Stundenplans.
- Woche als Startansicht, außerdem Monat, Tag und Jahr. Standardwoche Montag bis Freitag, Umschaltung auf sieben Tage; Auswahl merken.
- Beim Öffnen eines Termins sofort eine leere Notizfläche anbieten. Erst die erste tatsächliche Eingabe legt eine gespeicherte Notiz an. Handschrift und Text direkt bearbeiten; bei Bedarf im normalen Editor vergrößern.
- Mit einer festen Seite beginnen, weitere Seiten bei Bedarf ergänzen. Bei schmalem Fenster/Hochformat große Notizansicht über dem Kalender mit klarer Rückkehr.
- Sobald Inhalt vorhanden ist, am Termin einen sichtbaren Notizhinweis zeigen, unabhängig von Handschrift oder Text. Notizen zusätzlich in der normalen Bibliothek im Ordner „Kalendernotizen“, nach Fach und Datum benannt.
- Verschobene Stunden behalten ihre Notizen; ausgefallene Stunden bleiben mit Kennzeichnung und vorhandenen Notizen erreichbar.
- Eigene Termine anlegen, bearbeiten und löschen; tägliche, wöchentliche und monatliche Wiederholungen mit einzelnen Ausnahmen. Bei Änderung/Löschung zwischen einzelnem Termin und gesamter Serie wählen.
- Eigene Termine zusätzlich zum Formular durch längeres Drücken und Ziehen verschieben; Ziehen am unteren Rand ändert die Dauer.
- Automatische, je Fach einheitliche und anpassbare Farben; eigene Termine zunächst mit separater Farbe.
- Erinnerungen optional pro Termin und standardmäßig ausgeschaltet. Zusätzlich allgemeine Unterrichtseinstellung, beispielsweise zehn Minuten vorher.
- Jahresansicht mit zwölf Monaten, markierten Termintagen und Ferien; Antippen öffnet den Tag.
- Später Apple Kalender und Outlook: Termine anzeigen, anlegen, bearbeiten und löschen, Änderungen im jeweiligen Kalender übernehmen und dieselben lokalen Terminnotizen anbieten. Reine Leseanbindung genügt nicht dem bestätigten Zielumfang.
- Später Backend-Synchronisierung eigener Termine einschließlich Notizen, Verknüpfungen und Einstellungen zwischen den eigenen Geräten. Offlinebetrieb bleibt vollständig nutzbar; eine separate Sicherung bleibt erforderlich.
- Ebenfalls später: einzelne Stundennotizen zu einem durchgehenden Fachheft öffnen können. Eine dauerhafte Fachheftzuordnung gehört nicht zur ersten Version.

**Beispiel:** „Rechnungswesen · 08:00–09:30“ antippen → Notizseite im Terminfenster → mit Pencil oder Tastatur schreiben → am Termin erscheint der Notizhinweis. Weitere Seiten hinzufügen oder die Notiz vergrößern; anschließend zum ursprünglichen Termin zurückkehren.

Der Nutzer hat diesen Umfang am 03.11.2026 mit „ja so will ich das aber nur festhalten nicht bauen“ bestätigt, einschließlich der Reihenfolge WebUntis mit Stundennotizen und eigenen Terminen → Apple/Outlook → spätere Backend-Synchronisierung. Offlinebetrieb, Datenerhalt und getrennte Bereiche bleiben verbindlich.

**Spätere Entscheidungen und Aufträge des Nutzers:**

- 03.11.2026: Auftrag **Stufe A** (Design mit fiktiven Daten). Eigene Test-App „noty calendar“ (`de.la.noty.calendar`, eigene Daten, nur von `feat/kalender`).
- 04.11.2026: **WebUntis-Quelle** ist der inoffizielle Zugang über die Untis-Mobile-Freigabe, kein Backend ([§7](#webuntis-entscheidung-04112026)); Lehrkräfte liefert die Schule für Schüler nicht. Aufträge **B1, B2, B3**, jeweils nur als „noty calendar“.
- 06.11.2026: **Outlook/Microsoft 365 über die Systemkonten des iPads** (EventKit), keine Graph-API (Stufe C). Ferien-Rückfall für **NRW**. UI-Überarbeitung nach Rückmeldung („Statusmeldungen wegen WebUntis-Freigabe stören … Merker-Bereich als größeres schwebendes Fenster“).
- 07.11.2026: Animationen „vernünftig einpflegen“.
- 08.11.2026: Umschalter Hefte/Kalender mit ausgeblendeter Bibliotheksleiste; neues Terminfenster („Das Pop-up für die Notizen gefällt mir noch nicht so“); Zoom zwischen den Ansichten; **Benachrichtigungen** mit festgelegtem Umfang ([§2](#benachrichtigungen-08112026)); **Push bei geschlossener App** als bewusste Ausnahme von „kein Backend“ ([PUSH](PUSH.md)); **Live Activity „Schultag“ und Widget „Heute“** mit eigenen Entscheidungen ([LIVE-ACTIVITY-PLAN](LIVE-ACTIVITY-PLAN.md#entscheidungen-des-nutzers-08112026)), Bauauftrag für die Schritte 0, 1 und 3.

Weiterhin **nicht beauftragt**: Stufe D (Synchronisierung), durchgehendes Fachheft, Live Activity per Push (Schritt 2), die Ideen in [CALENDAR-IDEAS](CALENDAR-IDEAS.md). Freigabeweg: Arbeit auf `feat/kalender`, Test in noty calendar; nach `dev`/`main` erst mit ausdrücklicher Freigabe.

## 2. Funktionsumfang

Beschrieben ist der aktuelle Stand des Codes (Commit `0fb2951`). Was davon in welchem Build steckt, zeigt die Tabelle oben.

### Gestaltungsgrundsätze

- Native Systemschrift, deutsche Beschriftungen, 24-Stunden-Zeit, Montag als Wochenbeginn, ISO-Kalenderwochen; Dynamic Type und VoiceOver. Kalenderlogik über `Calendar`-Operationen, nie feste 24 h.
- Ruhige App-Oberfläche in noty-Materialien, kein weißes Papierblatt. Systemblau für Auswahl und Aktionen, „heute“ rot wie in Apple Kalender. Fachfarben dienen der Zuordnung; Status nie allein über Farbe (Symbol und Text). Nichts wird still abgeschnitten („+ n weitere“, Listen).
- Trefferflächen mindestens 44 pt (kleine Knöpfe über `NotyHitShape` in `NotyHitArea.swift`, auch die Segmente des Umschalters); bewusste Ausnahme: Tage im Mini-Monat 36 pt hoch (über Jahr/Monat ebenfalls erreichbar). Finger, Pencil, Hardwaretastatur und Trackpad (Hover, Tooltips) bedienbar.
- Im Kalenderraster keine Stiftpalette, Lineatur, Lasso- oder Zeichenmodi; in der Notiz des Terminfensters gelten die normalen Editorwerkzeuge.

### Umschalter Bibliothek/Kalender (08.11.2026)

- Der Kalender ist eine Seite **neben** der Bibliothek (`LibraryView.showsCalendar`), kein Ort in ihr. Umschalter „Hefte | Kalender“ links in der Kopfzeile, auf beiden Seiten dasselbe Element (`leadingToolbar`), im schmalen Fenster nur Symbole; VoiceOver und Voller Tastaturzugriff sehen eine Segmentauswahl. Dazu ⇧⌘K (Menü „Darstellung“, nur ohne geöffnetes Heft) und „Kalender zeigen“/„Hefte zeigen“ in der Befehlspalette. Der Seitenleisteneintrag „Kalender“ bleibt als zweiter Weg. Zurück zu „Hefte“ zeigt den vorher offenen Ordner.
- **Knopf der Kalenderleiste links vom Umschalter** (Nutzerwunsch 08.11.2026, Screenshot: vorher stand er rechts daneben, weil die Kalenderansicht ihn in ihrer eigenen Werkzeugleiste hinter die Elemente der Bibliothek setzte). Jetzt ein eigenes `ToolbarItem` in `LibraryView.leadingToolbar` vor dem Umschalter, nur im Kalender und nur, wenn die Leiste Platz hat (`CalendarModel.sidebarFits`, ab 864 pt Kalenderbreite: Querformat ja, Hochformat des 11-Zoll-iPads und schmale Split-View-Fenster nein – wie bisher). Zustand im Modell (`sidebarWanted`, derselbe Schlüssel `noty.calendar.sidebar`); Knopf gleitet mit `NotyMotion.panel`, ⌃⌘S ohne Bewegung; gesperrt bei offenem Terminfenster. Beim Wechsel Hefte → Kalender rückt der Umschalter dadurch um die Knopfbreite nach rechts (ungeprüft, ob das stört).
- Im Kalender ist die Bibliotheksleiste ausgeblendet (`columnVisibility = .detailOnly`), ohne Systemknopf; beim Zurückkehren gilt die vorherige Sichtbarkeit (ohne Zwang auf „alle Spalten“). Wird die Leiste hereingewischt, führen „Alle Unterlagen“, „Zuletzt verwendet“ und Ordner zurück zu den Heften; ein Heft öffnet sich über dem Kalender und kehrt beim Schließen dorthin zurück. Ansicht, Datum und Auswahl bleiben erhalten (das `CalendarModel` gehört dem Bereich).
- Übergang per Tipp: 0,3 s, 12 pt Versatz mit Überblenden; per Taste ohne Bewegung; „Bewegung reduzieren“: nur Überblenden.
- **Schutz:** Umschalter und ⇧⌘K ruhen bei offenem Terminfenster, Terminformular, vergrößerter Notiz, Seriennachfrage und offenen Kalender-Blättern oder -Popovern (`presentingOverlays`); Kalendertasten wirken nicht hinter Blättern der Bibliothek. Tastaturmodus: Elementbefehle (`hjkl`, öffnen, umbenennen …) wirken im Kalender auf keine unsichtbaren Hefte. Im Kalender wird ⌘N zu „Neuer Termin …“.

### Ansichten und Kopf (UI-Überarbeitung 06.11.2026)

- **Kopf:** Zeitraum groß links („November 2026“), darunter in der Woche „KW 45 · 2.–6. November 2026“, im Tag „Heute, Freitag · KW 45“; rechts Segmente „Tag · Woche · Monat · Jahr“ (unter 660 pt ein Menü) und ‹ Heute › als Kapsel. Werkzeugleiste: Kalenderleiste (links vom Umschalter, siehe oben), Sync-Symbol (nur mit WebUntis, Systemkalendern, Speichersperre oder gekürzter Serie), Glocke, „…“, „+“. „…“ und „+“ sind bei offenem Terminfenster gesperrt.
- **Menü „…“:** Wochentage (Montag–Freitag/ganze Woche, je Bereich gemerkt), „Termine suchen …“, „Fachfarben …“, „Benachrichtigungen …“, „Gelöschte Termine (n) …“; Abschnitt „Kalender“ zum Ein-/Ausblenden der Quellen (schreibgeschützte benannt); Abschnitt „WebUntis (inoffiziell)“ mit „Aktualisieren“ und „WebUntis verbinden …“ bzw. „WebUntis-Verbindung …“; „Beispieldaten anzeigen“.
- **Status ohne Statuszeile:** WebUntis-Stand, „teilweise geladen“, Fehler, „Zugang neu verbinden“, Systemkalender-Stand, Ferienquelle und gekürzte Serien stehen im Popover des Sync-Symbols („Jetzt aktualisieren“, „Neu einlesen“, „Verbindung …“, „iPad-Einstellungen“). Das Symbol dreht sich beim Aktualisieren (bei „Bewegung reduzieren“ statisch) und trägt einen orangen Punkt bei Speichersperre, fehlgeschlagener Aktualisierung, fehlendem Zugang oder Zugriffsproblem der Systemkalender. Sichtbar bleiben schlanke Banner (Speichersperre, Speicherfehler mit „Erneut speichern“, wiederhergestellter älterer Stand) und kurze Hinweise als Toast; Banner und Toasts liegen über dem offenen Terminfenster, der einmalige Erlaubnis-Hinweis für Mitteilungen erscheint dagegen nicht, solange es offen ist. Laden, das länger als 300 ms dauert, zeigt einen Spinner mit Text. „Zeitraum noch nicht geladen“ steht als Karte mit „Laden“ im Raster, nie „keine Termine“.
- **Woche/Tag:** Tagesköpfe mit Wochentag über großem Datum (Antippen öffnet den Tag), heute im roten Kreis; Wochenende und Ferien leicht abgesetzt (Ferien zusätzlich in der Ganztagszeile und im VoiceOver-Label). Ganztagszeile mit Bahnen – bei Bedarf und immer, solange man anlegen kann (Fläche für ganztägige Termine per Halten und Ziehen). 24-Stunden-Raster, beim Öffnen zur aktuellen Stunde gescrollt (sonst 07:00). Zeitlinie schwach über die Woche, kräftig in der heutigen Spalte. Überschneidungen nebeneinander. Karten mit 3-pt-Farbstreifen und Tönung: Titel, Zeit, je nach Höhe Raum (Tag: mit Lehrkraft) und Status als Badge; Ausfall mit orangem Symbol, durchgestrichen und abgeblendet; Notizsymbol bei Inhalt; Buchsymbol, wenn offene Hausaufgaben fällig sind. Zu schmale Spalten scrollen waagerecht, die Ansicht wechselt nie von selbst.
- **Monat:** sieben Spalten mit leiser KW; höchstens drei Zeilen je Tag einschließlich „+ n weitere“ (Kapsel, öffnet die vollständige Tagesliste mit „Tag öffnen“); unter 76 pt Spaltenbreite Farbpunkte (höchstens acht) plus „+ n“, Ausfall als Ring und „davon n Ausfall“. Datum antippen öffnet den Tag. Monate untereinander, senkrecht seitenweise geblättert (siehe „Monat senkrecht blättern“); große Schrift: Zeilen behalten ihre Mindesthöhe, die Monate scrollen frei.
- **Jahr:** zwölf Monate mit 44-pt-Tagen, Punkt für Termintage, Ferienband mit Legende; Tag antippen öffnet den Tag, Monatsname den Monat. Steht beim Öffnen auf dem Monat des Ankers (siehe „Jahr öffnet beim aktuellen Monat“).
- **Kalenderleiste links** (ab 864 pt Kalenderbreite, ⌃⌘S, gemerkt): Mini-Monat (eigenes Blättern, Termintage, Ferienband, Tippen zeigt den Tag), „Als Nächstes“ (laufender Termin mit Fortschritt und Restzeit, Ausfälle sichtbar, „Heute: 4 Stunden · 1 Ausfall“), Hausaufgaben (bis zu fünf offene), Kalender mit Farbe (Systemkalender je Konto) zum Ein-/Ausblenden. Außerhalb des berechneten Zeitraums behauptet sie keine Leere.
- **Suche** („Termine suchen …“) und Blätter für Fachfarben, gelöschte Termine und Benachrichtigungen sind eigene Blätter der Kalenderansicht; währenddessen ruhen die Kalendertasten.
- **Beispieldaten** (`CalendarSampleData`, frei erfunden, für die Designabnahme): nur über den Schalter „Beispieldaten anzeigen“ (Standard aus), dann ausschließlich erfundene Einträge mit Marke neben dem Titel, „+“ gesperrt, nichts gespeichert, nie mit echten Einträgen gemischt.

### Navigation

- ‹ Heute › und die Segmente blättern bzw. wechseln die Ansicht; „Heute“ lässt die heutige Markierung einmal pulsieren (Woche, Monat, Jahr, Mini-Monat).
- **Tastatur** (alle ohne Bewegung, nur solange kein Terminfenster, Formular, Blatt, Heft, keine Befehlspalette und Tastenübersicht darüber liegt): ⌘← / ⌘→ zurück/vor, ⌘T Heute (ohne Puls), ⌘1–⌘4 Tag/Woche/Monat/Jahr, ⌘+ (auch ⌘=) / ⌘− eine Ansicht feiner/gröber, ⌘N neuer Termin (Formular), ⌥⌘N Schnell anlegen, ⌃⌘S Kalenderleiste, ⇧⌘K Hefte/Kalender, Esc schließt Terminfenster bzw. Großansicht. Übersicht und Konflikte: [KEYBOARD](KEYBOARD.md#kalender).
- **Monat blättern:** seit 08.11.2026 senkrecht seitenweise (Finger, Trackpad, Mausrad); das frühere waagerechte Fingerwischen im Monat ist entfallen (VoiceOver-Aktionen „Nächster/Vorheriger Monat“ bleiben). In Woche/Tag bewusst kein Fingerwisch (konkurriert mit senkrechtem und waagerechtem Scrollen und dem Ziehen von Terminen).

#### Trackpad-Wischen (08.11.2026)

Zwei Finger waagerecht auf dem Trackpad blättern in Tag, Woche, Monat und Jahr wie ‹ ›: natürliche Richtung (Finger nach links = nächster Zeitraum), Schwelle 96 pt, eine Periode je Geste, darunter Gummiband und Zurückfedern. Umgesetzt mit einem `UIPanGestureRecognizer` ohne Berührungen (`allowedTouchTypes = []`, nur kontinuierliches Scrollen) am Hosting-View (`CalendarTrackpadSwipe`): Finger, Pencil, Mausrad, das lange Drücken auf Karten und zum Anlegen und der Pinch erreichen ihn nicht; senkrechtes Scrollen im Stundenraster bleibt. Aus bei offenem Terminfenster oder anderem darüberliegendem Inhalt und während des Blätterns.

#### Zoom zwischen Ansichten (08.11.2026)

Anlass, Nutzer: „Man soll zoomen können, zwischen Jahren, Monaten und so weiter in der Auswahlansicht.“

- **Geste:** Zwei Finger auseinander = feinere Ansicht (Jahr → Monat → Woche → Tag), zusammen = gröbere. Ziel ist der Zeitraum unter den Fingern: Monatskachel im Jahr, Wochenzeile im Monat, Tagesspalte in der Woche; zwischen zwei Kacheln die nächstliegende. Anker: bleibt, wenn er im gewählten Zeitraum liegt, sonst heute, wenn heute darin liegt, sonst der erste Tag (Woche → Tag: genau der Tag). Herauszoomen behält den Anker; der Zeitraum, aus dem man kam, leuchtet in der gröberen Ansicht einmal kurz blau auf (nur Deckkraft).
- **Rückmeldung:** Während der Geste skaliert die Ansicht weich um den Fingerpunkt (logarithmisch, höchstens ±10 %; am Ende der Stufen nur ein Drittel davon). Ab Faktor 1,2 bzw. 1/1,2 ist die Stufe „scharf“: ein blauer Umriss zeigt, dass Loslassen wechselt (das iPad hat keine Haptik, die das spürbar machte); darunter federt die Ansicht mit der Fingergeschwindigkeit zurück. Ab 1,6 bzw. 1/1,6 wechselt sie noch während der Geste. Höchstens ein Schritt je Geste.
- **Übergang:** Hineinzoomen wächst die neue Ansicht aus der Mitte des geöffneten Zeitraums (Start 40 %, ohne bekannten Rahmen vom Fingerpunkt 80 %), Herauszoomen setzt sie sich vom Fingerpunkt aus zurück (125 %); Scrollposition und Raster ohne `id`-Neuaufbau. „Bewegung reduzieren“: keine Skalierung, nur der Umriss und Überblenden.
- **Tastatur:** ⌘+ / ⌘= und ⌘− mit Anker wie oben (ohne Fingerpunkt: Zeitraum des Ankers); ohne nächste Stufe ist das Kürzel nicht belegt. ⌘+/⌘− von Editor und Gesetzesleser wirken nur dort.
- **Gestenentscheidung Woche/Tag:** Pinch wechselt auch dort die Ansicht; die Stundenhöhe wird **nicht** per Pinch gezoomt. `MagnifyGesture` (iPadOS 17) liefert keine Fingerrichtung; eine Unterscheidung senkrecht/waagerecht bräuchte einen UIKit-Pinch mit Berührungspunkten (`UIGestureRecognizerRepresentable` erst ab iPadOS 18; ein UIKit-Erkenner im Gesetzesfenster blieb unter iPadOS 27 wirkungslos) oder `SpatialEventGesture` (ab 18) – beides ungeprüft und mit Risiko für Scrollen und Termin-Ziehen; zudem müsste das 24-Stunden-Raster je Gestenschritt neu layouten. Stundenhöhe-Zoom bleibt Vorschlag (§9).
- **Konflikte:** `simultaneousGesture` am Inhalt; Scrollen, Antippen und das lange Drücken zum Ziehen bleiben. Ein Pinch verschiebt keine Termine; ein Tippen oder Wisch, der Teil eines Pinchs war (bis 0,45 s danach), öffnet bzw. blättert in keiner Ansicht. Aus bei offenem Terminfenster, vergrößerter Notiz oder Formular. Live-Skalierung in eigenem Objekt (`CalendarPinchState`), damit nur die Hülle neu zeichnet.
- **Code:** Logik in `Core/Sources/NotebookCore/CalendarZoom.swift` (`CalendarMode.finer/coarser`, `CalendarZoom`, `CalendarPinch`), Tests `CalendarZoomTests`; UI in `Sources/Noty/CalendarZoomGesture.swift`, Anbindung in `CalendarView`.

#### Termin per Halten und Ziehen anlegen (08.11.2026)

Anlass, Nutzer: „Mit langem Halten und Ziehen über Tage/Woche einen neuen Termin erstellen.“ Plan (vor der Umsetzung festgehalten):

- **Format:** keine Änderung. `CalendarEventTiming.timed` speichert Beginn und Ende als Zeitpunkte (bis fünf Jahre) und kann damit auch **mehrtägige Termine mit Uhrzeit**; ganztägig bleibt `allDay` mit zivilen Daten und exklusivem Ende. Das Raster zeichnet mehrtägige Uhrzeittermine bereits je Tag als Abschnitt (`minutesIntoDay`). Gespeichert wird wie bisher erst im Formular.
- **Woche/Tag (Stundenraster):** lange drücken (0,35 s wie beim Verschieben) auf eine **freie** Stelle → Platzhalter im 15-Minuten-Raster an der Stelle des Drucks („09:15–09:30“). Ziehen legt das andere Ende fest: die Spanne reicht vom gedrückten bis zum Viertelstundenfeld unter dem Finger, beide eingeschlossen, in beiden Richtungen (nach oben = früherer Beginn), mindestens 15 Minuten. Waagerecht über andere Tagesspalten → **ein** mehrtägiger Termin mit Uhrzeit von Tag/Zeit des Drucks bis Tag/Zeit unter dem Finger (in der Woche; Tagesspalte wechselt erst 16 pt hinter der Spaltengrenze). Nahe am oberen/unteren Rand des Rasters scrollt es von selbst. Anzeige im Platzhalter „09:15–10:30“ bzw. „Mo 09:00 – Mi 11:00“ (`monospacedDigit`).
- **Ganztagszeile der Woche/des Tags:** halten und waagerecht ziehen → ganztägiger Termin über die überstrichenen Tage. Damit sie erreichbar ist, steht die Ganztagszeile in Woche und Tag immer da, solange man anlegen kann (sonst wie bisher nur bei Bedarf).
- **Monat:** auf einer Tageszelle halten und über Tage/Wochen ziehen → ganztägiger (mehrtägiger) Termin, überstrichene Tage hervorgehoben (zusammenhängend wie eine Textauswahl).
- **Loslassen** öffnet das bestehende Terminformular über `model.requestNewEvent(start:end:allDay:)`, vorbelegt mit Beginn, Ende, ganztägig; Fokus im Titel (bei jedem neuen, leeren Formular). Der Platzhalter bleibt hinter dem Formular stehen, bis es schließt (ruhiger als Verschwinden und Wiederauftauchen als Karte); „Abbrechen“ verwirft ihn spurlos, „Hinzufügen“ ersetzt ihn durch die echte Karte.
- **Nur** bei `canWrite && !showsSamples`, ohne offenes Terminfenster oder Formular; sonst bleibt langes Drücken wirkungslos.
- **Konflikte:** lange drücken auf eine eigene Karte verschiebt sie wie bisher; auf fremden/schreibgeschützten Karten und Ganztags-Chips beginnt nichts. Scrollen (senkrecht, waagerecht in schmaler Woche, Monat) bleibt: Anlegen braucht Stillhalten, eine Bewegung über 10 pt vorher ist Scrollen. Zwei Finger (Pinch) verhindern bzw. brechen das Anlegen ab. Trackpad-Wischen (Scroll-Ereignisse) ist unberührt.
- **Technik:** ein `UILongPressGestureRecognizer` (0,35 s, 10 pt) am Hosting-View wie das Trackpad-Wischen (`CalendarHoldDrag`), begrenzt auf die Rasterfläche und freie Stellen (Kartenrechtecke aus derselben Layoutrechnung). Er liefert die Fingerposition schon beim Auslösen und bleibt beim automatischen Scrollen richtig (`location(in:)` rechnet den Versatz ein). Finger, Pencil und Zeiger (Klicken und halten, dann ziehen; `UIApplicationSupportsIndirectInputEvents`) lösen ihn aus. Direktes Klick-Ziehen ohne Halten nicht (konkurriert mit dem Scrollen per Klick-Ziehen).
- **Bewegung:** Platzhalter erscheint mit Deckkraft und Skalierung 0,95 → 1 in 0,18 s ease-out („Bewegung reduzieren“: nur Deckkraft), Rasterschritte sofort ohne Feder, Austritt `NotyMotion.exit`. Keine Haptik als Rückmeldung (iPad).
- **Barrierefreiheit:** „+“ bleibt der VoiceOver-Weg; der Platzhalter ist für VoiceOver ausgeblendet.
- **Core:** Rasterung und Normalisierung rein in `CalendarCreation.swift` (Viertelstundenfeld, Reihenfolge tauschen, Mindestdauer, Tagesgrenzen 0:00/24:00, Spaltenwechsel mit Hysterese, Wanduhr ↔ Zeitpunkt über Sommerzeit: Zeit in der Lücke → erster Moment danach, doppelte Stunde → erste) mit `CalendarCreationTests`.


**Umsetzung (08.11.2026, nach Build 140, nicht committet):** implementiert, Core-Tests grün (1507, davon 10 neu in `CalendarCreationTests`; 3 übersprungen), iPad-Build erfolgreich; **nicht installiert, am iPad ungeprüft**. Code: `Core/Sources/NotebookCore/CalendarCreation.swift`, `Sources/Noty/CalendarCreateGesture.swift` (`CalendarHoldDrag`, `CalendarCreateState`, Platzhalter), Anbindung in `CalendarTimeGrid` (Stundenraster, Ganztagszeile) und `CalendarMonthView`, `CalendarModel.requestNewEvent(start:end:allDay:)`, Titelfokus in `CalendarEventForm`. Entscheidungen bei der Umsetzung:

- **Halten ohne Ziehen = 15 Minuten.** Was der Platzhalter zeigt, steht im Formular (keine stille Stunde wie bei „+“); längere Termine durch Ziehen oder im Formular.
- **Raster 15 Minuten** auch in der Tagesansicht (das Verschieben dort bleibt bei 5 Minuten).
- Der Platzhalter bleibt hinter dem Formular stehen und verschwindet beim Schließen (`NotyMotion.exit`); nach „Hinzufügen“ erscheint an seiner Stelle die Karte.
- **Zeiger:** Klicken, 0,35 s halten, ziehen (derselbe Erkenner, `allowedTouchTypes` mit `.indirectPointer`). Ob iPadOS den Klick-und-halten-Druck so liefert, ist am Gerät zu prüfen; direktes Klick-Ziehen ohne Halten ist bewusst nicht eingebaut (Konkurrenz zum Scrollen per Klick-Ziehen).
- Zwei Finger (auch eine zweite Berührung irgendwo im Kalender) brechen ein laufendes Anlegen ab; ein Pinch kurz davor verhindert es.

**Gerätetest (gebündelt, ungeprüft):** (1) Woche quer: auf freie Stelle 0,4 s halten → Block „09:15–09:30“; nach unten ziehen → Ende wächst im Viertelstundenraster, nach oben über den Druckpunkt → Beginn wandert; loslassen → Formular mit diesen Zeiten, Tastatur im Titel; „Abbrechen“ → nichts gespeichert, Block weg; „Hinzufügen“ → Karte an derselben Stelle. (2) Waagerecht über zwei Tage → Block je Tag, Text „Mo 09:00 – Mi 11:00“, Formular mit beiden Daten. (3) Finger am unteren/oberen Rasterrand ruhen lassen → Raster scrollt, Block folgt. (4) Ganztagszeile (auch in einer Woche ohne Ganztagstermine sichtbar) halten und waagerecht ziehen → Formular „ganztägig“ mit erstem/letztem Tag. (5) Monat: Tag halten, über zwei Wochen ziehen → Tage zeilenweise markiert, Formular ganztägig; das Antippen des Datums nach dem Loslassen öffnet nicht den Tag. (6) Schnell senkrecht scrollen und in schmaler Woche waagerecht scrollen → nichts wird angelegt. (7) Langes Drücken auf eigene Karte verschiebt sie wie bisher; auf Unterricht/Systemtermin/Ganztags-Chip passiert nichts. (8) Pinch auf freier Fläche → Ansichtswechsel, kein Block. (9) Pencil: halten und ziehen legt an. (10) Trackpad: klicken, halten, ziehen; Zwei-Finger-Wischen blättert weiter. (11) Bewegung reduzieren: Block blendet nur ein. (12) Beispieldaten oder Speichersperre: langes Drücken ohne Wirkung, keine leere Ganztagszeile. (13) Sommerzeit-Sonntag (z. B. 28.03.2027) 02:00–03:00 ziehen → Formular zeigt eine gültige Spanne ab 03:00.

#### Monat senkrecht blättern (08.11.2026)

Anlass, Nutzer: „Mach bitte, dass man hoch und runter scrollt bei Monat.“ Plan:

- Senkrechte Seiten je Monat (`ScrollView` mit `LazyVStack` über ±60 Monate um den Anker, Seitenhöhe = sichtbare Höhe, `PagingScrollTargetBehavior`); gerendert werden nur sichtbare Monate. Scrollposition ↔ `model.anchor`: die Seite in der Mitte bestimmt Titel, Anker (Tag im Monat bleibt wie bei ‹ ›) und Zoom-Ziele; ‹ ›, Tasten, „Heute“ und Trackpad-Wischen springen zur Seite (Taste ohne Bewegung, Tipp mit der Blätterbewegung, im Monat senkrecht).
- Passt ein Monat mit sechs Wochen nicht auf die Höhe (große Schrift, kleines Fenster), wird nicht geblättert, sondern frei gescrollt (Monate untereinander mit kleinem Monatstitel); Scrollen innerhalb eines Monats geht damit immer.
- Das waagerechte Fingerwischen im Monat entfällt (doppelt zum senkrechten Blättern und kollidiert mit dem waagerechten Ziehen beim Anlegen); VoiceOver-Aktionen „Nächster/Vorheriger Monat“ und Trackpad-Wischen bleiben.


**Umsetzung (08.11.2026, nach Build 140, nicht committet):** implementiert und gebaut, am iPad ungeprüft (`CalendarMonthView`: `LazyVStack` + `CalendarMonthPaging` + `scrollPosition(id:anchor: .center)`; ab iPadOS 18 `defaultScrollAnchor(.center, for: .initialOffset)` gegen ein erstes Bild an falscher Stelle und `onScrollPhaseChange`: der Anker folgt erst, wenn das Scrollen ruht – ein angezogener und zurückgefederter Monat lässt den Titel nicht flackern). Die Blätterbewegung von ‹ › gleitet im Monat senkrecht (16 pt), passend zur Scrollrichtung. Zoom-Ziele (Wochenzeilen) und Anlegen gelten nur auf der gezeigten Seite, weil eine Woche auf zwei Seiten stehen kann. **Gerätetest (ungeprüft):** (1) Finger, Trackpad (zwei Finger senkrecht) und Mausrad blättern genau einen Monat, Titel folgt nach dem Einrasten. (2) ‹ ›, ⌘←/⌘→, „Heute“, Mini-Monat, Trackpad waagerecht → richtige Seite ohne Scroll-Animation. (3) Große Schrift/kleines Fenster: Monate scrollen frei mit Monatstitel. (4) Drehen während eines Monats → derselbe Monat bleibt. (5) Pinch auf eine Wochenzeile → diese Woche; aus der Woche herauszoomen → Monat mit aufleuchtender Zeile. (6) „+ n weitere“, Heute-Puls, Datum antippen. (7) Weit (Jahre) scrollen → kein Sprung beim Nachladen.

#### Jahr öffnet beim aktuellen Monat (08.11.2026)

Anlass, Nutzer: „dass Jahr auf das aktuelle Jahr so ist und nicht ganz oben“. Plan: Die Jahresansicht steht beim Öffnen, beim Zoomen aus einem Monat, bei ‹ › und „Heute“ ohne sichtbares Springen so, dass die Zeile mit dem Monat des Ankers in der Mitte steht – im laufenden Jahr ohne Navigation ist das der aktuelle Monat, nach dem Herauszoomen der Monat, aus dem man kam (er leuchtet dort auf). Senkrechtes Weiterscrollen ins nächste/vorige Jahr bleibt aus (Risiko für Zoom-Ziele und Anker; ‹ › und Trackpad-Wischen genügen).

**Umsetzung (08.11.2026, nach Build 140, nicht committet):** implementiert und gebaut, am iPad ungeprüft. Die Monatskacheln sind Scroll-Ziele (Zeilen aus `HStack`s statt `LazyVGrid`), `scrollPosition(id:anchor: .center)` beginnt beim Monat des Ankers; beim Erscheinen, bei Ankerwechsel, geänderter Spaltenzahl und beim Antippen von „Heute“ wird ohne Bewegung dorthin gescrollt. **Gerätetest (ungeprüft):** Jahr per ⌘4, Segment und Herauszoomen aus Juni öffnen → Juni bzw. der aktuelle Monat mittig, kein sichtbares Springen von Januar; ‹ › ins Vorjahr → derselbe Monat; Hoch-/Querformat.

#### Kalenderleisten-Knopf und Benennung (08.11.2026)

Umgesetzt und gebaut, am iPad ungeprüft: Knopf der Kalenderleiste links vom Umschalter (siehe „Umschalter Bibliothek/Kalender“); die Oberfläche sagt nicht mehr „inoffiziell“ (siehe WebUntis). **Gerätetest:** Querformat Kalender → Knopf links von „Hefte | Kalender“, Leiste gleitet; ⌃⌘S ohne Bewegung; Hochformat → kein Knopf; Terminfenster offen → Knopf gesperrt; zurück zu Hefte → Knopf weg.

### Bewegung und Animationen (07.11.2026, Feinschliff 08.11.2026)

Anlass, Nutzer: Animationen „vernünftig einpflegen“ (07.11.2026). Vorbilder: Apple Kalender (Zoom zwischen Ansichten, Termin wächst aus der Karte), Fantastical/Notion Calendar (ruhiges Gleiten), Things 3/Structured (Abhaken mit kurzem Moment). Seit dem Emil-Feinschliff gelten die allgemeinen Regeln aus [DESIGN](DESIGN.md#bewegung-regeln-nach-häufigkeit--07112026); `CalendarMotion` nutzt die Tokens von `NotyMotion`.

- **Grundregel:** Nur vom Nutzer ausgelöstes Chrome bewegt sich; Speichern, Notiz, Tinte und Abrufe bekommen keine eigene Animation. Tastatur sofort, Taps kurz und ohne Überschwingen, Austritte schneller als Eintritte, Feder mit Überschwingen nur nach einer Geste mit Geschwindigkeitsübergabe (Kopf-Zug, Pinch, Ablegen). Keine dauernden Animationen im Raster, kein Konfetti, keine Parallaxe.
- **Blättern** (‹ ›, Heute, Umschalter): der neue Zeitraum gleitet 16 pt aus der Pfeilrichtung bzw. setzt sich aus leichter Skalierung, kritisch gedämpft in 0,24 s ohne Überschwingen, Deckkraft von 0,6 in 0,15 s. Ein Wechsel innerhalb von 0,3 s nach dem vorigen und jeder Wechsel per Taste bewegt sich nicht. Scrollposition und Raster bleiben (kein Neuaufbau per `id`).
- **Terminfenster** wächst aus der angetippten Karte (Woche/Tag, Ganztagszeile, Monatszeile, „Als Nächstes“; ohne Karte aus der Mitte) und schrumpft beim Schließen dorthin zurück: öffnen 0,3 s ohne Überschwingen, schließen 0,18 s, keine Schließ-Haptik. `CalendarGrowEffect` skaliert und versetzt die ganze Hülle gleichmäßig; der eingebettete Editor behält seine Identität. Kartenrahmen melden sich über eine nicht beobachtete Referenz (`CalendarOriginTracker`).
- **Kopf ziehen:** Das Fenster folgt dem Finger nach unten (leicht kleiner, Hintergrund hellt auf), nach oben mit Gummiband; über 120 pt oder mit Schwung schließt es, sonst federt es mit der Geschwindigkeit zurück. Zugwert in eigenem Objekt (`CalendarWindowPull`), damit das Raster nicht neu zeichnet. Beim Schreiben bewegt sich nichts.
- **Puls „Heute“:** 1 → 1,12 → 1 (0,12 s hin, 0,18 s zurück), nur beim Antippen, nicht bei ⌘T.
- **Termin ziehen:** Karte hebt sich (Schatten, 4 % größer), jeder Rasterschritt rastet ein; nach dem Loslassen bleibt sie liegen, bis das Modell verschoben hat (eigener Token je Ablage), bei Ablehnung oder abgebrochener Seriennachfrage federt sie zurück.
- **Karten** animieren nur bei eigenen Änderungen der Termine eines Tages, nicht bei jeder Modellaktualisierung. Hausaufgabe abhaken: Haken sofort, gespeichert ~0,4 s später, dann gleitet die Zeile aus der Liste. Countdown „Als Nächstes“ rollt (`numericText`), Zeitlinie gleitet. Sync-Symbol ab iPadOS 18 mit dem System-Dreheffekt.
- **„Bewegung reduzieren“:** Layout sofort, Ein-/Ausblenden nur als kurzes Überblenden; nichts gleitet, wächst oder pulsiert; Sync-Symbol statisch.

### Terminfenster und Terminnotizen

#### Terminfenster überarbeitet (08.11.2026)

- **Fenster:** Details und Notiz öffnen als großes, zentriertes, schwebendes Fenster (≈ 92 % der Kalenderfläche, unter 700 pt fast vollflächig, Ecken 20 pt), einheitlich dunkel wie der Editor (auch im hellen Systemmodus), abgedunkelter Hintergrund. Für VoiceOver modal. Glocke, „…“ und „+“ des Kalenders sind währenddessen aus.
- **Notiz als Hauptfläche:** der normale noty-Editor randlos im Fenster; Seitenblättern, „Neue Seite“ und „Vergrößern“ sind die Bedienelemente des Editors selbst.
- **Ein schlanker Kopf:** Griff, Farbstreifen, Titel (höchstens zwei Zeilen), „Dienstag, 3. November 2026 · 08:00–08:45 · R 204“ (bei Platzmangel kurzes Datum), Notizstand in Worten („Schreiben legt die Notiz an“, „Wird angelegt …“, „In ‚Kalendernotizen‘“, orange „Nicht gespeichert“; Fehler immer mit Text und „Erneut“), Details, „…“, Schließen.
- **Details** ab 900 pt Fensterbreite als 272-pt-Spalte links (Status als Hinweisfeld, Raum, Lehrkraft, Kalender mit „Schreibgeschützt“, Wiederholung, Erinnerung, Hausaufgaben mit Abhaken, weitere Statuszeilen, Zuordnung „Ungeklärt“, Beschreibung, Herkunft), ausblendbar; schmaler als aufklappbarer Streifen (höchstens 40 % der Höhe). Gemerkt je Anordnung (`noty.calendar.window.detailsBeside`, Standard an; `noty.calendar.window.detailsAbove`, Standard aus). Ausfall, Änderung und ungeklärte Zuordnung öffnen den Streifen einmal von selbst; sonst steht der Status als Marke neben dem Titel, offene Hausaufgaben als Zahl am Details-Knopf. Ein-/Ausblenden ist bewusst nicht animiert.
- **Menü „…“:** Notiz (Vergrößern, Seite hinzufügen, bei leerer neuer Notiz „Vorhandene Notiz verknüpfen“), Fachfarbe bzw. „Termin bearbeiten“, „Termin löschen“ zuletzt (nur bei schreibbaren Terminen, `model.canEdit`).
- **Ruhige Zustände** (Papierkorb, endgültig gelöscht, nicht verfügbar, groß geöffnet, Laden) zentriert auf dem Editorhintergrund mit Erklärung und Knöpfen („Wiederherstellen“, „Verknüpfung lösen“).
- **Schließen:** Esc, Kopf nach unten ziehen, ✕, VoiceOver-„Escape“ – alle über `selection = nil` (Notiz wird committet und freigegeben). **Tippen neben das Fenster schließt nicht** (Handballen beim Schreiben; SwiftUI und UIKit unterscheiden einen aufliegenden Handballen nicht zuverlässig von einem Finger). Verschwindet der gewählte Termin (Quelle ausgeblendet, Aktualisierung, neue Systemkennung), endet die Auswahl über denselben Weg.
- **Editor-Identität:** dieselbe Editor-Instanz bei Updates, Breitenwechsel und Ein-/Ausblenden der Details (feste Position im selben `AnyLayout`, `id` nur je Notizsitzung). Code: `CalendarEventDetail`, `CalendarEventDetailParts`, `CalendarEventDetailNotes`.

#### Terminnotizen

- **Echte Hefte:** Die Notiz ist der normale noty-Editor (`ContentView` eingebettet: Stifte, Text, Undo, Werkzeugleiste, weitere Seiten) – kein zweites Notizformat. Ohne Notiz lebt die Seite nur im Speicher; erst die erste echte Eingabe (Handschrift, Text, Bild oder Form) legt ein gewöhnliches Heft an (eine Seite, Standardaussehen): Heftpaket committen, in die Bibliothek (Ordner „Kalendernotizen“ per ID, fehlt er → neu), dann den Link committen (Regel 8, §4). Eingaben während der Anlage landen im selben Editor; ein Fehler zeigt „Erneut“ und setzt mit demselben Heft fort. Titel „Fach-Langname bzw. Termintitel · TT.MM.JJJJ“ (doppelte Stunde: eindeutiger Zusatz), umbenennbar.
- **Notizhinweis** nur, wenn das verknüpfte Heft Inhalt hat und in der Bibliothek liegt. Fehlendes Ziel: Papierkorb → „Wiederherstellen“/„Verknüpfung lösen“; endgültig gelöscht → Hinweis, kein anderes (auch kein gleichnamiges) Heft.
- **Vergrößern:** gespeicherte Notiz → Sitzung committen und schließen, Heft im Vollbild-Editor der Bibliothek mit „Zurück zu <Termin> · <Datum>“; danach wieder im Terminfenster. Noch nicht angelegte Notiz → dieselbe Seite groß über dem Kalender.
- **Ein Schreiber:** Die Notiz hält die Schreibsperre ihres Hefts; vor jedem Öffnen eines Hefts aus der Bibliothek, beim Verlassen des Kalenders, beim Terminwechsel und vor einem Bereichswechsel wird sie committet und freigegeben. Was nicht committen kann, bleibt im Speicher und wird beim nächsten Öffnen wiederverwendet. Bereichswechsel mit nur im Speicher liegender Notiz oder Änderung: Meldung „Kalender nicht gespeichert“ mit ausdrücklichem „Verwerfen und wechseln“. Wechsel in den Hintergrund startet eine fällige Anlage sofort unter iOS-Hintergrundzeit.

### Eigene Termine

- **Kalender „Persönlich“** ohne Konto oder Systemberechtigung. Formular: Titel, Ort, ganztägig, Beginn/Ende (24 h, ungültige Spannen erklärt und gesperrt), Kalender (Persönlich oder ein beschreibbarer Systemkalender), Wiederholung, Erinnerung (Standard aus; Fußtext nennt die allgemeine Erinnerung), Beschreibung. Zeitgebunden mit Zeitzonenkennung oder ganztägig/mehrtägig mit zivilen Daten und exklusivem Ende. Das Formular schließt erst nach dem Commit; ein Schreibfehler zeigt „Nicht gespeichert … Erneut speichern“ und hält die Änderung im Speicher.
- **Wiederholungen:** täglich/wöchentlich/monatlich, Ende nie, nach Anzahl (1–999) oder am Datum, Ausnahmen. „Nur dieser Termin“ oder „Alle Termine der Serie“ beim Bearbeiten, Löschen und Ziehen; Änderungen an Regel/Ausnahmen gelten immer der Serie (geänderte Regel bietet nur „Alle“). Monatlich am 29.–31. entfällt in kürzeren Monaten (Hinweis). Wandzeit bleibt über die Sommerzeit. „Alle“ verschieben nimmt einzeln geänderte Termine und ihre Notizen mit (Tage und Wanduhr, sommerzeitfest, `CalendarSeries.moved`). Expansion um das angezeigte Jahr, höchstens 500 Termine je Serie, Überschreitung im Sync-Popover.
- **Ziehen/Dauer** (eigene zeitgebundene Termine in Woche/Tag): lange drücken und ziehen, Raster 15 Minuten (Woche, auch auf andere Tage) bzw. 5 Minuten (Tag), Uhrzeit-Vorschau; Griff am unteren Rand für die Dauer; unter 5 Minuten oder ungültig → Hinweis. Serien fragen nach dem Loslassen. VoiceOver-Aktionen „15 Minuten früher/später/länger/kürzer“, „Einen Tag früher/später“. Nicht ziehbar: ganztägige Termine, WebUntis, Ferien, Beispiele, Systemtermine (kein „Rückgängig“ für EventKit, Gefahr versehentlichen Verschiebens in iCloud/Outlook).
- **Löschen, Rückgängig, „Gelöschte Termine“:** „Rückgängig“ nach Ändern/Löschen stellt Termin und Ziele seiner Notizlinks in einem Commit wieder her (`CalendarUndoSnapshot`). Gelöschte eigene Termine, Serien und einzelne Serientermine landen in „Gelöschte Termine (n) …“ (höchstens 1000): „Wiederherstellen“ bringt sie mit ihrer ID und damit ihren Notizen zurück, „Endgültig entfernen“/„Alle endgültig entfernen …“ löscht nur den Eintrag, nie ein Heft. Ein einzelner Serientermin wird durch Entfernen seiner Ausnahme wiederhergestellt; ist die Serie selbst gelöscht, zuerst die Serie. „Rückgängig“ direkt nach dem Löschen entfernt auch den Eintrag; bei mehr als 1000 Einträgen machen die ältesten Platz. Systemtermine haben kein noty-„Rückgängig“ und keinen Eintrag dort.
- **Eine Reihenfolge:** Termine, Links, Einstellungen, „Erneut speichern“, Verbinden/Trennen laufen nacheinander durch `CalendarMutationQueue` auf dem neuesten Stand.
- **Schnell anlegen:** „+“ öffnet ein Popover mit Textfeld („z. B. Mathe Klausur Fr 10 Uhr“) und Live-Vorschau; Enter/„Weiter“ öffnet das vorausgefüllte Formular, „Leeres Formular“ das normale (Fokus im Titel); Kürzel ⌥⌘N. Außerdem per Halten und Ziehen im Raster (siehe Navigation). `CalendarQuickEntry` (Core) liest u. a. „Klassenfahrt 12.11.“, „morgen 9.15 Uhr“, „Mo 16:30-18 Uhr“, „12.11. bis 14.11.“, „22–1 Uhr“ (endet am Folgetag), „24 Uhr“ = 0:00 Folgetag; vergangene Uhrzeit am heutigen Wochentag → nächste Woche; „so“ ist kein Sonntag. Gespeichert wird erst im Formular.

### WebUntis

- **Zugang:** inoffiziell über die Untis-Mobile-Freigabe ([§7](#webuntis-entscheidung-04112026)). Verbindungsblatt „Kalender verbinden“: QR-Code scannen (VisionKit, `NSCameraUsageDescription`), „Freigabe aus Zwischenablage einfügen“ oder Server, Schule, Benutzer, Schlüssel von Hand; „Verbindung testen“ (nur lesen), „Verbinden“ (nur nach erfolgreichem Test), „Aktualisieren“, „Mit anderer Freigabe verbinden“, „Trennen“ (Zugangsdaten und Offline-Stundenplan weg, eigene Termine und Notizen bleiben). Zugangsdaten nur im Schlüsselbund.
- **Benennung in der Oberfläche (08.11.2026, Nutzerwunsch):** Die App nennt den Zugang nicht mehr „inoffiziell“ (Menüabschnitt „WebUntis“, Herkunft „WebUntis (Untis-Mobile-Freigabe)“, Verbindungsblatt „Anmeldung über die Untis-Mobile-Freigabe …“, Status und Benachrichtigungsblatt ohne „inoffiziell“); die Anbindung selbst und der Einwilligungstext `webuntis-push-1` (enthielt das Wort nicht) sind unverändert.
- **Handeingabe** (`WebUntisEntry`, Core): feste Feldbezeichnungen mit Beispiel; tolerant gegenüber Leerzeichen, ganzen Browser-Adressen (`school=` auch im Fragment), vertauschtem Server/Schule (Knopf „Vertauscht? Server und Schule tauschen“), `untis://setschool?…` in jedem Feld; Schlüssel ohne Leerzeichen/Bindestriche in Großbuchstaben, A–Z/2–7, Länge 8…128. Normalisiert beim Verlassen eines Felds, beim Einfügen und vor Test/Verbinden. Statt grauer Knöpfe ein sichtbarer Grund („Es fehlt: …“). Testfehler im Klartext (Server nicht erreichbar, Schule unbekannt, Benutzer/Schlüssel abgelehnt mit Hinweis auf die iPad-Uhrzeit, Antwort unlesbar). Der Schlüssel erscheint in keiner Meldung und keinem Log.
- **Abruf:** beim Öffnen des Kalenders, bei App-Aktivierung und während der Kalender sichtbar ist höchstens alle 15 Minuten, im Hintergrund über `BGAppRefreshTask` (nicht garantiert), sonst von Hand. Standardfenster eine Woche zurück bis fünf Wochen voraus; angezeigte Zeiträume über „Laden“. Stundenzeiten werden tolerant gelesen (angehängtes Z, Sekunden/Bruchteile, Leerzeichen, einstellige Stunde; Dauer 0 und mehrtägige Einträge erlaubt). Nur vollständig geprüfte Antworten werden übernommen; Teil-, Fehler- und leere Antworten ersetzen keinen Stand (ein Tag mit Stunden, der leer zurückkommt, gilt als nicht neu abgerufen).
- **Anzeige:** Unterricht schreibgeschützt (Schloss) mit Fach, Raum, Klasse; Lehrkräfte nur, wenn geliefert. Status best effort: Ausfall, Prüfung, Änderung/Vertretung, Raumänderung (aus `is` und `orgId` ≠ `id`), unbekannte Werte neutral als „Hinweis: unbekannter WebUntis-Status …“ (Belege: §9). Nach einem Restore ohne Zugangsdaten: „Zugang auf diesem Gerät neu verbinden · Stand … (veraltet)“, kein Abruf.
- **Stundennotizen und Zuordnung:** Notizen hängen an der Perioden-ID (Kontext: Kurs-ID, ursprüngliches Datum und Beginn) und an der geheimnisfreien Kontokennung, sodass dieselbe Freigabe nach Trennen/Neuverbinden ihre Notizen wiederfindet. Gleiche ID zu anderer Zeit oder als Ausfall → Notiz folgt. Fehlt die Stunde an einem geladenen Tag → „Ungeklärt“ an der alten Zeit mit Vorschlägen nur aus demselben Kurs (±14 Tage); erst die Auswahl speichert eine Zuordnung. Nicht geladener Tag → „Stunde nicht im Offline-Stundenplan“. Nie Zusammenführung über Titel.
- **Fachfarben:** automatisch und stabil je Fach (WebUntis-Fach-ID, sonst Name), änderbar über „Fachfarben …“ oder im Terminfenster; gespeichert in den Kalendereinstellungen. Eigene Termine grün, Ferien grau.

### Apple Kalender und Outlook

- **Verbinden** im Verbindungsblatt: „Apple Kalender und Outlook verbinden …“ fragt erst dann nach Vollzugriff (`requestFullAccessToEvents`, `NSCalendarsFullAccessUsageDescription`). Outlook/Microsoft 365 erscheint, wenn das Konto unter iPad-Einstellungen › Kalender › Accounts eingerichtet ist. Kalender je Konto ein-/ausblendbar (Kalenderleiste, gemerkt), Vorauswahl „Neue Termine in“.
- **Lesen:** für das Erweiterungsfenster (Jahr der Ansicht ± Wochen) außerhalb des Main Actors, bei Systemänderung (`EKEventStoreChanged`), Aktivierung/Öffnen (höchstens alle 30 s) und „Neu einlesen“; **nicht** im Kalenderpaket gespeichert. Status „Systemkalender zuletzt eingelesen: …“, nie „synchronisiert“. Eigene Quelle „Kalender“ mit echter Kalenderfarbe, Name, Konto und Schloss bei schreibgeschützten Kalendern.
- **Schreiben** über das Formular: Anlegen, Bearbeiten, Löschen; Serien „Nur dieser Termin“ (`EKSpan.thisEvent`) oder „Alle“ (ab dem ersten Termin, `.futureEvents`, um Kalendertage plus Wanduhr-Differenz; Notizen wandern mit). Regeln, die noty nicht darstellen kann („monatlich am 1. Montag“, wöchentlich an einem anderen Wochentag), bleiben unverändert; Einzeltermin ↔ Serie und ganztägig ↔ mit Uhrzeit einer ganzen Systemserie werden abgelehnt; Ausnahmen lassen sich nicht eintragen. Vor dem Schreiben wird das `EKEvent` frisch geholt; wurde es inzwischen geändert, wird nicht überschrieben. Schreibgeschützter oder fehlender Kalender, gelöschter Termin und Providerfehler werden genannt. Erinnerungen von Systemterminen trägt der Systemkalender ein (keine doppelte noty-Mitteilung).
- **Verschieben zwischen noty und Systemkalender** (nur Einzeltermine): Ziel zuerst schreiben, dann Quelle entfernen; System → noty löscht den Systemtermin erst nach bestätigtem Commit. Ein Fehler dazwischen hinterlässt beide sichtbar, nie keinen; der noty-Termin geht nach „Gelöschte Termine“.
- **Terminnotizen:** dieselben noty-Hefte. Anker: `calendarItemExternalIdentifier` (sonst `calendarItemIdentifier`) + ursprünglicher Vorkommensbeginn bei Serien (ganztägig/„floating“ als Ortsdatum bzw. Ortszeit `occurrenceLocal`) + Kalender. Dieselbe Einladung in zwei Kalendern: der ursprüngliche Kalender entscheidet, sonst „ungeklärt“; fehlt der Termin im eingelesenen Zeitraum → „Ungeklärt“ mit Auswahl aus demselben Kalender (±14 Tage), außerhalb → „nicht im eingelesenen Zeitraum“; vorläufige Exchange-Kennungen werden bei eindeutigem Treffer ersetzt.
- **Rechteentzug/Ausschalten:** keine Systemtermine mehr, Notizen bleiben als „Systemkalender nicht verfügbar“ erreichbar; „Ausschalten“ entfernt weder Termine noch Notizen. Restore schaltet Systemkalender aus.

### Ferien und Feiertage (Ferien-Rückfall NRW, 06.11.2026)

WebUntis-Ferien aus den Stammdaten gelten innerhalb ihres Zeitraums (erster Beginn bis letztes Ende; Ende als einschließlich angenommen). Sonst Schulferien NRW 2025/26–2027/28 aus der eingebauten Tabelle `CalendarHolidaysNRW` (aus Modellwissen eingetragen, nicht heruntergeladen; laut Prüfung vom 06.11. gegen BASS 19-1/Kalenderpedia abgeglichen, Pfingstferien 2028 entfernt, Sommerferien 2028 vorläufig, bewegliche Ferientage fehlen) und die gesetzlichen Feiertage NRW (Ostern-basiert berechnet, ohne Oster-/Pfingstsonntag), ohne doppeltes Band in Ferien. Kein KMK-ICS-Abruf. Fehlende Daten werden nicht als Ferienfreiheit ausgegeben. Die Quelle nennt das Sync-Popover („Ferien und Feiertage“).

### Hausaufgaben aus WebUntis

`homeWorks` der `getTimetable2017`-Perioden werden tolerant gelesen (Feldnamen aus Community-Clients, auch Datum als Zahl `20261113`; fehlerhafte Einträge übersprungen, nie der Stundenplan verworfen), im Offline-Stundenplan gehalten (tageweise ersetzt wie Stunden) und gezeigt: an der Stunde (Buchsymbol, Abschnitt im Terminfenster mit Abhaken), in der Kalenderleiste (bis zu fünf offene, nächste Fälligkeit zuerst, „fällig heute/morgen/Mo 9.11.“ bzw. orange „überfällig seit …“, „Alle“ öffnet die Liste mit „Erledigte zeigen“) und im Morgen-Überblick. „Erledigt“ gilt nur in noty (Kalenderformat 4, an die Kontokennung gebunden, im Bibliotheksbackup), nur mit WebUntis-Verbindung und Schreibrecht, und wird nie an WebUntis gesendet.

### Benachrichtigungen (08.11.2026)

**Vom Nutzer festgelegt:** (a) Stundenplanänderungen aus WebUntis (Ausfall, Vertretung, Raumwechsel, verlegte Stunde), (b) Erinnerung vor Terminen – Standard nur eigene Termine, 15 Minuten vorher, Unterricht standardmäßig ohne, (c) Morgen-Überblick an Schultagen um 6:45 (einstellbar) mit erster Stunde und Raum, Änderungen des Tages, fälligen Hausaufgaben (nur hier) und Terminen; an Tagen ohne Unterricht/Termine keiner. Ausgabe als iPad-Mitteilung und in der Glocke. Abruf auch im Hintergrund, Ruhezeiten 21:00–06:00, kein Time-Sensitive.

- **Änderungserkennung** (Core `CalendarChanges.swift`, rein; dieselbe Logik nutzt der Server): vergleicht den Offline-Stundenplan vor und nach einer Aktualisierung, **nur an Tagen, die beide Stände abdecken und die der neue später abgerufen hat**. Erster Abruf, neue Verbindung, Fensterverschiebung, gekürzte Tage und leer zurückgekommene Tage ergeben nichts. Zuordnung nur über die Perioden-ID; doppelte IDs gelten als mehrdeutig. **Eine verschwundene Stunde wird nie als Ausfall gemeldet** – nur ein ausdrücklicher Status zählt. Arten: Ausfall, findet wieder statt, verlegt, Raumwechsel, Vertretung, zusätzliche Stunde (neue Periode mit ausdrücklich unregelmäßigem Status an einem Tag, der vorher Stunden hatte). Nur Stunden, die noch beginnen. Texte z. B. „Do 12.11., 08:00 Deutsch fällt aus“ (Uhrzeit statt „2. Std.“, weil der Zugang keine Stundennummer liefert). Deterministische ID je Änderung; dieselbe Änderung nach einer anderen dazwischen („Ausfall“ → „findet statt“ → „Ausfall“) wird als `…~2`, `…~3` erneut gemeldet.
- **Planung** (Core `CalendarNotifications.swift`): Morgen-Überblicke der nächsten 7 Tage, dann Erinnerungen (`CalendarReminderPlanner`), zusammen höchstens 50 der etwa 64 Mitteilungen, die iPadOS je App hält, die nächsten zuerst (Erinnerungen der nächsten 30 Tage; das Blatt nennt „geplant bis …“). Überblick: Titel „Dein Tag · Mo 9.11.“, erste nicht ausgefallene Stunde mit Raum bzw. „Alle Stunden fallen aus.“, bis zu drei Änderungen, offene fällige Hausaufgaben, bis zu drei Termine aus noty und sichtbaren Systemkalendern; Inhalt ist der Stand der letzten Aktualisierung. Neu geplant bei Aktivierung, nach jedem Commit und jeder Aktualisierung (auch im Hintergrund).
- **Erinnerungen:** im Termin „Zum Beginn, 5/10/15/30 Minuten, 1 Stunde, 1 Tag vorher“ (Serie: jeder Termin; ganztägig ab 9:00 des ersten Tages; „1 Tag“ behält die Uhrzeit über die Zeitumstellung). Allgemein „Erinnerung vor eigenen Terminen“ (an, 15 Minuten; 5/10/15/30/60) für eigene Termine mit Uhrzeit ohne eigene Erinnerung; die Erinnerung im Termin hat Vorrang; ausgeschaltet keine Erinnerungen an eigene Termine. „Unterricht X Minuten vorher“ (Standard aus; ausgefallene Stunden nie; ohne Zugangsdaten keine aus einem veralteten Plan). Eine feste Kennung je Durchführung (keine Duplikate), keine wiederholenden Auslöser. Apple Kalender/Outlook erinnern selbst.
- **Ruhezeiten** (21:00–06:00, einstellbar, abschaltbar): keine Mitteilung für Änderungen (nur Glocke) und keine Stundenerinnerung; ein Überblick in der Ruhezeit kommt zu ihrem Ende (am selben Tag, sonst entfällt er). Erinnerungen an eigene Termine kommen auch in der Ruhezeit. Keine Time-Sensitive-Mitteilungen.
- **Glocke** neben dem Sync-Symbol (roter Zähler, VoiceOver „Benachrichtigungen, n ungelesene“), bei offenem Terminfenster aus. Popover mit Verlauf (neueste zuerst, ungelesen fett, „Alle gelesen“, Zahnrad, „Als gelesen markieren“). Ein Eintrag gilt erst als gelesen, wenn er geöffnet wurde; gelesen entfernt die Mitteilung auch aus der Mitteilungszentrale. Verlauf je Bereich in `Library/Application Support/CalendarNotifications/` (abgeleitet, nicht im Backup, höchstens 200 Einträge/60 Tage).
- **Antippen** (`CalendarNotificationHub`, Delegate): öffnet über `model.openNotification` den Termin/die Stunde, sonst den Tag; die Bibliothek schaltet auf den Kalender. Ist der Kalender gerade nicht sichtbar oder liegt ein Formular, eine vergrößerte Notiz oder eine Seriennachfrage darüber, wird der Tipp gemerkt und ausgeführt, sobald der Kalender sichtbar ist. Startet die App über den Tipp, wartet sie auf das Modell. Mitteilungen eines anderen Bereichs öffnen nichts, sondern sagen es. Im Vordergrund Banner plus Glocke.
- **Blatt „Benachrichtigungen“** (Menü „…“ › „Benachrichtigungen …“ und Zahnrad der Glocke; ersetzt das frühere „Erinnerungen …“): Erlaubnisstatus mit „Einschalten“ bzw. Weg zu den iPad-Einstellungen, Stundenplanänderungen (nur mit WebUntis), Morgen-Überblick mit Uhrzeit, Erinnerung vor eigenen Terminen, Unterricht, Ruhezeiten, „Auch bei geschlossener App“ (Push), „Schultag auf dem Sperrbildschirm“ (Live Activity, mit Test-Kachel), „n Mitteilungen geplant bis …“. Geräte-Einstellung (`UserDefaults`), nicht im Backup. **Erlaubnis** nie ungefragt beim Start: einmaliger Hinweis im Kalender, sobald echte Daten da sind; sonst beim Einschalten eines Schalters. Ohne Erlaubnis landet alles nur in der Glocke.
- **Hintergrund:** `BGAppRefreshTask` `de.la.noty.calendar.refresh`, beantragt beim Wechsel in den Hintergrund (frühestens 15 Minuten). Der Lauf nutzt das Kalendermodell des geöffneten Bereichs (dasselbe `CalendarRepository`, kein zweiter Schreiber); ohne geladenes Modell oder ohne geschützte Daten tut er nichts. Schlüsselbund `AfterFirstUnlockThisDeviceOnly`; `errSecInteractionNotAllowed` (vor dem ersten Entsperren) gilt nicht als „Zugang fehlt“.
- **Nur der geöffnete Bereich** plant und benachrichtigt; ein Bereichswechsel ersetzt die geplanten Mitteilungen.

### Push-Dienst

Mitteilungen über Stundenplanänderungen auch bei geschlossener App kommen vom eigenen Server **noty-push** (`push/`, Swift, auf dem VPS hinter nginx unter `https://noty.xclipsen.de/push/v1/`). Nur mit ausdrücklicher Einwilligung (`webuntis-push-1`) wird die Freigabe verschlüsselt dorthin übertragen; „Trennen“, Ausschalten oder Löschen des Bereichs meldet ab und löscht sie dort. Solange der Server für die Verbindung zuständig ist, schreibt die App eigene Funde nur in die Glocke; vor eigenen Änderungsmitteilungen holt sie dessen Verlauf, bei jedem Problem meldet sie wieder selbst. Architektur, API, Datenschutz, Betrieb und Grenzen: [PUSH](PUSH.md).

### Schultag-Kachel und Widget

Live Activity „Schultag“ (Sperrbildschirm und Mitteilungszentrale: aktuelle Stunde mit Raum und Countdown, Pause/Freistunde, „Stunde 3/6“, „Danach …“ mit Ausfall/Vertretung/Raumwechsel, keine Hausaufgabenzeile) und Widget „Heute“, lokal aus der App gesteuert; nur in noty calendar mit eigener Widget-Extension. Verhalten, JSON-Vertrag für einen späteren Push-Weg, Bau und Nachsignieren der Extension: [LIVE-ACTIVITY-PLAN](LIVE-ACTIVITY-PLAN.md).

### Backup und Wiederherstellung

- Das **Bibliotheksbackup** (manuell und automatisch/extern) enthält den bestätigten Kalender des Bereichs – eigene Termine mit Serien, Ausnahmen, geänderten Terminen und Erinnerung, gelöschte Termine, Notiz-Links, Stundenzuordnungen, Fachfarben, Einstellungen, Systemkalender-Einstellungen, Hausaufgaben-Haken, den geheimnisfreien Verbindungseintrag – sowie den letzten WebUntis-Offline-Stundenplan mit Abrufzeiten (Archivformat 3, [LIBRARY-BACKUP](LIBRARY-BACKUP.md)). Ohne Kalenderdaten bleibt es Format 2. Terminhefte sind gewöhnliche Hefte im Backup. Ein Heftbackup enthält keinen Kalender (Einstellungen › Backup sagt es).
- **Restore** nur in einen neuen getrennten Bereich, Kalenderteil vor dem Veröffentlichen vollständig geprüft; Links zeigen auf die Hefte des neuen Bereichs, nie bereichsübergreifend. WebUntis wird nie automatisch aktiv (neue Verbindungs-ID, „Auf diesem Gerät neu verbinden …“), Systemkalender sind aus. Die Bestätigung beim Öffnen einer `.notylibrary` nennt Termine, Terminnotizen, Stundenplanstand und das Neuverbinden.
- **Nicht im Backup** (abgeleitet bzw. gerätebezogen): Mitteilungsverlauf, Benachrichtigungs- und Push-Einstellungen, Systemkalender-Termine, Zugangsdaten, Kachel-/Widget-Daten.

## 3. Stufen und Lieferumfang

Häkchen = implementiert und gebaut; Installation, Gerätetest und Nutzerbestätigung je Funktion in der Tabelle oben, je Build in [CALENDAR-LOG](CALENDAR-LOG.md).

### Stufe A – Kalenderdesign und Navigation (Auftrag 03.11.2026)

- [x] Native Ansichten und Termindetails mit ausschließlich fiktiven Beispielen; Jahr, Monat, Woche, Tag, Heute und Datumsauswahl; Fünf-/Siebentageumschaltung.
- [x] Direkt beschreibbare Notizseite, Inhaltsindikator, zusätzliche Seiten, Vergrößern und Rückkehr (in Stufe A nur Entwurf im Speicher, seit B2 echte Hefte).
- [ ] Hoch-/Querformat, kleine Fenster, Tastatur und große Schrift: im Code berücksichtigt, am iPad **ungeprüft**.
- [ ] Gestaltung und Weg „Termin → schreiben → vergrößern → zurück“ vom Nutzer abnehmen lassen. **Offen** (Rückmeldungen zu Build 99 und vor 127 sind eingearbeitet, eine Abnahme gab es nicht).

**Abnahme:** Bestätigung des konkreten Designs, noch kein Nachweis dauerhafter Speicherung. Vorzulegen (fiktive Daten genügen): gefüllte Fünf-/Siebentagewoche, Monat mit Terminüberlauf, Tag, Jahr, Terminfenster mit leerer und beschriebener Notiz, zusätzliche Notizseiten, Vergrößern/Rückkehr, Terminformular mit Wiederholungen/Erinnerungen, leere Ansicht, schmaler Split-View-Ausschnitt, Ausfall mit Notiz und schreibgeschützter WebUntis-Termin. Dabei noch zu entscheiden: Mini-Monat mit 36-pt-Tagen (unter 44 pt), Farbe „heute“ (jetzt Rot, Blau bleibt Auswahl), Breitenregeln des Terminfensters (Details ab 900 pt Fensterbreite daneben). Entschieden seit Stufe A: eigener Umschalter statt Ort in der Bibliotheksleiste (Build 133), Notiz als normaler Editor statt Entwurfsseite (Build 102).

#### Umsetzungsstand Stufe A (03.11.2026)

Ansichten, Termindetails, Formular und Entwurfsnotizseite mit Beispieldaten; Core `CalendarLayout.swift` mit `CalendarLayoutTests`. Seit Build 99 als eigene Test-App, mit Build 100 vereinfacht, mit Build 127 überarbeitet; heutiger Stand in §2. Nachweise und Gerätetest: [CALENDAR-LOG, Build 99](CALENDAR-LOG.md#build-99--test-app-noty-calendar-stufe-a-03112026) und [Build 100](CALENDAR-LOG.md#build-100--vereinfachung-04112026).

### Stufe B – Erste nutzbare Version: WebUntis, lokale Termine und Stundennotizen

- [x] Erlaubten WebUntis-Zugang klären: Untis-Mobile-Freigabe, kein Backend ([§7](#webuntis-entscheidung-04112026)).
- [x] Unterricht mit den tatsächlich gelieferten Fach-, Raum-, Lehrkraft-, Vertretungs-, Ausfall- und Prüfungsdaten anzeigen; Zeiten aus der Quelle, eigene Ergänzungen getrennt (Status außer `REGULAR`: §9).
- [x] Bereichsbezogener Offlinebestand mit Datenstand und geladenem Zeitraum; verschobene/ausgefallene Stunden und ihre Notizen zuordnen (ob WebUntis verschobene Stunden unter derselben ID liefert: §9).
- [x] Eigener lokaler Kalender ohne Konto, eigene Termine anlegen, bearbeiten, löschen (ganztägig, mehrtägig); Duplizieren bleibt Vorschlag.
- [x] Wiederholungen mit Ende und Ausnahmen, „Nur dieser/Alle“.
- [x] Verschieben und Daueränderung per Formular und Ziehen; ungültige Spannen verständlich ablehnen.
- [x] Alle vier Ansichten aus denselben Daten, letzte Ansicht und Fünf-/Siebentagewahl pro Bereich; Ferienquelle (WebUntis, Rückfall NRW).
- [x] Direkt bearbeitbare Terminnotiz, Anlage erst ab Eingabe, weitere Seiten, Notizhinweis, Vergrößern/Rückkehr, „Kalendernotizen“.
- [x] Fachfarben, separate Farbe für eigene Termine.
- [x] Optionale Erinnerungen pro Termin und Unterrichtseinstellung, ohne doppelte Mitteilungen.
- [x] Sichere Speicherung, Fehleranzeige, lokale Wiederherstellung, Bibliotheksbackup mit Kalender, Notizen und Links.
- [x] Löschen mit Rückgängig und „Gelöschte Termine“; Notizen bleiben erhalten.

**Abnahme (offen):** Im Flugmodus geladenen Stundenplan öffnen, eigenen Termin und Notiz anlegen, schreiben, speichern, App neu starten und beides erneut öffnen. Erst Handschrift/Text setzt den Notizhinweis. Verschiebung/Ausfall, Serienausnahme, wiederholtes Einlesen und veralteter Offlinebestand erhalten korrekte Zuordnungen und Notizen. Ziehen, Daueränderung, Fensterwechsel und Vergrößern am iPad prüfen. Vollständiges Backup in einen neuen Bereich zurückspielen; Kalender, Notizen und Links stimmen dort. Schreibfehler dürfen keinen falschen Speichererfolg anzeigen.

#### Umsetzungsstand B1 (04.11.2026)

WebUntis über die Untis-Mobile-Freigabe, eigene Einzeltermine, Kalenderpaket je Bereich (Format 1). Build 101; Korrekturen in 104–106. [Nachweise und Gerätetest](CALENDAR-LOG.md#build-101--b1-webuntis-eigene-termine-kalenderpaket-04112026).

#### Umsetzungsstand B2 (04.11.2026)

Terminnotizen als Hefte in „Kalendernotizen“, Stundenzuordnung, Wiederholungen, Ziehen/Dauer, Fachfarben, Kalenderformat 2. Build 102. [Nachweise und Gerätetest](CALENDAR-LOG.md#build-102--b2-terminnotizen-serien-ziehen-fachfarben-04112026).

#### Umsetzungsstand B3 (04.11.2026)

Kalender im Bibliotheksbackup mit Restore in einen neuen Bereich, „Gelöschte Termine“, Erinnerungen, Kalenderformat 3. Build 103; Review-Korrekturen Build 104. [Nachweise und Gerätetest](CALENDAR-LOG.md#build-103--b3-backup-gelöschte-termine-erinnerungen-04112026).

### Stufe C – Apple Kalender und Outlook lesen und schreiben

Umgesetzt mit EventKit seit Build 127 (Nutzerentscheidung 06.11.2026: Outlook/M365 über die Systemkonten), dazu Ferien-Rückfall NRW, Hausaufgaben und Schnell anlegen. Funktionsumfang: §2 „Apple Kalender und Outlook“.

- [x] Providerweg: EventKit mit Vollzugriff; tatsächliche Konten und Schreibrechte am iPad **ungeprüft**.
- [x] Termine anzeigen, anlegen, bearbeiten und löschen mit Zielkalenderwahl, Fehler- und Konfliktbehandlung.
- [x] Dieselbe Terminnotizfunktion wie in Stufe B; Notizen bleiben noty-Dokumente und werden nicht zu Apple/Outlook hochgeladen.
- [x] Berechtigungszustände, Aktualisierung und Serienereignisse mit Verknüpfungen pro Durchführung (Stabilität der Exchange-Kennungen: §9).

**Abnahme (offen):** Änderungen in beide Richtungen überprüfen; Rechteentzug, fehlende Verbindung, Schreibfehler, Quellenwechsel und Serienänderungen verursachen weder Duplikate noch Notizverlust. Die Kalenderanbindung belegt keine eigene Backend-Synchronisierung von noty-Notizen.

### Stufe D – Eigenes Backend zur Synchronisierung, später

**Synchronisierung nicht begonnen; nur teilweise berührt.** Seit 08.11.2026 gibt es mit noty-push ein eigenes Backend – aber nur für Änderungsmitteilungen (Freigabe verschlüsselt, Vergleichsstand, Verlauf). Es erfüllt damit den letzten Punkt unten (ein WebUntis-Backend getrennt vom Synchronisationsumfang), synchronisiert aber keine Termine, Notizen oder Einstellungen; die übrigen Punkte sind offen und nicht beauftragt.

- [ ] Eigene Termine, Einstellungen, Notizen einschließlich editierbarer Handschrift/Text und Verknüpfungen zwischen den eigenen Geräten synchronisieren.
- [ ] Vollständige Offlinebearbeitung erhalten; Synchronisierung und separate Sicherung bleiben getrennte Funktionen.
- [ ] Vor Umsetzung Architektur, Hosting, Anmeldung, Gerätezuordnung, Konflikte, Löschungen, Bereichsgrenzen und Wiederherstellung konkret planen.
- [x] Ein für WebUntis nötiges Backend von diesem Synchronisationsumfang unterscheiden: noty-push ist getrennt ([PUSH](PUSH.md)).

**Abnahme:** Noch als eigene technische Planung auszuarbeiten; mindestens Offlineänderungen auf mehreren Geräten, Konflikte, Unterbrechungen und Erhalt sämtlicher Notizdaten prüfen. Lokales Speichern allein ist kein Synchronisationsnachweis.

### Späterer Ausbau

**Bestätigt für später:** einzelne Stundennotizen als durchgehendes Fachheft öffnen. Ergebnis bestätigt; Zusammenstellung, Reihenfolge und Bearbeitungssemantik sind noch zu planen. Eine dauerhafte Fachheftzuordnung ebenfalls später.

**Noch nicht bestätigt:** zusätzliche Heft-/Seitenverknüpfungen, mehrere eigene Kalender, erweiterte Suche, ICS-Export, Kalender-PDF/Drucken, Kurzbefehle, weitere Feiertagsquellen und Aufgabenverwaltung (separates Produktpaket; eine handschriftliche Checkbox im Heft ist keine Kalenderaufgabe). Weitere Vorschläge: [CALENDAR-IDEAS](CALENDAR-IDEAS.md). Widgets sind seit 08.11.2026 beauftragt und umgesetzt (Widget „Heute“).

## 4. Regeln für Terminhefte und Verknüpfungen

1. **Ein Heft bleibt ein gewöhnliches noty-Dokument.** „Kleines Heft“ beschreibt den Einstieg mit einer Seite, kein zweites Notizformat. Weitere Seiten und vorhandene Editorfunktionen bleiben nutzbar.
2. **Verknüpfung über Identitäten:** Bereich, Dokument-ID und optional Seiten-ID; niemals Name, Dateipfad oder Seitenposition. Ein Termin kann mehrere Hefte verknüpfen, ein Heft mehrere Termine.
3. **Keine Kaskadenlöschung:** Termin entfernen, Quelle trennen oder Fachzuordnung ändern löscht kein Heft. Verbindung lösen entfernt ausschließlich den Link.
4. **Verschieben erhält die Notiz:** Lokale Termine behalten ihre ID. Bei externen Terminen hilft eine eigene Zuordnungstabelle; unsichere Zuordnungen als ungeklärt anzeigen statt anhand gleicher Titel automatisch zusammenzuführen.
5. **Serien:** Das Heft einer einzelnen Unterrichtsstunde gehört zur Durchführung. Ein allgemeines Fachheft und das Zusammenführen von Stundennotizen sind spätere Erweiterungen, nicht Teil der ersten Version. Ein neues Heft einer Durchführung wird nicht automatisch an jede Wiederholung gehängt.
6. **Fehlende Ziele:** Heft/Seite im Papierkorb oder endgültig entfernt → verständlicher Hinweis und Auswahl eines anderen Ziels. Nicht unbemerkt ein gleichnamiges Heft öffnen. Fehlt nur die Seite, das Heft als ausdrückliche Alternative anbieten.
7. **Duplizieren:** Ein duplizierter Termin erhält eine neue ID und standardmäßig keine Heftlinks. Links bewusst übernehmen ist später möglich; keine stillen Kopien von Heftinhalten.
8. **Heftanlage bei Fehlern:** Erst ab tatsächlicher Eingabe anlegen; eine bloß geöffnete leere Fläche erzeugt kein persistentes Heft. Zuerst das Heft über die Bibliothek vollständig committen, dann verknüpfen. Scheitert der zweite Schritt, bleibt das Heft in der Bibliothek auffindbar und der Link kann erneut gesetzt werden. Weitere Eingaben während laufender Anlage dürfen keine Duplikate erzeugen oder Inhalt verlieren.

## 5. Architektur, Code und Prüfregeln

**Schichten:** Plattformunabhängige Logik in `Core/Sources/NotebookCore` (keine Apple-Typen): `CalendarData` (Zustand, Format), `CalendarRepository` (Paket, ein Schreiber), `CalendarSourceSnapshot` (Offline-Stundenplan), `WebUntis`/`WebUntisEntry`, `CalendarLayout`, `CalendarRecurrence`, `CalendarEditing`, `CalendarNotes` (Links, Anker, `CalendarNoteCreation` für Regel 8), `CalendarSystem` (EventKit-Anker, Einstellungen), `CalendarHomework`, `CalendarHolidaysNRW`, `CalendarQuickEntry`, `CalendarZoom`, `CalendarCreation`, `CalendarReminders`, `CalendarChanges`, `CalendarNotifications`, `CalendarSchoolDay`, `CalendarArchive`. App-Schicht in `Sources/Noty`: `CalendarModel` (`@MainActor`, gehört dem Bereich) mit Erweiterungen `+Events`, `+Notes`, `+WebUntis`, `+System`, `+Homework`, `+QuickEntry`, `+Notifications`, `+UI`; Ansichten `CalendarView`, `CalendarWeekView`, `CalendarMonthView`, `CalendarSidebar`, `CalendarStatus`, `CalendarNavigation`, `CalendarEntry`, `CalendarStyle`, `CalendarMotion`, `CalendarZoomGesture`, `CalendarTrackpadSwipe`, `CalendarCreateGesture`, `CalendarEventDetail(+Parts, +Notes)`, `CalendarEventForm`, Blätter (`CalendarConnectionSheet`, `CalendarNotificationSettingsSheet`, `CalendarDeletedEventsSheet`, `CalendarColorsSheet`, `CalendarSearchSheet`, `CalendarHomeworkViews`, `CalendarSystemViews`, `CalendarQuickEntryPopover`), Dienste `WebUntisClient`, `CalendarReminderCenter`, `CalendarNotificationHub`, `CalendarPushClient`, `CalendarSchoolDayCenter`. Extension `Sources/NotyCalendarWidgets` mit `Sources/NotyCalendarShared`. Server `push/` (eigenes Swift-Paket, bindet `../Core` per Pfad ein). EventKit-, Benachrichtigungs-, ActivityKit- und UIKit-Code bleiben in der App-Schicht; keine neue Abstraktionsschicht im Hefteditor allein für den Kalender.

**Anschlussstellen im übrigen Code:** Notizen sind gewöhnliche Hefte (`Notebook.swift`, kein neuer Dokumenttyp, kein Kalenderlayer); `EditorModel`/`ContentView(embedded:)` als Speicherbesitzer der Notiz; `WorkspaceAppModel`/`WorkspaceStore` für Bereiche; `LibraryArchive` mit `CalendarArchive` und Python-Prüfern; `PageGeometry`/`PagePresentation`/PDF-Export bleiben für Terminhefte maßgeblich, das Kalenderraster ist normale UI ohne Heftkoordinaten.

Vor größeren Änderungen zusätzlich [DESIGN](DESIGN.md), [ARCHITECTURE](ARCHITECTURE.md), [STORAGE](STORAGE.md), [LIBRARY](LIBRARY.md), [LIBRARY-BACKUP](LIBRARY-BACKUP.md), [BACKUPS](BACKUPS.md), [KEYBOARD](KEYBOARD.md) und [ACCEPTANCE](ACCEPTANCE.md) heranziehen und historische Aussagen dort mit dem Code abgleichen.

**Prüfregeln bei Änderungen:**

- Core-Tests für Datum, Intervalle, Überschneidungen, IDs/Links, Serienausnahmen, Save-Reihenfolge, Schreibfehler, Recovery, Migration und Restore in getrennte Bereiche (`swift test --package-path Core --filter Calendar`); Server: `swift test --package-path push`.
- Provider-Fixtures für Verschiebung, Absage, fehlende IDs, unvollständige Antworten, gleitende Zeitfenster und mehrfaches Einlesen; **keine privaten Stundenplandaten** als Fixtures committen.
- Host-Roundtrip (`bash scripts/check_page_workflow.sh`) und unabhängige Prüfer (`scripts/calendar_format.py`, `verify_library_backup.py`, `verify_device_store.py`) bei Kalenderformat- und Backupänderungen; Swift-Validierung und Python gemeinsam anpassen.
- iPad-SDK-Build bei UI/EventKit/ActivityKit; Veröffentlichung nur über `NOTY_CHANNEL=calendar scripts/publish_ota.sh` mit `ota_check.py` (Push-Entitlement, Extension, Versiegelung). Gebündelte Gerätetests für Navigation, Tastatur, Heftöffnung, Speichern/Neustart, Fenstergröße, Berechtigungsentzug und Offlineverhalten.
- Bei späterem Kalender-PDF echte Ausgabe mit `pdfinfo`, `pdftoppm` und `pdftotext` prüfen; der Heft-PDF-Export beweist keinen Kalenderexport.
- Ergebnisse immer als implementiert, gebaut, veröffentlicht, installiert und am iPad getestet getrennt in [CALENDAR-LOG](CALENDAR-LOG.md) eintragen.

## 6. Persistenz, Datum und Backup

Ein eigenes Kalenderpaket unter dem aktiven Bereichsroot (`Calendar/`) mit genau einem Writer. Lokale Termine, Heftlinks und relevante Einstellungen bilden einen gemeinsam bestätigten Stand. Externe Snapshots sind getrennte, ersetzbare Daten; eigene Links und Hefte sind keine Cacheeinträge.

- Vollständige unveränderliche Revisionen, geprüft zurücklesen, Manifest zuletzt ersetzen. Ältere asynchrone Saves dürfen keine neueren ersetzen; Actor-Reentranz und spät eintreffende Providerantworten mit Generation/Revision und Bereichskennung abfangen.
- Unbekannte neuere Formate sperren. Fehler erhalten den letzten gültigen Stand und ungesicherte Änderungen. Alte Bytes vor einer Migration sichern; kein „Gespeichert“ vor Commit.
- Kalender nicht als ein riesiges Jahresheft modellieren. Jahr/Monat/Woche/Tag sind Projektionen derselben Termine; kein duplizierter Terminbestand je Ansicht.
- Zeitgebundene Termine speichern Beginn/Ende und relevante Zeitzonenkennung. Ganztagstermine speichern zivile Datumsgrenzen mit exklusivem Enddatum; keine Mitternachts-UTC-Ersatzlogik.
- Tages-/Wochenrechnung über Kalenderoperationen, nie fest `24 × 60 × 60` Sekunden. Sommer-/Winterzeit, Jahreswechsel mit ISO-Woche 1/53, Schaltjahr und Reisen in andere Zeitzonen testen.
- Serienexpansion und Quellenabfragen sind zeitlich und mengenmäßig begrenzt; Überschreitungen werden gemeldet, nicht unbemerkt abgeschnitten.
- Abgeleitete Daten (Mitteilungsverlauf, Kachel-/Widget-Datei, Systemkalender-Termine) liegen außerhalb des Pakets und sind keine bestätigten Stände.

**Backup:** Das Bibliotheksarchiv enthält lokale Kalender, Termine, Heftlinks, Einstellungen und die gewöhnlichen Terminhefte, dazu den Offline-Stundenplan mit Datenstand, damit wiederhergestellte Notizen ihren Terminkontext behalten. Keine Tokens, Zugangsdaten oder privaten Abonnement-URLs exportieren. Restore aktiviert keine Verbindung und schreibt niemals Termine in externe Kalender zurück. Archivformat ausdrücklich versioniert; ältere Leser lehnen neuere Formate ab, statt unvollständig wiederherzustellen; alte Archive bleiben lesbar und ergeben einen Bereich ohne Kalenderbestand. Restore veröffentlicht einen getrennten Bereich und ordnet Links dessen Heften zu (explizite ID-Abbildung); bereichsübergreifende Heftlinks sind ausgeschlossen. Ein Heftbackup bleibt ein Heftbackup und behauptet keine Kalendersicherung.

## 7. Externe Kalender und WebUntis: Regeln und Identitäten

### Apple Kalender und Outlook; Google nicht als eigener Wunsch bestätigt

EventKit greift auf den zugänglichen Systemkalenderbestand zu. Outlook/Google sind darüber nur nutzbar, soweit das betreffende Konto im iPad-Systemkalender verfügbar ist; die bloße Installation der Outlook-App reicht als Integrationsnachweis nicht aus. Direkte Microsoft-Graph-/Google-API-Anbindungen gehören nicht zur Umsetzung.

Das Projekt hat iPadOS 17 als Mindestversion. Für das Lesen von Terminen verlangt EventKit Vollzugriff; reine Schreibberechtigung genügt nicht. Beim bewussten Verbinden passende Erklärung und `NSCalendarsFullAccessUsageDescription` verwenden. Ablehnung oder Entzug blockiert weder lokale Termine noch Hefte. Siehe [Apple TN3152](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels) und [EventKit-Zugriff](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui).

Erneut einlesen bei App-Aktivierung, Systemänderungen und manueller Aktion; nicht „Cloud erfolgreich synchronisiert“ melden. Hintergrundaktualisierung ist kein garantiertes Echtzeitintervall. Ein eigener Offlinebestand braucht eine definierte Zeitabdeckung; außerhalb davon „Zeitraum noch nicht geladen“ statt „keine Termine“.

Bei Rechteentzug externe Details ausblenden und Cache gemäß festgelegter Löschregel entfernen; eigene Heftlinks als nicht verfügbare Quelle erhalten. Beim bewussten Trennen Quelle/Cache entfernen, Hefte und eigene Links bewahren. Geheimnisse gehören in den Keychain, niemals in Logs oder ins öffentliche Repository.

### ICS und WebUntis

#### WebUntis-Entscheidung (04.11.2026)

Die Schule des Nutzers sperrt anonyme/öffentliche Stundenpläne, bietet kein iCal an und meldet über Office-365-SSO an. Der Nutzer hat deshalb den **inoffiziellen Zugang über die Untis-Mobile-Freigabe** freigegeben (WebUntis → Profil → Freigaben: QR-Code, Benutzer, Schlüssel). In App und Dokumentation als „inoffizieller Zugang über Untis-Mobile-Freigabe“ bezeichnet. Kein Backend für den Abruf durch die App. **Ausnahme seit 08.11.2026 (Nutzerentscheidung):** Für Mitteilungen bei geschlossener App liegt die Freigabe nach ausdrücklicher Einwilligung verschlüsselt auf dem eigenen Server noty-push ([PUSH](PUSH.md)).

Vom Nutzer am 04.11.2026 einmalig erprobt (Daten danach gelöscht): JSON-RPC 2.0 per POST an `https://<server>/WebUntis/jsonrpc_intern.do?m=<methode>&school=<schule>&v=i2.2`, `auth {clientTime (ms), user, otp}`, OTP nach RFC 6238 (SHA-1, 30 s, 6 Ziffern, Schlüssel base32). `getUserData2017` liefert Benutzerelement (`STUDENT`, `elemId`) und Stammdaten (Fächer, Räume, Klassen, Ferien „YYYY-MM-DD“; Lehrkräfte für diese Schüler leer). `getTimetable2017` liefert Perioden mit `id` (je Stunde), `lessonId` (je Kurs), lokalen Zeiten (Europe/Berlin), Elementen mit `orgId` und `is`. Bestätigt ist nur `is = REGULAR` (alle weiteren Werte: §9). Der QR-Inhalt `untis://setschool?url=…&school=…&user=…&key=…&schoolNumber=…` ist community-dokumentiert und wird tolerant gelesen. Die Zuordnung der JSON-RPC-Fehlercodes außer -8520 (-8500 Schule, -8502/-8504/-8998 Anmeldung) und die Wortsuche in Servermeldungen stammen aus Community-Angaben und sind ungeprüft. Die Freigabe kann von der Schule oder Untis jederzeit geändert oder gesperrt werden.

ICS-Dateiimport ist eine einmalige Übernahme; ein Abonnement ist wiederholtes Einlesen einer Quelle. Beides separat benennen. Öffentlich sichtbare WebUntis-Webseiten sind noch kein bestätigter ICS-/API-Zugang. Untis beschreibt öffentliche Pläne als freigegebene Webansichten: [Öffentliche Stundenpläne](https://help.untis.at/hc/de/articles/18077455725340-%C3%96ffentliche-Stundenpl%C3%A4ne).

Untis nennt für iCal bestimmte Benutzer-/Modulvoraussetzungen und standardmäßig einen begrenzten Zeitraum von einer Woche zurück bis zwölf Wochen voraus. Das ist keine vollständige Schuljahreshistorie; verfügbare Felder und Änderungen müssen mit der konkreten Quelle geprüft werden. [Untis iCal-Abonnement](https://help.untis.at/hc/de/articles/360014979580-Wie-funktioniert-das-iCal-Kalender-Abonnement-in-WebUntis)

Die im ursprünglichen Entwurf genannte fehlende iCal-Option an der eigenen Schule ist ein Nutzerhinweis, hier nicht am Konto überprüft. Die offizielle Webservices-Seite nennt ein Zusatzmodul und verweist an den Untis-Partner; sie belegt keinen verfügbaren Zugang für dieses Projekt. [Untis Webservices](https://help.untis.at/hc/de/articles/360015504940-Webservices)

Die Quellenhinweise in diesem Abschnitt stammen aus dem ursprünglichen Entwurf (03.11.2026) und wurden seitdem nicht erneut extern geprüft.

Vor Freigabe eines weiteren direkten Providers: erlaubten Zugang, Beispieldaten, Identitäten, Wiederholungen, Vertretungen/Ausfälle, Zeitabdeckung, Aktualisierung und Limits prüfen. Kein Scraping als angenommener Standardweg. Fach, Raum, Lehrkraft und Ausfallstatus nur anzeigen, wenn die Quelle sie tatsächlich liefert.

### Identitäten und sichere Aktualisierung

- Lokale Ereignisse: eigene stabile UUID. Externe Ereignisse: Verbindung + Quellkalender + Providerkennung; Wiederholungen zusätzlich über die ursprüngliche Durchführung identifizieren. Aktuelle Startzeit oder Titel allein sind kein Schlüssel.
- Für ICS insbesondere `UID`, `RECURRENCE-ID` und Änderungsinformationen berücksichtigen. Bei EventKit die tatsächliche Stabilität der Kennungen bei Verschiebung/Serienänderung prüfen; keine lebenslange Stabilität voraussetzen.
- Antworten vollständig prüfen und nur im bestätigten Quell-/Zeitbereich ersetzen. Timeout, Parsefehler, Teilantwort oder leere Antwort sind keine leere Kalenderliste.
- Ein Termin außerhalb des gleitenden Quellzeitfensters gilt nicht automatisch als gelöscht. Letzten Kontext für verknüpfte Termine als veraltet erhalten, ohne ihn als aktuellen Unterricht auszugeben.
- Keine automatische Zusammenführung anhand gleicher Titel/Uhrzeiten. Gleiche Quelle über EventKit und direktes ICS möglichst nicht doppelt aktivieren; im Zweifel Duplikat anzeigen und Quellenwahl anbieten.
- Beim externen Schreiben Ziel und Schreibbarkeit prüfen, zwischenzeitliche Änderungen berücksichtigen und Providerfehler anzeigen. Eigene Heftdaten bleiben von Schreibkonflikten unabhängig.
- Änderungsmeldungen beruhen nur auf ausdrücklichen Status und neu abgerufenen, von beiden Ständen abgedeckten Tagen: lieber weniger melden als etwas erfinden (App und Server nutzen dieselbe Core-Logik).

## 8. Datenformat, Speicherpfade und feste Schlüssel

Formatdetails: [STORAGE](STORAGE.md) (Kalenderpaket Format 1–4), [LIBRARY-BACKUP](LIBRARY-BACKUP.md) (Archiv Format 3).

- **Kalenderpaket** je Bereich (`<Bereich>` = `Documents/Noty` bzw. `NotyWorkspaces/Areas/<UUID>/Data`): `Calendar/manifest.json`, `manifest-previous.json`, `Revisions/<UUID>.json` (unveränderliche `CalendarState`-Revisionen), `Quarantine/`, `Migration/format-<n>-<Datei>` (exakte Altbytes), `Cache/<Verbindung>.json` (Offline-Stundenplan `CalendarSourceSnapshot` Format 1, optional `homework`). Ein Schreiber: `CalendarRepository` mit `PackageWriteLock`.
- **Kalenderformat (`CalendarState.formatVersion`) aktuell 4:** 1 = B1, 2 = B2 (Serien, Links, Zuordnungen, Fachfarben, Notizordner, Kontokennung), 3 = B3 (Erinnerungen, Unterrichtserinnerung, gelöschte Termine), 4 = Stufe C (`settings.systemCalendars`, Notizziel `system`, `homeworkDone`). Formate 1–3 werden gelesen und beim ersten Commit migriert; Format ≥ 5 sperrt. Ältere Builds sperren neuere Formate (Build 101 sperrt 2, Build 102 sperrt 3, Builds 103–123 sperren 4).
- **Zeitwerte** in Kalenderdateien: Sekunden seit 2001-01-01 UTC (Foundation-Referenzdatum); nur `savedAtUnix` im Manifest ist Unix-Zeit. Ganztägig: zivile Daten, Ende exklusiv.
- **Bibliotheksarchiv** Format 3 mit Datensätzen `calendar` (Kalenderformat 3 oder 4) und optional `calendarSource`; ohne Kalender Format 2.

**Feste Kennungen – nicht ändern** (gespeicherte Daten, Schlüsselbund, geplante Mitteilungen, Server-Verträge und Profile hängen daran; eine Änderung verliert Daten oder erzeugt Doppelte):

| Art | Kennung |
| --- | --- |
| Bundle-IDs | Basis `de.la.noty.calendar`; installiert `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar` (= APNs-Topic); Extension `….de.la.noty.calendar.NotyCalendarWidgets`; Live-Activity-Topic `….de.la.noty.calendar.push-type.liveactivity` |
| Info.plist | `NotyChannel` (`calendar`), `NotyPushURL` (`https://noty.xclipsen.de/push`), `BGTaskSchedulerPermittedIdentifiers` = `de.la.noty.calendar.refresh`, URL-Schema `notycalendar` |
| Schlüsselbund | Dienst `noty.calendar.webuntis` (Konto = Verbindungs-UUID), `noty.calendar.push` (Geräte-ID + Secret); beide `AfterFirstUnlockThisDeviceOnly` |
| UserDefaults | `noty.calendar.sidebar`, `noty.calendar.window.detailsBeside`, `noty.calendar.window.detailsAbove`, `noty.calendar.notifications`, `noty.calendar.notifications.hintDone`, `noty.calendar.push.state`, `noty.calendar.schoolDayActivity`, `noty.calendar.schoolDayActivity.segments` |
| Mitteilungen | geplant `noty.calendar.<Kanal>.<Bereich>.(event\|lesson\|overview).…`; Änderungen `noty.calendar-change.<Kanal>.<Bereich>.change.…`, vom Server `….push.<changeID>`; Thread `noty.calendar.<Bereich>`, Kategorie `noty.calendar.<Art>`; Server-Threads `noty.calendar.changes.<connectionID>`, `noty.calendar.test`; Änderungs-ID `change.<Periode>.<YYYY-MM-DD>.<Arten>.<Beginn>.<Räume>[~n]` |
| Dateien außerhalb des Pakets | `Library/Application Support/CalendarNotifications/<Kanal>.<Bereich>.json` (Verlauf); App Group `group.de.la.noty.shared` (mit `XTL-`-Präfix) › `NotyWidgets/<Kanal>/schoolday.json` |
| Deep Link | `notycalendar://schultag?connection=…&day=…&entry=…` |
| Push-Vertrag | Einwilligung `webuntis-push-1`; API `…/push/v1/{health,register,device,changes}`; `userInfo["noty"]` mit `kind` `change`/`summary`/`auth`/`test`; Live Activity `attributes-type` `SchoolDayAttributes`, `content-state` `v = 1` ([LIVE-ACTIVITY-PLAN](LIVE-ACTIVITY-PLAN.md#json-vertrag-für-noty-push-schritt-2)) |
| Bibliothek | Ordner „Kalendernotizen“ nur über `settings.notesFolderID`, nie über den Namen |
| Server | `/etc/noty-push/config.json`, `data.key`, `apns.p8`; `/var/lib/noty-push/devices/<id>.sealed`; Dienst `127.0.0.1:8795` |

## 9. Offene Punkte

**Belege und Gerätetests**

- **WebUntis-Status außer `REGULAR` real unbestätigt.** Bestätigt ist nur `is = REGULAR`; `CANCELLED`, `IRREGULAR`, `SUBSTITUTION`, `ROOMSUBSTITUTION`, `EXAM` usw. und die Ableitung über `orgId` stammen aus Community-Dokumentation. Liefert die Schule Änderungen anders (z. B. Stunde entfernt statt als Ausfall markiert), zeigen Kalender, Mitteilungen, Push und Kachel weniger, nie etwas Erfundenes. Erste echte Änderung gegen WebUntis im Browser vergleichen (Gerätetest in [CALENDAR-LOG](CALENDAR-LOG.md#ausstehend-gebündelter-gerätetest-für-den-nächsten-build)). Alle anderen Dokumente verweisen hierher.
- Ob WebUntis verschobene Stunden unter derselben Perioden-ID liefert; ob Ferienenden einschließlich sind; Hausaufgaben-Feldnamen an der Schule; Zuordnung der JSON-RPC-Fehlercodes.
- Stabilität der Exchange-/Outlook-Kennungen bei Verschieben und Serienänderung; tatsächliche Konten und Schreibrechte.
- Ferientabelle NRW vor Nutzung mit schulministerium.nrw abgleichen (2027/28, Sommerferien 2028 vorläufig, bewegliche Ferientage fehlen).
- Alle gebündelten Gerätetests in [CALENDAR-LOG](CALENDAR-LOG.md) außer den dort als bestätigt vermerkten Punkten; Designabnahme Stufe A; Abnahmen Stufe B und C.
- Push: echte Änderung über den Server bei geschlossener App, Ruhezeit-Zusammenfassung um 6 Uhr, Abmelden löscht die Serverdatei, Verhalten nach dem Server-Update vom 08.11. ([PUSH](PUSH.md#grenzen-und-risiken)). Live Activity: echter Schultag, Widget, Start ab iPadOS 26 ([LIVE-ACTIVITY-PLAN](LIVE-ACTIVITY-PLAN.md)).
- ⌃⌘S (Kalenderleiste) kann mit einem System-Kürzel für die Seitenleiste kollidieren – ungeprüft ([KEYBOARD](KEYBOARD.md#kalender)).

**Bekannte Grenzen (bewusst)**

- Hintergrundabruf ist nicht garantiert (iPadOS entscheidet; nach Wegwischen in der Regel keiner); ohne Push kommen Änderungen dann erst beim nächsten Öffnen. Nur der geöffnete Bereich benachrichtigt; ein Gerät kann nur eine Verbindung per Push melden lassen.
- Eine Zusatzstunde an einem bisher stundenfreien (oder leer abgerufenen) Tag wird nicht gemeldet.
- Einzelne Termine lassen sich nicht von der allgemeinen Erinnerung ausnehmen (bräuchte ein Feld „keine Erinnerung“ = Formatänderung). Eine eigene Erinnerung einzelner Serientermine gibt es nicht (gilt der Serie).
- Anlegen per Halten und Ziehen: kein direktes Klick-Ziehen mit dem Zeiger ohne Halten; kein automatisches Waagerecht-Scrollen in der schmalen Woche (nur senkrecht im Stundenraster); im Monat nur innerhalb der gezeigten Seite (sechs Wochen), kein Blättern während des Ziehens; Halten auf dem Hinweis „Zeitraum noch nicht geladen“ oder einem Toast über dem Raster kann ebenfalls anlegen (der Erkenner sieht nur die Rasterfläche, nicht, was darüber liegt).
- Jahr: kein senkrechtes Weiterscrollen ins nächste/vorige Jahr.
- Nicht umgesetzt: Ziehen ganztägiger Termine, „Diesen und alle folgenden“, mehrere Notizen je Termin in der Oberfläche (Datenmodell erlaubt sie), Ziehen von Systemterminen, Stundenhöhe-Zoom per Pinch (Vorschlag ab iPadOS 18: senkrechter Pinch = Stundenhöhe, waagerecht = Ansicht).
- Erinnerungen/Überblicke, die außerhalb der App zugestellt und vor dem nächsten Öffnen aus der Mitteilungszentrale gelöscht wurden, fehlen im Verlauf.
- Esc in der Notiz schließt das Terminfenster nicht, wenn der Tastaturmodus für Textdokumente (Helix) aktiv oder die Tastenübersicht offen ist (die Leinwand nimmt Esc); dann ✕.

**Noch zu entscheiden bzw. nachzuziehen**

- Live Activity per Push (Schritt 2), Stufe D, durchgehendes Fachheft – nicht beauftragt.
- [LIBRARY-BACKUP](LIBRARY-BACKUP.md) nennt im Kalenderdatensatz noch Kalenderformat 3; das Archiv trägt seit Build 127 Format 3 oder 4 (Prüfer bereits angepasst).
- Umschalter: Darstellung unter iPadOS 26+ (eigene Kapsel in Glasplatte?) und ob die Markierung beim Inhaltswechsel gleitet oder springt – ungeprüft.
