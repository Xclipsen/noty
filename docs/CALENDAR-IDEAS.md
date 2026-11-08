# Kalender – Feature-Vorschläge (08.11.2026)

Ideensammlung, **nicht beauftragt**. Erstellt nach Durchsicht von CALENDAR-PLAN, SCOPE und Kalendercode auf `feat/kalender` (Build 129). Umschalter, Zoom und neues Terminfenster sind bewusst nicht enthalten.

| # | Vorschlag | Aufwand | Formatänderung | Einschätzung |
|---|---|---|---|---|
| 1 | **„Jetzt mitschreiben“**: Knopf/Kürzel öffnet die laufende (bzw. nächste) Stunde direkt mit Notiz | S | nein | sehr lohnend |
| 2 | **Letzte Stunde im Blick**: im Terminfenster Vorschau der letzten Notiz desselben Kurses (über `lessonID`) + offene Hausaufgaben | S–M | nein | sehr lohnend |
| 3 | **Stundenplanänderungen hervorheben**: „Neu“-Marken, Abschnitt „Änderungen“, optionale Mitteilung | M | nein (Cache) | sehr lohnend; WebUntis-Status außer REGULAR erst am echten Fall bestätigen |
| 4 | **Fachansicht**: alle Stundennotizen eines Fachs chronologisch durchblättern, gemeinsamer PDF-Export (nur Links, kein Sammelheft) | M | nein | hoch |
| 5 | **Klausuren** mit Countdown und vorgeschlagenen Lernblöcken | M–L | ja (Format 5) | hoch |
| 6 | Freie Zeit doppelt antippen → Schnell anlegen vorbelegt (Scribble im Feld) | S | nein | hoch |
| 7 | Eigene Hausaufgaben „bis zur nächsten Stunde“ | M | ja | erst Abgrenzung zum Merker klären |
| 8 | Kanzlei-Fristen aus dem Merker im Kalender | L | ja | erst nach Merker M1; Mandantennamen schützen |
| 9 | Fehltag: verpasste Stunden und fehlende Mitschriften auflisten | S–M | ja (klein) | mittel |
| 10 | Heft auf Termin ziehen (verknüpfen) | M | nein | mittel |
| 11 | Woche/Stundenplan als PDF/Druck | M | nein | mittel–niedrig |
| 12 | Kurzbefehle/Siri (App Intents) | M | nein | mittel; xtool-Unterstützung ungeprüft |
| 13 | Heute-Widget/Sperrbildschirm | L | nein | mittel; eigene Extension/App-ID nötig |
| 14 | Noten pro Fach | M | ja | nur auf ausdrücklichen Wunsch |

Empfohlene Reihenfolge: Gerätetest des bestehenden Stands (echte WebUntis-Status) → 1, 6, 2 → 3, 4 → 5/7/9 gebündelt in einem Formatwechsel → 7/8 nach Merker-Entscheidung.
