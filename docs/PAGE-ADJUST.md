# Bestehende Seite anpassen: Schreibplatz auch für Papierseiten · 20.10.2026

Nutzerwunsch: eine vorhandene Seite nachträglich erweitern. Der Platz soll vor allem **rechts** wachsen, über denselben „Schreibplatz“ wie bei PDF-Seiten. Die Linien sollen **in den neuen Platz übergehen** und nicht abschneiden. Diese Entscheidung ersetzt den ersten Konzeptvorschlag vom selben Tag, die Papierseite über ihre Geometrie nur nach unten zu verlängern.

## Bedienung

- **Zugänge:**
  - Seitenleiste › Seitenmenü: „Seite anpassen …“ bei Papierseiten, „Schreibplatz …“ bei PDF-Seiten. Vorher hieß der Eintrag „PDF-Schreibplatz …“ und gab es nur für PDF-Seiten.
  - Editor › „…“ › „Diese Seite anpassen …“, gleich neben „Papier für neue Seiten …“. Der Eintrag ist ausgegraut auf der leeren Reserve-Seite und auf Prototyp-Testseiten.
- **Dialog „Seite anpassen“ bei Papierseiten** (Nutzerentwurf vom 20.10., im noty-Stil mit dunklen Karten und Akzentfarbe):
  - **Vorschau:** Der neue Platz ist gestrichelt in der Akzentfarbe markiert.
  - **Mehr Platz:**
    - „Rechts verlängern“ und „Unten verlängern“, jeweils mit Schalter, Stufen „+¼ / +½ / +1 Seite“ und feinem Regler.
    - Startwert: rechts +1 Seite, wie beim PDF-Schreibplatz. Unten startet beim Einschalten mit +½.
    - Darunter „Gilt für“: „Diese Seite“ oder „Alle Papierseiten“. Bei „Alle Papierseiten“ wächst jede vorhandene Papierseite um denselben Anteil ihrer Größe.
    - PDF-Seiten, neue Seiten und gelöschte Seiten bleiben unverändert.
  - **Papier dieser Seite:**
    - Vorlage (Blanko/Liniert/Kariert) und Farbe (Weiß/Dunkel) nur für diese Seite. Der zusätzliche Platz folgt automatisch.
    - Beim Farbwechsel wird schwarze und weiße Schrift getauscht, farbige bleibt (`Notebook.setPaper`, gleiche Umfärbung wie „Ganzes Notizbuch“).
- **Nie etwas löschen:**
  - Die Regler enden am vorhandenen Inhalt (Handschrift, Text, Bilder, Formen), und solange dort Inhalt liegt, lässt sich die Seite nicht ganz zurückschalten.
  - Würde „Alle Papierseiten“ auf einer anderen Seite Handschrift abschneiden, bricht das Anwenden mit einem Hinweis ab, statt zu löschen.
  - Undo funktioniert, alles ist ein Schritt.
- **PDF-Seiten:** Dialog „Schreibplatz“ wie bisher, also vier Seiten, eigenes Papier/Farbe, „Dieser PDF-Import“ und Verkleinern mit Sicherung im Seitenpapierkorb.

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
- Schreibplatz als Standard für neue Seiten.

## Nachweise

- **Implementiert** auf `ui/menu-polish`.
- **Installiert (20.10.2026, 16:02):** Build 48 (IPA `bef3dca0…`, gleiche App-ID/Team/Zertifikat wie Build 46, Profil bis 27.10.2026) per `xtool install --usb`. Vorher alle Documents gesichert unter `/home/la/Backups/noty-before-build48-2026-10-20T14-02-03-869620305Z/`, danach installierte Version 48 bestätigt und frisch zurückgelesen: 3 Notizbücher, 23 Dateien unverändert, `verify_device_store.py --compare` meldet 3 unveränderte Dokumente, keine Quarantäne.
- **Core-Tests:** zusammen mit Build 47 495/495, davon 9 in `PaperWritingSpaceTests`.
- **Host-Roundtrip:** mit Papierseite plus Schreibplatz (Schema 11) bestanden, Python-Prüfer für Heft-, Bibliotheks- und Gerätespeicher eingeschlossen.
- **Negativproben im Python-Prüfer** werden abgelehnt: links, oben, fremde Vorlage, fremde Farbe, Schema 10.
- **SDK-Build:** iPad-SDK-Build 48 ohne Fehler und Warnungen, siehe auch [UI-POLISH](UI-POLISH.md).
- **Auf dem iPad ungeprüft:**
  - Schreiben im neuen Platz.
  - Lineatur-Übergang in Editor, Vorschau und PDF.
  - Einpassen und Schreibscrollen.
  - Text in der rechten Spalte.
  - Grenze beim Verkleinern.
  - Farbwechsel einer beschriebenen Seite.
