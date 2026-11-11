"""Prepares a build with the widget extension (docs/LIVE-ACTIVITY-PLAN.md): the
normal noty (NOTY_CHANNEL=stable) and noty calendar.

noty dev and noty AI build from the checked-in files without extension, Live
Activities or URL scheme. Changes the files in place (publish_ota.sh keeps
copies and restores them after the build):

  - xtool.yml: `extensions:` with NotyCalendarWidgets (PlugIns/NotyCalendarWidgets.appex),
  - Info.plist: NSSupportsLiveActivities, NSSupportsLiveActivitiesFrequentUpdates and
    the URL scheme of the app (deep link of tile and widget; `noty` for the
    normal noty, `notycalendar` for noty calendar, as SchoolDayLink.scheme),
  - NotyCalendarWidgets.plist: CFBundleVersion/CFBundleShortVersionString of the app
    (iPadOS expects the extension's numbers to match the app), and NotyChannel with
    the matching CFBundleDisplayName: the extension reads its own plist, and the
    channel decides which widget file it shows, which app its links open and
    which app its texts name (SchoolDayWidgetStore.channel).

Usage: python3 -I scripts/calendar_build.py [PROJECT_ROOT]
Idempotent; prints what it set.
"""
import os, plistlib, re, sys

CHANNELS = ("stable", "calendar")
# Home-screen names, as APP_NAME in publish_ota.sh and SchoolDayText.appName(channel:).
APP_NAMES = {"stable": "noty", "calendar": "noty calendar"}

EXTENSION = """extensions:
- product: NotyCalendarWidgets
  infoPath: NotyCalendarWidgets.plist
  entitlementsPath: NotyCalendarWidgets.entitlements
"""


def scheme(channel):
    """As SchoolDayLink.scheme(channel:): one scheme per app, never shared."""
    return "noty" if channel == "stable" else "noty" + channel


def info_addition(channel):
    return f"""    <key>NSSupportsLiveActivities</key><true/>
    <key>NSSupportsLiveActivitiesFrequentUpdates</key><true/>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>de.la.noty.{channel}.schultag</string>
        <key>CFBundleURLSchemes</key><array><string>{scheme(channel)}</string></array>
    </dict></array>
"""


def main(root):
    xtool = os.path.join(root, "xtool.yml")
    with open(xtool, encoding="utf-8") as handle: text = handle.read()
    if not re.search(r"^product: Noty$", text, re.M):
        raise SystemExit("xtool.yml ohne „product: Noty“ (zwei Bibliotheksprodukte im Paket)")

    info_path = os.path.join(root, "Info.plist")
    with open(info_path, encoding="utf-8") as handle: info_text = handle.read()
    channel = plistlib.loads(info_text.encode()).get("NotyChannel")
    if channel not in CHANNELS:
        raise SystemExit(f"NotyChannel ist „{channel}“; die Widget-Extension gibt es nur für {', '.join(CHANNELS)}")

    if "NotyCalendarWidgets" not in text:
        text = text.rstrip("\n") + "\n" + EXTENSION
        with open(xtool, "w", encoding="utf-8") as handle: handle.write(text)

    if "NSSupportsLiveActivities" not in info_text:
        marker = re.search(r"^\s*<key>NotyChannel</key>.*\n", info_text, re.M)
        if not marker: raise SystemExit("Info.plist ohne NotyChannel-Zeile")
        info_text = info_text[:marker.end()] + info_addition(channel) + info_text[marker.end():]
        with open(info_path, "w", encoding="utf-8") as handle: handle.write(info_text)
    info = plistlib.loads(info_text.encode())  # also checks the result is a valid plist

    widget_path = os.path.join(root, "NotyCalendarWidgets.plist")
    with open(widget_path, encoding="utf-8") as handle: widget = handle.read()
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        widget, count = re.subn(rf"(<key>{key}</key><string>)[^<]*(</string>)", rf"\g<1>{info[key]}\g<2>", widget)
        if count != 1: raise SystemExit(f"{key} in NotyCalendarWidgets.plist nicht gefunden")
    for key, value in (("NotyChannel", channel), ("CFBundleDisplayName", APP_NAMES[channel])):
        widget, count = re.subn(rf"(<key>{key}</key><string>)[^<]*(</string>)", rf"\g<1>{value}\g<2>", widget)
        if count != 1: raise SystemExit(f"{key} in NotyCalendarWidgets.plist nicht gefunden")
    if plistlib.loads(widget.encode()).get("NotyChannel") != channel:
        raise SystemExit("NotyChannel in NotyCalendarWidgets.plist nicht gesetzt")
    with open(widget_path, "w", encoding="utf-8") as handle: handle.write(widget)
    print(f"{channel}: Extension NotyCalendarWidgets, Live Activities, Schema {scheme(channel)}, Build {info['CFBundleVersion']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
