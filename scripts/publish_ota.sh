#!/usr/bin/env bash
# Baut noty signiert und legt es zur Installation über den Browser auf den
# eigenen Server (docs/ENVIRONMENT.md, „Update unterwegs“). Ziel und geheimer
# Pfad stehen in .tools/ota.env, nie im öffentlichen Repo:
#   OTA_HOST=ssh-host  OTA_DIR=/absoluter/pfad  OTA_URL=https://host/pfad
# Gibt es OTA_DIR hier, läuft das Skript auf dem Zielrechner selbst: ohne ssh.
# Die Datei muss die installierte App-ID tragen, sonst entstünde eine zweite
# App mit leerem Container. xtool stellt beim Signieren immer die Team-ID
# voran, deshalb wird hier mit der einfach präfixierten ID gebaut.
#
# Zwei Apps nebeneinander (docs/ENVIRONMENT.md, „noty dev“): Ohne Angabe geht
# ein Build an „noty dev“ mit eigener App-ID und eigenen Daten. Die normale App
# mit den echten Heften bekommt ihn nur ausdrücklich: NOTY_CHANNEL=stable.
# Dritte App „noty AI“ (NOTY_CHANNEL=ai): KI-Experiment von exp/*, eigene
# App-ID und Daten. Alle drei teilen die App Group für den Abgleich
# (docs/APP-SYNC.md); Info.plist `NotyChannel` sagt der App, welche sie ist.
# Vierte App „noty calendar“ (NOTY_CHANNEL=calendar): Kalender-Feature, nur
# von feat/kalender, eigene App-ID und Daten, spiegelt noty und noty dev.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${OTA_ENV:-$HOME/workspace/noty/.tools/ota.env}"
# shellcheck disable=SC1090
. "$ENV_FILE"
. ./scripts/env.sh >/dev/null 2>&1

case "${NOTY_CHANNEL:-dev}" in
  stable) BASE_ID=de.la.noty.prototype; APP_NAME=noty; PAGE_DIR="$OTA_DIR"; PAGE_URL="$OTA_URL"
          PAGE_NOTE="Vorher in noty ein Bibliotheksbackup erstellen und die App schließen. Das Update ersetzt die App, die Hefte bleiben erhalten." ;;
  dev)    BASE_ID=de.la.noty.dev; APP_NAME="noty dev"; PAGE_DIR="$OTA_DIR-dev"; PAGE_URL="$OTA_URL-dev"
          PAGE_NOTE="Testversion mit eigenen Daten. Die normale noty und ihre Hefte bleiben unberührt." ;;
  ai)     BASE_ID=de.la.noty.ai; APP_NAME="noty AI"; PAGE_DIR="$OTA_DIR-ai"; PAGE_URL="$OTA_URL-ai"
          PAGE_NOTE="KI-Testversion mit eigenen Daten. noty und noty dev bleiben unberührt." ;;
  calendar) BASE_ID=de.la.noty.calendar; APP_NAME="noty calendar"; PAGE_DIR="$OTA_DIR-calendar"; PAGE_URL="$OTA_URL-calendar"
          PAGE_NOTE="Kalender-Testversion mit eigenen Daten. noty und noty dev bleiben unberührt." ;;
  *) echo "NOTY_CHANNEL muss stable, dev, ai oder calendar sein" >&2; exit 1 ;;
esac

# Branch-Regeln (AGENTS.md, „Branches und Apps“): Die normale noty bekommt nur
# freigegebene, committete Stände von main; noty dev nur committete Stände von
# dev, exp/* oder feat/*. So steht immer fest, was auf welchem iPad läuft.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"; COMMIT="$(git rev-parse --short HEAD)"
DIRTY="$(git status --porcelain --untracked-files=no)"
case "${NOTY_CHANNEL:-dev}" in
  stable)
    [ "$BRANCH" = main ] || { echo "Die normale noty wird nur von main gebaut (aktuell: $BRANCH)." >&2; exit 1; }
    [ -z "$DIRTY" ] || { echo "main hat uncommittete Änderungen; nichts veröffentlicht." >&2; exit 1; }
    [ "${NOTY_STABLE_CONFIRMED:-}" = 1 ] || { echo "Normale noty nur nach Freigabe durch den Nutzer und Sicherung vorher: NOTY_STABLE_CONFIRMED=1 setzen." >&2; exit 1; } ;;
  dev)
    case "$BRANCH" in dev|exp/*|feat/*) ;; *) echo "noty dev wird nur von dev, exp/* oder feat/* gebaut (aktuell: $BRANCH)." >&2; exit 1 ;; esac
    if [ -n "$DIRTY" ] && [ "${NOTY_ALLOW_DIRTY:-}" != 1 ]; then echo "Uncommittete Änderungen; erst committen (Ausnahme: NOTY_ALLOW_DIRTY=1)." >&2; exit 1; fi ;;
  ai)
    case "$BRANCH" in exp/*) ;; *) echo "noty AI wird nur von exp/* gebaut (aktuell: $BRANCH)." >&2; exit 1 ;; esac
    if [ -n "$DIRTY" ] && [ "${NOTY_ALLOW_DIRTY:-}" != 1 ]; then echo "Uncommittete Änderungen; erst committen (Ausnahme: NOTY_ALLOW_DIRTY=1)." >&2; exit 1; fi ;;
  calendar)
    [ "$BRANCH" = feat/kalender ] || { echo "noty calendar wird nur von feat/kalender gebaut (aktuell: $BRANCH)." >&2; exit 1; }
    if [ -n "$DIRTY" ] && [ "${NOTY_ALLOW_DIRTY:-}" != 1 ]; then echo "Uncommittete Änderungen; erst committen (Ausnahme: NOTY_ALLOW_DIRTY=1)." >&2; exit 1; fi ;;
esac
SOURCE="$BRANCH · $COMMIT"; [ -z "$DIRTY" ] || SOURCE="$SOURCE · mit uncommitteten Änderungen"
# Buildnummern zählen über beide Apps durchgehend hoch.
NEXT="$(sed -n 's#.*<key>CFBundleVersion</key><string>\([0-9]*\)</string>.*#\1#p' Info.plist)"
LAST="$( { if [ -d "$OTA_DIR" ]; then ls "$OTA_DIR" "$OTA_DIR-dev" "$OTA_DIR-ai" "$OTA_DIR-calendar" || true; else ssh "$OTA_HOST" "ls '$OTA_DIR' '$OTA_DIR-dev' '$OTA_DIR-ai' '$OTA_DIR-calendar' || true"; fi; } 2>/dev/null | sed -n 's/^Noty-\([0-9]*\)\.ipa$/\1/p' | sort -n | tail -1)"
if [ -n "$LAST" ] && [ "$NEXT" -le "$LAST" ] && [ "${NOTY_SAME_BUILD:-}" != 1 ]; then
  echo "Build $NEXT ist nicht größer als der zuletzt veröffentlichte Build $LAST; CFBundleVersion erhöhen." >&2; exit 1
fi
INSTALLED_ID="XTL-BAFXLQ964V.XTL-BAFXLQ964V.$BASE_ID"
ORIGINAL="$(mktemp)"; ORIGINAL_INFO="$(mktemp)"
cp xtool.yml "$ORIGINAL"; cp Info.plist "$ORIGINAL_INFO"
restore() { cp "$ORIGINAL" xtool.yml; cp "$ORIGINAL_INFO" Info.plist; rm -f "$ORIGINAL" "$ORIGINAL_INFO"; }
trap restore EXIT
sed -i "s/^bundleID: .*/bundleID: XTL-BAFXLQ964V.$BASE_ID/" xtool.yml
CHANNEL="${NOTY_CHANNEL:-dev}"
sed -i "s#<key>NotyChannel</key><string>[a-z]*</string>#<key>NotyChannel</key><string>$CHANNEL</string>#" Info.plist
grep -q "<key>NotyChannel</key><string>$CHANNEL</string>" Info.plist || { echo "NotyChannel nicht gesetzt" >&2; exit 1; }
if [ "$CHANNEL" != stable ]; then
  sed -i "s#^iconPath: .*#iconPath: Resources/AppIcon-$CHANNEL.png#" xtool.yml
  sed -i "s#<key>CFBundleDisplayName</key><string>noty</string>#<key>CFBundleDisplayName</key><string>$APP_NAME</string>#" Info.plist
fi
LOG="$(mktemp)"
script -qec "xtool dev build --sign --ipa" "$LOG" >/dev/null
grep -q 'COMMAND_EXIT_CODE="0"' "$LOG" || { tail -20 "$LOG"; exit 1; }
restore; trap - EXIT

mkdir -p .tools
# Prüft ID, Profil, Gerät, Ablauf und ob das Profil alle Entitlements der
# App-Signatur erlaubt (sonst verweigert iOS die Installation). Jedes Problem
# bricht ab, bevor etwas veröffentlicht wird.
CHECK_STATUS=0
python3 -I scripts/ota_check.py xtool/Noty.ipa "$INSTALLED_ID" > .tools/ota-check.json || CHECK_STATUS=$?
cat .tools/ota-check.json
PROBLEMS="$(python3 -I -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["problems"]))' .tools/ota-check.json 2>/dev/null || echo unlesbar)"
if [ "$CHECK_STATUS" -ne 0 ] || [ "$PROBLEMS" != 0 ]; then
  echo "OTA-Prüfung meldet Probleme (siehe problems); nichts veröffentlicht." >&2
  exit 1
fi
BUILD="$(python3 -I -c 'import json;print(json.load(open(".tools/ota-check.json"))["build"])')"
SHORT="$(python3 -I -c 'import json;print(json.load(open(".tools/ota-check.json"))["version"])')"

STAGE="$(mktemp -d)"
cat > "$STAGE/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$PAGE_URL/Noty-$BUILD.ipa</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>$INSTALLED_ID</string><key>bundle-version</key><string>$SHORT</string><key>kind</key><string>software</string><key>title</key><string>$APP_NAME Build $BUILD</string></dict>
</dict></array></dict></plist>
PLIST
LINK="itms-services://?action=download-manifest&url=$PAGE_URL/manifest.plist"
cat > "$STAGE/index.html" <<HTML
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>$APP_NAME</title>
<style>body{font:17px -apple-system,sans-serif;background:#111;color:#eee;max-width:32em;margin:3em auto;padding:0 1em;line-height:1.5}
a.b{display:block;background:#0a84ff;color:#fff;text-align:center;padding:.8em;border-radius:12px;text-decoration:none;font-weight:600;margin:1.5em 0}</style></head>
<body><h1>$APP_NAME Build $BUILD</h1><p>$PAGE_NOTE</p><p style="color:#999">Stand: $SOURCE</p>
<a class="b" href="$LINK">Build $BUILD installieren</a><p>Auf diesem iPad in Safari öffnen. Nach dem Tippen erscheint die Abfrage „Installieren“, der Fortschritt läuft auf dem Home-Bildschirm.</p></body></html>
HTML
if [ -d "$OTA_DIR" ]; then DEST="$PAGE_DIR"; mkdir -p -m 755 "$PAGE_DIR"; else
  DEST="$OTA_HOST:$PAGE_DIR"; ssh "$OTA_HOST" "mkdir -p -m 755 '$PAGE_DIR'"
fi
# Datei zuerst, Verweise zuletzt: die Seite zeigt nie auf etwas Unfertiges.
rsync -a --chmod=D755,F644 xtool/Noty.ipa "$DEST/Noty-$BUILD.ipa"
rsync -a --chmod=F644 "$STAGE/manifest.plist" "$STAGE/index.html" "$DEST/"
rm -rf "$STAGE"
# Nur die letzten zwei Builds bleiben liegen.
PRUNE="cd '$PAGE_DIR' && ls -t Noty-*.ipa | tail -n +3 | xargs -r rm --"
if [ "$DEST" = "$PAGE_DIR" ]; then bash -c "$PRUNE"; else ssh "$OTA_HOST" "$PRUNE"; fi
if [ "${NOTY_CHANNEL:-dev}" = stable ]; then
  # Jede Installation auf die normale noty bekommt ein Tag; der Hook pusht main, Tags gehen hier mit.
  git tag -a "stable/build-$BUILD" -m "Normale noty Build $BUILD" && git push -q origin "stable/build-$BUILD" || echo "Tag stable/build-$BUILD nicht gesetzt oder nicht gepusht" >&2
fi
echo "Veröffentlicht: $APP_NAME Build $BUILD · $SOURCE · $PAGE_URL"
