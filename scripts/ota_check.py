"""Checks a signed IPA before it may be published; prints a summary without device IDs."""
import datetime, json, plistlib, sys, zipfile

path, expected = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(path) as ipa:
    names = ipa.namelist()
    app = next(n for n in names if n.count("/") == 2 and n.endswith(".app/Info.plist"))
    root = app.rsplit("/", 1)[0]
    info = plistlib.loads(ipa.read(app))
    raw = ipa.read(root + "/embedded.mobileprovision")
profile = plistlib.loads(raw[raw.index(b"<?xml"):raw.index(b"</plist>") + 8])
entitlements = profile["Entitlements"]
expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
team = profile["TeamIdentifier"][0]
problems = []
if info["CFBundleIdentifier"] != expected: problems.append("IPA-ID weicht von der installierten ID ab")
if entitlements["application-identifier"] != f"{team}.{expected}": problems.append("Profil gehört zu einer anderen App-ID")
if not profile.get("ProvisionedDevices"): problems.append("Profil ohne Gerät")
if expires < datetime.datetime.now(datetime.timezone.utc): problems.append("Profil abgelaufen")
print(json.dumps({"build": info["CFBundleVersion"], "version": info.get("CFBundleShortVersionString", info["CFBundleVersion"]),
                  "id_ok": info["CFBundleIdentifier"] == expected, "team": team, "devices": len(profile.get("ProvisionedDevices", [])),
                  "profile_expires": expires.date().isoformat(), "debug_entitlement": entitlements.get("get-task-allow"),
                  "problems": problems}, ensure_ascii=False))
sys.exit(1 if problems else 0)
