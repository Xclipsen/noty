# Abgleich zwischen noty, noty dev, noty AI und noty calendar

Stand 05.11.2026, Build 118 (`feat/appsync`): **implementiert, Core-Tests und SDK-Build erfolgreich.** Installation und iPad-Test stehen bei den Build-Angaben unten; die normale noty hat den Abgleich erst nach Freigabe und Merge nach `main`.

## Entscheidungen des Nutzers (05.11.2026)

- Die normale noty **gibt nur ab**: noty dev und noty AI bekommen Kopien, aber nichts fließt zurück. Weder Änderungen noch Löschungen in den anderen Apps erreichen die echten Hefte.
- Umfang: **die ganze Bibliothek** („Meine Bibliothek“ mit Ordnern, Papierkorb und Werkzeugeinstellungen).
- Dritte App **„noty AI“** (`de.la.noty.ai`, türkises Icon `Resources/AppIcon-ai.png`), gebaut nur von `exp/*`: `NOTY_CHANNEL=ai bash scripts/publish_ota.sh`, Installationsseite `<OTA_URL>-ai`.
- Vierte App **„noty calendar“** (`de.la.noty.calendar`, seit Build 121 am Abgleich): gebaut nur von `feat/kalender` mit `NOTY_CHANNEL=calendar`, Installationsseite `<OTA_URL>-calendar`. Spiegelt wie noty AI, legt selbst nichts ab.

## Wer gibt ab, wer spiegelt

| App | Kanal | legt Abzug ab | spiegelt |
| --- | --- | --- | --- |
| noty | `stable` | ja („Meine Bibliothek“) | nie |
| noty dev | `dev` | ja (ihre eigene „Meine Bibliothek“) | noty |
| noty AI | `ai` | nein | noty, noty dev |
| noty calendar | `calendar` | nein | noty, noty dev |

Der Kanal folgt aus der App-ID, nicht allein aus `Info.plist` (`NotyChannel`, setzt `publish_ota.sh`): `de.la.noty.prototype` ist immer `stable`, keine andere App-ID kann `stable` sein, unpassende Paare bekommen gar keinen Abgleich (`AppSyncChannel.resolve`, Test `testOnlyTheRealBundleIDIsStableAndStableNeverMirrors`).

## Warum die echten Hefte sicher bleiben

- In noty läuft nur der bestehende, lesende Bibliotheksbackup-Weg (`LibraryModel.buildArchive`, wie beim automatischen Backup inkl. kurzem Editor-Commit) und danach Schreiben **ausschließlich** im gemeinsamen Ordner. Der Spiegelpfad (`AppSyncModel.mirror`) bricht für `stable` sofort ab (keine Quellen und ausdrückliche Prüfung).
- noty liest nie etwas aus dem gemeinsamen Ordner außer ihrem eigenen `current.json` (nur zum Vergleich, ob sich etwas geändert hat).
- Abgelegt wird nur „Meine Bibliothek“ (`Documents/Noty`), nie ein Test-, Restore- oder Spiegelbereich.
- Core-Test `testMirrorRoundTripLeavesSourceLibraryUntouched`: Nach Ablegen und zweimaligem Spiegeln ist der Quellbaum Byte für Byte unverändert.

## Gemeinsamer Ordner

App Group `group.de.la.noty.shared` in `Noty.entitlements`; xtool registriert sie beim Signieren als `group.XTL-BAFXLQ964V.de.la.noty.shared` und schreibt die Signatur entsprechend um (xtool-Quelle `ProvisioningIdentifiers`, `DeveloperServicesAssignAppGroupsOperation`). Die App probiert beide Kennungen (`ProvisionedIdentifier.groupCandidates`). `ota_check.py` lehnt einen Build ab, dessen Profil die Gruppe nicht erlaubt.

`<Gruppe>/NotySync/v1/<kanal>/`, nur die jeweilige Quelle schreibt hinein:

- `snapshot-<n>.notylibrary`: gewöhnliches Bibliotheksbackup (Format 2), vollständig geprüft.
- `current.json`: `formatVersion 1`, Kanal, laufende Nummer, Zeit, Größe+CRC, Heftzahl, `content` (SHA-256 über Index, Werkzeuge und Heftblock-Prüfsummen, ohne Erstellungszeit).

Reihenfolge: als `.partial` kopieren, Größe+CRC prüfen, umbenennen, `current.json` zuletzt atomar ersetzen. Der vorige Abzug bleibt liegen, damit ein gerade kopierender Spiegel nicht den Boden verliert; ältere eigene Abzüge und Reste werden entfernt, fremde Namen nie. Unveränderter Inhalt (gleiches `content`) erzeugt keinen neuen Abzug.

## Wann

- **Abzug:** beim Wechsel der Quelle in den Hintergrund (also beim Umschalten in eine andere noty-App; höchstens alle 2 min), während der Nutzung höchstens alle 30 min, und sofort über Einstellungen › Backup › „Zwischen noty-Apps“ › „Jetzt Abzug ablegen“.
- **Spiegel:** beim Aktivwerden der Spiegel-App und jede Minute (liest nur das kleine `current.json`), sofort über „Spiegel jetzt aktualisieren“.

## Spiegelbereiche

Neuer Stand → Bibliotheks-Restore (vollständige Prüfung inkl. Apple-Frameworks wie beim normalen Restore) in einen **neuen** Bereich der Art `mirror`, Titel „Von noty · Datum“. Danach wird der vorige Spiegel derselben Quelle entfernt, sobald er nicht geöffnet ist; ist der aktuelle Spiegel geöffnet, wartet die Übernahme, bis der Bereich verlassen wird. Änderungen in einem Spiegel gehen beim nächsten Stand verloren und kommen nie zurück. Der Merkzettel je Quelle (letzter Inhalt, Bereich, ausstehende alte Bereiche) liegt in den `UserDefaults` der Spiegel-App.

Ältere Builds kennen die Bereichsart `mirror` nicht und zählen solche Bereiche als „nicht lesbar“; das betrifft nur noty dev/noty AI.

## Grenzen

- Kein Hintergrundabgleich ohne geöffnete App; die Quelle muss einmal in den Hintergrund gehen, die Spiegel-App muss aktiv werden.
- Zusätzlicher Platz: bis zu zwei Abzüge je Quelle im gemeinsamen Ordner plus Spiegelbereich(e) in jeder Spiegel-App.
- Einzelne Hefte aus einem Spiegel in die eigene Bibliothek der Spiegel-App übernehmen ist noch nicht eingebaut.
- Ungeprüft: iPad-Lauf, Verhalten bei sehr großen Bibliotheken im Hintergrundzeitfenster.
