# noty Kalender – Produkt- und Entwicklungsplan

Stand: 04.11.2026. **Bestätigte Produktplanung. Stufe A (Design und Navigation mit Beispieldaten) ist auf `feat/kalender` implementiert und gebaut; die Designabnahme durch den Nutzer steht aus. Meilenstein B1 (WebUntis über die Untis-Mobile-Freigabe, gespeicherte eigene Einzeltermine, Kalenderpaket je Bereich) ist implementiert, erfolgreich gebaut und als Test-App „noty calendar“ Build 101 veröffentlicht. Meilenstein B2 (echte Terminnotizen als noty-Hefte in „Kalendernotizen“, Zuordnung verschobener Stunden, Wiederholungen, Ziehen/Dauer, Fachfarben, Kalenderformat 2) ist implementiert, erfolgreich gebaut und als „noty calendar“ Build 102 veröffentlicht. Meilenstein B3 (Kalender im Bibliotheksbackup mit Restore in einen neuen Bereich, „Gelöschte Termine“, Erinnerungen, Kalenderformat 3) ist implementiert, erfolgreich gebaut und als „noty calendar“ Build 103 veröffentlicht. Korrekturen aus der unabhängigen Prüfung von B2/B3 sind implementiert, erfolgreich gebaut und als „noty calendar“ Build 104 veröffentlicht ([Review-Korrekturen](#review-korrekturen-build-104-04112026)). Alle diese Builds sind nicht installiert geprüft und am iPad ungeprüft.** EventKit (Stufe C) und Backend (Stufe D) fehlen weiterhin ([B3](#umsetzungsstand-b3-04112026)). Technischer Ausgangsabgleich mit `dev` bei `6524a97`; technische Vorschläge und Quellenhinweise unten bleiben vor der Umsetzung zu prüfen. Dieser Plan erweitert den bisherigen [SCOPE](SCOPE.md).

**Aufträge:** Zunächst nur festgehalten (Bestätigung der Anforderungen, keine Freigabe zum Bauen). Am 03.11.2026 folgte der Umsetzungsauftrag für **Stufe A** (Design zur Ansicht mit fiktiven Daten). Am 04.11.2026 folgte der Auftrag für **Meilenstein B1** von Stufe B (Veröffentlichung nur als Test-App „noty calendar“), am selben Tag der für **Meilenstein B2** (Terminnotizen, Stundenzuordnung, Wiederholungen, Ziehen, Fachfarben; ebenfalls nur „noty calendar“). Ebenfalls am 04.11.2026 folgte der Auftrag für **Meilenstein B3** (Bibliotheksbackup/Restore mit Kalenderdaten, Löschen mit Wiederherstellung, Erinnerungen; nur „noty calendar“). C–D sind nicht beauftragt. Umsetzungsstand: [Stufe A](#umsetzungsstand-stufe-a-03112026), [B1](#umsetzungsstand-b1-04112026), [B2](#umsetzungsstand-b2-04112026), [B3](#umsetzungsstand-b3-04112026).

## 1. Ziel und bestätigte Richtung

Ein nativer Kalender für den Schulalltag, mit der vertrauten Bedienlogik von Apple Kalender und Outlook und der Gestaltung von noty. Schule und Mitschriften haben Vorrang, private Termine sind ebenfalls möglich. Kalenderbeschriftungen und Termine verwenden normale Schrift und Tastatureingabe. Das Kalenderraster selbst ist keine Handschriftfläche; zu einem angeklickten Termin erscheint jedoch eine eigene, direkt beschreibbare Notizseite daneben.

**Bestätigt im Entscheidungsinterview vom 03.11.2026:**

- WebUntis mit Stundennotizen zuerst; eigene lokale Termine ebenfalls bereits in der ersten nutzbaren Version.
- WebUntis soll Unterricht, Fächer, Räume, Lehrkräfte, Vertretungen, Ausfälle und verfügbare Prüfungen liefern. **Quelle seit 04.11.2026 entschieden:** inoffizieller Zugang über die Untis-Mobile-Freigabe (siehe [Abschnitt 7](#webuntis-entscheidung-04112026)); Lehrkräfte liefert die Schule für Schüler nicht. Unterrichtszeiten werden aus WebUntis übernommen; eigene Ergänzungen bleiben Notizen oder separate Termine, keine persönlichen Überschreibungen des Stundenplans.
- Woche als Startansicht, außerdem Monat, Tag und Jahr. Standardwoche Montag bis Freitag, Umschaltung auf sieben Tage; Auswahl merken.
- Beim Öffnen eines Termins sofort eine leere Notizfläche anbieten. Erst die erste tatsächliche Eingabe legt eine gespeicherte Notiz an. Handschrift und Text direkt daneben bearbeiten; bei Bedarf im normalen Editor vergrößern.
- Mit einer festen Seite beginnen, weitere Seiten bei Bedarf ergänzen. Neben dem Termin eine Seite anzeigen und durchblättern lassen. Bei schmalem Fenster/Hochformat ohne ausreichenden Platz große Notizansicht über dem Kalender mit klarer Rückkehr.
- Sobald Inhalt vorhanden ist, am Termin einen sichtbaren Notizhinweis zeigen, unabhängig von Handschrift oder Text. Notizen zusätzlich in der normalen Bibliothek im Ordner „Kalendernotizen“, nach Fach und Datum benannt, erreichbar machen.
- Verschobene Stunden behalten ihre Notizen; ausgefallene Stunden bleiben mit Kennzeichnung und vorhandenen Notizen erreichbar.
- Eigene Termine anlegen, bearbeiten und löschen; tägliche, wöchentliche und monatliche Wiederholungen mit einzelnen Ausnahmen. Bei Änderung/Löschung zwischen einzelnem Termin und gesamter Serie wählen.
- Eigene Termine zusätzlich zum Formular durch längeres Drücken und Ziehen verschieben; Ziehen am unteren Rand ändert die Dauer.
- Automatische, je Fach einheitliche und anpassbare Farben; eigene Termine zunächst mit separater Farbe.
- Erinnerungen optional pro Termin und standardmäßig ausgeschaltet. Zusätzlich allgemeine Unterrichtseinstellung, beispielsweise zehn Minuten vorher.
- Jahresansicht mit zwölf Monaten, markierten Termintagen und Ferien; Antippen öffnet den Tag. Die Ferienquelle ist noch zu bestimmen.
- Später Apple Kalender und Outlook: Termine anzeigen, anlegen, bearbeiten und löschen, Änderungen im jeweiligen Kalender übernehmen und dieselben lokalen Terminnotizen anbieten. Reine Leseanbindung genügt nicht dem bestätigten Zielumfang.
- Später Backend-Synchronisierung eigener Termine einschließlich Notizen, Verknüpfungen und Einstellungen zwischen den eigenen Geräten. Offlinebetrieb bleibt vollständig nutzbar; eine separate Sicherung bleibt erforderlich.
- Ebenfalls später: einzelne Stundennotizen zu einem durchgehenden Fachheft öffnen können. Eine dauerhafte Fachheftzuordnung gehört damit nicht zur ersten Version.

**Beispiel:** „Rechnungswesen · 08:00–09:30“ antippen → daneben eine Notizseite → mit Pencil oder Tastatur schreiben → am Termin erscheint der Notizhinweis. Weitere Seiten hinzufügen oder die Notiz vergrößern; anschließend zum ursprünglichen Termin zurückkehren.

Offlinebetrieb, Datenerhalt und getrennte Bereiche bleiben verbindlich. Konkrete technische Architektur und nicht ausdrücklich bestätigte Bedienungsdetails in den folgenden Abschnitten sind Umsetzungsvorschläge.

## 2. Design als erster Arbeitsschritt

### Aufbau auf dem iPad

- Einstieg „Kalender“ in der bestehenden Navigation neben der Bibliothek; Wechsel erhält den zuletzt geöffneten Heftkontext.
- Dunkle noty-Bedienelemente, bestehende native Materialien und dezente Trennlinien. Die Kalenderfläche ist eine ruhige App-Oberfläche, kein weißes Papierblatt.
- Native Systemschrift, deutsche Beschriftungen, 24-Stunden-Zeit, Montag als Wochenbeginn und ISO-Kalenderwochen. Dynamic Type und VoiceOver berücksichtigen.
- Oben: Seitenleistensteuerung, Datum/Zeitraum, zurück/vor, „Heute“, Umschaltung „Jahr · Monat · Woche · Tag“, Suche und „+“.
- Links bei ausreichender Breite: kleiner Monatskalender und auswählbare Kalender mit Farbpunkten. Bei schmalem Fenster einklappbar.
- Mitte: Kalenderansicht. Daneben bei ausreichender Breite Termindetails und direkt bearbeitbare Notizseite. Bei Platzmangel große Notizansicht über dem Kalender mit klarer Zurück-Schaltfläche. Keine erzwungene Dreispaltenansicht auf kleinem Platz.
- Systemblau für Auswahl und Aktionen; Automatische, anpassbare Fachfarben dienen der Zuordnung; eigene Termine erhalten zunächst eine separate Farbe. Lesbarkeit und Kennzeichnungen dürfen nicht allein von Farbe abhängen.
- Touchziele grundsätzlich mindestens 44 pt; Hardwaretastatur und Finger bedienbar. Im Kalenderraster keine Stiftpalette, Lineatur, Lasso- oder Zeichenmodi; auf der daneben geöffneten Notizseite gelten die normalen Editorwerkzeuge.

### Ansichten

**Woche als bestätigter Start:** standardmäßig fünf Tagesspalten Montag bis Freitag, auf sieben Tage umschaltbar und Auswahl gemerkt; fixierte Tagesköpfe, separate Ganztagszeile und vertikal scrollbares Stundenraster. Initial zum aktuellen Tagesabschnitt scrollen, aber alle 24 Stunden erreichbar halten. Überlappende Termine nebeneinander; Beginn, Ende, Titel und optional Raum sichtbar. Heute dezent hervorheben, aktuelle Uhrzeit als Linie.

**Monat:** sieben Spalten, Termine als kompakte beschriftete Zeilen. Begrenzten Platz mit „+ n weitere“ kennzeichnen; Öffnen zeigt die vollständige Tagesliste. Ein Fingertipp auf das Datum öffnet den Tag. Kein stilles Abschneiden von Terminen.

**Tag:** breiter Stundenplan mit Ganztagszeile, gleichen Terminkarten und mehr Detailplatz. In schmalen Fenstern bleibt diese Ansicht vollständig bedienbar; Wochenansicht darf horizontal scrollen und darf nicht unbemerkt den ausgewählten Ansichtsmodus wechseln.

**Jahr:** zwölf kompakte Monate mit markierten Termintagen und Ferien. Antippen eines Tages öffnet die Tagesansicht. Ferien nur aus einer noch festzulegenden Quelle darstellen; fehlende Daten nicht als Ferienfreiheit ausgeben.

Termin mit tatsächlichem Notizinhalt erhält ein kleines Notizsymbol, unabhängig davon, ob Handschrift oder Text enthalten ist. Nur das Öffnen einer leeren Notizfläche erzeugt keinen Hinweis. Titel und Uhrzeit bleiben wichtiger als Vorschaugrafiken. Monats-/Wochenwechsel per Schaltflächen; Wischgesten gegen Scrollen und das bestätigte Drag-and-drop prüfen.

### Termindetails

Reihenfolge: Titel → Datum/Uhrzeit oder ganztägig → Kalender → Ort → Beschreibung → Abschnitt „Notizen“. Bearbeiten und Löschen nur bei schreibbaren Terminen. Kalenderquelle und schreibgeschützter Zustand erkennbar.

Die Notizseite ist direkt neben dem Termin beschreibbar, ohne vorgeschalteten Knopf „Notizen anlegen“. Eine leere Fläche ist zunächst nur UI-Zustand: kein gespeichertes leeres Heft je angezeigtem oder geöffnetem Termin. Ab erster tatsächlicher Eingabe wird ein gewöhnliches noty-Heft mit zunächst einer festen Seite gespeichert und dem Termin zugeordnet. Weitere Seiten sind ergänzbar und neben dem Termin durchblätterbar.

„Vergrößern“ öffnet die Notiz im normalen Editor, mit klarer Rückkehr zu Termin und Datum. Bei schmalem Fenster und unzureichendem Platz erscheint die Notiz groß über dem Kalender. Die normale Bibliothek enthält die Notizen zusätzlich im Ordner „Kalendernotizen“, mit Fach bzw. Termintitel und Datum, beispielsweise „Rechnungswesen · 03.11.2026“; Titel bleiben änderbar.

Das Verknüpfen bestehender Hefte oder Zielseiten und die Darstellung mehrerer Heftlinks bleiben ergänzende Vorschläge, keine Voraussetzung des bestätigten Erstumfangs. Durchgehende Fachhefte aus Stundennotizen sind für später vorgemerkt.

### Erste Designabnahme

Mit ausschließlich fiktiven Daten die folgenden Zustände zeigen und abstimmen: gefüllte Fünf-/Siebentagewoche, Monat mit Terminüberlauf, Tag, Jahr, Termindetails mit leerer und beschriebener Notizseite, zusätzliche Notizseiten, Vergrößern/Rückkehr, Terminformular mit Wiederholungen/Erinnerungen, leere Ansicht, schmaler Split-View-Ausschnitt, Ausfall mit Notiz und schreibgeschützter WebUntis-Termin. Erst danach die vollständige Terminlogik integrieren.

## 3. Lieferumfang und Reihenfolge

Häkchen = implementiert und erfolgreich gebaut, **nicht** am iPad getestet. Stufe A und die Punkte von Stufe B mit Häkchen sind umgesetzt; Stufen C–D sind **geplant und nicht umgesetzt**.

### Stufe A – Kalenderdesign und Navigation, Umsetzungsauftrag vom 03.11.2026

- [x] Native Ansichten und Termindetails gemäß Abschnitt 2 mit ausschließlich fiktiven Beispielen.
- [x] Jahr, Monat, Woche, Tag, Heute und Datumsauswahl; Fünf-/Siebentageumschaltung.
- [x] Direkt beschreibbare Notizseite, Inhaltsindikator, zusätzliche Seiten sowie Vergrößern und Rückkehr gestalten (Entwurf, Inhalt nur im Speicher).
- [ ] Hoch-/Querformat, kleine Fenster, Tastatur und große Schrift berücksichtigen. Im Code berücksichtigt (Breitenregeln, Overlay, waagerechtes Scrollen, ⌘-Kürzel, Dynamic Type, VoiceOver-Beschriftungen), am iPad **ungeprüft**.
- [ ] Gestaltung und Weg „Termin → daneben schreiben → vergrößern → zurück“ vom Nutzer abnehmen lassen. **Offen.**

**Abnahme:** Bestätigung des konkreten Designs, noch kein Nachweis dauerhafter Speicherung.

#### Umsetzungsstand Stufe A (03.11.2026)

Branch `feat/kalender` (vom Stand `dev` @6524a97). **Implementiert, Core-Tests bestanden (1110 ausgeführt, davon 13 neu in `CalendarLayoutTests`, 0 Fehler, 4 umgebungsbedingt übersprungen), iPad-SDK-Build (`xtool dev build`, unsigniert) erfolgreich ohne Warnungen in den neuen Dateien; nicht installiert, am iPad ungeprüft, Designabnahme offen.**

- **Einstieg:** Zeile „Kalender“ in der Bibliotheksleiste unter „Zuletzt verwendet“. Die Detailspalte zeigt dann den Kalender mit eigener Werkzeugleiste; Namenssuche, Bearbeiten-Modus und Ablegen gehören nur zur Sammlung. Bibliotheksleiste, angeheftete Einträge und Baum bleiben sichtbar; ein dort geöffnetes Heft kehrt beim Schließen in den Kalender zurück. Ansicht, Datum, Auswahl und Entwurfsnotizen bleiben beim Wechsel Kalender ↔ Bibliothek erhalten (Modell lebt mit der Bibliothek, pro Bereich neu). Im Kalender wird ⌘N zu „Neuer Termin …“.
- **Kopf:** Zeitraum („KW 45 · 2.–6. November 2026“), zurück/vor, „Heute“, Hinweis „Beispieldaten · nichts wird gespeichert“. Werkzeugleiste: Kalenderleiste ein/aus, Segmente „Jahr · Monat · Woche · Tag“, in der Woche „5 Tage/7 Tage“ (gemerkt in `noty.calendar.weekDays`), Suche, „+“.
- **Woche/Tag:** feste Tagesköpfe (Antippen öffnet den Tag), Ganztagszeile mit Bahnen (nichts abgeschnitten), 24-Stunden-Raster, beim Öffnen zur aktuellen Stunde gescrollt (sonst 07:00), heute rot markiert, rote Linie mit Uhrzeit, Überschneidungen nebeneinander. Karten: Titel, Zeit, Raum, Status in Text und Symbol (Ausfall zusätzlich durchgestrichen und schraffiert), Notizsymbol. Zu schmale Spalten scrollen waagerecht, die Ansicht wechselt nie selbst. Tag mit mehr Detail (Lehrkraft, Vertretung, Beschreibung).
- **Monat:** sieben Spalten mit KW, kompakte Zeilen; was nicht passt, zählt „+ n weitere“ (öffnet die vollständige Tagesliste mit „Tag öffnen“). Datum antippen öffnet den Tag. Bei großer Schrift behalten Zeilen ihre Mindesthöhe und scrollen.
- **Jahr:** zwölf Monate mit 44-pt-Tagen, Punkt für Termintage, Band für Beispielferien mit Legende „Ferien (Beispiel – keine echte Ferienquelle)“. Tag antippen öffnet den Tag, Monatsname den Monat.
- **Linke Leiste** (nur mit genug Platz, einklappbar, `noty.calendar.panel`): Minimonat mit markiertem Zeitraum, Kalender mit Farbpunkten, Herkunft und Schloss für schreibgeschützte, ein-/ausblendbar; Schalter „Beispieldaten anzeigen“ für die leere Ansicht.
- **Termindetails:** Titel → Datum/Uhrzeit → Kalender (mit Herkunft) → Ort → Lehrkraft/Vertretung → Wiederholung/Erinnerung → Beschreibung → „Notizen“. Schreibgeschützte WebUntis-Beispiele mit Kennzeichnung; „Bearbeiten“/„Löschen“ nur bei eigenen Terminen. Löschen fragt bei Serien nach einzelnem Termin oder Serie, blendet nur in der Sitzung aus und bietet „Rückgängig“.
- **Notizseite:** A4-Seite in festen Seitenkoordinaten neben den Details, direkt beschreibbar (PencilKit-Stift schwarz, Finger und Pencil) oder umschaltbar auf „Tippen“; Seite x von n, blättern, Seite hinzufügen. Erst echter Inhalt setzt den Notizhinweis, das bloße Öffnen nicht. „Vergrößern“ zeigt dieselbe Seite groß mit „Zurück zu <Termin> · <Datum>“. Schmales Fenster: Details und Seite groß über dem Kalender mit „‹ Kalender“.
- **Formular:** Titel, Ort, ganztägig, Beginn/Ende (24 h, ungültige Spanne wird erklärt und gesperrt), Kalender „Persönlich“, Wiederholung täglich/wöchentlich/monatlich mit Ende (nie, Datum, Anzahl) und Ausnahmen, Erinnerung standardmäßig aus, Beschreibung. Bei Serien fragt „Fertig“ nach einzelnem Termin oder Serie. Nichts wird gespeichert.
- **Tastatur:** ⌘← / ⌘→ zurück/vor, ⌘T Heute, ⌘1–⌘4 Tag/Woche/Monat/Jahr, ⌘N neuer Termin, Esc schließt Details bzw. Großansicht. Kalenderkürzel ruhen, solange ein Heft oder ein Kalenderdialog darüber liegt.

**Vereinfachung Build 100 (04.11.2026)** nach Nutzerrückmeldung zu Build 99 („noch so überfüllt … schlanker, Design verfeinern“). **Implementiert, `CalendarLayoutTests` bestanden (13, 0 Fehler), iPad-SDK-Build erfolgreich ohne Warnungen in den Kalenderdateien, als noty calendar Build 100 veröffentlicht; nicht installiert geprüft, am iPad ungeprüft.** Die Punkte „Kopf“ und „Linke Leiste“ oben sind damit überholt:

- **Kopf und Werkzeugleiste:** nur ruhiger Zeitraum („November 2026“, über Monatsgrenzen „Okt. – Nov. 2026“, Tag „3. November 2026“; neues `CalendarText.headline`, genauer Zeitraum mit KW bleibt für VoiceOver), ‹ Heute ›, Ansichtsumschalter „Tag · Woche · Monat · Jahr“ (Segmente, im schmalen Fenster ein Menü), „…“ und „+“. Der Hinweis „Beispieldaten“ steht nicht mehr im Kopf.
- **Ein Menü „…“:** Wochentage Mo–Fr/ganze Woche (weiter gemerkt), Termine suchen, Kalender ein-/ausblenden (Stundenplan/Ferien als schreibgeschützt bezeichnet), „Beispieldaten anzeigen“ mit Entwurfshinweis.
- **Linke Leiste entfernt** (Minimonat und Kalenderliste); Kalenderfilter im Menü, Datumsnavigation über ‹ › und Jahr/Monat.
- **Woche/Tag:** kompakte Tagesköpfe „Mo 3“, heute als rote Zahl im Kreis, leisere Stundenbeschriftung und Haarlinien, Ganztagszeile nur bei ganztägigen Terminen, dünnere Zeitlinie (1 pt). Karten: farbiger 3-pt-Streifen und schwache Tönung statt gefüllter Blöcke, kein Rahmen außer Auswahl (Blau); Titel und Zeit, Status oder Raum nur, wenn es neben die Zeit passt; Status als Symbol, Ausfall zusätzlich durchgestrichen und abgeblendet (Schraffur entfällt).
- **Monat:** höchstens drei Zeilen je Tag einschließlich „+ n weitere“, Punkt + Titel, Uhrzeit nur bei genug Breite; KW leise in schmaler Spalte, keine Wochenendtönung.
- **Jahr:** ohne Kachelhintergründe, kleinere Ziffern bei weiter 44-pt-Tagen, Legende unten.
- **Termindetails:** Kopf mit Titel, Datum · Zeit, Raum · Lehrkraft, Kalender mit Herkunft und Schloss; Status, Wiederholung, Erinnerung und Beschreibung nur bei Inhalt („Keine Erinnerung“ entfällt). Bearbeiten/Löschen in einem „…“-Menü in der Kopfzeile (nur eigene Termine). Notizseite als Hauptelement; eine Zeile darüber mit Stift/Tippen, Blättern (nur bei mehreren Seiten, „1/2“), Seite hinzufügen und Vergrößern. Großansicht mit Zurück-Schaltfläche und denselben Steuerungen in einer Zeile.
- **Formular:** ohne Abschnittstitel, Ausnahmen hinter „Ausnahmen“ aufklappbar, Ende der Wiederholung nur bei gewählter Wiederholung, Hinweise gekürzt; Kalender und Beschreibung zusammen.

**Nur Entwurf (bewusst, Stufe B):** Termine, Notizen, gelöschte Termine und Formulareingaben leben nur im Speicher; kein Heft, keine Ablage in „Kalendernotizen“, kein Backup. Die Notizseite ist kein noty-Editor (keine Werkzeugleiste, kein Undo, ein schwarzer Stift); „Vergrößern“ öffnet noch nicht den normalen Editor. Kein Ziehen/Verschieben von Terminen, keine Wischgesten, keine echte Wiederholungslogik, keine Benachrichtigungen.

**Beispieldaten:** `Sources/Noty/CalendarSampleData.swift`, frei erfunden (Fächer wie Rechnungswesen, Räume, Lehrkräfte, Ferienzeiträume). Die Woche von „heute“ enthält die Designfälle: beschriebene Rechnungswesen-Notiz mit zwei Seiten, Ausfall mit Notiz, Vertretung, Prüfung, Überschneidung, voller Freitag für „+ n weitere“, ganztägiger und mehrtägiger Termin, wöchentliche eigene Serie.

**Code:** Core `CalendarLayout.swift` (ISO-Kalender `de_DE`, Wochen- und Monatsraster, Überlappungsspalten, Ganztagsbahnen, „+ n weitere“, stabile Fachfarben, deutsche Titel/Uhrzeit, alles über `Calendar`-Operationen) mit `CalendarLayoutTests` (Sommerzeit Berlin, Tage ohne Mitternacht in Santiago/Havanna, KW 1/53, Schaltjahr, Jahreswechsel). App: `CalendarView`, `CalendarWeekView`, `CalendarMonthView`, `CalendarEventDetail`, `CalendarEventForm`, `CalendarSampleData`; in `LibraryView` nur Ort `.calendar`, Leistenzeile und Detailweiche, in `NotyCommands` ⌘N.

**Für die Designabnahme zu entscheiden:** Kalender als Ort in der Bibliotheksleiste oder eigener Umschalter; Farbe für „heute“ (jetzt Rot wie Apple Kalender, Blau bleibt Auswahl); kompakte Monatszeilen und Minimonat unter 44 pt Höhe; Breitenregel für Details neben dem Kalender (jetzt ab 860 pt Detailspalte; auf dem iPad Pro 11″ quer passt das auch mit Bibliotheksleiste); Stift-/Tippen-Umschalter der Entwurfsseite gegenüber dem späteren Editorverhalten.

**Gerätetest (gebündelt, alles ungeprüft),** in noty calendar: (1) Kalender öffnen, Woche 5/7 im Menü „…“ umschalten, App neu starten, Wahl bleibt; zurück/vor/Heute, ⌘-Kürzel. (2) Monat mit „+ n weitere“ am Freitag, Tagesliste, Datum → Tag. (3) Jahr: Tag und Monat antippen, Ferienband. (4) Rechnungswesen Di 08:00 antippen, Seite 2 blättern, auf leerer Seite eines anderen Termins schreiben → Notizsymbol erscheint; Vergrößern, schreiben, zurück: Strich auch in der kleinen Seite. (5) Split View/Hochformat: Overlay mit „‹ Kalender“, Woche scrollt waagerecht. (6) Große Schrift, VoiceOver auf Karten und Tagen. (7) Formular mit Wiederholung, Ausnahme, Erinnerung; Serie löschen und Rückgängig. (8) Aus dem Kalender ein Heft über die Leiste öffnen und schließen: Kalender bleibt.

### Stufe B – Erste nutzbare Version: WebUntis, lokale Termine und Stundennotizen

- [x] Verfügbaren, erlaubten WebUntis-Zugang und nötigenfalls ein Backend dafür technisch klären. Entschieden und vom Nutzer am 04.11.2026 einmalig erprobt: Untis-Mobile-Freigabe, kein Backend ([Abschnitt 7](#webuntis-entscheidung-04112026)). Der App-Anschluss (B1) ist am iPad **ungeprüft**.
- [ ] Unterricht mit tatsächlich verfügbaren Fach-, Raum-, Lehrkraft-, Vertretungs-, Ausfall- und Prüfungsdaten anzeigen; Zeiten aus der Quelle übernehmen, eigene Ergänzungen getrennt halten. B1: implementiert und gebaut (Status außer „REGULAR“ unbestätigt), am iPad ungeprüft.
- [ ] Bereichsbezogener Offlinebestand mit sichtbarem Datenstand und geladenem Zeitraum. Verschobene/ausgefallene Stunden und ihre Notizen sicher zuordnen und erhalten. B1: Offlinebestand, „Stand“ und „Zeitraum noch nicht geladen“; B2: Notizen über Perioden-ID, „ungeklärt“ mit Auswahl aus demselben Kurs, gespeicherte Zuordnung – implementiert und gebaut, am iPad ungeprüft (ob WebUntis verschobene Stunden unter derselben ID liefert, ist unbestätigt).
- [x] Eigener lokaler Kalender ohne erforderliches Kalenderkonto bzw. Systemkalenderberechtigung, zunächst „Persönlich“. B1: implementiert und gebaut, am iPad ungeprüft.
- [x] Eigene Termine anlegen, bearbeiten, löschen; Titel, Ort, Beschreibung, Beginn/Ende, ganztägig und mehrtägig. Duplizieren bleibt ein ergänzender Vorschlag. B1: implementiert und gebaut (Einzeltermine), am iPad ungeprüft.
- [x] Tägliche, wöchentliche und monatliche Wiederholungen, Serienende und einzelne Ausnahmen; Änderung/Löschung für einzelnen Termin oder gesamte Serie. B2: implementiert und gebaut, am iPad ungeprüft.
- [x] Verschieben und Daueränderung per Formular sowie durch längeres Drücken/Ziehen bzw. Ziehen am unteren Rand; ungültige Zeitspannen verständlich ablehnen. Gilt für schreibbare eigene Termine, nicht für WebUntis-Unterricht. B2: implementiert und gebaut (zeitgebundene Termine in Woche/Tag), am iPad ungeprüft – Gestenverhalten im Raster ist das größte Risiko.
- [ ] Alle vier Ansichten aus denselben Daten, stabile Navigation, letzte Ansicht und Fünf-/Siebentagewahl pro Bereich merken. Ferienquelle für die Jahresansicht bestimmen.
- [x] Direkt bearbeitbare Terminnotiz, persistente Anlage erst ab tatsächlicher Eingabe, weitere Seiten, Notizhinweis, Vergrößern/Rückkehr und Bibliotheksablage unter „Kalendernotizen“. B2: implementiert und gebaut, am iPad ungeprüft.
- [x] Einheitliche anpassbare Fachfarben und separate Farbe für eigene Termine. B2: implementiert und gebaut, am iPad ungeprüft.
- [x] Optionale Erinnerungen pro Termin, standardmäßig aus; zusätzliche allgemeine Unterrichtseinstellung. Berechtigung und Herkunft erkennbar machen, doppelte Benachrichtigungen vermeiden. B3: implementiert und gebaut, am iPad ungeprüft (Zustellung und Berechtigungsdialog unbelegt).
- [x] Sichere Speicherung, Fehleranzeige, lokale Wiederherstellung sowie vollständiges Bibliotheksbackup mit Kalenderdaten, Notizen und Verknüpfungen. B1–B3: implementiert und gebaut (Bibliotheksarchiv Format 3, Restore in neuen Bereich, Swift- und Python-Prüfer, Host-Roundtrip); Restore am iPad ungeprüft.
- [x] Terminlöschung mit Rückgängig-/Wiederherstellungsweg; Notizen bleiben erhalten. B3: „Gelöschte Termine“ (dauerhaft, im Backup) zusätzlich zu „Rückgängig“; implementiert und gebaut, am iPad ungeprüft.

#### Umsetzungsstand B1 (04.11.2026)

Branch `feat/kalender`. **Implementiert; Core-Tests bestanden (siehe [Nachweise](#nachweise-b1)); iPad-SDK-Build (`xtool dev build`) erfolgreich ohne Warnungen in den Kalenderdateien; als „noty calendar“ Build 101 veröffentlicht. Nicht installiert geprüft, am iPad ungeprüft, WebUntis-Anschluss aus der App ungeprüft.**

- **Kalenderpaket je Bereich:** `<Bereich>/Calendar/` mit genau einem Schreiber (`CalendarRepository`, Prozesssperre `PackageWriteLock`), unveränderlichen vollständigen Revisionen, geprüftem Zurücklesen, vorherigem Manifest und Manifest zuletzt; ältere Saves ersetzen keine neueren (Revisionszähler), fremde Commits werden erkannt; unbekannt neueres Format oder Paket ohne lesbare Revision sperrt das Schreiben statt leer zu starten; beschädigte neueste Revision/Manifest → älterer geprüfter Stand mit Hinweis, beschädigte Dateien bleiben. Bestätigter Stand: eigene Termine, Einstellungen (5/7 Tage, letzte Ansicht – jetzt pro Bereich statt `noty.calendar.weekDays`), Verbindungseintrag ohne Geheimnisse. Format: [STORAGE](STORAGE.md#ergänzung-04112026--kalenderpaket-b1).
- **Eigene Termine („Persönlich“):** anlegen, bearbeiten, löschen (mit „Rückgängig“ in der Sitzung, gleiche ID); zeitgebunden mit Zeitzonenkennung oder ganztägig/mehrtägig mit zivilen Daten und exklusivem Ende. Das Formular schließt erst nach dem Commit; ein Schreibfehler zeigt „Nicht gespeichert … Erneut speichern“ und hält die Änderung im Speicher. Wiederholungen und Erinnerungen sind im Formular ausgeblendet und dort als „folgen in einem späteren Build“ genannt.
- **WebUntis (inoffiziell):** Menü „…“ → „WebUntis verbinden …“: QR-Code scannen (VisionKit `DataScannerViewController`, `NSCameraUsageDescription`) oder Server, Schule, Benutzer, Schlüssel von Hand; „Verbindung testen“ (nur lesen), „Verbinden“ (nur nach erfolgreichem Test; Zugangsdaten nur im Schlüsselbund, `…ThisDeviceOnly`), „Aktualisieren“, „Mit anderer Freigabe verbinden“, „Trennen“ (Zugangsdaten und Offline-Stundenplan weg, eigene Termine und Notizen bleiben). Aktualisierung beim Öffnen des Kalenders, bei App-Aktivierung und während der Kalender sichtbar ist höchstens alle 15 Minuten, sonst nur von Hand; Standardfenster eine Woche zurück bis fünf Wochen voraus, der angezeigte Zeitraum über „Laden“.
- **Anzeige:** Unterricht schreibgeschützt (Schloss in Karte, Liste, Details) mit Fach, Raum, Klasse; Lehrkräfte nur, wenn geliefert. Status best effort: Ausfall, Prüfung, Änderung/Vertretung, Raumänderung (aus `is` und `orgId` ≠ `id`), unbekannte Status neutral als „Hinweis: unbekannter WebUntis-Status …“. Ferien aus den WebUntis-Stammdaten in Jahr/Monat/Woche (Ende als einschließlich angenommen, am Gerät prüfen). Unter dem Titel eine leise Zeile „Stundenplan aus WebUntis · Stand: heute 07:12“, bei Fehlern „Aktualisierung fehlgeschlagen: … · Stand …“ mit „Erneut“; nicht geladene Zeiträume zeigen „Zeitraum noch nicht geladen“ mit „Laden“ statt „keine Termine“.
- **Beispieldaten:** nur noch als ausdrücklicher Schalter „Beispieldaten anzeigen“ (Standard aus); dann ausschließlich erfundene Einträge, „+“ gesperrt, nichts bearbeitbar oder gespeichert.
- **Notizen:** weiterhin nur im Speicher (Stufe-A-Entwurf), sichtbar gekennzeichnet „Notizen werden noch nicht gespeichert – ab dem nächsten Build“.

**Nicht in B1:** echte Terminhefte/Links/„Kalendernotizen“, Wiederholungen, Ziehen/Dauer, Fachfarben anpassen, Erinnerungen, Kalender im Bibliotheksbackup und Python-Prüfer, EventKit. Das Bibliotheksbackup enthält `Calendar/` **nicht**; ein Restore-Bereich hat daher keinen Kalender. Verschobene Stunden werden über Perioden-ID + gelieferten Beginn identifiziert; eine Zuordnungstabelle für Notizen folgt mit B2.

##### Nachweise B1

- Core: `CalendarRepositoryTests` (12) und `WebUntisTests` (11), nur erfundene Daten: Rundlauf, ältere Saves, Schreibfehler an zwei Commitstufen, unbekannt neueres Revisions-/Manifestformat sperrt ohne Dateiänderung, beschädigte Revision/Manifest → älterer Stand und Quarantäne, Paket ohne Revision sperrt, zweiter Schreiber (Sperre und fremdes Manifest), Cache getrennt/ersetzbar/an Verbindung gebunden, beschädigter und neuerer Cache; QR-Parsing tolerant, ungültige Freigaben, TOTP nach RFC-6238-Vektoren, Anfragekörper, Stammdaten/Ferien, Statusabbildung, Sommer-/Winterzeit, Teil-/Fehlerantworten werden abgelehnt statt leer, Abdeckung „nicht geladen“ ≠ „kein Unterricht“, spätere ältere Antwort ersetzt keine neueren Tage, Größenbegrenzung.
- iPad-SDK-Build erfolgreich; `scripts/ota_check.py` beim Veröffentlichen bestanden (nur neuer Info.plist-Schlüssel `NSCameraUsageDescription`, keine neue Berechtigung).
- **Ungeprüft:** Installation, jeder Gerätelauf, Netzwerkzugriff aus der App, Schlüsselbund, Kamera/QR, Darstellung echter Daten, Ferienenden, alle Status außer „REGULAR“.

**Gerätetest B1 (gebündelt, in noty calendar):** (1) Menü „…“ → „WebUntis verbinden …“ → QR-Code der Freigabe scannen → „Verbindung testen“ → „Verbinden“; eigene Stunden der Woche erscheinen mit Schloss, Raum und Fach, „Stand: heute …“. (2) Monat/Jahr: Ferien erscheinen an den richtigen Tagen (Ende!). (3) Mehrere Wochen vor blättern → „Zeitraum noch nicht geladen“ → „Laden“. (4) Flugmodus, App beenden und neu starten: Stundenplan der geladenen Wochen mit altem „Stand“, „Aktualisieren“ zeigt einen Fehler, kein leerer Plan. (5) Eigenen Termin anlegen (zeitgebunden und ganztägig über zwei Tage), bearbeiten, App neu starten: Termin bleibt; löschen, „Rückgängig“, neu starten. (6) 5/7 Tage und Ansicht wechseln, neu starten: bleibt. (7) Testbereich wechseln: dort kein Kalender des Hauptbereichs. (8) „Trennen“: Unterricht und Ferien verschwinden, eigene Termine bleiben; erneut verbinden geht. (9) Ausfälle/Vertretungen/Prüfungen, sobald WebUntis welche zeigt, mit der WebUntis-App vergleichen.

#### Umsetzungsstand B2 (04.11.2026)

Branch `feat/kalender`. **Implementiert; Core-Tests bestanden (vollständige Suite 1148 ausgeführt, 3 umgebungsbedingt übersprungen, 0 Fehler; davon 15 neu in `CalendarB2Tests`); iPad-SDK-Build (`xtool dev build`) erfolgreich ohne Warnungen in den geänderten Dateien; als „noty calendar“ Build 102 veröffentlicht. Nicht installiert geprüft, am iPad ungeprüft.**

- **Terminnotizen (echte Hefte):** Neben dem Termin steht der normale noty-Editor (`ContentView` eingebettet: Stifte, Text, Undo, Werkzeugleiste, weitere Seiten) – kein zweites Notizformat. Ohne Notiz ist die Seite nur im Speicher; erst die erste echte Eingabe (Handschrift, Text, Bild oder Form) legt ein gewöhnliches Heft an (eine Seite, Standardaussehen der Einstellungen): zuerst das Heftpaket vollständig committen, dann in die Bibliothek (Ordner „Kalendernotizen“, per ID, fehlt er → neu), dann den Link committen (Regel 8). Eingaben während der Anlage landen im selben Editor und im nächsten Autosave; ein Fehler zeigt „Erneut“ und setzt mit demselben Heft fort. Titel „Fach-Langname bzw. Termintitel · TT.MM.JJJJ“ (doppelte Stunde: eindeutiger Zusatz), umbenennbar. Zeile über der Seite: Zustand in Worten („Schreiben legt die Notiz an“, „Wird angelegt …“, „In „Kalendernotizen““), ‹ 1/2 ›, Seite hinzufügen, vorhandene Notiz verknüpfen (nur ohne Link), Vergrößern. Der Hinweis „Notizen werden noch nicht gespeichert“ ist entfernt.
- **Notizhinweis** nur, wenn das verknüpfte Heft Inhalt hat und in der Bibliothek liegt. **Fehlendes Ziel:** Papierkorb → Hinweis mit „Wiederherstellen“ und „Verknüpfung lösen“; endgültig gelöscht → Hinweis, kein anderes (auch kein gleichnamiges) Heft. Keine Kaskade: Termin/Serie löschen, Trennen oder Link lösen lassen das Heft stehen.
- **Vergrößern:** gespeicherte Notiz → die Sitzung wird committet und geschlossen, dann öffnet das Heft im normalen Vollbild-Editor der Bibliothek mit „Zurück zu <Termin> · <Datum>“; danach erscheint die Notiz wieder neben dem Termin. Noch nicht angelegte Notiz → dieselbe Seite groß über dem Kalender. Schmales Fenster: Details und Notiz groß über dem Kalender mit „‹ Kalender“ (wie B1).
- **Ein Schreiber:** Die Notiz neben dem Termin hält die Schreibsperre ihres Hefts; vor jedem Öffnen eines Hefts aus der Bibliothek, beim Verlassen des Kalenders, beim Terminwechsel und vor einem Bereichswechsel wird sie committet und freigegeben. Was nicht committen kann, bleibt im Speicher und wird beim nächsten Öffnen wiederverwendet.
- **WebUntis-Zuordnung:** Stundennotizen hängen an der Perioden-ID (plus Kurs-ID, ursprünglichem Datum und Beginn als Kontext) und an einer geheimnisfreien Kontokennung, sodass dieselbe Freigabe nach Trennen/Neuverbinden ihre Notizen wiederfindet. Gleiche ID zu anderer Zeit oder als Ausfall → Notiz folgt. Fehlt die Stunde an einem geladenen Tag → Eintrag „Ungeklärt“ an der alten Zeit mit Vorschlägen nur aus demselben Kurs (±14 Tage); erst die Auswahl speichert eine Zuordnung. Nicht geladener Tag → Eintrag „Stunde nicht im Offline-Stundenplan“. Nie Zusammenführung über Titel.
- **Wiederholungen:** täglich/wöchentlich/monatlich; Ende nie, nach Anzahl (1–999) oder am Datum; Ausnahmen im Formular. „Nur dieser Termin“ (eigener geänderter Termin) oder „Alle Termine der Serie“ beim Bearbeiten, Löschen und Ziehen; Änderungen an Wiederholung/Ausnahmen gelten immer der Serie. Monatlich am 29.–31. entfällt in kürzeren Monaten (Hinweis im Formular). Wandzeit bleibt über die Sommerzeit. Expansion um das angezeigte Jahr, höchstens 500 Termine je Serie; Überschreitung steht in der Statuszeile. Die Notiz eines einzelnen Termins gehört nur zu ihm; Serienänderungen nehmen Termin-Notizen mit (Verschiebung um Tage, Einzeltermin ↔ Serie über den ersten Termin).
- **Ziehen/Dauer** (eigene zeitgebundene Termine in Woche/Tag): lange drücken und ziehen, Raster 15 Minuten (Woche, auch auf andere Tage) bzw. 5 Minuten (Tag), Uhrzeit-Vorschau; ausgewählt erscheint ein Griff am unteren Rand für die Dauer. Unter 5 Minuten oder ungültige Spannen werden mit Hinweis abgelehnt. Serien fragen nach dem Loslassen. „Rückgängig“-Banner. VoiceOver-Aktionen „15 Minuten früher/später/länger/kürzer“, „Einen Tag früher/später“. Ganztägige Termine, WebUntis, Ferien und Beispiele sind nicht ziehbar.
- **Fachfarben:** automatisch und stabil je Fach (WebUntis-Fach-ID, sonst Name), änderbar über das Palettensymbol in den Stundendetails oder „…“ → „Fachfarben …“; gespeichert in den Kalendereinstellungen. Eigene Termine grün, Ferien grau; Status weiter mit Symbol/Text.
- **Format 2:** siehe [STORAGE](STORAGE.md#ergänzung-04112026--kalenderpaket-format-2-und-terminnotizen-b2); B1-Pakete werden migriert (exakte Altbytes vorher in `Calendar/Migration/`), Build 101 sperrt Format 2.

**Nicht in B2:** Erinnerungen (B3), Kalender und Links im Bibliotheksbackup/Restore und Python-Prüfer, EventKit, Ziehen ganztägiger Termine, „Diesen und alle folgenden“, mehrere Notizen je Termin in der Oberfläche (Datenmodell erlaubt sie), dauerhafter Termin-Papierkorb.

##### Nachweise B2

- Core: `CalendarB2Tests` (15, nur erfundene Daten): wöchentliche Serie über die Herbst- und Frühjahrsumstellung (Wandzeit, Uhrzeit in der Lücke), monatlich am 31. und 29.02. mit Zählende, Ausnahmen/Ende/verschobener Einzeltermin mit Notizidentität, ganztägige Serie, Sprung über 36 Jahre, Grenze je Serie und Zeitraum gemeldet, Validierung, Rundlauf von Serien/Links/Zuordnungen/Farben/Ordner, Regel 8 mit echtem `RevisionStore`, `LibraryStore` und `CalendarRepository` (Link scheitert → Heft im Ordner, kein Link; Wiederholung → nur Link, ein Heft; gleichzeitige Läufe → ein Commit; Bibliotheksschritt scheitert → Paket wird von `load()` gefunden), Ordner nur per ID, Titel, Stundenzuordnung (verschoben, ausgefallen, ungeklärt nur mit Kurs-Kandidaten, gespeicherte Zuordnung, fremdes Konto, Zyklus, nicht geladen), Kontokennung ohne Schlüssel, Farbstabilität, Migration eines Format-1-Pakets mit Fehlerinjektion vor dem Archivieren und exakten Altbytes, Format 1 mit Format-2-Feldern abgelehnt, Format 3 gesperrt. `CalendarRepositoryTests` auf Format 3 als „neuer“ angepasst.
- iPad-SDK-Build erfolgreich; `scripts/ota_check.py` beim Veröffentlichen.
- **Ungeprüft:** Installation und jeder Gerätelauf, insbesondere eingebetteter Editor neben dem Termin (Werkzeugleiste in schmaler Spalte, Tastatur, Pencil), Anlage bei erster Eingabe, Vergrößern/Rückkehr, Gesten im Raster (Konflikt mit Scrollen), Esc/⌘-Kürzel während der Texteingabe in der Notiz, WebUntis-Verhalten bei verschobenen Stunden.

**Gerätetest B2 (gebündelt, in noty calendar):** (1) Eigenen Termin antippen, daneben mit dem Pencil schreiben → Zustand „Wird angelegt …“ → „In „Kalendernotizen““, Notizsymbol am Termin; App beenden und neu starten → Notiz und Symbol bleiben. (2) Einen anderen Termin nur öffnen, nichts schreiben, zurück: kein neues Heft in „Kalendernotizen“. (3) Bibliothek → „Kalendernotizen“: Heft „Titel · TT.MM.JJJJ“; umbenennen, Kalender: Notiz bleibt verknüpft. (4) Vergrößern → normaler Editor mit „Zurück zu …“, schreiben, zurück → Strich neben dem Termin sichtbar; Seite hinzufügen, blättern. (5) Schmales Fenster/Hochformat: Notiz über dem Kalender, „‹ Kalender“. (6) Heft in den Papierkorb → Hinweis im Termin, „Wiederherstellen“; endgültig löschen → Hinweis, kein anderes Heft. (7) WebUntis-Stunde mit Notiz; sobald WebUntis eine Stunde verlegt oder ausfallen lässt: Notiz bleibt an der Stunde bzw. erscheint „Ungeklärt“ mit Vorschlag. (8) Wöchentliche Serie anlegen, einen Termin „Nur dieser Termin“ verschieben, einen löschen, dann „Alle“ umbenennen; Notiz an einem einzelnen Termin erscheint nur dort. (9) Termin lange drücken und ziehen (auch auf einen anderen Tag), Dauer am Griff ändern, „Rückgängig“; zu kurz ziehen → Hinweis. (10) Fachfarbe einer Stunde ändern, Neustart: bleibt; „Fachfarben …“. (11) Build 101 nicht mehr starten (Format 2 wäre dort gesperrt).

#### Umsetzungsstand B3 (04.11.2026)

Branch `feat/kalender`. **Implementiert; Core-Tests bestanden (vollständige Suite 1158 ausgeführt, 3 umgebungsbedingt übersprungen, 0 Fehler; davon 10 neu in `CalendarB3Tests`); Host-Roundtrip mit beiden Python-Prüfern bestanden; iPad-SDK-Build (`xtool dev build`) erfolgreich ohne Warnungen in den geänderten Dateien; als „noty calendar“ Build 103 veröffentlicht. Nicht installiert geprüft, am iPad ungeprüft.** Damit sind alle Punkte von Stufe B außer der Ferienquelle und „letzte Ansicht/Fünf-Sieben-Tage pro Bereich“ (umgesetzt in B1, Punkt bleibt wegen der Ferienquelle offen) implementiert; die Abnahme am Gerät steht für alle aus.

- **Bibliotheksbackup mit Kalender (Format 3):** Das Bibliotheksbackup (manuell und automatisch/extern) enthält den bestätigten Kalender des Bereichs – eigene Termine mit Serien, Ausnahmen, geänderten Terminen und Erinnerung, gelöschte Termine, Terminnotiz-Links, Stundenzuordnungen, Fachfarben, Einstellungen, den geheimnisfreien Verbindungseintrag – sowie den letzten WebUntis-Offline-Stundenplan mit Abrufzeiten. Ohne Kalenderdaten bleibt es Format 2. Ältere Builds lehnen Format 3 ab; Format 1/2 ergeben einen Bereich ohne Kalender. Links auf endgültig gelöschte Hefte werden nicht gesichert und als Warnung genannt. Details: [LIBRARY-BACKUP](LIBRARY-BACKUP.md#ergänzung-04112026--format-3-mit-kalender-kalender-b3).
- **Restore:** in einen neuen getrennten Bereich, Kalenderteil vor jedem Veröffentlichen vollständig geprüft; Links zeigen auf die Hefte des neuen Bereichs (Heft-IDs bleiben, ausdrückliche Identitätsabbildung), nie bereichsübergreifend. Die WebUntis-Verbindung wird nie automatisch aktiv (neue Verbindungs-ID): Hinweis „WebUntis: Zugang auf diesem Gerät neu verbinden · Stand … (veraltet)“, im Verbindungsdialog „Auf diesem Gerät neu verbinden …“. Die Bestätigung beim Öffnen einer `.notylibrary` nennt Termine, Terminnotizen, Stundenplanstand und den Hinweis zum Neuverbinden. Einstellungen › Backup erklärt, was das Bibliotheksbackup enthält und dass ein Heftbackup keinen Kalender enthält.
- **Gelöschte Termine:** Löschen eines eigenen Termins, einer Serie oder eines einzelnen Serientermins legt einen Eintrag an (Menü „…“ → „Gelöschte Termine (n) …“): „Wiederherstellen“ bringt den Termin mit seiner ID und damit seine Notizen zurück (einzelner Serientermin: Ausnahme entfernt; ist die Serie selbst gelöscht, zuerst die Serie), „Endgültig entfernen“/„Alle endgültig entfernen …“ löscht nur den Eintrag, nie ein Heft. „Rückgängig“ direkt nach dem Löschen entfernt auch den Eintrag. Höchstens 1000 Einträge (älteste machen Platz).
- **Erinnerungen (UserNotifications, nur App-Schicht):** Im Terminformular „Erinnerung“ (Standard aus) mit „Zum Beginn, 5/10/15/30 Minuten, 1 Stunde, 1 Tag vorher“ (Serie: jeder Termin; ganztägig ausgehend von 9:00 des ersten Tages; „1 Tag“ behält die Uhrzeit über die Zeitumstellung). Menü „…“ → „Erinnerungen …“: „Unterricht: 5/10/15/30/60 Minuten vorher“ (Standard aus; ausgefallene Stunden nie), Berechtigungszustand mit Knopf zu den iPad-Einstellungen bei Ablehnung, „n Erinnerungen geplant bis …“. Die Erlaubnis wird nur beim Einschalten einer Erinnerung erfragt. Planung in Core (`CalendarReminderPlanner`, rein, getestet): höchstens 50 einmalige Mitteilungen der nächsten 30 Tage, eine feste Kennung je Durchführung (dieselbe Kennung ersetzt, keine Duplikate), keine wiederholenden Auslöser; neu geplant bei App-Aktivierung, nach jedem Commit und jeder WebUntis-Aktualisierung. Nur der geöffnete Bereich plant; ein Bereichswechsel ersetzt die Erinnerungen. Ohne Zugangsdaten (wiederhergestellter Bereich) keine Stundenerinnerungen aus dem veralteten Plan.
- **Format 3:** siehe [STORAGE](STORAGE.md#ergänzung-04112026--kalenderpaket-format-3-b3); B1/B2-Pakete werden mit exakten Altbytes migriert, Build 102 sperrt Format 3.

**Nicht in B3:** EventKit/Outlook (Stufe C), Backend-Synchronisierung (Stufe D), Ferienquelle für die Jahresansicht, eigene Erinnerung einzelner Serientermine (die Erinnerung gilt der Serie), Erinnerungen für Bereiche, die gerade nicht geöffnet sind.

##### Nachweise B3

- Core: `CalendarB3Tests` (10) – siehe [TESTING](TESTING.md#kalender-b3-04112026-featkalender-noty-calendar-build-103). Host-Roundtrip mit `CalendarBackupCheck.swift`, `verify_library_backup.py`, `verify_device_store.py` (Quelle und wiederhergestellter Bereich) und `check_calendar_backup.py` (beschädigte Kopie und acht Mutationen abgelehnt).
- iPad-SDK-Build erfolgreich; `scripts/ota_check.py` beim Veröffentlichen. Lokale Mitteilungen brauchen keine zusätzliche Berechtigung im Profil.
- **Ungeprüft:** Installation und jeder Gerätelauf, insbesondere Berechtigungsdialog, Zustellung zur richtigen Zeit, Verhalten bei abgelehnter Erlaubnis, Neuplanung beim Aktivieren, Restore-Ablauf und Neuverbinden in der App.

**Gerätetest B3 (gebündelt, in noty calendar):** (1) Eigene Serie und Einzeltermin anlegen, Notiz zu einem Termin schreiben, WebUntis verbunden lassen; Einstellungen › Backup › Bibliotheksbackup exportieren (Hinweistext lesen). (2) Die `.notylibrary` öffnen („In noty öffnen“): Bestätigung nennt Termine, Terminnotizen, Stundenplanstand und „neu verbinden“ → als neuen Bereich wiederherstellen, dorthin wechseln: Termine, Serie, Notizsymbol, Notiz in „Kalendernotizen“, Fachfarben, Stundenplan mit „Zugang auf diesem Gerät neu verbinden · Stand … (veraltet)“; kein Abruf. „Auf diesem Gerät neu verbinden …“ → Stundennotizen erscheinen wieder an ihren Stunden. Zurück zu „Meine Bibliothek“: unverändert. (3) Termin löschen, einen Serientermin „Nur diesen“ löschen, Serie löschen; „…“ → „Gelöschte Termine“: wiederherstellen (Notizsymbol wieder da), endgültig entfernen (Heft bleibt in „Kalendernotizen“). (4) Termin in 6 Minuten mit „5 Minuten vorher“ anlegen → Erlaubnisdialog erscheint erst jetzt; App in den Hintergrund: Mitteilung kommt einmal. Termin verschieben: nur die neue Zeit meldet sich. (5) „Erinnerungen …“: „Unterricht 10 Minuten vorher“, „n Erinnerungen geplant bis …“ plausibel; ausgefallene Stunde ohne Mitteilung. (6) In den iPad-Einstellungen Mitteilungen für noty calendar ausschalten: Hinweis mit Knopf zu den Einstellungen im Formular und in „Erinnerungen …“. (7) Testbereich wechseln: Erinnerungen des Hauptbereichs entfallen, beim Zurückwechseln wieder geplant. (8) Build 102 nicht mehr starten (Format 3 wäre dort gesperrt).

#### Review-Korrekturen Build 104 (04.11.2026)

Branch `feat/kalender`, nach der unabhängigen Prüfung von `394c281..eb5abf7` (und B3). **Implementiert; Core-Tests bestanden (vollständige Suite 1168 ausgeführt, 3 umgebungsbedingt übersprungen, 0 Fehler; davon 10 neu in `CalendarReviewFixTests`); Host-Roundtrip (`check_page_workflow.sh`) bestanden; iPad-SDK-Build (`xtool dev build`) erfolgreich; als „noty calendar“ Build 104 veröffentlicht. Nicht installiert geprüft, am iPad ungeprüft.** Kein Formatwechsel (Kalenderformat 3 bleibt).

- **Bereichswechsel verwirft keine Notiz mehr still:** Vor dem Wechsel schließt der Kalender die Notiz, setzt noch nicht angelegte Notizen fort, versucht nicht gespeicherte Notizen und eine nicht gespeicherte Kalenderänderung erneut (`CalendarModel.prepareAreaSwitch`). Bleibt etwas nur im Speicher (Speichern scheitert, Import läuft), wird nicht gewechselt; die Meldung „Kalender nicht gespeichert“ nennt es und bietet ausdrücklich „Verwerfen und wechseln“ an. `closeNote()` meldet, ob noch etwas offen ist.
- **„Rückgängig“ nimmt Terminnotizen mit:** Der Rückgängig-Schritt hält Termin und Ziele seiner Notizlinks vor der Änderung (`CalendarUndoSnapshot`, Core) und stellt beides in einem Kalendercommit wieder her. Seitdem neu angelegte Links bleiben, seitdem gelöste kommen nicht zurück. Gelöschte Termine/Durchführungen ändern keine Links; ihr Rückgängig entfernt den Eintrag aus „Gelöschte Termine“ wie bisher.
- **Neue Notiz beim Wechsel in den Hintergrund:** Hat die Notiz Inhalt, aber noch kein Heft (400-ms-Eingabepause nicht abgelaufen), startet der Wechsel in den Hintergrund die Anlage sofort (Regel 8: Heft, Bibliothek, Link) unter iOS-Hintergrundzeit (`sceneLeftForeground`), ebenso für noch nicht angelegte zurückgestellte Notizen; danach werden sie gespeichert und freigegeben.
- **Eine Reihenfolge für alle Kalenderänderungen:** Termine, Links, Einstellungen, „Erneut speichern“ sowie Verbinden/Trennen laufen nacheinander durch eine Warteschlange (`CalendarMutationQueue`, Core) und setzen immer auf dem neuesten Stand auf. Verbinden/Trennen übernimmt den Verbindungseintrag erst nach erfolgreichem Commit; ein paralleler Link geht nicht verloren, und ein später Commit kann eine getrennte Verbindung nicht zurückbringen.
- **Serie „Alle“ verschieben/ändern nimmt einzeln geänderte Termine mit:** Ausnahmen, Ende und die Identität geänderter Termine wandern um die Tage des ersten Termins; die eigene Zeit eines geänderten Termins wandert um dieselben Tage und dieselbe Wanduhr-Änderung von Beginn und Ende in seiner Zeitzone (Sommerzeit-sicher), seine Abweichung bleibt relativ erhalten; bei Wechsel ganztägig ↔ mit Uhrzeit nur die Tage (`CalendarSeries.moved`). Wird „Alle Termine der Serie“ im Formular von einem einzeln geänderten Termin aus gespeichert, übernimmt dieser Termin die neuen Serienwerte (seine Einzeländerung entfällt).
- **Speicherreihenfolge auch beim Warten auf die Sperre:** `CalendarRepository.save` prüft die Revision nach dem Warten auf die Schreibsperre erneut; gleichzeitige Saves warten auf denselben Sperrversuch, ein nach `close()` eintreffender wird sofort freigegeben.

Nachweise: `CalendarReviewFixTests` (10, erfundene Daten): Serie +7 Tage mit verlegtem Termin, Uhrzeitänderung, Sommerzeitende, ganztägig und Artwechsel, Validierung; Rückgängig einer täglichen und wöchentlichen Serie mit Notiz, Rückgängig einer Löschung ohne Link-Neuanlage; Warteschlange ohne Überlappung; ältere Saves unter Sperrkonkurrenz (sechs Runden, beide Reihenfolgen) und Sperre nach `close()`. Die App-Teile (Bereichswechsel-Dialog, Hintergrundzeit, Verbinden/Trennen) sind nur gebaut, nicht ausgeführt.

**Gerätetest Review-Korrekturen (gebündelt, in noty calendar):** (1) Wöchentliche Serie, einen Termin „Nur dieser Termin“ auf einen anderen Tag/eine andere Zeit ziehen, Notiz an einem anderen Termin schreiben; dann einen Termin „Alle“ um einen Tag ziehen: der verlegte Termin wandert mit (nicht an alter Stelle), die Notiz hängt am selben Termin; „Rückgängig“: Serie, verlegter Termin und Notiz wieder wie vorher; App neu starten. (2) Neuen Termin öffnen, sofort schreiben und innerhalb einer halben Sekunde zum Homescreen wechseln; App aus dem App-Umschalter beenden, neu starten: Notiz ist da und verknüpft. (3) Notiz schreiben und direkt den Bereich wechseln: ohne Meldung gewechselt, Notiz beim Zurückwechseln vorhanden. (4) Während einer Notiz ein Bild importieren und sofort den Bereich wechseln: Meldung „Kalender nicht gespeichert“; „Abbrechen“ → Bild/Notiz bleiben, nach Abschluss erneut wechseln geht. (5) WebUntis trennen und gleich danach eine neue Notiz an einem eigenen Termin schreiben, App neu starten: Verbindung bleibt getrennt, Notiz verknüpft.

**Abnahme:** Im Flugmodus geladenen Stundenplan öffnen, eigenen Termin und Notiz anlegen, schreiben, speichern, App neu starten und beides erneut öffnen. Erst Handschrift/Text setzt den Notizhinweis. Verschiebung/Ausfall, Serienausnahme, wiederholtes Einlesen und veralteter Offlinebestand erhalten korrekte Zuordnungen und Notizen. Ziehen, Daueränderung, Fensterwechsel und Vergrößern am iPad prüfen. Vollständiges Backup in einen neuen Bereich zurückspielen; Kalender, Notizen und Links stimmen dort. Schreibfehler dürfen keinen falschen Speichererfolg anzeigen.

### Stufe C – Apple Kalender und Outlook lesen und schreiben

- [ ] Passenden Providerweg einschließlich tatsächlich verfügbarer Konten und Schreibrechte klären; EventKit ist ein technischer Vorschlag, kein bestätigter Anschluss.
- [ ] Termine anzeigen, anlegen, bearbeiten und löschen, mit bewusster Zielkalenderwahl sowie Fehler-/Konfliktbehandlung. Änderungen müssen im jeweiligen Kalender ankommen. Eine reine Lesevorstufe erfüllt diese Stufe nicht vollständig.
- [ ] Dieselbe Terminnotizfunktion wie in Stufe B; Notizen bleiben noty-Dokumente. Das Schreiben eines Kalendertermins bedeutet nicht, dass die Notiz zu Apple/Outlook hochgeladen wurde.
- [ ] Berechtigungszustände, Offlinebestand, Aktualisierung und Serienereignisse mit Verknüpfungen pro Durchführung behandeln.

**Abnahme:** Änderungen in beide Richtungen überprüfen; Rechteentzug, fehlende Verbindung, Schreibfehler, Quellenwechsel und Serienänderungen verursachen weder Duplikate noch Notizverlust. Die Kalenderanbindung belegt keine eigene Backend-Synchronisierung von noty-Notizen.

### Stufe D – Eigenes Backend zur Synchronisierung, später

- [ ] Eigene Termine, Einstellungen, Notizen einschließlich editierbarer Handschrift/Text und Verknüpfungen zwischen den eigenen Geräten synchronisieren.
- [ ] Vollständige Offlinebearbeitung erhalten; Synchronisierung und separate Sicherung bleiben getrennte Funktionen.
- [ ] Vor Umsetzung Architektur, Hosting, Anmeldung, Gerätezuordnung, Konflikte, Löschungen, Bereichsgrenzen und Wiederherstellung konkret planen. Diese technischen Entscheidungen sind noch offen.
- [ ] Falls schon für WebUntis ein Backend benötigt wird, dessen Quellenanbindung von diesem späteren Synchronisationsumfang unterscheiden.

**Abnahme:** Noch als eigene technische Planung auszuarbeiten; mindestens Offlineänderungen auf mehreren Geräten, Konflikte, Unterbrechungen und Erhalt sämtlicher Notizdaten prüfen. Lokales Speichern allein ist kein Synchronisationsnachweis.

### Späterer Ausbau und ergänzende Vorschläge

**Bestätigt für später:** einzelne Stundennotizen als durchgehendes Fachheft öffnen. Das gewünschte Ergebnis ist bestätigt, die genaue Zusammenstellung, Reihenfolge und Bearbeitungssemantik sind noch zu planen. Eine dauerhafte Fachheftzuordnung ist ebenfalls später zu behandeln.

**Noch nicht bestätigt:** zusätzliche Heft-/Seitenverknüpfungen, mehrere eigene Kalender, erweiterte Suche, ICS-Export, Kalender-PDF/Drucken, Widgets, Kurzbefehle, weitere Feiertagsquellen und Aufgabenverwaltung. Aufgaben sind ein separates Produktpaket; eine handschriftliche Checkbox im Heft ist keine Kalenderaufgabe. Notizen direkt neben Terminen, Ziehen eigener Termine und ausblendbare Wochenenden gehören bereits zur ersten nutzbaren Version.

## 4. Regeln für Terminhefte und Verknüpfungen

1. **Ein Heft bleibt ein gewöhnliches noty-Dokument.** „Kleines Heft“ beschreibt den Einstieg mit einer Seite, kein zweites Notizformat. Weitere Seiten und vorhandene Editorfunktionen bleiben nutzbar.
2. **Verknüpfung über Identitäten:** Bereich, Dokument-ID und optional Seiten-ID; niemals Name, Dateipfad oder Seitenposition. Ein Termin kann mehrere Hefte verknüpfen, ein Heft mehrere Termine.
3. **Keine Kaskadenlöschung:** Termin entfernen, Quelle trennen oder Fachzuordnung ändern löscht kein Heft. Verbindung lösen entfernt ausschließlich den Link.
4. **Verschieben erhält die Notiz:** Lokale Termine behalten ihre ID. Bei externen Terminen hilft eine eigene Zuordnungstabelle; unsichere Zuordnungen als ungeklärt anzeigen statt anhand gleicher Titel automatisch zusammenzuführen.
5. **Serien:** Das Heft einer einzelnen Unterrichtsstunde gehört zur Durchführung. Ein allgemeines Fachheft und das Zusammenführen von Stundennotizen sind spätere Erweiterungen, nicht Teil der ersten Version. Ein neues Heft einer Durchführung wird nicht automatisch an jede Wiederholung gehängt.
6. **Fehlende Ziele:** Heft/Seite im Papierkorb oder endgültig entfernt → verständlicher Hinweis und Auswahl eines anderen Ziels. Nicht unbemerkt ein gleichnamiges Heft öffnen. Fehlt nur die Seite, das Heft als ausdrückliche Alternative anbieten.
7. **Duplizieren:** Ein duplizierter Termin erhält eine neue ID und standardmäßig keine Heftlinks. Links bewusst übernehmen ist später möglich; keine stillen Kopien von Heftinhalten.
8. **Heftanlage bei Fehlern:** Erst ab tatsächlicher Eingabe anlegen; eine bloß geöffnete leere Fläche erzeugt kein persistentes Heft. Zuerst das Heft über die Bibliothek vollständig committen, dann verknüpfen. Scheitert der zweite Schritt, bleibt das Heft in der Bibliothek auffindbar und der Link kann erneut gesetzt werden. Weitere Eingaben während laufender Anlage dürfen keine Duplikate erzeugen oder Inhalt verlieren.

## 5. Anschluss an den aktuellen Code

Der untersuchte Stand enthält noch keine EventKit- oder eigene Kalenderimplementierung. Vorhandene Bausteine sind Anschlussstellen, kein Beleg dafür, dass Kalender bereits unterstützt werden:

- [Notebook.swift](../Core/Sources/NotebookCore/Notebook.swift): `Page` mit Zeichen-, Text-, Bild- und Formdaten; `DocumentKind` kennt Heft und Textdokument, aktuelles Maximalschema 15. Terminhefte benötigen zunächst keinen neuen Dokumenttyp und kein zusätzliches Kalenderlayer.
- [NotebookRepository.swift](../Core/Sources/NotebookCore/NotebookRepository.swift): Actor und geordnete Revisionen für Heftspeicherung. Kalendercode darf keine Heftdateien daneben schreiben.
- [EditorWorkspace.swift](../Sources/Noty/EditorWorkspace.swift): gemeinsamer Speichereigentümer pro geöffnetem Heft, unabhängige Editoransichten. Diese Klasse ist derzeit auf Heftmodelle ausgerichtet; „Kalender neben Heft“ erfordert eine gezielte Erweiterung und ist nicht schon durch zwei Heftansichten erledigt.
- [WorkspaceAppModel.swift](../Sources/Noty/WorkspaceAppModel.swift) und [WorkspaceStore.swift](../Core/Sources/NotebookCore/WorkspaceStore.swift): aktive Bibliothek und getrennte Test-/Restorebereiche. Kalenderdaten müssen denselben Bereichswechsel respektieren.
- [LibraryArchive.swift](../Core/Sources/NotebookCore/LibraryArchive.swift): bestehendes Bibliotheksarchiv. Seit B3 Format 3 mit Kalender ([CalendarArchive.swift](../Core/Sources/NotebookCore/CalendarArchive.swift)), Restore in neue Bereiche und unabhängige Prüfer (`calendar_format.py`).
- [PageGeometry.swift](../Core/Sources/NotebookCore/PageGeometry.swift), [PagePresentation.swift](../Sources/Noty/PagePresentation.swift) und bestehender PDF-Export bleiben für die verknüpften Hefte maßgeblich. Das Kalenderraster ist normale UI und verwendet keine Heftseitenkoordinaten.

Vor Implementierung zusätzlich [DESIGN](DESIGN.md), [ARCHITECTURE](ARCHITECTURE.md), [STORAGE](STORAGE.md), [LIBRARY](LIBRARY.md), [LIBRARY-BACKUP](LIBRARY-BACKUP.md), [BACKUPS](BACKUPS.md), [KEYBOARD](KEYBOARD.md) und [ACCEPTANCE](ACCEPTANCE.md) heranziehen. Historische Aussagen dort mit dem dann aktuellen Code abgleichen.

### Vorgeschlagene neue Komponenten

- **NotebookCore:** `CalendarEvent`, `CalendarCollection`, `EventOccurrenceKey`, `EventNotebookLink`, Datums-/Intervalllogik sowie validierter, versionierter `CalendarRepository`.
- **Sources/Noty:** `CalendarViewModel`, native Jahres-/Monats-/Wochen-/Tagesansichten, Terminformular und eingebettete Notizseite; WebUntis-Provider nach Zugangsprüfung, später `EventKitCalendarProvider` und gegebenenfalls `ICSCalendarProvider`.
- Provider liefern normalisierte Daten und Fähigkeiten wie lesbar/schreibbar; keine Apple-Typen in NotebookCore. EventKit-, Benachrichtigungs- und UIKit-Code bleiben in der App-Schicht.

Die Namen sind Vorschläge. Keine neue Abstraktionsschicht im bestehenden Hefteditor allein für den Kalender einführen.

## 6. Persistenz, Datum und Backup

**Empfehlung:** ein eigenes Kalenderpaket unter dem aktiven Bereichsroot, beispielsweise `Calendar/`, mit genau einem Writer. Lokale Termine, Heftlinks und relevante Einstellungen bilden einen gemeinsam bestätigten Stand. Externe Snapshots sind getrennte, ersetzbare Daten; eigene Links und Hefte sind keine Cacheeinträge.

- Vollständige unveränderliche Revisionen, geprüft zurücklesen, Manifest zuletzt ersetzen. Ältere asynchrone Saves dürfen keine neueren ersetzen; Actor-Reentranz und spät eintreffende Providerantworten mit Generation/Revision und Bereichskennung abfangen.
- Unbekannte neuere Formate sperren. Fehler erhalten den letzten gültigen Stand und ungesicherte Änderungen. Alte Bytes vor einer Migration sichern; kein „Gespeichert“ vor Commit.
- Kalender nicht als ein riesiges Jahresheft modellieren. Jahr/Monat/Woche/Tag sind Projektionen derselben Termine; kein duplizierter Terminbestand je Ansicht.
- Zeitgebundene Termine speichern Beginn/Ende und relevante Zeitzonenkennung. Ganztagstermine speichern zivile Datumsgrenzen mit exklusivem Enddatum; keine Mitternachts-UTC-Ersatzlogik.
- Tages-/Wochenrechnung über Kalenderoperationen, nie fest `24 × 60 × 60` Sekunden. Sommer-/Winterzeit, Jahreswechsel mit ISO-Woche 1/53, Schaltjahr und Reisen in andere Zeitzonen testen.
- Serienexpansion und Quellenabfragen sind zeitlich und mengenmäßig begrenzt. Ressourcenlimits und Verhalten bei Überschreitung vor Providerfreigabe festlegen, nicht unbemerkt abschneiden.

**Backup ist Teil der ersten nutzbaren Version:** Bibliotheksarchiv enthält lokale Kalender, Termine, Heftlinks, Einstellungen und die gewöhnlichen Terminhefte. Benötigte externe Offline-Snapshots mit Datenstand sichern, damit wiederhergestellte Notizen ihren Terminkontext behalten. Keine Tokens, Zugangsdaten oder privaten Abonnement-URLs exportieren. Restore aktiviert keine Verbindung und schreibt niemals Termine in externe Kalender zurück.

Archivformat vor dem Ausbau ausdrücklich versionieren; ältere Leser müssen das neue Format ablehnen, statt unvollständig wiederherzustellen. Swift-Validierung, `verify_library_backup.py`, `verify_device_store.py` und Host-Roundtrip gemeinsam erweitern. Alte Archive bleiben lesbar und ergeben einen Bereich ohne Kalenderbestand.

**Umgesetzt in B3** (Format 3, siehe [LIBRARY-BACKUP](LIBRARY-BACKUP.md)); am iPad ungeprüft. Restore veröffentlicht einen getrennten Bereich und ordnet lokale Links dessen Heften zu; bei neuen Dokument-IDs eine explizite ID-Abbildung anwenden. Verknüpfungen dürfen nicht versehentlich auf die ursprüngliche Bibliothek zeigen. Bereichsübergreifende Heftlinks sind für die erste Version ausgeschlossen. Ein einzelnes Heftbackup bleibt ein Heftbackup und behauptet keine vollständige Kalendersicherung.

## 7. Externe Kalender realistisch anbinden

### Apple Kalender und Outlook; Google nicht als eigener Wunsch bestätigt

EventKit greift auf den zugänglichen Systemkalenderbestand zu. Outlook/Google sind darüber nur nutzbar, soweit das betreffende Konto im iPad-Systemkalender verfügbar ist; die bloße Installation der Outlook-App reicht als Integrationsnachweis nicht aus. Direkte Microsoft-Graph-/Google-API-Anbindungen gehören nicht zur ersten Umsetzung.

Das Projekt hat derzeit iPadOS 17 als Mindestversion. Für das Lesen von Terminen verlangt EventKit Vollzugriff; reine Schreibberechtigung genügt nicht. Beim bewussten Verbinden passende Erklärung und `NSCalendarsFullAccessUsageDescription` verwenden. Ein als technische Vorstufe schreibgeschützter Provider bedeutet daher nicht, dass iPadOS eine separate Leseberechtigung erteilt; der bestätigte Apple-/Outlook-Zielumfang enthält auch Schreiboperationen. Ablehnung oder Entzug blockiert weder lokale Termine noch Hefte. Siehe [Apple TN3152](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels) und [EventKit-Zugriff](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui).

Erneut einlesen bei App-Aktivierung, Systemänderungen und manueller Aktion; nicht „Cloud erfolgreich synchronisiert“ melden. Status etwa „Systemkalender zuletzt eingelesen …“. Hintergrundaktualisierung ist kein garantiertes Echtzeitintervall. Ein eigener Offlinebestand braucht eine definierte Zeitabdeckung; außerhalb davon „Zeitraum noch nicht geladen“ statt „keine Termine“.

Bei Rechteentzug externe Details ausblenden und Cache gemäß festgelegter Löschregel entfernen; eigene Heftlinks als nicht verfügbare Quelle erhalten. Beim bewussten Trennen Quelle/Cache entfernen, Hefte und eigene Links bewahren. Geheimnisse gehören in den Keychain, niemals in Logs oder ins öffentliche Repository.

### ICS und WebUntis

#### WebUntis-Entscheidung (04.11.2026)

Die Schule des Nutzers sperrt anonyme/öffentliche Stundenpläne, bietet kein iCal an und meldet über Office-365-SSO an. Der Nutzer hat deshalb den **inoffiziellen Zugang über die Untis-Mobile-Freigabe** freigegeben (WebUntis → Profil → Freigaben: QR-Code, Benutzer, Schlüssel). In App und Dokumentation als „inoffizieller Zugang über Untis-Mobile-Freigabe“ bezeichnet. Kein Backend.

Vom Nutzer am 04.11.2026 einmalig erprobt (Daten danach gelöscht): JSON-RPC 2.0 per POST an `https://<server>/WebUntis/jsonrpc_intern.do?m=<methode>&school=<schule>&v=i2.2`, `auth {clientTime (ms), user, otp}`, OTP nach RFC 6238 (SHA-1, 30 s, 6 Ziffern, Schlüssel base32). `getUserData2017` liefert Benutzerelement (`STUDENT`, `elemId`) und Stammdaten (Fächer, Räume, Klassen, Ferien „YYYY-MM-DD“; Lehrkräfte für diese Schüler leer). `getTimetable2017` liefert Perioden mit `id` (je Stunde), `lessonId` (je Kurs), lokalen Zeiten (Europe/Berlin), Elementen mit `orgId` und `is`. **Bestätigt ist nur `is = REGULAR`**; CANCELLED/IRREGULAR/EXAM usw. stammen aus Community-Dokumentation und sind unbestätigt. Der QR-Inhalt `untis://setschool?url=…&school=…&user=…&key=…&schoolNumber=…` ist ebenfalls community-dokumentiert und wird tolerant gelesen. Die Freigabe kann von der Schule oder Untis jederzeit geändert oder gesperrt werden.

ICS-Dateiimport ist eine einmalige Übernahme; ein Abonnement ist wiederholtes Einlesen einer Quelle. Beides separat benennen. Öffentlich sichtbare WebUntis-Webseiten sind noch kein bestätigter ICS-/API-Zugang. Untis beschreibt öffentliche Pläne als freigegebene Webansichten: [Öffentliche Stundenpläne](https://help.untis.at/hc/de/articles/18077455725340-%C3%96ffentliche-Stundenpl%C3%A4ne).

Untis nennt für iCal bestimmte Benutzer-/Modulvoraussetzungen und standardmäßig einen begrenzten Zeitraum von einer Woche zurück bis zwölf Wochen voraus. Das ist keine vollständige Schuljahreshistorie; verfügbare Felder und Änderungen müssen mit der konkreten Quelle geprüft werden. [Untis iCal-Abonnement](https://help.untis.at/hc/de/articles/360014979580-Wie-funktioniert-das-iCal-Kalender-Abonnement-in-WebUntis)

Die im ursprünglichen Entwurf genannte fehlende iCal-Option an der eigenen Schule ist ein Nutzerhinweis, hier nicht am Konto überprüft. Die offizielle Webservices-Seite nennt ein Zusatzmodul und verweist an den Untis-Partner; sie belegt keinen bereits verfügbaren Zugang für dieses Projekt. [Untis Webservices](https://help.untis.at/hc/de/articles/360015504940-Webservices)

Vor Freigabe eines direkten Providers: erlaubten Zugang, Beispieldaten, Identitäten, Wiederholungen, Vertretungen/Ausfälle, Zeitabdeckung, Aktualisierung und Limits prüfen. Kein Scraping als angenommener Standardweg. Fach, Raum, Lehrkraft und Ausfallstatus nur anzeigen, wenn die Quelle sie tatsächlich liefert.

### Identitäten und sichere Aktualisierung

- Lokale Ereignisse: eigene stabile UUID. Externe Ereignisse: Verbindung + Quellkalender + Providerkennung; Wiederholungen zusätzlich über die ursprüngliche Durchführung identifizieren. Aktuelle Startzeit oder Titel allein sind kein Schlüssel.
- Für ICS insbesondere `UID`, `RECURRENCE-ID` und Änderungsinformationen berücksichtigen. Bei EventKit die tatsächliche Stabilität der Kennungen bei Verschiebung/Serienänderung prüfen; keine lebenslange Stabilität voraussetzen.
- Antworten vollständig prüfen und nur im bestätigten Quell-/Zeitbereich ersetzen. Timeout, Parsefehler oder Teilantwort sind keine leere Kalenderliste.
- Ein Termin außerhalb des gleitenden Quellzeitfensters gilt nicht automatisch als gelöscht. Letzten Kontext für verknüpfte Termine als veraltet erhalten, ohne ihn als aktuellen Unterricht auszugeben.
- Keine automatische Zusammenführung anhand gleicher Titel/Uhrzeiten. Gleiche Quelle über EventKit und direktes ICS möglichst nicht doppelt aktivieren; im Zweifel Duplikat anzeigen und Quellenwahl anbieten.
- Beim externen Schreiben in Stufe C Ziel und Schreibbarkeit prüfen, zwischenzeitliche Änderungen berücksichtigen und Providerfehler anzeigen. Eigene Heftdaten bleiben von Schreibkonflikten unabhängig.

## 8. Prüfungen und Freigabe

**Stufe A (03.11.2026):** siehe [Umsetzungsstand](#umsetzungsstand-stufe-a-03112026). Core-Tests und unsignierter iPad-SDK-Build bestanden; keine Installation, kein Gerätetest, keine Nutzerabnahme.

**Für die Planungsaktualisierung:** Abgleich mit den bestätigten Antworten des Entscheidungsinterviews, Prüfung der Dokumentkonsistenz und lokaler Linkziele. Die technischen Quellenhinweise stammen aus dem ursprünglichen Entwurf und wurden in dieser reinen Anforderungsrunde nicht erneut extern geprüft. Keine App-Funktion geändert; kein Build, keine Installation und kein Gerätetest durchgeführt. Kalenderdesign, Terminlogik, WebUntis-Zugang und Backend sind weiterhin ungeprüft.

**Bei der Umsetzung:**

- Core-Tests für Datum, Intervalle, Überschneidungen, IDs/Links, Serienausnahmen, Save-Reihenfolge, Schreibfehler, Recovery, Migration und Restore in getrennte Bereiche.
- Provider-Fixtures für Verschiebung, Absage, fehlende IDs, unvollständige Antworten, gleitende Zeitfenster und mehrfaches Einlesen; keinerlei private Stundenplandaten als Testfixtures committen.
- Host-Roundtrip und unabhängige Archiv-/Geräteprüfer bei Kalenderformat und Backupänderungen.
- iPad-SDK-Build bei UI/EventKit; gebündelte Gerätetests für Navigation, Tastatur, Heftöffnung, Speichern/Neustart, Fenstergröße, Berechtigungsentzug und offline Verhalten.
- Bei späterem Kalender-PDF echte Ausgabe rendern und Text mit `pdfinfo`, `pdftoppm` und `pdftotext` prüfen. Der bestehende Heft-PDF-Export beweist keinen Kalenderexport.

Umsetzung in `dev` oder einem von `dev` abgezweigten Featurebranch; danach noty dev zur Nutzerprüfung. Erst ausdrücklich freigegebene Stände gehen nach `main` und in die normale noty. Implementiert, erfolgreich gebaut, installiert und auf dem iPad getestet weiterhin getrennt ausweisen.

## 9. Bestätigung und offene technische Planung

Der Nutzer hat den zusammengefassten Produktumfang am 03.11.2026 mit „ja so will ich das aber nur festhalten nicht bauen“ bestätigt. Die Bestätigung umfasst die in Abschnitt 1 aufgeführten Entscheidungen und die Reihenfolge WebUntis mit Stundennotizen und eigenen lokalen Terminen → Apple/Outlook → spätere Backend-Synchronisierung; ein für WebUntis nötiges Backend kann bereits beim ersten Schritt erforderlich werden.

Offen bleiben insbesondere der konkrete erlaubte WebUntis-Zugang samt Datenabdeckung und Backendbedarf, die Ferienquelle, der geeignete Apple-/Outlook-Provider sowie Hosting, Anmeldung und Konfliktregeln der späteren Synchronisierung. Diese Punkte sind keine stillschweigend festgelegten Architekturentscheidungen. Nicht bestätigte Ergänzungen sind in Abschnitt 3 getrennt gekennzeichnet.

**Nächster Schritt:** noty calendar Build 103 installieren und die Gerätetests [B1](#umsetzungsstand-b1-04112026), [B2](#umsetzungsstand-b2-04112026) und [B3](#umsetzungsstand-b3-04112026) durchgehen; danach Abnahme von Stufe B. Stufe C (Apple Kalender/Outlook) nur mit eigenem Auftrag.
