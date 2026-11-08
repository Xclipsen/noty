# Umgebung und Toolchain

Ermittelt auf dem tatsächlichen Rechner `la@lab`, 16.10.2026:

- Linux x86_64, Arch/Omarchy `4.0.0.r6871.g04b374a`.
- Ausgangszustand: kein Swift, xtool, Xcode/iOS-SDK, xcrun oder pymobiledevice3 gefunden. Kein SwiftPM-/xtool-Projekt unter `/home/la/workspace`.
- Vorhanden: libimobiledevice `1.4.0-2`, usbmuxd `1.1.1-4`. usbmuxd zunächst inaktiv, kein Socket; `idevice_id -l` und `-n` meldeten „Unable to retrieve device list“. `lsusb` zeigte kein Apple-Gerät.
- Mit ausdrücklicher Nutzerfreigabe installiert: Swift **6.4.1** über offiziellen Swiftly-Installer, xtool **1.22.2** als offizielle x86_64-AppImage.
- Swiftly unter `~/.local/share/swiftly`; Ubuntu-24.04-Toolchain gewählt, da offizieller Swiftly-Pfad Arch nicht direkt abdeckt. Kein Ubuntu-Paketmanager ausgeführt, kein ungeprüftes Community-Skript verwendet.
- Für den Binärbetrieb lokal entpackt: Ubuntu libncurses6/libtinfo6 `6.4+20240113-1ubuntu2.2` und Arch libxml2-legacy `2.13.9-2`. Nur Benutzerverzeichnis `~/.local/share/noty-toolchain/compat`; keine Systembibliotheken ersetzt. Echte passende Bibliotheken, keine ABI-vortäuschenden Symlinks.
- Drei Verweise in der neu installierten Swift-Runtime (`usr/lib/swift/linux`) machen diese lokalen Bibliotheken auch für SwiftBuild-Subprozesse auffindbar. Dadurch läuft der normale Swift-6.4-Buildweg ohne den zuerst nötigen, veralteten `--build-system native`-Ausweg.
- `~/.local/bin/xtool` startet `~/.local/share/xtool/xtool-1.22.2.AppImage` mit `APPIMAGE_EXTRACT_AND_RUN=1`; keine FUSE-/Systeminstallation nötig. Swiftly, swift, swiftc und sourcekit-lsp sind über neue Links in `~/.local/bin` verfügbar; vorhandene Dateien wurden nicht überschrieben.
- `scripts/env.sh` aktiviert Toolchain und lokale Bibliotheken nur für die aktuelle Shell. Keine Shell-/Desktop-Konfiguration verändert; kein Root-Zugriff vorhanden (`sudo -n` benötigt Passwort).
- SDK-Quelle vom Nutzer: `/home/la/Downloads/Xcode_27.1.xip`, 2.027.369.056 Byte. Erfolgreich installiert: iPhoneOS27.1, iPhoneSimulator27.1, MacOSX27.0; `/home/la/.swiftpm/swift-sdks/darwin.artifactbundle`, normal, `epoch=3,darwinTools=1.1.0,oam=1.3.0`. `swift sdk list` meldet `darwin`.
- Kompatibilität für den Prototyp belegt: `xtool dev build` erfolgreich, ARM64-Mach-O in `xtool/Noty.app/Noty`, Bundle-ID und iPad-Gerätefamilie im erzeugten Info.plist geprüft.
- iPad Pro 11 Zoll, Pencil Pro und externe Tastatur laut Auftrag. Jetzt per USB erkannt: `ProductType=iPad17,1`, `ProductVersion=27.0.1`, usbmuxd aktiv. Der Gerätename „iPhone von Leon“ ist irreführend; die iPad-Modellkennung wurde separat abgefragt, keine iPhone-Version übernommen.

## Tatsächlich gelesene Hilfe

`xtool --help`, `--version`, `sdk --help`, `sdk install --help`, `sdk build --help`, `sdk status`, `dev build --help`, `dev run --help`, `devices --help`, `setup --help`.

`xtool dev build` ohne TTY verursachte in dieser Automationsumgebung einen SwiftNIO-Fehler (`epoll_ctl … Operation not permitted`). Mit TTY erreichte derselbe Befehl den SDK-Dialog. Interaktive xtool-Aufrufe deshalb im Terminal/PTY ausführen; dies belegt noch keinen App-Build.

## Offizielle Quellen

- [xtool Linux-Anleitung, passend zu 1.22.2](https://github.com/xtool-org/xtool/blob/1.22.2/Documentation/xtool.docc/Installation-Linux.md)
- [xtool Template-Quelle](https://github.com/xtool-org/xtool/blob/1.22.2/Sources/XToolSupport/NewCommand.swift)
- [xtool DevCommand-Quelle](https://github.com/xtool-org/xtool/blob/1.22.2/Sources/XToolSupport/DevCommand.swift)
- [Offizielle Swift-Installation](https://www.swift.org/install/linux/)
- [Apple Developer Account und Personal-Team-Grenzen](https://developer.apple.com/help/account/basics/about-your-developer-account/)

Apple-Anmeldung vom Nutzer erledigt. Nach ausdrücklicher Freigabe wurde das bisherige Entwicklungszertifikat widerrufen und von xtool ersetzt. Neues noty-Profil aus signierter IPA gelesen: erstellt 16.10.2026 18:16:09 UTC, Ablauf 23.10.2026 18:16:09 UTC, ein provisioniertes Gerät, Debug-Entitlement vorhanden. ZIP-Struktur und eingebettetes Profil geprüft; keine privaten Schlüssel oder Auth-Dateien gelesen.

Erste Installation nach Signierung scheiterte am Drei-App-Limit (Amethyst, SideStore, StikDebug). Nutzer gab einen Platz frei. Danach `xtool install --usb xtool/Noty.ipa` mit „Successfully installed!“ abgeschlossen und nochmals als Update ohne Deinstallation ausgeführt.

**Installationsidentität beibehalten:** Basis-ID in xtool.yml ist `de.la.noty.prototype`. Signierter IPA-Info.plist: `XTL-BAFXLQ964V.de.la.noty.prototype`. `xtool install` signiert diese IPA erneut; tatsächliche ID auf dem Gerät: `XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype`. Diese ID wurde über die vorhandene InstallationProxy-API gelesen. Bis zu einer bewusst geplanten Migration denselben Build-Sign-/IPA-Installweg und dieselbe Signierungsidentität verwenden. Ein Wechsel zu `xtool dev run` würde einen anderen Container erzeugen.

Automatischer Start: App mit tatsächlicher ID gefunden, Debugserver aber nicht erreichbar. `idevicedebug` verlangt ein Developer-Disk-Image. Manueller Start und Grundfunktionen vom Nutzer bestätigt.

Kostenloses Personal Team: sieben Tage Profilgültigkeit (auch am realen Profil nachgewiesen), maximal drei installierte Apps. Vor Ablauf erneuern; App nicht vorher löschen. Update-Datenerhalt wurde am Hauptdokument durch logischen Vorher-/Nachhervergleich nachgewiesen. Langfristiger persönlicher Betrieb und Erneuerungsablauf werden im Scope-Interview festgelegt.

**Zweiter Bauort (seit 02.11.2026):** Swift, Kompatibilitätsbibliotheken, xtool, Darwin-SDK und auf Nutzerwunsch auch die Apple-Anmeldung mit Signierschlüssel (`~/.config/xtool`) liegen auf dem eigenen Server unter denselben Pfaden, damit `lab` nicht laufen muss. Dort immer als `la` arbeiten (`runuser -u la`), sonst bleiben root-eigene Dateien im Arbeitsbaum. `scripts/publish_ota.sh` erkennt am vorhandenen `OTA_DIR`, dass es auf dem Zielrechner läuft, und nutzt dann kein ssh.

**noty dev (seit 02.11.2026, Build 90):** Zwei Apps stehen nebeneinander auf dem iPad. „noty dev“ (`de.la.noty.dev`, oranges Icon `Resources/AppIcon-dev.png`, eigener Container, also eigene Hefte, Einstellungen und Backup-Ziele) bekommt jeden Build; ihre Installationsseite ist der Pfad aus `.tools/ota.env` mit der Endung `-dev`. Die normale noty (`de.la.noty.prototype`) mit den echten Heften ändert sich nur durch `NOTY_CHANNEL=stable bash scripts/publish_ota.sh`, und erst wenn der Nutzer mit dem Stand in dev zufrieden ist. `publish_ota.sh` setzt App-ID, Name und Icon nur für die Dauer des Builds und stellt `xtool.yml` und `Info.plist` danach wieder her.

**Update unterwegs (seit 02.11.2026, Build 70):** `scripts/publish_ota.sh` baut signiert und legt IPA, Manifest und eine Installationsseite auf den eigenen Server; das iPad installiert per `itms-services`-Link aus Safari, ohne USB, ohne App Store Connect. Das IPA trägt die installierte App-ID (das Skript baut dafür mit der einfach präfixierten ID) und das Entwicklungsprofil mit dem registrierten iPad; `scripts/ota_check.py` bricht bei abweichender ID ab. Ziel und geheimer Pfad stehen in `.tools/ota.env`, nie im Repo: Das eingebettete Profil enthält die UDID. TestFlight wäre eine andere Lieferkette (Distributionszertifikat, App-Store-Connect-Eintrag, Upload über macOS oder API) und ist hier nicht eingerichtet. Grenze: Die Pflicht zur vollständigen Sicherung vor dem Update geht ohne USB nicht; unterwegs vorher in noty ein Bibliotheksbackup erstellen und nach der Rückkehr den Bestand vergleichen.

**Seit 29.10.2026 bezahltes Apple Developer Program (Einzelperson).** Das Personal Team wurde umgewandelt; Team-ID `BAFXLQ964V`, Signierungsidentität und installierte App-ID blieben gleich. Während der Umstellung war die Geräteliste kurz leer und die Profilerstellung scheiterte mit „There are no current IOS devices on this team“; nach Freischaltung registrierte `xtool install` das Gerät neu. Build 64 wurde mit Vorher-/Nachhervergleich (alle Hefte unverändert) neu signiert; neues Profil gültig bis 29.10.2027, begrenzt durch das Zertifikat (16.10.2027). Kein Drei-App-Limit und keine Sieben-Tage-Erneuerung mehr; vor Zertifikatsablauf neu signieren.

**xtool mit iCloud (seit 08.11.2026).** `scripts/publish_ota.sh` signiert Kanäle aus `scripts/icloud-channels` (anfangs nur `dev`) mit `xtool-noty` und eigenem Container ([ICLOUD](ICLOUD.md)). Neben dem normalen `xtool` 1.24.0 gibt es `xtool-noty` (`~/.local/share/xtool/xtool-1.24.0-noty.4.AppImage`, Quelle `~/workspace/xtool-noty`, Zweig `noty/icloud`, gebaut mit dem offiziellen Docker-Build von xtool). Er schaltet iCloud ein und ändert vorhandene Fähigkeiten nie; `XTOOL_TRACE_CAPABILITIES=1` protokolliert die Aufrufe. Bisher nur für die Test-App `~/workspace/icloud-probe` benutzt, keine noty-App. Ergebnis und Update-Regeln: [BACKUP-RESTORE-PLAN](BACKUP-RESTORE-PLAN.md) Phase 5 und `~/workspace/xtool-noty/NOTY.md`.

**xtool 1.24.0 (seit 03.11.2026).** `~/.local/bin/xtool` startet jetzt `~/.local/share/xtool/xtool-1.24.0.AppImage` (ebenfalls mit `APPIMAGE_EXTRACT_AND_RUN=1`); die alte AppImage 1.22.2 bleibt daneben liegen, ihr früherer Wrapper als `~/.local/bin/xtool.1.22.2.bak`. Zurück auf 1.22.2 nur durch Zurückkopieren dieses Wrappers. Grund: Erst 1.24.0 kennt „Sign in with Apple“ (`AppleSignInEntitlement`), 1.22.2 löschte die Fähigkeit bei jedem signierten Build wieder (docs/APPLE-LOGIN.md). Nach dem Breaking Change der Anmeldespeicherung in 1.23 war am 03.11.2026 eine Neuanmeldung bei Apple nötig (vom Nutzer erledigt); das neue Anmeldetoken gilt laut xtool bis 03.11.2027. Die Fähigkeit kommt über `entitlementsPath: Noty.entitlements` in `xtool.yml` (`com.apple.developer.applesignin = [Default]`); xtool schaltet sie damit für die App-ID ein. Nachweis am signierten Build 93 von noty dev (`xtool/Noty.ipa`, `python3 -I scripts/ota_check.py xtool/Noty.ipa XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.dev`): Signatur und eingebettetes Profil enthalten beide `com.apple.developer.applesignin`, Profil gültig bis 03.11.2027, `problems` leer. `ota_check.py` liest dafür die Entitlements direkt aus dem Codesignatur-Blob der App (CS_SuperBlob, Entitlements-Blob `0xfade7171`, kein codesign nötig) und meldet jedes Entitlement, das das Profil nicht erlaubt, als Problem; `publish_ota.sh` bricht dann vor dem Veröffentlichen ab.

