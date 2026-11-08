# iCloud-Ablage

Stand 08.11.2026, Zweig `feat/wiederherstellen`, Build 141: **implementiert, Core-Tests (1368) und Host-Roundtrip erfolgreich, SDK-Build (`xtool dev build`) ohne Fehler; nicht installiert, am iPad ungeprüft.** Vorarbeit und Entscheidungen: [BACKUP-RESTORE-PLAN](BACKUP-RESTORE-PLAN.md) Phase 5. Die iCloud-Berechtigung selbst ist mit einer Test-App am iPad bestätigt (CloudKit und iCloud-Dokumente).

## Was sie tut

Jedes Heft und Textdokument aus „Meine Bibliothek“ wird nach einer Änderung **einzeln** in den iCloud-Ordner der App gesichert, als eigene Datei mit mehreren älteren Ständen. Das entspricht Stufe 1 aus dem Plan: nur hochladen, Heft für Heft, noch kein Abgleich in beide Richtungen. Der Aufbau ist schon auf mehrere Geräte ausgelegt.

- **Wann:** im Betrieb jede Minute eine Prüfung (höchstens alle 2 Minuten ein Durchgang), ein geändertes Heft höchstens alle 10 Minuten; beim Verlassen der App und bei „Jetzt sichern“ sofort. Ein Durchgang ohne Änderung liest nur die `manifest.json` der Pakete.
- **Was:** der bestätigte Stand (gleicher Lesepfad wie das Bibliotheksbackup, `LibraryBackupPlan.readableNotebook`), als `.notybackup` Format 2 mit allen Bildoriginalen, genau das geprüfte Format von „Als .noty teilen“. Ist die neueste Revision unlesbar, wird **kein** älterer Stand hochgeladen (`VaultError.olderStateOnly`). Bereiche (Test, Restore, Spiegel) werden nie gesichert.
- **Aufbewahrung je Heft** (`VaultRetention`, nach der Nutzerentscheidung 7 Tage / 4 Wochen / 6 Monate): die drei neuesten Stände sowie der neueste Stand jedes der letzten 7 Tage, 4 Wochen und 6 Monate. Der neueste Stand wird nie entfernt. Gelöschte Hefte behalten ihre Stände.
- **Zurückholen:** Einstellungen › Backup & Daten › iCloud-Ablage › „Stände in iCloud ansehen und zurückholen …“. Hefte sind nach heutigem Zustand gruppiert („In der Bibliothek“, „Heute im Papierkorb“, „Gelöscht“), je Stand mit Datum, Seiten, Größe und Gerät. „Als Kopie zurückholen“ (Standard) legt „Titel (Stand TT.MM.JJJJ, HH:MM)“ neben das Heft. „Ersetzen …“ legt nach Bestätigung den heutigen Stand in den Papierkorb und den gewählten an seine Stelle. Beides geht über den geprüften `.noty`-Import (`LibraryModel.importBackup`), in den damaligen Ordner, falls es ihn noch gibt.
- **Status:** „Zuletzt geprüft …, N Hefte gesichert“ getrennt von „N Dateien warten noch auf den Upload zu iCloud“. Das Schreiben in den Ordner ist **kein** Upload-Nachweis; der Upload-Zustand kommt aus `URLResourceValues.ubiquitousItemIsUploaded`.
- **Schalter:** „Hefte einzeln in iCloud sichern“, anfangs **aus** (UserDefaults `noty.v2.icloudVault.enabled`). Das tägliche Komplettbackup (WebDAV / Dateien-Ordner) bleibt unabhängig davon bestehen.

## Ablage im iCloud-Container

`<Container>/Noty/v1/` (nicht unter `Documents`, also in der Dateien-App unsichtbar):

- `Versions/<HEFT-UUID>/<unix>-<uuid>.noty`: unveränderliche Stände. Sie werden als `<name>.partial` geschrieben, zurückgelesen, umbenannt und noch einmal zurückgelesen (Größe und CRC). Ein Rest-`.partial` zählt nie als Stand.
- `Devices/<GERÄTE-UUID>.json` (`VaultHead`, Format 1): nur von diesem Gerät bzw. dieser Installation geschrieben, nach jedem Upload. Enthält Bibliotheksindex (Ordner, Titel, Papierkorb) und je Heft die Stände (Datei, Zeit, Seiten, Größe, CRC, CRC der archivierten `manifest.json`). Ein Kopf eines neueren Formats wird nicht überschrieben (`VaultError.unsupported`). Die Geräte-ID steht in UserDefaults `noty.v2.icloudVault.device`, eine Neuinstallation beginnt einen neuen Kopf, der alte bleibt für Wiederherstellungen lesbar.
- Gelöscht werden nur Dateien mit gültigem Versionsnamen im Ordner desselben Hefts, nie Ordner, Links oder fremde Dateien.

Die Bibliothek wird nur gelesen (schreibgeschützte `RevisionStore`, `BackupActivity` gegen Asset-Aufräumen); es gibt keinen zweiten Writer. Ändert ein Commit die `manifest.json` während des Archivierens, wird das Heft im nächsten Durchgang gesichert.

## Container und Signierung

- Je App ein **eigener** Container, nie ein gemeinsamer (Einbahnstraße aus [APP-SYNC](APP-SYNC.md)): `iCloud.de.la.noty.dev` (noty dev), später `iCloud.de.la.noty` (noty), `iCloud.de.la.noty.ai`, `iCloud.de.la.noty.calendar`.
- `scripts/icloud-channels` nennt die Kanäle mit iCloud (anfangs nur `dev`). Für diese setzt `scripts/publish_ota.sh` die Berechtigungen (`icloud-services = CloudDocuments`, Container- und Ubiquity-Container-ID) und `NotyICloudContainer` in Info.plist nur für die Dauer des Builds, signiert mit `xtool-noty` (schaltet iCloud an der App-ID ein, ändert vorhandene Fähigkeiten nie; `~/workspace/xtool-noty/NOTY.md`) und veröffentlicht nur, wenn das Profil die iCloud-Einträge erlaubt. Alle anderen Kanäle bauen unverändert mit `xtool` und ohne iCloud; die App blendet die iCloud-Ablage dann aus.
- Einmal je App im Apple-Entwicklerportal: Container anlegen und der App-ID zuordnen (iCloud mit „Include CloudKit support“). CloudKit brauchte bei der Test-App rund 15 Minuten, iCloud-Dokumente gingen sofort.

## Nachweise

- `NotebookVaultTests` (9): erster Durchgang sichert alle aktiven Hefte, unveränderte Bibliothek erzeugt nichts, Pakete bytegleich; Mindestabstand und sofortiges Sichern; Stand mit Bildoriginal über den geprüften Import mit datiertem Titel zurück, heutiges Heft unverändert; manipulierte Datei und unsicherer Name abgelehnt; Aufbewahrung; Aufräumen nur eigener Stände, nie des neuesten; fremde Geräte, neueres Format und Müll in `Devices/`; Katalog über Geräte mit heutigem Zustand und Ordner; strenge Versionsnamen. Dazu `LibraryBackupBrowserTests` (Kopietitel mit Uhrzeit) und die bestehenden Import-Tests.
- **Ungeprüft am iPad:** Schalter und Status, tatsächlicher Upload und Upload-Anzeige, Sichern beim Verlassen der App (Hintergrundzeit), Platzhalter beim Zurückholen, Zurückholen als Kopie und Ersetzen an echten Heften.
- **Noch nicht umgesetzt:** Abgleich in beide Richtungen (Stufe 2, braucht ein zweites Gerät), Aufräumen alter `.partial`-Reste, Anzeige des iCloud-Speicherplatzes insgesamt.

## Normale noty (08.11.2026, Build 147)

`stable` steht seit Build 147 in `scripts/icloud-channels`: Die normale noty wird mit `xtool-noty` und dem Container `iCloud.de.la.noty` signiert. Voraussetzung im Apple-Entwicklerportal: Container `iCloud.de.la.noty` angelegt und der App-ID **„XTool XTL-BAFXLQ964V de la noty prototype“** zugeordnet (iCloud mit „Include CloudKit support“). Fehlt die Zuordnung, lehnt `ota_check.py` den Build ab – es wird dann nichts veröffentlicht. Die iCloud-Ablage ist in der App anfangs aus (Schalter unter Backup & Daten).
