# Einstellungen

Stand 08.11.2026, Zweig `feat/einstellungen` → `dev`: **implementiert, SDK-Build (`xtool dev build`) ohne neue Warnungen; nicht installiert, am iPad ungeprüft.** Ersetzt die Beschreibung der Einstellungen in [LIBRARY](LIBRARY.md) („Zentrale Einstellungen“) und [UI-POLISH](UI-POLISH.md).

## Aufbau

Die Einstellungen öffnen sich über das ganze Fenster (`fullScreenCover`, aus der Bibliothek und aus dem Heft), nach dem Vorbild der Einstellungen von T3 Code:

- **Breit (≥ 680 pt):** links eine Seitenleiste (`List(selection:)`, 300 pt), rechts die Seite in einem eigenen `NavigationStack`, höchstens 820 pt breit. ⌘↓/⌘↑ wechseln die Seite, Esc schließt.
- **Schmal (Stage Manager):** dieselbe Liste, die die Seiten aufschiebt (wie früher). Beim Wechsel der Breite bleibt die gewählte Seite.
- **Oben in der Seitenleiste:** App-Symbol, Name (in Test-Apps „noty dev“ usw.), Version und Build; in einem Bereich zusätzlich „Bereich „…““. Dann das Suchfeld: Es sucht über einzelne Einstellungen (`SettingsSearchItem.index`), ein Treffer zeigt „Seite › Abschnitt“ und öffnet die Seite.

| Gruppe | Seite | Inhalt |
| --- | --- | --- |
| – | Allgemein | Bibliothek (Anordnung, Sortierung), Beim Start („Zuletzt geöffnetes Heft wieder öffnen“, neu), „Einstellungen zurücksetzen …“ (nur app-weite Werte, `AppSettingsKey.resettable`) |
| – | Darstellung | Akzentfarbe (9 Farben, neu), Vorschau, Hinweis auf das dunkle Design |
| Schreiben | Ansicht & Seiten | Seiten (Blättern, PDFs einheitlich: je Bereich), Schreiben (Schreibscrollen, Seitenleiste), Bearbeiten (Einrasten) |
| Schreiben | Text & Tastatur | Neue Textfelder, Beim Tippen, Hardware-Tastatur (Helix „Experimentell“, Klammern) |
| Schreiben | Stift & Werkzeuge | Stift und Bleistift (Autostift, Formen, **Durchkritzeln löscht** neu), Textmarker, Radierer, Eingabe (Finger), Werkzeugleiste anpassen, Apple Pencil (Systemwerte für Doppeltippen, Drücken und Schweben, nur Anzeige) |
| Schreiben | Papier für neue Hefte | unverändert |
| Funktionen | Gesetzessammlung, noty-Konto | unverändert, ohne den doppelten Link vom Konto |
| Daten | Backup & Wiederherstellen | Statuskarte, Automatisches Backup (→ „Ziel und Aufbewahrung“), iCloud-Ablage, Bibliotheksbackup als Datei, Wiederherstellen („Ältere automatische Backups“, „Bibliotheksbackup-Datei öffnen …“, Bereiche sobald es welche gibt) |
| Daten | Papierkorb | unverändert |
| – | Über noty | Version, Build (Tippen kopiert; siebenmal schaltet in der normalen noty die Entwickleroptionen ein), Datenablage, Signierung erneuern, Hinweise |
| – | Datenschutz | neu: was das iPad wann verlässt und was auf dem iPad bleibt |
| – | Entwickler | nur noty dev/AI/calendar oder freigeschaltet: Bereiche, Zwischen noty-Apps, Diagnose, Experimente (Neuer Texteditor), Interna |

## Regeln für neue Einstellungen

- **Zeile:** `settingToggle(Titel, detail:, badge:, isOn:)` bzw. `SettingLabel` als Label von Pickern: Titel und sichtbare Erklärung darunter, nicht nur als `accessibilityHint`. Jede Zeile bekommt eine `.keyOption(...)`, jede Seite `.keyboardSheet()`.
- **Ort:** in der Seite, zu der die Aufgabe gehört; nichts doppelt anbieten. Kontextnahe Kurzwege (Bibliotheksmenü, Werkzeugoptionen im Heft) dürfen bleiben.
- **Bereich:** Werte aus `toolbar.json` gelten je Bereich. Das sagt die Seite nur außerhalb von „Meine Bibliothek“ (`AreaScopeFooter`, `AreaNotice`); Bereiche sind ein Testwerkzeug.
- **Test- und Entwicklerwerkzeuge** nur über `DeveloperAccess.visible`; Bereiche über `DeveloperAccess.showsAreas(workspaces)`, damit ein wiederhergestellter Bereich auch in der normalen noty erreichbar bleibt.
- **Akzentfarbe:** Farbe über die Formatvorlage `.tint` (bzw. `AccentChoice.current.color` in `Canvas` und `AttributedString`), nie `Color.accentColor`. Das Heft behält `Color.notyAccent` für die Werkzeugleiste.
- **Suche:** Jede neue Einstellung bekommt einen Eintrag in `SettingsSearchItem.index` mit Seite, Abschnitt und Suchwörtern.
- **Neue Seite:** Fall in `SettingsPage` (Titel, Symbol, Farbe), Gruppe in `SettingsPage.groups`, Ziel in `SettingsView.destination`.

## Kalender (für `feat/kalender`)

Der Kalender hat heute keine Seite in den Einstellungen; seine Optionen liegen in drei Sheets und vier Menüs. Vorgesehen ist eine Seite **„Kalender“** in der Gruppe „Funktionen“ mit:

1. **Ansicht:** Wochentage (5/7), Quellen ein/aus (Stundenplan, Persönlich, Ferien, Apple Kalender). `hiddenSources` dabei speichern.
2. **Verbindungen:** WebUntis (Status, Aktualisieren, neu verbinden, trennen) und „Apple Kalender und Outlook“ (`CalendarSystemSection`) getrennt; „Neue Termine in“.
3. **Fachfarben** (Link auf das bestehende Sheet).
4. **Mitteilungen:** Erlaubnis, Stundenplanänderungen, Morgen-Überblick, Erinnerungen, Unterricht, Ruhezeiten, „Auch bei geschlossener App“. Ein Begriff („Mitteilungen“) statt Benachrichtigungen/Erinnerungen gemischt; was je Gerät und was je Bereich gespeichert ist, in der Zeile sagen.
5. **Entwickler-Seite:** „Beispieldaten anzeigen“, Test-Kachel, Planerzähler und Push-Diagnose dorthin, aus dem Kalender heraus.
6. **Datenschutz:** WebUntis (Zugang im Schlüsselbund, Abruf vom Schulserver) und der Push-Server (`NotyPushURL`) als eigene Zeilen in `PrivacySettingsPage`.

Die Sheets im Kalender können als Kurzwege bleiben, sollten aber dieselben Ansichten wiederverwenden.

## Bewusst nicht umgesetzt

- **Helles Design / „System“:** Die App erzwingt dunkel und enthält über 200 fest dunkle Farben; das wäre ein eigenes Projekt und eine neue Entscheidung zu DESIGN.md Q16/Q22.
- **Alternative App-Symbole:** technisch über `resources:` in `xtool.yml` und `CFBundleAlternateIcons` möglich, aber erst mit eigenen Symbolen; die Farbsymbole unterscheiden heute noty, noty dev und noty AI.
- **Ungeprüft am iPad:** Breite und Wechsel der Ansichten, Seitenleiste im Vollbild, Tastatur (⌘↓/⌘↑, Esc), Akzentfarben in Bibliothek, Heft und Ablage-Fenster, Zurücksetzen, Kopieren des Builds, Freischalten der Entwickleroptionen.
