# Zoom-Grenze, durchgehende Fläche, Schreibscrollen und Strichstärke · Feedback 33

## Auftrag (Screenshot 18.10., 22:54)

Beim Herauszoomen mit zwei Fingern driftet das Blatt zur Seite; es soll mittig bleiben. Eigene Kopfleiste unter der Werkzeugleiste entfernen, Zurück-Pfeil/Heftname als Glasblase. Herauszoomen bis ca. drei Seitenbreiten auf den Bildschirm passen; darüber hinaus elastisch, dann zurückschnappen. Seiten enger aneinander, Hintergrund außerhalb der Seiten grau, dunkle Seiten schwarz mit grauen Linien. Neuer Modus rechts neben Wiederholen: seitlich scrollen, bis höchstens noch die Blattmitte sichtbar ist; bei Schreibplatz bis dieser noch zu 50 % sichtbar ist. Stift auf dem Schreibplatz neben einer PDF deutlich dünner als auf normalen Seiten; auch andere Stifte sollen passen.

## Umsetzung

- `NotebookViewportGeometry.zoomRange`: Minimum = Viewportbreite / (3 × Grundseitenbreite), höchstens Ganzblatt/Breite. Elastisches Minimum bleibt 0,65 × Minimum; `zoomDestination` schnappt darunter auf das Minimum zurück, zentriert horizontal und behält die vertikale Leseposition (früher: Sprung auf Ganzblatt-Mitte). Breiteneinpassung (±8 %) unverändert, Maximum unverändert ≥ 6×.
- `NotebookViewport`: Horizontalbegrenzung läuft jetzt auch während des Pinchs (Ziel nach dem UIScrollView-Handler), dadurch bleibt ein schmaleres Blatt mittig. Seitlicher Scrollraum = Viewportbreite; tatsächliche Grenze je Seite über `horizontalOffset`.
- Schreibscrollen (`@AppStorage("noty.editor.writingScroll")`, Kopfzeilenknopf rechts neben Wiederholen und Toggle im Optionsmenü): `NotebookPagePlacement.writingScrollAnchors` liefert die Mitte des äußersten linken/rechten Bereichs (Rand zählt als eigener Bereich). Grenze: linker Anker an rechter Bildschirmkante, rechter Anker an linker. Reine Anzeigeeinstellung, kein Heft-/Werkzeugformat geändert.
- Keine Kopfleiste mehr: Editor nutzt die volle Höhe; Kopf/Palette schweben darüber, `contentInset.top` = Kopfhöhe (+ Optionsleiste), Caret-Reveal berücksichtigt den verdeckten Bereich. Zurück + Titel in `notyGlass` (Titel entfällt bei sehr schmalem Platz). Kopfaktionen: 6 voll, schmaler entfallen „Seite hinzufügen“, dann Schreibscrollen, dann Wiederholen (`ToolbarLayout.headerActionCount`).
- Seitenabstand `NotebookViewportLayout.pageGap` 24 → 8; Hintergrund außerhalb der Seiten Grau 0,2 (auch Statusleistenbereich). Dunkles Papier war bereits Schwarz mit grauen Linien (0,3); unverändert, damit Export/Vorschau gleich bleiben.
- `Page.inkWidthScale` = dargestellte Grundbreite / 595. Stift-, Marker- und Radiererbreite werden damit in kanonische Seiteneinheiten umgerechnet: Auf normalisiert angezeigten großen Scans (z. B. 1190 pt breit, Anzeige-Skalierung 0,5) samt Schreibplatz erscheint der Strich so dick wie auf normalem Papier. Bereits gespeicherte Striche werden nicht umgeschrieben.

## Nachweise und Grenzen

270 Core-Tests ohne Fehler (`.tools/core-editor33.log`), neue Klasse `ViewportWriting33Tests` (Drei-Seiten-Grenze und Rückschnappen, Zentrierung, Schreibscroll-Grenzen mit/ohne Rand, Seitenabstand, gleiche angezeigte Strichstärke). Angepasste ältere Tests: Ganzblatt-Minimum → Drei-Seiten-Minimum, Kopfaktionen 6, Inset = Viewportbreite. `xtool dev build` in PTY erfolgreich (`.tools/build-feedback33.log`). Signiert gebaut und als Build 33 installiert, alle 23 Hefte/159 Dateien nach Rücklesen unverändert ([TESTING](TESTING.md)). **Auf dem iPad ungeprüft**: Pinch-Gefühl, Rückschnappen, Schreibscrollen, Glasblase, Strichstärke auf echten Scans. Kein Host-Roundtrip nötig: kein Speicher-/Formatcode geändert.

## Nachtrag: Hänger bei starkem Zoom (Builds 34–37)

Nutzerbefund nach Build 33: Bei starkem Zoom hakt alles, Rauszoomen unmöglich, Handschrift „verschiebt sich“; auch ohne Handschrift. Kein Absturzbericht; Gerätelog (`idevicesyslog`) zeigte HangTracer-Hänger 0,8–6 s.

- **Build 34 (Fehlannahme):** Ink-Auflösung auf `EditorRenderGeometry.maximumInkScale` = 4·√2 begrenzt, PencilKit-Viewport während Pinch nur bei fehlender Abdeckung neu, PencilKit-eigener Pinch nach jedem Zoomsetzen deaktiviert. Hänger blieben (bis 5,7 s) → Kachelstufe war nicht die Ursache. Begrenzung bleibt als Speicherschutz.
- **Build 35 (Diagnose):** `HangProbe` — Watchdog-Thread tastet bei >0,7 s blockiertem Hauptthread dessen Frame-Pointer-Kette ab (nur Adressen/Bildnamen) und zählt markierte Codepfade je Runloop-Iteration. Ergebnis aller 11 Stichproben: Hauptthread in **PDFKit** (eigener Main-Queue-Block, QuartzCore-Layeraufbau); eigener Code nicht auf dem Stapel, nur 5–36 Viewport-Aufrufe je Iteration.
- **Build 36 (Behebung):** `PDFSourceRasterView` ersetzt `PDFView` im Editor: kleines Ganzseitenbild (≤2,5 MP) plus scharfer sichtbarer Ausschnitt (≤12 MP) auf serieller Hintergrundqueue, gleiche Geometrie wie Export (`sourceFrame`-Clip + `pdfToCanvas`). `PDFView` erhält nur noch im Lesewerkzeug ein Dokument. Nutzer: **keine Ruckler**; Log: kein Hänger, keine Stall-Stichprobe.
- **Build 37:** Zweiter Fehler im Log sichtbar: Der Pinch-Target wurde in `init` angehängt, als `pinchGestureRecognizer` noch `nil` war (UIScrollView erzeugt ihn erst bei min < max). Mittiges Halten während des Pinchs (Build 33) und Abschluss-Neuzeichnen liefen daher nie. Jetzt in `layoutSubviews` einmalig angehängt.

Grenzen: Lesewerkzeug nutzt weiter PDFKit und kann bei starkem Zoom erneut hängen. Native PDF-Schärfe/Position, gedrehte/Crop-Seiten im neuen Renderer und Pinch-Zentrierung ab Build 37 nur durch Nutzerangabe bzw. **noch ungeprüft**. `HangProbe` bleibt vorerst aktiv (geringe Last: 100-ms-Watchdog, Zähler).
