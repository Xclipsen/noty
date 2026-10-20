# Sammeltest für Build 11

Status: Build 11 am 17.10.2026 erfolgreich als Update installiert. Vorher/Nachher-Gerätebackup geprüft: alle sechs Hefte vollständig gleich, alle 32 zuvor vorhandenen App-Dateien bytegleich. Nutzer bestätigt den ersten Bedienungsblock 1–4 (Wiederfinden, Testbereich, PDF/Übersicht und grundlegende Leisten-/Undo-/Lasso-Bedienung). Dateiinventur bestätigt Testhefte und Ink sowie unveränderten Altbestand. Gezielter Neustart-/Präferenztest und Backup-/Restoretest D–F bleiben offen. Siehe TESTING.md für Umfang und Grenzen der Rückmeldung.

Fortschritt: Nutzer bestätigt Neustart und Export ohne Fehler. Echtes Gerätearchiv mit drei Heften, zwei Ordnern, einem Papierkorbeintrag und zwei Lieblingsstiften auf dem PC geprüft, vollständig gleich zum gespeicherten Testbereich. Geprüfte und gezielt beschädigte Testkopie zurück auf dem iPad, Transfer bytegenau geprüft. Nächster Block: E und beschädigtes Archiv aus F. Spezifische Linksposition, Fingeroption, Umordnung/Fensterwechsel und lokale Historie nicht pauschal abgenommen.

Aktueller Abschluss: E und beschädigter Import aus F vom Nutzer bestätigt. Beide gültigen Restore-Bereiche zurückgelesen, Archivmetadaten/Quellen/vorhandene Ink erhalten, Textänderung in Restore 3 gespeichert. Ausgangsheftinhalte unverändert; dessen Reihenfolge/Papierkorbmarker wurden seit Export verändert. Neue Pencil-Bearbeitung in Restore noch nicht in Dateien belegt, lokale Historie weiter offen. Auf Nutzerwunsch jetzt keine weiteren Routine-Einzeltests; unwichtige Varianten überspringen, wichtige offene Punkte beim nächsten Speichertest bündeln. Details in TESTING.md.

## A – Vorbestand und Testbereich

Zuerst nur ansehen: „Meine Bibliothek“ → `+ → Kopien mit Textvorschau finden` → `RESTORE-17` → Seite 2. Sind Wort und Handschrift da? Dieser frühere Sichtnachweis ist weiterhin offen. Bei fehlenden Inhalten zunächst klären.

Danach `Bereiche → Neuen Testbereich anlegen`, anschließend dessen neuen Eintrag öffnen. Oben müssen der Testname und „Getrennter Bereich“ stehen. Zwei Demoordner und das Heft „Werkzeugtest“ vorhanden? Neue Eingaben ab hier ausschließlich in diesem Testbereich.

## B – Seitenübersicht und Bibliothek

Die lokale `Seitenformate.pdf` aus dem bisherigen Test als **neues Heft** importieren. Falls sie fehlt, vor dem Test aus `fixtures/Seitenformate.pdf` per USB bereitstellen. „Seiten“ im Editor öffnen: vier Vorschaubilder in korrekter Rotation/Proportion, Sprung zu Seite 2. Strich und eindeutigen Text setzen, Übersicht schließen/öffnen; Vorschau aktualisiert, richtige Seite geöffnet? Ordner-/Such-/Favoriten-/Papierkorbtest aus [BATCH-TEST-10.md](BATCH-TEST-10.md) ebenfalls nur mit Testheften ausführen.

## C – Eigene Werkzeugleiste

Stift erneut antippen: Farbe/Breite ändern, als Lieblingsstift speichern. Über Schieberegler-Symbol Leiste links/rechts/oben sowie schwebend einstellen, Werkzeuge umordnen. Schwebende Leiste am Griff bewegen; Hoch-/Querformat und kleinere Fenster prüfen. Werkzeuge bleiben erreichbar, Schriftpositionen unverändert? Nach Positionswechsel Undo/Redo für einen vorherigen Strich prüfen; Canvas soll erhalten bleiben.

Fingermalen ausdrücklich aktivieren: Finger zeichnet, zwei Finger navigieren. Wieder deaktivieren: Finger navigiert und erzeugt keine Striche. Pencil, beide Radierer, Lasso nach Texteingabe, Textfokus und Undo/Redo gemeinsam nachprüfen. Schließen, App beenden/neustarten, über „Bereiche“ Test wieder öffnen: Reihenfolge, Lieblingsstift, Farbe/Breite, Position und Fingeroption erhalten?

## D – Vollständiges Bibliotheksbackup

Im Testbereich: Hefte schließen, ein Testheft in Papierkorb lassen. `Sicherung → Bibliotheksbackup exportieren`. Das `.notylibrary` außerhalb des noty-Containers speichern oder anschließend auf den PC kopieren; Datei dort mit `scripts/verify_library_backup.py` prüfen. Heft- und Ordnerzahl/Papierkorb/Favorit mit vorher notiertem Testbestand vergleichen. Erfolgreicher Dateiexport beweist keinen abgeschlossenen iCloud-Upload.

## E – Restore als neue Instanz

`Sicherung → Bibliotheksbackup als neuen Bereich wiederherstellen`, dann über „Bereiche“ den neuen „Restore …“-Eintrag öffnen. Ordnerreihenfolge, aktive Hefte, Papierkorb, Quellen, Text/Ink und Stifteinstellungen prüfen. Seite 2 in der Kopie weiterbearbeiten, speichern, schließen und nach App-Neustart erneut öffnen. In den ursprünglichen Testbereich wechseln: dessen Stand unverändert? „Meine Bibliothek“ ebenfalls unverändert? Agent liest Export und Stände später unabhängig zurück.

## F – Fehlerfall und bisherige lokale Historie

Nur eine **Kopie des Testarchivs** auf dem PC gezielt beschädigen und zurückübertragen. Import muss fehlschlagen, kein neuer veröffentlichter Bereich entstehen und kein aktuelles Heft verändert werden. Original-Testarchiv aufbewahren.

Lokale Historie am neuen PDF-Testheft wie in Test 10 prüfen: Linie speichern, X speichern, zweiten geprüften Stand bewusst als neue Kopie öffnen. Quelle mit X, Kopie ohne X; beide auffindbar und nach Neustart erhalten. Quelle/Seite vor Auswahl kontrollieren.

Rückmeldung später gebündelt: `A–F okay` oder Buchstabe mit Meldung/Beobachtung. Keine Abnahme aus fehlender Rückmeldung. Noch offen bleiben Seitenoperationen, freie Text-/Bild-/Formobjekte, gemischtes Lasso, zwei Ansichten, OCR/Inhaltssuche, externe automatische Backupziele, große Bestände und Langzeit-/Alltagsfreigabe.
