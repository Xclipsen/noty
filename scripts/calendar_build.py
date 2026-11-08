"""Prepares a build of noty calendar with its widget extension (docs/LIVE-ACTIVITY-PLAN.md).

Only for NOTY_CHANNEL=calendar; the other apps build from the checked-in files
without extension, Live Activities or URL scheme. Changes the files in place
(publish_ota.sh keeps copies and restores them after the build):

  - xtool.yml: `extensions:` with NotyCalendarWidgets (PlugIns/NotyCalendarWidgets.appex),
  - Info.plist: NSSupportsLiveActivities, NSSupportsLiveActivitiesFrequentUpdates and
    the URL scheme `notycalendar` (deep link of tile and widget),
  - NotyCalendarWidgets.plist: CFBundleVersion/CFBundleShortVersionString of the app
    (iPadOS expects the extension's numbers to match the app).

Usage: python3 -I scripts/calendar_build.py [PROJECT_ROOT]
Idempotent; prints what it set.
"""
import os, plistlib, re, sys

EXTENSION = """extensions:
- product: NotyCalendarWidgets
  infoPath: NotyCalendarWidgets.plist
  entitlementsPath: NotyCalendarWidgets.entitlements
"""
INFO_ADDITION = """    <key>NSSupportsLiveActivities</key><true/>
    <key>NSSupportsLiveActivitiesFrequentUpdates</key><true/>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>de.la.noty.calendar.schultag</string>
        <key>CFBundleURLSchemes</key><array><string>notycalendar</string></array>
    </dict></array>
"""


def main(root):
    xtool = os.path.join(root, "xtool.yml")
    with open(xtool, encoding="utf-8") as handle: text = handle.read()
    if not re.search(r"^product: Noty$", text, re.M):
        raise SystemExit("xtool.yml ohne „product: Noty“ (zwei Bibliotheksprodukte im Paket)")
    if "NotyCalendarWidgets" not in text:
        text = text.rstrip("\n") + "\n" + EXTENSION
        with open(xtool, "w", encoding="utf-8") as handle: handle.write(text)

    info_path = os.path.join(root, "Info.plist")
    with open(info_path, encoding="utf-8") as handle: info_text = handle.read()
    if "NSSupportsLiveActivities" not in info_text:
        marker = re.search(r"^\s*<key>NotyChannel</key>.*\n", info_text, re.M)
        if not marker: raise SystemExit("Info.plist ohne NotyChannel-Zeile")
        info_text = info_text[:marker.end()] + INFO_ADDITION + info_text[marker.end():]
        with open(info_path, "w", encoding="utf-8") as handle: handle.write(info_text)
    info = plistlib.loads(info_text.encode())  # also checks the result is a valid plist
    if info.get("NotyChannel") != "calendar":
        raise SystemExit(f"NotyChannel ist „{info.get('NotyChannel')}“, nicht calendar")

    widget_path = os.path.join(root, "NotyCalendarWidgets.plist")
    with open(widget_path, encoding="utf-8") as handle: widget = handle.read()
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        widget, count = re.subn(rf"(<key>{key}</key><string>)[^<]*(</string>)", rf"\g<1>{info[key]}\g<2>", widget)
        if count != 1: raise SystemExit(f"{key} in NotyCalendarWidgets.plist nicht gefunden")
    plistlib.loads(widget.encode())
    with open(widget_path, "w", encoding="utf-8") as handle: handle.write(widget)
    print(f"noty calendar: Extension NotyCalendarWidgets, Live Activities, Schema notycalendar, Build {info['CFBundleVersion']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
