# UI-Feinschliff: Menüs, Icons, App-Icon · 19.10.2026

Nutzerauftrag: „Wenn man in einer Seite drin ist und auf … geht, wird man fast erschlagen.“ Konzept für einfache Bedienung, andere Menüs dürfen angepasst werden, App soll wie eine fertige App wirken. Dazu Nutzerentwürfe für App-Icon und Werkzeug-Icons (HTML-Mockups, 19.10.2026). Keine Funktion entfernt, keine Format-/Speicheränderung.

## Leitregeln

- **Ein Ort pro Aufgabe.** Was in der Kopfzeile sichtbar ist (Rückgängig, Wiederholen, Seite hinzufügen), steht nicht zusätzlich im Menü. Fehlt es dort aus Platzgründen, erscheint es im Menü (Build-26-Regel bleibt erfüllt).
- **Häufiges oben, Seltenes in Untermenüs, Zerstörerisches unten.** Gruppen statt langer Listen.
- **Status ist kein Menüeintrag.** Routinezustände („Lokal gespeichert“) stehen nur noch als Überschrift im Optionenmenü. Unten links erscheint nur, was Aufmerksamkeit braucht oder gerade passiert ist.
- **Einheitliche Sprache und Symbole:** „Notizbuch“ statt „Heft“, „…“ hinter Einträgen, die einen Dialog öffnen, ein Symbol pro Bedeutung, „ellipsis“ für Überlaufmenüs, „Fertig“ für informative Sheets.

## Editor: Optionenmenü („…“)

Vorher bis zu 25 Zeilen: vier bis fünf Statuszeilen, doppeltes Rückgängig/Wiederholen, drei Schalter und neun bis zehn Export-/Backup-Zeilen ohne Gruppierung. Drei davon (PDF importieren, Backup als Kopie wiederherstellen, Wiederhergestellte Kopien) waren im Editor nie erreichbar, weil der Editor immer als Bibliotheksdokument oder Restore-Kopie geöffnet wird.

Jetzt (`ContentView.optionsMenu`):

| Gruppe | Einträge |
| --- | --- |
| Überschrift | Speicherstatus; bei Fehler „Erneut speichern“; Werkzeugstatus nur wenn vorhanden |
| (nur schmale Kopfzeile) | Wiederholen, Seite hinzufügen ▸ |
| Arbeiten | Im Notizbuch suchen (⌘F) · Teilen und exportieren ▸ (PDF: Diese Seite, Ganzes Notizbuch · Vollständiges Backup …, mit Backupstatus als Überschrift) |
| Anzeige und Notizbuch | Ansicht ▸ (Schreibscrollen, Blättern, PDFs einheitlich) · Papier für neue Seiten … · Lokale Wiederherstellungspunkte … |
| App | Einstellungen … |

Entfallen: „Jetzt speichern“ (Autosave und Sichern beim Verlassen bleiben unverändert; Fehlerfall weiterhin per „Erneut speichern“), die drei toten Einträge und die Statuszeilen als eigene Menüzeilen.

**Statushinweis unten links:** nicht mehr dauerhaft „Lokal gespeichert“. Sichtbar bei Speicherfehler (orange, antippen speichert erneut), bei ungewöhnlichen Zuständen wie Lesefehler/Wiederherstellungskopie sowie vier Sekunden nach Export-/Backup-/Papiermeldungen. Die Animation ist auf den Hinweis begrenzt; Autosave-Updates im Editor bleiben unanimiert.

## Seitenleiste

- Kopfmenü gruppiert: Seite hinzufügen …, Seiten anordnen | Seitenpapierkorb (n) …, Zu den Notizbüchern.
- Seitenmenü behält die bestätigte Reihenfolge (UI-REBUILD §6) und wird wie die Referenz gruppiert: Seite hinzufügen | Ausschneiden, Kopieren, Einfügen, Duplizieren | Lesezeichen, PDF-Schreibplatz …, Verschieben ▸ | Seite leeren, Löschen. Zusätzliche Einträge stehen wie „Vorlage erstellen“ in der Referenz zwischen Duplizieren und den zerstörerischen Aktionen.
- Symbole entdoppelt: Duplizieren `plus.square.on.square` (vorher wie Kopieren), PDF-Schreibplatz eigenes Erweitern-Symbol (vorher wie Seitenbreite einpassen), Verschieben `arrow.up.arrow.down.square` (vorher wie Seiten anordnen). Seitenmenü-Knopf `ellipsis` statt `chevron.down` (das bleibt dem Filter vorbehalten).

## Bibliothek und Einstellungen

- Werkzeugleiste von bis zu acht auf sechs Bedienelemente: Backup-Hinweis (nur bei Bedarf), Inhalte suchen, Darstellung, Bearbeiten (nur beim Umordnen), **Neu** (Notizbuch, Ordner | PDF importieren …, Backup als Kopie importieren …, Wiederhergestellte Kopien …), Einstellungen.
- Einstellungen in drei Gruppen; die einzelne „Diagnose“-Seite ist als Abschnitt in „Über noty“ aufgegangen (gleicher Schalter, gleicher Speicherschlüssel).
- „Meine Bibliothek“ statt „Hauptbibliothek“, „Lokale Wiederherstellungspunkte“ einheitlich, „Fertig“ in informativen Sheets.

## Icons

- **App-Icon** nach Nutzerentwurf (dunkle Variante: Glasblatt mit leuchtendem „n“-Strich). `Resources/AppIcon.svg` ist die Quelle, `Resources/AppIcon.png` (1024 × 1024, deckend, vollflächig; iOS maskiert die Ecken) wird über `iconPath` in `xtool.yml` eingebunden. xtool setzt `CFBundleIconFile`; helle/getönte Varianten bräuchten einen Asset-Katalog (actool), den es unter Linux nicht gibt.
- **Werkzeug-Icons** nach Nutzerentwurf als native SwiftUI-Pfade (`ToolbarGlyph.swift`): Stift, Marker (Keil- und Rundspitze), Radierer, Präzisionsradierer, Lasso, Gemischtes Lasso („Auswahl“), Text, Formen, Bild, PDF lesen. Bleistift und Laserpointer fehlten im Entwurf und sind im selben Stil ergänzt. Rückgängig/Wiederholen in der Kopfzeile nutzen die Entwurfsglyphen. Ausgewähltes Werkzeug mit dezentem Akzent (#7DD3FC) statt grauem Feld.

![Werkzeug-Icons nach Entwurf](assets/ui-polish/werkzeug-icons.png)

## Stand und Nachweise

- **Implementiert** auf Branch `ui/menu-polish` (Worktree `noty-ui-polish`), zunächst als 46.1 auf Basis von Build 46. Der UI-Feinschliff selbst ändert weder Core noch Format. 46.2 ergänzt den Schreibplatz für Papierseiten (Schema 10, [PAGE-ADJUST](PAGE-ADJUST.md)).
- **Erfolgreich gebaut:** zwei `xtool dev build` und `xtool dev build --sign --ipa` ohne Fehler und ohne Warnungen in den geänderten Dateien. IPA geprüft: `XTL-BAFXLQ964V.de.la.noty.prototype`, Team BAFXLQ964V, gleiches Zertifikat wie Build 46 (`50f3e096…`), `CFBundleIconFile`/`CFBundleIcons~ipad` = AppIcon, Profil bis 26.10.2026. Glyphen per Rückrender-Vergleich mit dem Entwurf (0 abweichende Pixel bei 80/28 px, Subagent).
- **Installiert (20.10.2026, 16:02):** Build 48 (IPA `bef3dca0…`, gleiche App-ID/Team/Zertifikat wie Build 46, Profil bis 27.10.2026) per `xtool install --usb`. Vorher alle Documents gesichert unter `/home/la/Backups/noty-before-build48-2026-10-20T14-02-03-869620305Z/`, danach installierte Version 48 bestätigt und frisch zurückgelesen: 3 Notizbücher, 23 Dateien unverändert, `verify_device_store.py --compare` meldet 3 unveränderte Dokumente, keine Quarantäne.
- **Auf dem iPad getestet:** nein. Offen: Optionenmenü in breiter/schmaler Kopfzeile (Wiederholen/Seite hinzufügen nur bei Platzmangel), Untermenüs Teilen/Ansicht, Statushinweis bei Export und Speicherfehler, Seitenmenü-Gruppen, „Neu“-Menü der Bibliothek, Einstellungen/Über noty, Werkzeugglyphen und Auswahlfarbe im Glas (Leuchtrand am Zellrand), App-Icon auf dem Home-Bildschirm (ohne Asset-Katalog).
