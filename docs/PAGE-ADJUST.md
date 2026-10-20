# Bestehende Seite anpassen: Schreibplatz auch für Papierseiten · 20.10.2026

Nutzerwunsch: eine vorhandene Seite nachträglich erweitern. Der Platz soll vor allem **rechts** wachsen, über denselben „Schreibplatz“ wie bei PDF-Seiten. Die Linien sollen **in den neuen Platz übergehen** und nicht abschneiden. Diese Entscheidung ersetzt den ersten Konzeptvorschlag vom selben Tag, die Papierseite über ihre Geometrie nur nach unten zu verlängern.

## Bedienung

- **Zugänge:**
  - Seitenleiste › Seitenmenü › „Schreibplatz …“ für PDF- und Papierseiten. Vorher hieß der Eintrag „PDF-Schreibplatz …“ und gab es nur für PDF-Seiten.
  - Editor › „…“ › „Schreibplatz dieser Seite …“, gleich neben „Papier für neue Seiten …“. Der Eintrag ist ausgegraut auf der leeren Reserve-Seite und auf Prototyp-Testseiten.
- **Dialog „Schreibplatz“ bei Papierseiten:**
  - Nur **Rechts** und **Unten**, jeweils mit Schalter, Regler und Schmal/Mittel/Breit (25/60/100 % der Seitenbreite bzw. -höhe).
  - Startwert: rechts 100 %, wie beim PDF-Schreibplatz.
  - Es gibt keine eigene Papierwahl, denn der Platz ist dasselbe Papier wie die Seite. Die Vorschau zeigt das Ergebnis.
- **Anwenden auf:**
  - „Aktuelle Seite“ oder „Alle Papierseiten“: jede vorhandene Papierseite mit demselben Anteil ihrer eigenen Größe.
  - PDF-Seiten bleiben dabei unverändert, ebenso neue Seiten und gelöschte Seiten.
- **Verkleinern wie beim PDF-Rand:**
  - Text, Bilder oder Formen im wegfallenden Bereich blockieren.
  - Handschrift dort wird nach Rückfrage entfernt. Der vollständige vorherige Stand landet im Seitenpapierkorb und lässt sich an Ort und Stelle wiederherstellen.
  - Undo funktioniert.
- **PDF-Seiten:** unverändert, also vier Seiten, eigenes Papier/Farbe und „Dieser PDF-Import“.

## Warum nur rechts und unten bei Papier

Inhalte und Lineatur sind ab der linken oberen Blattecke gespeichert. Platz links oder oben würde alles verschieben oder die Linien gegeneinander versetzen. Rechts und unten laufen die Linien dagegen nahtlos weiter, ohne Bruch und ohne Trennlinie, und an bestehenden Inhalten ändert sich nichts.

## Technik

Details in [STORAGE](STORAGE.md#ergänzung-20102026--notebook-schema-11-schreibplatz-an-papierseiten).
- **Schema 11:**
  - `margins` an Papierseiten ist nur rechts/unten erlaubt, in Papierart und -farbe der Seite.
  - Gehoben wird erst beim Anwenden, nachdem die exakten Altbytes archiviert sind.
  - Ältere Builds sperren solche Notizbücher.
- **Gleicher Maßstab:** Schreibplatz neben Papier nutzt Seiteneinheiten (`writingSpaceExtendsPaper`, Maßstab 1). Text im neuen Platz ist eine eigene Spalte, wie beim PDF-Rand. Läuft er über, geht es auf einer normalen neuen Seite weiter.
- **Notizbuchweiter Papierwechsel:** zieht den Schreibplatz mit.
- **Nicht betroffen:** Reserve-Seite und Folgeseiten bekommen keinen Schreibplatz.

## Nicht umgesetzt (bewusst)

- Platz links/oben an Papierseiten (siehe oben).
- Endlose Seite oder automatisches Wachsen beim Schreiben.
- Format eines beschriebenen Blatts tauschen.
- Vorlage/Farbe für eine einzelne Seite; das bleibt eine mögliche spätere Ergänzung.
- Schreibplatz als Standard für neue Seiten.

## Nachweise

- **Implementiert** auf `ui/menu-polish`.
- **Core-Tests:** 449/449, davon 8 neue in `PaperWritingSpaceTests`.
- **Host-Roundtrip:** mit Papierseite plus Schreibplatz (Schema 11) bestanden, Python-Prüfer für Heft-, Bibliotheks- und Gerätespeicher eingeschlossen.
- **Negativproben im Python-Prüfer** werden abgelehnt: links, oben, fremde Vorlage, fremde Farbe, Schema 10.
- **SDK-Build:** siehe [UI-POLISH](UI-POLISH.md).
- **Auf dem iPad ungeprüft:**
  - Schreiben im neuen Platz.
  - Lineatur-Übergang in Editor, Vorschau und PDF.
  - Einpassen und Schreibscrollen.
  - Text in der rechten Spalte.
  - Verkleinern mit Wiederherstellen.
