# noty

Native iPad-App für Schulnotizen, entwickelt auf `la@lab` unter Omarchy.
Auftrag: Master-Prompt „Schulnotizen auf dem iPad“, 16.10.2026; Name vom Nutzer auf **noty** geändert.

## Native Gesetzessammlung – separater Feature-Worktree

Der bestätigte Ausbau ist in `feat/native-law-library` implementiert: optionale native Gesetzessammlung als internes Slide-over oder angedockte zweite Ansicht, lokale Texte/optionale PDFs, Direktfundstellen wie `144 HGB`, Apples Tastaturen und appweites E-Mail-Konto. Drei getrennte Schalter (Aktivierung aus, persönlicher Sync an, automatische Gesetzesupdates an). Notizbücher bleiben lokal; Gesetzesmarkierungen haben eine eigene dauerhafte Warteschlange und Sicherungsdatei.

Core-Tests, echter Host-Offlineroundtrip und iPad-SDK-Build sind geprüft. Website und Backend sind seit 20.10.2026 auf IONOS ausgerollt und öffentlich geprüft. Mail bleibt auf Nutzerwunsch aus; E-Mail-Registrierung/Recovery sind deshalb noch nicht verfügbar, bestehende Namenslogins bleiben unterstützt. **Build 54 ist seit 20.10.2026 auf dem iPad installiert**, einschließlich der zwischenzeitlichen Funktionen aus Build 53. Vorher-/Nachhervergleich: 14 Hefte und alle 60 Dateien unverändert. Bedienung am iPad weiterhin ungeprüft. Aktivierung unter Einstellungen → Gesetzessammlung. [Umfang und Architektur](docs/LAW-INTEGRATION-PLAN.md), [Prüfungen](docs/TESTING.md#native-gesetzessammlung--feature-worktree).

## Aktueller Stand der bisherigen Lieferung

**Build 49 (20.10.2026)** = Build 48 plus sechs Editor-Korrekturen aus dem Review: Nach einem abgebrochenen Anheben mit Werkzeugwechsel zeigt der Canvas wieder die gespeicherte Tinte, statt Striche beim nächsten Zeichnen zu verlieren. Der Bild-Cache fasst 160 MB/48 Einträge und zeigt bei Fehltreffern die nächstbeste Auflösung statt Grau. Dekodierfehler werden erneut versucht. Gezogene Bilder bleiben in der richtigen Reihenfolge. Werkzeugeinstellungen werden auch beim Wechsel in den Hintergrund fertig geschrieben. Die Strichbreite lernt nur noch von Stift, Bleistift und Marker. Nachweise: [TESTING](docs/TESTING.md#build-49--editor-korrekturen).

**Build 48 (20.10.2026, installiert)** fasst zwei Arbeitsstränge zusammen: die Review-Überarbeitung (intern Build 47, nie separat installiert) und UI-Feinschliff mit „Seite anpassen“ für Papierseiten. Stand und Nachweise der Installation: [TESTING](docs/TESTING.md), [UI](docs/UI-POLISH.md), [Schreibplatz](docs/PAGE-ADJUST.md).

- **UI (Build 48):** aufgeräumtes Optionenmenü, gruppierte Seiten- und Bibliotheksmenüs, ruhiger Statushinweis, neue Werkzeug-Icons und App-Icon nach Nutzerentwurf. Papierseiten lassen sich rechts/unten mit nahtlos weiterlaufenden Linien erweitern, Papier je Seite (Notebook-Schema 11).
- **Daten (Review):** Ein Rückfall auf einen älteren Stand verschiebt neuere Revisionen in eine Quarantäne (höchstens drei Sätze), statt sie zu löschen. Nach einem Rückfall kein automatisches Speichern. Lokale Historie mit Zwischenständen im Abstand von mindestens 10 Minuten (`checkpoints.json`). Das Manifest bleibt im Build-46-Format. Fehlgeschlagenes Speichern wird nach 2/5/15/60 s erneut versucht. PDF-Originale bis 100 MB; Hefte mit Quellen über 20 MB nutzen Schema 10.
- **Backups (Review):** Das Bibliotheksbackup wird gestreamt, statt im Speicher aufgebaut (Format 1 unverändert). Externes Ziel wird vor dem Erstellen geprüft. Backoff bei Fehlern. Der Editor pausiert nur noch für den Commit. `.notybackup`/`.notylibrary` lassen sich aus Dateien direkt öffnen. Hinweis 24 h vor Ablauf des Signierprofils.
- **Editor (Review):** weniger Arbeit im Stiftpfad, beim Ziehen und beim Seitenwechsel. Vorschaubilder und PDF-Helligkeit werden außerhalb des Hauptthreads berechnet. Bilder werden im Hintergrund dekodiert. Bei Speicherwarnungen werden Caches freigegeben. Undo in allen Modi. Tastenkürzel ⌘N/F/S/E/⇧E/↑/↓ und für Auswahlen. Doppeltipp folgt der Pencil-Systemeinstellung. Seitenpapierkorb mit endgültigem Löschen. Bedienhilfen-Bezeichnungen.
- **Suche/Export (Review):** persistenter, abgeleiteter Suchindex in `Library/Caches`, der nur Geändertes neu erkennt. PDF-Export seitenweise mit Fortschritt und Abbrechen.
- **Aufgeräumt (Review):** toter Code entfernt (u. a. `ZoomingWorksheet`), große Editor-Dateien aufgeteilt, Diagnose standardmäßig aus, Python-Prüfer ohne `assert` mit Negativtests (`scripts/check_verifiers.sh`), Build-Protokolle nach `docs/history/`.

**Achtung bei Rückkehr zu einem älteren Build:** Build 46 sperrt Hefte mit PDF-Quellen über 20 MB (Schema 10) und löscht Zwischenstände der Historie. Build 46 und 47 sperren Hefte mit erweitertem Papier-Schreibplatz (Schema 11). Gesperrt heißt: nicht geöffnet und nicht verändert. Vorher vollständig sichern.

Bestätigt bis Build 46 („passt alles“). Verlauf aller früheren Stände: [CHANGELOG](CHANGELOG.md). Offene Punkte: [PLAN](docs/PLAN.md).

## Befehle auf diesem Rechner

```bash
cd /home/la/workspace/noty
. ./scripts/env.sh
swift --version
xtool --version
swift test --package-path Core
bash scripts/check_page_workflow.sh   # Host-Roundtrip inkl. Prüfer-Negativtests
xtool sdk status
# Nach vollständigem Xcode-Download:
xtool sdk install /home/la/Downloads/Xcode_27.1.xip
xtool dev build
```

Apple-Anmeldung übernimmt der Nutzer selbst: `xtool auth` im eigenen Terminal.
Danach iPad anschließen, entsperren und Vertrauen bestätigen:

```bash
xtool devices --no-wait
xtool dev build --sign --ipa
xtool install --usb xtool/Noty.ipa
```

Für Updates den nachgewiesenen IPA-Weg mit derselben Signierungsidentität beibehalten. Basis-Bundle-ID: `de.la.noty.prototype`; tatsächlich installiert: `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`. xtool fügt bei Build-Signierung und erneuter Signierung durch `install` jeweils ein Präfix hinzu. `xtool dev run` würde hier eine andere App-ID erzeugen; daher vorerst den konsistenten IPA-Weg verwenden. App **nicht vorher löschen**. Vor jedem Update vollständige App-Documents sichern und danach zurücklesen und vergleichen ([TESTING](docs/TESTING.md#update-auf-das-ipad)).

Details: [Plan](docs/PLAN.md), [Architektur](docs/ARCHITECTURE.md), [Prüfungen und Gerätetest](docs/TESTING.md), [Speicherformat](docs/STORAGE.md), [Bibliotheksbackup](docs/LIBRARY-BACKUP.md), [Umgebung](docs/ENVIRONMENT.md), [Auftragsumfang](docs/REQUIREMENTS.md), [Verlauf](CHANGELOG.md).
