# noty Kalender – Produkt- und Entwicklungsplan

Stand: 03.11.2026. **Bestätigte Produktplanung. Stufe A (Design und Navigation mit Beispieldaten) ist auf `feat/kalender` implementiert und erfolgreich gebaut, nicht installiert, am iPad ungeprüft; die Designabnahme durch den Nutzer steht aus.** Es gibt weiterhin keine Kalenderspeicherung, keine echten Termine und keinen WebUntis-/EventKit-Anschluss (Stufe B/C). Technischer Ausgangsabgleich mit `dev` bei `6524a97`; technische Vorschläge und Quellenhinweise unten bleiben vor der Umsetzung zu prüfen. Dieser Plan erweitert den bisherigen [SCOPE](SCOPE.md).

**Aufträge:** Zunächst nur festgehalten (Bestätigung der Anforderungen, keine Freigabe zum Bauen). Am 03.11.2026 folgte der Umsetzungsauftrag für **Stufe A** (Design zur Ansicht mit fiktiven Daten, ohne Installation und Veröffentlichung). Stufen B–D sind weiterhin nicht beauftragt. Umsetzungsstand: [Stufe A](#umsetzungsstand-stufe-a-03112026).

## 1. Ziel und bestätigte Richtung

Ein nativer Kalender für den Schulalltag, mit der vertrauten Bedienlogik von Apple Kalender und Outlook und der Gestaltung von noty. Schule und Mitschriften haben Vorrang, private Termine sind ebenfalls möglich. Kalenderbeschriftungen und Termine verwenden normale Schrift und Tastatureingabe. Das Kalenderraster selbst ist keine Handschriftfläche; zu einem angeklickten Termin erscheint jedoch eine eigene, direkt beschreibbare Notizseite daneben.

**Bestätigt im Entscheidungsinterview vom 03.11.2026:**

- WebUntis mit Stundennotizen zuerst; eigene lokale Termine ebenfalls bereits in der ersten nutzbaren Version.
- WebUntis soll Unterricht, Fächer, Räume, Lehrkräfte, Vertretungen, Ausfälle und verfügbare Prüfungen liefern. Die konkrete Quelle und deren tatsächlich verfügbare Felder sind noch zu prüfen. Unterrichtszeiten werden aus WebUntis übernommen; eigene Ergänzungen bleiben Notizen oder separate Termine, keine persönlichen Überschreibungen des Stundenplans.
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

Stufe A ist implementiert und gebaut (Häkchen = implementiert und erfolgreich gebaut, **nicht** am iPad getestet). Stufen B–D sind **geplant und nicht umgesetzt**.

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

**Nur Entwurf (bewusst, Stufe B):** Termine, Notizen, gelöschte Termine und Formulareingaben leben nur im Speicher; kein Heft, keine Ablage in „Kalendernotizen“, kein Backup. Die Notizseite ist kein noty-Editor (keine Werkzeugleiste, kein Undo, ein schwarzer Stift); „Vergrößern“ öffnet noch nicht den normalen Editor. Kein Ziehen/Verschieben von Terminen, keine Wischgesten, keine echte Wiederholungslogik, keine Benachrichtigungen.

**Beispieldaten:** `Sources/Noty/CalendarSampleData.swift`, frei erfunden (Fächer wie Rechnungswesen, Räume, Lehrkräfte, Ferienzeiträume). Die Woche von „heute“ enthält die Designfälle: beschriebene Rechnungswesen-Notiz mit zwei Seiten, Ausfall mit Notiz, Vertretung, Prüfung, Überschneidung, voller Freitag für „+ n weitere“, ganztägiger und mehrtägiger Termin, wöchentliche eigene Serie.

**Code:** Core `CalendarLayout.swift` (ISO-Kalender `de_DE`, Wochen- und Monatsraster, Überlappungsspalten, Ganztagsbahnen, „+ n weitere“, stabile Fachfarben, deutsche Titel/Uhrzeit, alles über `Calendar`-Operationen) mit `CalendarLayoutTests` (Sommerzeit Berlin, Tage ohne Mitternacht in Santiago/Havanna, KW 1/53, Schaltjahr, Jahreswechsel). App: `CalendarView`, `CalendarWeekView`, `CalendarMonthView`, `CalendarEventDetail`, `CalendarEventForm`, `CalendarSampleData`; in `LibraryView` nur Ort `.calendar`, Leistenzeile und Detailweiche, in `NotyCommands` ⌘N.

**Für die Designabnahme zu entscheiden:** Kalender als Ort in der Bibliotheksleiste oder eigener Umschalter; Farbe für „heute“ (jetzt Rot wie Apple Kalender, Blau bleibt Auswahl); kompakte Monatszeilen und Minimonat unter 44 pt Höhe; Breitenregel für Details neben dem Kalender (jetzt ab 860 pt Detailspalte; auf dem iPad Pro 11″ quer passt das auch mit Bibliotheksleiste); Stift-/Tippen-Umschalter der Entwurfsseite gegenüber dem späteren Editorverhalten.

**Gerätetest (gebündelt, alles ungeprüft),** in noty dev: (1) Kalender öffnen, Woche 5/7 umschalten, App neu starten, Wahl bleibt; zurück/vor/Heute, ⌘-Kürzel. (2) Monat mit „+ n weitere“ am Freitag, Tagesliste, Datum → Tag. (3) Jahr: Tag und Monat antippen, Ferienband. (4) Rechnungswesen Di 08:00 antippen, Seite 2 blättern, auf leerer Seite eines anderen Termins schreiben → Notizsymbol erscheint; Vergrößern, schreiben, zurück: Strich auch in der kleinen Seite. (5) Split View/Hochformat: Overlay mit „‹ Kalender“, Woche scrollt waagerecht. (6) Große Schrift, VoiceOver auf Karten und Tagen. (7) Formular mit Wiederholung, Ausnahme, Erinnerung; Serie löschen und Rückgängig. (8) Aus dem Kalender ein Heft über die Leiste öffnen und schließen: Kalender bleibt.

### Stufe B – Erste nutzbare Version: WebUntis, lokale Termine und Stundennotizen

- [ ] Verfügbaren, erlaubten WebUntis-Zugang und nötigenfalls ein Backend dafür technisch klären. WebUntis ist priorisierter Lieferumfang, nicht erst ein Ausbau nach Apple/Outlook. Ohne belegten Zugang keinen erfolgreichen Anschluss behaupten.
- [ ] Unterricht mit tatsächlich verfügbaren Fach-, Raum-, Lehrkraft-, Vertretungs-, Ausfall- und Prüfungsdaten anzeigen; Zeiten aus der Quelle übernehmen, eigene Ergänzungen getrennt halten.
- [ ] Bereichsbezogener Offlinebestand mit sichtbarem Datenstand und geladenem Zeitraum. Verschobene/ausgefallene Stunden und ihre Notizen sicher zuordnen und erhalten.
- [ ] Eigener lokaler Kalender ohne erforderliches Kalenderkonto bzw. Systemkalenderberechtigung, zunächst „Persönlich“.
- [ ] Eigene Termine anlegen, bearbeiten, löschen; Titel, Ort, Beschreibung, Beginn/Ende, ganztägig und mehrtägig. Duplizieren bleibt ein ergänzender Vorschlag.
- [ ] Tägliche, wöchentliche und monatliche Wiederholungen, Serienende und einzelne Ausnahmen; Änderung/Löschung für einzelnen Termin oder gesamte Serie.
- [ ] Verschieben und Daueränderung per Formular sowie durch längeres Drücken/Ziehen bzw. Ziehen am unteren Rand; ungültige Zeitspannen verständlich ablehnen. Gilt für schreibbare eigene Termine, nicht für WebUntis-Unterricht.
- [ ] Alle vier Ansichten aus denselben Daten, stabile Navigation, letzte Ansicht und Fünf-/Siebentagewahl pro Bereich merken. Ferienquelle für die Jahresansicht bestimmen.
- [ ] Direkt bearbeitbare Terminnotiz, persistente Anlage erst ab tatsächlicher Eingabe, weitere Seiten, Notizhinweis, Vergrößern/Rückkehr und Bibliotheksablage unter „Kalendernotizen“.
- [ ] Einheitliche anpassbare Fachfarben und separate Farbe für eigene Termine.
- [ ] Optionale Erinnerungen pro Termin, standardmäßig aus; zusätzliche allgemeine Unterrichtseinstellung. Berechtigung und Herkunft erkennbar machen, doppelte Benachrichtigungen vermeiden.
- [ ] Sichere Speicherung, Fehleranzeige, lokale Wiederherstellung sowie vollständiges Bibliotheksbackup mit Kalenderdaten, Notizen und Verknüpfungen.
- [ ] Terminlöschung mit Rückgängig-/Wiederherstellungsweg; Notizen bleiben erhalten.

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
- [LibraryArchive.swift](../Core/Sources/NotebookCore/LibraryArchive.swift): bestehendes Bibliotheksarchiv. Kalenderdaten werden davon nicht automatisch mitgesichert; Erweiterung, Versionierung, Restore und unabhängige Prüfer gehören in Stufe B.
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

Restore veröffentlicht einen getrennten Bereich und ordnet lokale Links dessen Heften zu; bei neuen Dokument-IDs eine explizite ID-Abbildung anwenden. Verknüpfungen dürfen nicht versehentlich auf die ursprüngliche Bibliothek zeigen. Bereichsübergreifende Heftlinks sind für die erste Version ausgeschlossen. Ein einzelnes Heftbackup bleibt ein Heftbackup und behauptet keine vollständige Kalendersicherung.

## 7. Externe Kalender realistisch anbinden

### Apple Kalender und Outlook; Google nicht als eigener Wunsch bestätigt

EventKit greift auf den zugänglichen Systemkalenderbestand zu. Outlook/Google sind darüber nur nutzbar, soweit das betreffende Konto im iPad-Systemkalender verfügbar ist; die bloße Installation der Outlook-App reicht als Integrationsnachweis nicht aus. Direkte Microsoft-Graph-/Google-API-Anbindungen gehören nicht zur ersten Umsetzung.

Das Projekt hat derzeit iPadOS 17 als Mindestversion. Für das Lesen von Terminen verlangt EventKit Vollzugriff; reine Schreibberechtigung genügt nicht. Beim bewussten Verbinden passende Erklärung und `NSCalendarsFullAccessUsageDescription` verwenden. Ein als technische Vorstufe schreibgeschützter Provider bedeutet daher nicht, dass iPadOS eine separate Leseberechtigung erteilt; der bestätigte Apple-/Outlook-Zielumfang enthält auch Schreiboperationen. Ablehnung oder Entzug blockiert weder lokale Termine noch Hefte. Siehe [Apple TN3152](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels) und [EventKit-Zugriff](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui).

Erneut einlesen bei App-Aktivierung, Systemänderungen und manueller Aktion; nicht „Cloud erfolgreich synchronisiert“ melden. Status etwa „Systemkalender zuletzt eingelesen …“. Hintergrundaktualisierung ist kein garantiertes Echtzeitintervall. Ein eigener Offlinebestand braucht eine definierte Zeitabdeckung; außerhalb davon „Zeitraum noch nicht geladen“ statt „keine Termine“.

Bei Rechteentzug externe Details ausblenden und Cache gemäß festgelegter Löschregel entfernen; eigene Heftlinks als nicht verfügbare Quelle erhalten. Beim bewussten Trennen Quelle/Cache entfernen, Hefte und eigene Links bewahren. Geheimnisse gehören in den Keychain, niemals in Logs oder ins öffentliche Repository.

### ICS und WebUntis

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

**Nächster Schritt:** Stufe A in noty dev zur Designabnahme installieren (nur mit Freigabe des Nutzers), Rückmeldungen einarbeiten. Stufe B erst nach Abnahme und eigenem Auftrag.
