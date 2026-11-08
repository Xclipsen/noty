"""Checks a signed IPA before it may be published; prints a summary without device IDs.

Besides ID, profile, devices and expiry it compares the entitlements the app
signature claims (read from the code signature of the main executable, no
codesign needed) with what the embedded provisioning profile allows. iOS
refuses to install an app whose signature claims more, e.g.
`com.apple.developer.applesignin` without the capability in the profile.

Push (docs/PUSH.md): for noty calendar (ID ending in `.de.la.noty.calendar`,
or `--push`) `aps-environment` must be in the signature and in the profile
with the same value; otherwise APNs hands out no token and the push service
cannot reach the iPad. Both values are printed (`aps_environment`).

Widget extension (docs/LIVE-ACTIVITY-PLAN.md): every `PlugIns/*.appex` is checked
like the app – ID under the app's ID, same CFBundleVersion/ShortVersion, own
profile for its own ID (team, device, expiry), code signature present, the
executable not empty (xtool #313) – and its signed entitlements are listed
(`appex[].signed_entitlements`, `application_identifier`). xtool 1.24 signs
extensions with the app's entitlements (#131): the extension then claims the
app's `application-identifier`, which its own profile does not allow. That
is a problem; `--allow-appex-entitlements` turns exactly these entitlement
findings into `appex[].warnings` for a deliberate device test. noty calendar
must contain NotyCalendarWidgets.appex and NSSupportsLiveActivities.
"""
import datetime, fnmatch, json, plistlib, struct, sys, zipfile

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
LC_CODE_SIGNATURE = 0x1D
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH_MAGIC, MH_MAGIC_64 = 0xFEEDFACE, 0xFEEDFACF


def thin_slices(binary):
    """(offset, size) of every Mach-O slice (one for a thin binary)."""
    magic = struct.unpack_from(">I", binary, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", binary, 4)[0]
        slices, entry = [], 8
        for _ in range(count):
            if magic == FAT_MAGIC:
                _, _, offset, size, _ = struct.unpack_from(">iiIII", binary, entry); entry += 20
            else:
                _, _, offset, size, _, _ = struct.unpack_from(">iiQQII", binary, entry); entry += 32
            slices.append((offset, size))
        return slices
    return [(0, len(binary))]


def signature_entitlements(binary):
    """Entitlements (dict) of the code signature of each slice; ValueError if none."""
    found = []
    for base, size in thin_slices(binary):
        magic = struct.unpack_from("<I", binary, base)[0]
        if magic not in (MH_MAGIC, MH_MAGIC_64):
            raise ValueError("kein Mach-O")
        ncmds = struct.unpack_from("<I", binary, base + 16)[0]
        cursor = base + (32 if magic == MH_MAGIC_64 else 28)
        signature = None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", binary, cursor)
            if cmd == LC_CODE_SIGNATURE:
                dataoff, datasize = struct.unpack_from("<II", binary, cursor + 8)
                signature = (base + dataoff, datasize)
            cursor += cmdsize
        if signature is None:
            raise ValueError("keine Codesignatur")
        start, length = signature
        blob_magic, _, count = struct.unpack_from(">III", binary, start)
        if blob_magic != CSMAGIC_EMBEDDED_SIGNATURE:
            raise ValueError("unbekannte Signaturstruktur")
        entitlements = None
        for index in range(count):
            _, offset = struct.unpack_from(">II", binary, start + 12 + 8 * index)
            magic_at, blob_length = struct.unpack_from(">II", binary, start + offset)
            if magic_at == CSMAGIC_EMBEDDED_ENTITLEMENTS:
                entitlements = plistlib.loads(binary[start + offset + 8:start + offset + blob_length])
        found.append(entitlements or {})
    if not found:
        raise ValueError("keine Signatur")
    return found


def allowed(value, permitted):
    """Signed `value` within the profile's `permitted` (wildcards like `TEAM.*`)."""
    if isinstance(permitted, str) and isinstance(value, str):
        return fnmatch.fnmatchcase(value, permitted)
    # A text wildcard in the profile (e.g. "*") covers each entry of a signed list.
    if isinstance(permitted, str) and isinstance(value, list):
        return all(isinstance(v, str) and fnmatch.fnmatchcase(v, permitted) for v in value)
    if isinstance(permitted, bool):
        return value == permitted or (permitted is True and isinstance(value, bool))
    if isinstance(permitted, list):
        values = value if isinstance(value, list) else [value]
        return all(any(allowed(v, p) for p in permitted) for v in values)
    return value == permitted


def entitlement_problems(signed, permitted):
    problems = []
    for key in sorted(signed):
        if key not in permitted:
            problems.append(f"Signatur verlangt „{key}“, das Profil erlaubt es nicht")
        elif not allowed(signed[key], permitted[key]):
            problems.append(f"Signatur verlangt für „{key}“ mehr, als das Profil erlaubt")
    return problems


PUSH_SUFFIX = ".de.la.noty.calendar"


def push_problems(signed, permitted, required):
    """Problems with `aps-environment` (signature vs. profile; only required for push builds)."""
    problems = []
    in_signature, in_profile = signed.get("aps-environment"), permitted.get("aps-environment")
    if required:
        if in_signature is None:
            problems.append("Push: Signatur ohne „aps-environment“ (Noty.entitlements des Builds prüfen)")
        if in_profile is None:
            problems.append("Push: Profil ohne „aps-environment“ (Fähigkeit Push Notifications für die App-ID einschalten und neu signieren)")
    if in_signature is not None and in_profile is not None and in_signature != in_profile:
        problems.append(f"Push: Signatur „{in_signature}“, Profil „{in_profile}“ (aps-environment)")
    return problems


WIDGET_EXTENSION = "NotyCalendarWidgets.appex"
MINIMUM_APPEX_EXECUTABLE = 64 * 1024


def read_profile(raw):
    return plistlib.loads(raw[raw.index(b"<?xml"):raw.index(b"</plist>") + 8])


def check_appex(ipa, names, root, info, expected, allow_entitlements):
    """Findings of each PlugIns/*.appex: (reports, problems)."""
    reports, problems = [], []
    plugins = sorted({n.split("/")[3] for n in names if n.startswith(root + "/PlugIns/") and n.count("/") >= 4
                      and n.split("/")[3].endswith(".appex")})
    for name in plugins:
        base = f"{root}/PlugIns/{name}"
        own, warnings = [], []
        report = {"name": name}
        try:
            appex_info = plistlib.loads(ipa.read(base + "/Info.plist"))
        except KeyError:
            problems.append(f"{name}: Info.plist fehlt"); continue
        appex_id = appex_info.get("CFBundleIdentifier", "")
        report.update({"id_ok": appex_id.startswith(expected + "."), "build": appex_info.get("CFBundleVersion"),
                       "version": appex_info.get("CFBundleShortVersionString"),
                       "extension_point": (appex_info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")})
        if not report["id_ok"]: own.append("ID liegt nicht unter der App-ID")
        if appex_info.get("CFBundleVersion") != info.get("CFBundleVersion"): own.append("CFBundleVersion weicht von der App ab")
        if appex_info.get("CFBundleShortVersionString") != info.get("CFBundleShortVersionString"):
            own.append("CFBundleShortVersionString weicht von der App ab")
        try:
            binary = ipa.read(base + "/" + appex_info["CFBundleExecutable"])
        except KeyError:
            binary = None; own.append("Programmdatei fehlt")
        if binary is not None:
            report["executable_bytes"] = len(binary)
            if len(binary) < MINIMUM_APPEX_EXECUTABLE: own.append("Programmdatei fast leer (xtool #313: Linkerflag -u _main fehlt?)")
        try:
            profile = read_profile(ipa.read(base + "/embedded.mobileprovision"))
        except (KeyError, ValueError):
            profile = None; own.append("kein eigenes Profil (embedded.mobileprovision)")
        if profile is not None:
            permitted = profile["Entitlements"]
            team = profile["TeamIdentifier"][0]
            expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
            report["profile_expires"] = expires.date().isoformat()
            report["profile_entitlements"] = sorted(permitted)
            if permitted.get("application-identifier") != f"{team}.{appex_id}": own.append("Profil gehört zu einer anderen App-ID")
            if not profile.get("ProvisionedDevices"): own.append("Profil ohne Gerät")
            if expires < datetime.datetime.now(datetime.timezone.utc): own.append("Profil abgelaufen")
        if binary is not None:
            try:
                signed = {}
                for slice_entitlements in signature_entitlements(binary): signed.update(slice_entitlements)
                report["signed_entitlements"] = sorted(signed)
                report["application_identifier"] = {"signature": signed.get("application-identifier"),
                                                    "profile": (profile or {}).get("Entitlements", {}).get("application-identifier")}
                if profile is not None:
                    found = entitlement_problems(signed, profile["Entitlements"])
                    (warnings if allow_entitlements else own).extend(f"Entitlements: {p}" for p in found)
            except (ValueError, struct.error, plistlib.InvalidFileException) as error:
                own.append(f"keine lesbare Signatur ({error})")
        report["problems"] = own
        if warnings: report["warnings"] = warnings
        reports.append(report)
        problems += [f"{name}: {p}" for p in own]
    return reports, problems


def main(path, expected, push=None, allow_appex_entitlements=False):
    with zipfile.ZipFile(path) as ipa:
        names = ipa.namelist()
        app = next(n for n in names if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        root = app.rsplit("/", 1)[0]
        info = plistlib.loads(ipa.read(app))
        raw = ipa.read(root + "/embedded.mobileprovision")
        binary = ipa.read(root + "/" + info["CFBundleExecutable"])
        appex, appex_problems = check_appex(ipa, names, root, info, expected, allow_appex_entitlements)
    profile = read_profile(raw)
    entitlements = profile["Entitlements"]
    expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
    team = profile["TeamIdentifier"][0]
    problems = []
    if info["CFBundleIdentifier"] != expected: problems.append("IPA-ID weicht von der installierten ID ab")
    if entitlements["application-identifier"] != f"{team}.{expected}": problems.append("Profil gehört zu einer anderen App-ID")
    if not profile.get("ProvisionedDevices"): problems.append("Profil ohne Gerät")
    if expires < datetime.datetime.now(datetime.timezone.utc): problems.append("Profil abgelaufen")
    signed = {}
    try:
        for slice_entitlements in signature_entitlements(binary):
            signed.update(slice_entitlements)
            for problem in entitlement_problems(slice_entitlements, entitlements):
                if problem not in problems: problems.append(problem)
    except (ValueError, struct.error, plistlib.InvalidFileException) as error:
        problems.append(f"Entitlements der App-Signatur nicht lesbar ({error})")
    push_required = expected.endswith(PUSH_SUFFIX) if push is None else push
    for problem in push_problems(signed, entitlements, push_required):
        if problem not in problems: problems.append(problem)
    problems += appex_problems
    if expected.endswith(PUSH_SUFFIX):
        if not any(a["name"] == WIDGET_EXTENSION for a in appex): problems.append(f"noty calendar ohne {WIDGET_EXTENSION}")
        if info.get("NSSupportsLiveActivities") is not True: problems.append("noty calendar ohne NSSupportsLiveActivities")
    print(json.dumps({"build": info["CFBundleVersion"], "version": info.get("CFBundleShortVersionString", info["CFBundleVersion"]),
                      "id_ok": info["CFBundleIdentifier"] == expected, "team": team, "devices": len(profile.get("ProvisionedDevices", [])),
                      "profile_expires": expires.date().isoformat(), "debug_entitlement": entitlements.get("get-task-allow"),
                      "signed_entitlements": sorted(signed), "apple_sign_in": "com.apple.developer.applesignin" in signed,
                      "aps_environment": {"signature": signed.get("aps-environment"), "profile": entitlements.get("aps-environment"),
                                          "required": push_required},
                      "live_activities": info.get("NSSupportsLiveActivities") is True, "appex": appex,
                      "problems": problems}, ensure_ascii=False))
    return 1 if problems else 0


if __name__ == "__main__":
    arguments = [a for a in sys.argv[1:] if a not in ("--push", "--no-push", "--allow-appex-entitlements")]
    flag = True if "--push" in sys.argv else False if "--no-push" in sys.argv else None
    sys.exit(main(arguments[0], arguments[1], flag, "--allow-appex-entitlements" in sys.argv))
