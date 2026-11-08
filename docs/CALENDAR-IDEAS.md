# Kalender – Feature-Vorschläge (08.11.2026)

Ideensammlung, **nicht beauftragt** (außer wo „umgesetzt“ steht). Erstellt nach Durchsicht von CALENDAR-PLAN, SCOPE und Kalendercode auf `feat/kalender` (Build 129). Umschalter, Zoom und neues Terminfenster sind bewusst nicht enthalten. Stand der Spalte „Stand“: 08.11.2026; Einzelheiten zu umgesetzten Punkten in [CALENDAR-PLAN](CALENDAR-PLAN.md#stand-je-funktion), Nachweise in [CALENDAR-LOG](CALENDAR-LOG.md).

| # | Vorschlag | Aufwand | Formatänderung | Einschätzung | Stand |
|---|---|---|---|---|---|
| 1 | **„Jetzt mitschreiben“**: Knopf/Kürzel öffnet die laufende (bzw. nächste) Stunde direkt mit Notiz | S | nein | sehr lohnend | offen |
| 2 | **Letzte Stunde im Blick**: im Terminfenster Vorschau der letzten Notiz desselben Kurses (über `lessonID`) + offene Hausaufgaben | S–M | nein | sehr lohnend | offen (offene Hausaufgaben stehen inzwischen im Terminfenster) |
| 3 | **Stundenplanänderungen hervorheben**: „Neu“-Marken, Abschnitt „Änderungen“, optionale Mitteilung | M | nein (Cache) | sehr lohnend; hängt an den WebUntis-Status ([CALENDAR-PLAN §9](CALENDAR-PLAN.md#9-offene-punkte)) | **umgesetzt** als Benachrichtigungen: Änderungsmitteilungen, Verlauf in der Glocke, Änderungen im Morgen-Überblick (Build 136), Push bei geschlossener App (Build 137), Änderungsmarke in der Schultag-Kachel (Build 138). Nicht umgesetzt: „Neu“-Marken im Raster |
| 4 | **Fachansicht**: alle Stundennotizen eines Fachs chronologisch durchblättern, gemeinsamer PDF-Export (nur Links, kein Sammelheft) | M | nein | hoch | **anders umgesetzt** als Lernfeld-Hefte mit Stunden als Überschriften ([LERNFELDER](LERNFELDER.md), am iPad ungeprüft) |
| 5 | **Klausuren** mit Countdown und vorgeschlagenen Lernblöcken | M–L | ja (Format 5) | hoch | offen |
| 6 | Freie Zeit doppelt antippen → Schnell anlegen vorbelegt (Scribble im Feld) | S | nein | hoch | offen |
| 7 | Eigene Hausaufgaben „bis zur nächsten Stunde“ | M | ja | erst Abgrenzung zum Merker klären | offen |
| 8 | Kanzlei-Fristen aus dem Merker im Kalender | L | ja | erst nach Merker M1; Mandantennamen schützen | offen |
| 9 | Fehltag: verpasste Stunden und fehlende Mitschriften auflisten | S–M | ja (klein) | mittel | offen |
| 10 | Heft auf Termin ziehen (verknüpfen) | M | nein | mittel | offen |
| 11 | Woche/Stundenplan als PDF/Druck | M | nein | mittel–niedrig | offen |
| 12 | Kurzbefehle/Siri (App Intents) | M | nein | mittel; xtool-Unterstützung ungeprüft | offen |
| 13 | Heute-Widget/Sperrbildschirm | L | nein | mittel; eigene Extension/App-ID nötig | **umgesetzt** (beauftragt 08.11.2026): Live Activity „Schultag“ und Widget „Heute“ mit eigener Extension, Build 138/139 ([LIVE-ACTIVITY-PLAN](LIVE-ACTIVITY-PLAN.md)); Test-Kachel vom Nutzer bestätigt, Widget am iPad ungeprüft |
| 14 | Noten pro Fach | M | ja | nur auf ausdrücklichen Wunsch | offen |

Empfohlene Reihenfolge: Gerätetest des bestehenden Stands (echte WebUntis-Status) → 1, 6, 2 → 4 → 5/7/9 gebündelt in einem Formatwechsel → 7/8 nach Merker-Entscheidung.
