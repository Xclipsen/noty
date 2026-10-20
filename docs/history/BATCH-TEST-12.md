# Sammeltest Build 12 – Seitenleiste und Schreibplatz

Stand 17.10.2026: **implementiert, gebaut/signiert und als Update installiert; Bedienung noch nicht auf dem iPad getestet**. 111 Core-Tests plus unabhängiger Host-Archiv-/Restore-Roundtrip bestanden. Der Test wird gebündelt mit Testdaten durchgeführt; keine kleinen Farb-/Menüvarianten einzeln abfragen.

Vor Installation: App ruhig/geschlossen, vollständige Documents per AFC unter `/home/la/Backups/<Zeitstempel>/` sichern, bestehende Hefte prüfen. IPA-Update über nachgewiesene doppelt präfixierte Identität; nicht deinstallieren. Update-Inhaltserhalt zurücklesen, neuen Testbereich verwenden. Kein ursprüngliches Schulheft für Randverkleinerung verwenden.

Update inzwischen am 17.10.2026 durchgeführt: Vorbestand unter `/home/la/Backups/noty-before-pages-12-2026-10-17T13-51-52Z/Documents/`, danach Rücklesen nach `after-update/Documents/`. 15 Hefte in vier Bereichen/25 referenzierte Revisionen gültig und vollständig unverändert; alle 82 vorhandenen Dateien bytegleich, keine neuen Documents-Dateien. `update-inspection.json` und `.tools/ios-install-pages-12.log`. Das belegt Installation/Inhaltserhalt, keinen neuen UI-/Pencil-/Migrationsnachweis.

## Ein gemeinsamer Durchlauf

1. In neuem Testbereich die lokal vorhandene `Seitenformate.pdf` als Heft importieren. Linke Leiste öffnen, ein-/ausklappen und iPad einmal drehen (ab Build 14 keine manuelle Breitenverstellung). Zwei Seiten anhand SOURCE-Nummern erkennen. Auf einer Seite Lesezeichen setzen, ein dunkles Karoblatt ergänzen und auf der PDF ein kurzes Wort/Strich ergänzen. Stiftfarbe auf dunklem Papier ausdrücklich passend wählen. Normales Schreiben/Undo darf durch Leistenänderung nicht gestört werden.
2. PDF-Seite duplizieren, Kopie verschieben, nur Kopie ändern; eine Seite löschen und im Seitenpapierkorb wiederherstellen. Prüfen, dass Quelle/Striche/Text beim Umordnen zusammenbleiben und Original/Kopie unabhängig sind. Eine weitere PDF über das Einfügefenster ergänzen. Vorhandenes PDF-Inhaltsverzeichnis nur mit einer PDF testen, die tatsächlich Outline-Ziele enthält; `Seitenformate.pdf` hat keines. Ohne passende Datei diesen Sichtnachweis offen lassen.
3. Über Seitenmenü „PDF-Schreibplatz“ links und oben Platz ergänzen; dort Pencil schreiben. Rand verkleinern: Warnung zunächst abbrechen, dann bestätigen. Ab Build 16 im Seitenpapierkorb „Gesicherter Seitenstand → Schreibplatz wiederherstellen“ wählen: dieselbe Seite muss den früheren Rand samt kompletter Handschrift zeigen, die Seitenzahl darf nicht wachsen. Der verdrängte verkleinerte Stand liegt jetzt im Papierkorb. Diesen zurückholen: dieselbe Seite zeigt wieder die neueren Inhalte; der breite Stand bleibt als Sicherung erreichbar. Speichern/Neustart und Weiterbearbeitung bündeln.
4. „Lokal gespeichert“ abwarten, App im Umschalter beenden und wieder öffnen. Seitenreihenfolge, Lesezeichen, Papierfarben, zusätzliche Ränder und Rand-Handschrift noch richtig? PDF exportieren und vollständiges Testbibliotheksbackup exportieren. Auf PC zurücklesen/CRC/Quellen/Seitenzuordnung/PDF-Ausgabe prüfen. Backup als neuen Bereich importieren, einen Pencil-Strich ergänzen, speichern/neustarten. Damit auch den noch offenen neuen Ink-nach-Restore-Nachweis aus Build 11 bündeln.

Nur falls im selben Durchlauf noch sinnvoll: gespeicherten vorigen lokalen Stand als Kopie öffnen; lokale Ink-Historie bleibt andernfalls ausdrücklich offen. Langer Schreibtest, große Dateien, WebDAV/iCloud und persönliche Alltagsfreigabe bleiben spätere Nachweise.

## Ergebnis

Erster Gerätedurchlauf **nicht bestanden**: Nutzer meldet dauerhaften Ladekreis im PDF-Schreibplatz, Zurückspringen beim Scrollen und versetzte Trefferflächen der Randregler (Links löst Unten aus). Screenshot IMG_0235 zeigt den Ladekreis im Randfenster und eine funktionierende kleine Seitenvorschau links. Sammeltest deshalb unterbrochen; keine Abnahme der Rand-/Pencil-/Restorefunktionen. Korrektur und gezielter Retest in [BUG-13-PREVIEW.md](../BUG-13-PREVIEW.md).

PC-Build/Hosttests ersetzen diese Laufzeitprüfungen nicht. PencilKit-Translation bei links/oben, neue Undo-Grenzen nach Randänderung und Sheet→Dateien-Übergang weiterhin unbestätigt.

Gezielter Build-13-UI-Retest inzwischen mit „ja passt“ bestätigt. Build 14 mit gewünschten Darstellungs-/Schnellwertanpassungen installiert, alle 17 Hefte/96 Dateien nach Update unverändert. Mit dem übrigen Durchlauf im vorhandenen Testheft fortfahren; keine Abnahme der noch offenen Pencil-/Rand-Restore-/Exportprüfungen daraus ableiten.

Build-15-Prozent-Retest bei gemischten PDF-Formaten vom Nutzer bestätigt. Die übrigen oben benannten Rand-Pencil-/Restore-/Exportnachweise bleiben offen; keine erneute Prüfung aller UI-Varianten nötig.

Build 16: Nutzer bestätigt den angeleiteten Restore-/Rücktausch-/Speichern-/Neustart-Test mit „ja passt alles“. Die Seite wird zurückgesetzt, der verdrängte Stand bleibt zurückholbar. PDF-Ausgabe und externen Backup-Roundtrip für dieses Rand-Testheft noch prüfen; Bestätigung nicht pauschal auf den gesamten historischen Sammeltest ausweiten.

Tatsächliche Build-16-Geräteausgabe am PC geprüft: fünfseitige PDF inklusive rechter Rand-Handschrift, korrekte Maße/Rotationen/Quelltext; vollständiges Heftbackup bytegenau gleich zum gespeicherten Heft, Host-Restore erfolgreich. Keine getippten Texte oder Links-/Oben-Ränder im Exportbeispiel. Zurückübertragenes `noty-rand-geprueft.notybackup` noch am Gerät als Kopie weiterbearbeiten/neustarten; damit neuen Rand-/Ink-Restore abschließen.

Nach korrigierter Explorer-Importanleitung bestätigt der Nutzer mit „ja passt...“ den externen Heft-Restore einschließlich neuer Pencil-Ergänzung und Speichern/Neustart. Rechtsrand-Export und dieser Restore sind damit belegt; keine pauschale Abnahme von Links-/Oben-Randexport, getipptem Text im neuen Export oder allen historischen Menüvarianten.
