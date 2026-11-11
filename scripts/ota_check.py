"""Checks a signed IPA before it may be published; prints a summary without device IDs.

Besides ID, profile, devices and expiry it compares the entitlements the app
signature claims (read from the code signature of the main executable, no
codesign needed) with what the embedded provisioning profile allows. iOS
refuses to install an app whose signature claims more, e.g.
`com.apple.developer.applesignin` without the capability in the profile.

Push (docs/PUSH.md): for noty calendar and the normal noty (ID ending in `.de.la.noty.calendar` or `.de.la.noty.prototype`,
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
is always a problem; `scripts/resign_extensions.py` fixes it after the build.
noty calendar and the normal noty must contain NotyCalendarWidgets.appex and NSSupportsLiveActivities.

Seal (`seal_ok`, app and each appex): every CodeDirectory's page hashes and
bound Info.plist/requirements/CodeResources/entitlements, a non-ad-hoc CMS
blob, and every file of the bundle against `_CodeSignature/CodeResources`
(the app's seal covers the extension's files, so a re-signed extension needs
a re-sealed app). The CMS signature itself (certificate chain) is not
verified here; resign_extensions.py runs `rcodesign verify` for that.
"""
import datetime, fnmatch, hashlib, json, plistlib, struct, sys, zipfile

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


CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_REQUIREMENTS = 0xFADE0C01
CSMAGIC_EMBEDDED_DER_ENTITLEMENTS = 0xFADE7172
CSMAGIC_BLOBWRAPPER = 0xFADE0B01
HASH_TYPES = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256, 4: hashlib.sha384}


def signature_blobs(binary, base):
    """(slice bytes, {slot: blob bytes}) of the code signature of the slice at `base`."""
    magic = struct.unpack_from("<I", binary, base)[0]
    ncmds = struct.unpack_from("<I", binary, base + 16)[0]
    cursor = base + (32 if magic == MH_MAGIC_64 else 28)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", binary, cursor)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, _ = struct.unpack_from("<II", binary, cursor + 8)
            start = base + dataoff
            _, _, count = struct.unpack_from(">III", binary, start)
            blobs = {}
            for index in range(count):
                slot, offset = struct.unpack_from(">II", binary, start + 12 + 8 * index)
                length = struct.unpack_from(">I", binary, start + offset + 4)[0]
                blobs[slot] = binary[start + offset:start + offset + length]
            return blobs
        cursor += cmdsize
    raise ValueError("keine Codesignatur")


def seal_problems(files, executable, identifier):
    """Structural check of a bundle's signature (no CMS/chain check; rcodesign verify does that).

    `files`: bundle-relative path → bytes (nested bundles included). Checks for every
    CodeDirectory of every slice: identifier, page hashes up to codeLimit, special
    slots (Info.plist, requirements, CodeResources, entitlements XML/DER), a
    non-empty CMS signature; then every files2 entry of CodeResources against
    the content (hash2 / cdhash of nested code) and that every file is sealed.
    Returns (problems, cdhashes)."""
    problems, cdhashes = [], set()
    binary = files.get(executable)
    if binary is None: return [f"{executable} fehlt"], cdhashes
    special = {1: files.get("Info.plist"), 3: files.get("_CodeSignature/CodeResources")}
    for base, _ in thin_slices(binary):
        try:
            blobs = signature_blobs(binary, base)
        except (ValueError, struct.error) as error:
            problems.append(f"Signatur nicht lesbar ({error})"); continue
        directories = [b for slot, b in blobs.items() if slot == 0 or 0x1000 <= slot < 0x1005]
        if not directories: problems.append("keine CodeDirectory")
        cms = blobs.get(0x10000, b"")
        if len(cms) <= 8: problems.append("keine CMS-Signatur (ad-hoc)")
        for directory in directories:
            (magic, length, version, flags, hash_offset, ident_offset, n_special, n_code, code_limit,
             hash_size, hash_type, _, page_log) = struct.unpack_from(">IIIIIIIIIBBBB", directory, 0)
            algorithm = HASH_TYPES.get(hash_type)
            if magic != CSMAGIC_CODEDIRECTORY or algorithm is None:
                problems.append(f"unbekannte CodeDirectory (Hashtyp {hash_type})"); continue
            digest = lambda data: algorithm(data).digest()[:hash_size]
            name = directory[ident_offset:directory.index(b"\0", ident_offset)].decode()
            if name != identifier: problems.append(f"CodeDirectory-Kennung {name} statt {identifier}")
            page = 1 << page_log if page_log else code_limit
            for index in range(n_code):
                stored = directory[hash_offset + index * hash_size:hash_offset + (index + 1) * hash_size]
                chunk = binary[base + index * page:base + min((index + 1) * page, code_limit)]
                if digest(chunk) != stored:
                    problems.append(f"Seitenhash {index} passt nicht zur Programmdatei ({algorithm().name})"); break
            slots = {1: special[1], 2: blobs.get(2), 3: special[3], 5: blobs.get(5), 7: blobs.get(7)}
            labels = {1: "Info.plist", 2: "Anforderungen", 3: "CodeResources", 5: "Entitlements", 7: "DER-Entitlements"}
            for slot, content in slots.items():
                if slot > n_special:
                    if content is not None and slot in (2, 5, 7): problems.append(f"{labels[slot]} nicht in der CodeDirectory gebunden")
                    continue
                stored = directory[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size]
                if content is None:
                    if stored.strip(b"\0"): problems.append(f"{labels[slot]} gebunden, aber nicht vorhanden")
                elif digest(content) != stored:
                    problems.append(f"{labels[slot]}-Hash passt nicht ({algorithm().name})")
            cdhashes.add(algorithm(directory).digest()[:20])
    try:
        resources = plistlib.loads(special[3])["files2"]
    except (TypeError, KeyError, plistlib.InvalidFileException, ValueError):
        return problems + ["_CodeSignature/CodeResources fehlt oder unlesbar"], cdhashes
    for path, entry in resources.items():
        entry = entry if isinstance(entry, dict) else {"hash": entry}
        content = files.get(path)
        if "cdhash" in entry:
            continue  # nested code: checked by the caller with the nested bundle's cdhashes
        if content is None:
            if not entry.get("optional"): problems.append(f"versiegelte Datei fehlt: {path}")
        elif "hash2" in entry and hashlib.sha256(content).digest() != entry["hash2"]:
            problems.append(f"Hash in CodeResources passt nicht: {path}")
        elif "hash2" not in entry and "hash" in entry and hashlib.sha1(content).digest() != entry["hash"]:
            problems.append(f"Hash in CodeResources passt nicht: {path}")
    nested = {p for p, e in resources.items() if isinstance(e, dict) and "cdhash" in e}
    for path in files:
        if path in (executable, "Info.plist", "_CodeSignature/CodeResources") or path in resources: continue
        if any(path.startswith(n + "/") for n in nested): continue
        problems.append(f"nicht versiegelte Datei: {path}")
    return problems, cdhashes


def bundle_files(ipa, names, root):
    prefix = root + "/"
    return {n[len(prefix):]: ipa.read(n) for n in names if n.startswith(prefix) and not n.endswith("/")}


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


# Apps with push, Live Activities and the widget extension: noty calendar and the normal noty.
PUSH_SUFFIXES = (".de.la.noty.calendar", ".de.la.noty.prototype")


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


def check_appex(ipa, names, root, info, expected):
    """Findings of each PlugIns/*.appex: (reports, problems)."""
    reports, problems = [], []
    plugins = sorted({n.split("/")[3] for n in names if n.startswith(root + "/PlugIns/") and n.count("/") >= 4
                      and n.split("/")[3].endswith(".appex")})
    for name in plugins:
        base = f"{root}/PlugIns/{name}"
        own = []
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
        if appex_info.get("NotyChannel") != info.get("NotyChannel"):
            own.append("NotyChannel weicht von der App ab (Widget läse die Datei einer anderen App und öffnete deren Schema)")
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
                    hint = " (xtool #131: resign_extensions.py gelaufen?)"
                    own.extend(f"Entitlements: {p}" + (hint if "application-identifier" in p else "")
                               for p in entitlement_problems(signed, profile["Entitlements"]))
            except (ValueError, struct.error, plistlib.InvalidFileException) as error:
                own.append(f"keine lesbare Signatur ({error})")
        if binary is not None:
            seal, cdhashes = seal_problems(bundle_files(ipa, names, base), appex_info["CFBundleExecutable"], appex_id)
            report["seal_ok"] = not seal
            report["cdhashes"] = sorted(h.hex() for h in cdhashes)
            own.extend(f"Signatur: {p}" for p in seal)
        report["problems"] = own
        reports.append(report)
        problems += [f"{name}: {p}" for p in own]
    return reports, problems


def main(path, expected, push=None):
    with zipfile.ZipFile(path) as ipa:
        names = ipa.namelist()
        app = next(n for n in names if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        root = app.rsplit("/", 1)[0]
        info = plistlib.loads(ipa.read(app))
        raw = ipa.read(root + "/embedded.mobileprovision")
        binary = ipa.read(root + "/" + info["CFBundleExecutable"])
        appex, appex_problems = check_appex(ipa, names, root, info, expected)
        seal, _ = seal_problems(bundle_files(ipa, names, root), info["CFBundleExecutable"], info["CFBundleIdentifier"])
        resources = plistlib.loads(ipa.read(root + "/_CodeSignature/CodeResources"))["files2"] if not seal else {}
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
    push_required = expected.endswith(PUSH_SUFFIXES) if push is None else push
    for problem in push_problems(signed, entitlements, push_required):
        if problem not in problems: problems.append(problem)
    problems += [f"App-Signatur: {p}" for p in seal]
    # Nested code sealed by cdhash (Apple style) must name the extension's current CodeDirectory;
    # sealed file by file (zsign/rcodesign style) the seal check above already covers it.
    for report in appex:
        entry = resources.get(f"PlugIns/{report['name']}")
        if isinstance(entry, dict) and "cdhash" in entry and entry["cdhash"].hex() not in report.get("cdhashes", []):
            problems.append(f"App-Signatur: cdhash von {report['name']} in CodeResources veraltet")
    problems += appex_problems
    if expected.endswith(PUSH_SUFFIXES):
        if not any(a["name"] == WIDGET_EXTENSION for a in appex): problems.append(f"Build ohne {WIDGET_EXTENSION}")
        if info.get("NSSupportsLiveActivities") is not True: problems.append("Build ohne NSSupportsLiveActivities")
    print(json.dumps({"build": info["CFBundleVersion"], "version": info.get("CFBundleShortVersionString", info["CFBundleVersion"]),
                      "id_ok": info["CFBundleIdentifier"] == expected, "team": team, "devices": len(profile.get("ProvisionedDevices", [])),
                      "profile_expires": expires.date().isoformat(), "debug_entitlement": entitlements.get("get-task-allow"),
                      "seal_ok": not seal, "signed_entitlements": sorted(signed), "apple_sign_in": "com.apple.developer.applesignin" in signed,
                      "aps_environment": {"signature": signed.get("aps-environment"), "profile": entitlements.get("aps-environment"),
                                          "required": push_required},
                      "live_activities": info.get("NSSupportsLiveActivities") is True, "appex": appex,
                      "problems": problems}, ensure_ascii=False))
    return 1 if problems else 0


if __name__ == "__main__":
    arguments = [a for a in sys.argv[1:] if a not in ("--push", "--no-push")]
    flag = True if "--push" in sys.argv else False if "--no-push" in sys.argv else None
    sys.exit(main(arguments[0], arguments[1], flag))
