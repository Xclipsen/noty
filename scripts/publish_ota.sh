#!/usr/bin/env bash
# Baut noty signiert und legt es zur Installation über den Browser auf den
# eigenen Server (docs/ENVIRONMENT.md, „Update unterwegs“). Ziel und geheimer
# Pfad stehen in .tools/ota.env, nie im öffentlichen Repo:
#   OTA_HOST=ssh-host  OTA_DIR=/absoluter/pfad  OTA_URL=https://host/pfad
# Die Datei muss die installierte App-ID tragen, sonst entstünde eine zweite
# App mit leerem Container. xtool stellt beim Signieren immer die Team-ID
# voran, deshalb wird hier mit der einfach präfixierten ID gebaut.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${OTA_ENV:-$HOME/workspace/noty/.tools/ota.env}"
# shellcheck disable=SC1090
. "$ENV_FILE"
. ./scripts/env.sh >/dev/null 2>&1

INSTALLED_ID="XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.prototype"
ORIGINAL="$(mktemp)"
cp xtool.yml "$ORIGINAL"
restore() { cp "$ORIGINAL" xtool.yml; rm -f "$ORIGINAL"; }
trap restore EXIT
sed -i 's/^bundleID: .*/bundleID: XTL-BAFXLQ964V.de.la.noty.prototype/' xtool.yml
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
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$OTA_URL/Noty-$BUILD.ipa</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>$INSTALLED_ID</string><key>bundle-version</key><string>$SHORT</string><key>kind</key><string>software</string><key>title</key><string>noty Build $BUILD</string></dict>
</dict></array></dict></plist>
PLIST
LINK="itms-services://?action=download-manifest&url=$OTA_URL/manifest.plist"
cat > "$STAGE/index.html" <<HTML
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>noty</title>
<style>body{font:17px -apple-system,sans-serif;background:#111;color:#eee;max-width:32em;margin:3em auto;padding:0 1em;line-height:1.5}
a.b{display:block;background:#0a84ff;color:#fff;text-align:center;padding:.8em;border-radius:12px;text-decoration:none;font-weight:600;margin:1.5em 0}</style></head>
<body><h1>noty Build $BUILD</h1><p>Vorher in noty ein Bibliotheksbackup erstellen und die App schließen. Das Update ersetzt die App, die Hefte bleiben erhalten.</p>
<a class="b" href="$LINK">Build $BUILD installieren</a><p>Auf diesem iPad in Safari öffnen. Nach dem Tippen erscheint die Abfrage „Installieren“, der Fortschritt läuft auf dem Home-Bildschirm.</p></body></html>
HTML
ssh "$OTA_HOST" "mkdir -p '$OTA_DIR'"
# Datei zuerst, Verweise zuletzt: die Seite zeigt nie auf etwas Unfertiges.
rsync -a --chmod=D755,F644 xtool/Noty.ipa "$OTA_HOST:$OTA_DIR/Noty-$BUILD.ipa"
rsync -a --chmod=F644 "$STAGE/manifest.plist" "$STAGE/index.html" "$OTA_HOST:$OTA_DIR/"
rm -rf "$STAGE"
# Nur die letzten zwei Builds bleiben liegen.
ssh "$OTA_HOST" "cd '$OTA_DIR' && ls -t Noty-*.ipa | tail -n +3 | xargs -r rm --"
echo "Veröffentlicht: Build $BUILD"
