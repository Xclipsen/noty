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
  *) echo "NOTY_CHANNEL muss stable oder dev sein" >&2; exit 1 ;;
esac
INSTALLED_ID="XTL-BAFXLQ964V.XTL-BAFXLQ964V.$BASE_ID"
ORIGINAL="$(mktemp)"; ORIGINAL_INFO="$(mktemp)"
cp xtool.yml "$ORIGINAL"; cp Info.plist "$ORIGINAL_INFO"
restore() { cp "$ORIGINAL" xtool.yml; cp "$ORIGINAL_INFO" Info.plist; rm -f "$ORIGINAL" "$ORIGINAL_INFO"; }
trap restore EXIT
sed -i "s/^bundleID: .*/bundleID: XTL-BAFXLQ964V.$BASE_ID/" xtool.yml
if [ "${NOTY_CHANNEL:-dev}" = dev ]; then
  sed -i 's#^iconPath: .*#iconPath: Resources/AppIcon-dev.png#' xtool.yml
  sed -i 's#<key>CFBundleDisplayName</key><string>noty</string>#<key>CFBundleDisplayName</key><string>noty dev</string>#' Info.plist
fi
LOG="$(mktemp)"
script -qec "xtool dev build --sign --ipa" "$LOG" >/dev/null
grep -q 'COMMAND_EXIT_CODE="0"' "$LOG" || { tail -20 "$LOG"; exit 1; }
restore; trap - EXIT

mkdir -p .tools
python3 -I scripts/ota_check.py xtool/Noty.ipa "$INSTALLED_ID" > .tools/ota-check.json
cat .tools/ota-check.json
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
<body><h1>$APP_NAME Build $BUILD</h1><p>$PAGE_NOTE</p>
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
echo "Veröffentlicht: $APP_NAME Build $BUILD · $PAGE_URL"
