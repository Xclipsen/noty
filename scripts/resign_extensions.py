"""Re-signs the app extensions of a signed xtool IPA with their own entitlements.

Why (docs/LIVE-ACTIVITY-PLAN.md, „Nachsignieren“): xtool 1.24 hands Zupersign only
the app's entitlements (xtool #131), so every `PlugIns/*.appex` is signed with
the app's `application-identifier`, Sign in with Apple, Push and keychain
group, while its embedded profile belongs to its own App ID. iPadOS rejects
such an extension. This script, run after `xtool dev build --sign --ipa`,

1. unpacks the IPA into a private temp folder (0700),
2. signs each extension (inner first) with entitlements derived from its own
   embedded.mobileprovision: application-identifier, team-identifier,
   get-task-allow, keychain-access-groups = [application-identifier] (as xtool
   does for the app) plus every key requested in `<Name>.entitlements` of the
   project, mapped to the profile (App Group `group.X` → `group.XTL-TEAM.X`
   as xtool registers it); a requested key the profile lacks is an error,
3. re-signs the app itself shallowly (`--shallow`: the extension keeps its new
   signature, the app's CodeResources gets its new cdhash) with exactly the
   entitlements of xtool's app signature,
4. checks the result with `rcodesign verify` and writes the IPA back atomically.

Signing tool: rcodesign (apple-codesign 0.29.0, github.com/indygreg/apple-platform-rs),
pinned by SHA-256 of the binary (docs/ENVIRONMENT.md). Key and certificate come
from xtool's own store (`~/.config/xtool/data/<TEAM>`, plist with PEM key and
DER certificate); the certificate must be in both profiles. The key exists only
as a 0600 file in the private temp folder during signing and is deleted
afterwards; nothing secret is printed.

Usage: python3 -I scripts/resign_extensions.py IPA [PROJECT_ROOT]
Exit 0 and one summary line per extension on success; the IPA is unchanged on
any error. An IPA without PlugIns/ is left alone.
"""
import base64, hashlib, os, plistlib, shutil, stat, subprocess, sys, tempfile, zipfile

sys.dont_write_bytecode = True  # kein __pycache__ im Arbeitsbaum
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ota_check import read_profile, signature_entitlements, allowed  # noqa: E402

RCODESIGN_VERSION = "0.29.0"
RCODESIGN_SHA256 = "dab9a7465f96aba3c81e793775510f745b91a46b6418e89f7317b5d8fc7bcea2"
RCODESIGN_DEFAULT = os.path.expanduser(f"~/.local/share/noty-toolchain/apple-codesign-{RCODESIGN_VERSION}/rcodesign")
SIGNING_STORE = os.path.expanduser("~/.config/xtool/data")


def fail(message):
    raise SystemExit(f"resign_extensions: {message}")


def rcodesign_path():
    path = os.environ.get("NOTY_RCODESIGN", RCODESIGN_DEFAULT)
    try:
        with open(path, "rb") as handle: digest = hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        fail(f"rcodesign {RCODESIGN_VERSION} fehlt unter {path} (docs/ENVIRONMENT.md)")
    if digest != RCODESIGN_SHA256:
        fail(f"rcodesign unter {path} hat nicht die geprüfte SHA-256 von {RCODESIGN_VERSION}")
    return path


def run(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        tail = "\n".join(result.stdout.splitlines()[-15:])
        fail(f"{os.path.basename(arguments[0])} {arguments[1]} fehlgeschlagen:\n{tail}")
    return result.stdout


def bundle_executable(bundle):
    with open(os.path.join(bundle, "Info.plist"), "rb") as handle: return plistlib.load(handle)["CFBundleExecutable"]


def write_plist(path, value):
    with open(path, "wb") as handle: plistlib.dump(value, handle, fmt=plistlib.FMT_XML)


def appex_entitlements(profile, requested, name):
    """Entitlements for an extension: identity from its profile, capabilities as requested."""
    permitted = profile["Entitlements"]
    team = profile["TeamIdentifier"][0]
    identifier = permitted["application-identifier"]
    result = {"application-identifier": identifier, "com.apple.developer.team-identifier": team,
              "get-task-allow": permitted.get("get-task-allow", False),
              "keychain-access-groups": [identifier]}
    for key, value in requested.items():
        if key == "com.apple.security.application-groups":
            groups = []
            for group in value:
                candidates = [group]
                if group.startswith("group.") and not group.startswith(f"group.XTL-{team}."):
                    candidates.append(f"group.XTL-{team}.{group[len('group.'):]}")
                match = next((c for c in candidates if allowed([c], permitted.get(key, []))), None)
                if match is None:
                    fail(f"{name}: App Group {group} fehlt im Profil der Extension (Fähigkeit der Extension-App-ID prüfen)")
                groups.append(match)
            result[key] = groups
        else:
            result[key] = value
    for key, value in result.items():
        if key not in permitted or not allowed(value, permitted[key]):
            fail(f"{name}: Profil der Extension erlaubt „{key}“ nicht")
    return result


def write_identity(team, profiles, folder):
    """PEM file (PKCS#8 key + certificate) for rcodesign, 0600 in `folder`."""
    store = os.path.join(SIGNING_STORE, team)
    try:
        with open(store, "rb") as handle: info = plistlib.load(handle)
        key_pem, certificate = info["privateKey"]["data"], info["certificate"]
    except (OSError, KeyError, plistlib.InvalidFileException):
        fail(f"Signierschlüssel von xtool für Team {team} nicht lesbar")
    for profile in profiles:
        if certificate not in profile.get("DeveloperCertificates", []):
            fail("Zertifikat aus xtool steht nicht in jedem eingebetteten Profil (xtool neu signieren lassen)")
    path = os.path.join(folder, "identity.pem")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    # PKCS#1 → PKCS#8 (rcodesign liest „BEGIN PRIVATE KEY“); Schlüssel nur über stdin/Datei.
    converted = subprocess.run(["openssl", "pkey", "-out", path], input=key_pem,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if converted.returncode != 0: fail("Schlüssel nicht umwandelbar (openssl pkey)")
    body = base64.encodebytes(certificate).decode().replace("\n", "")
    lines = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
    with open(path, "a", encoding="ascii") as handle:
        handle.write(f"-----BEGIN CERTIFICATE-----\n{lines}\n-----END CERTIFICATE-----\n")
    os.chmod(path, 0o600)
    return path


def main(ipa_path, project):
    with zipfile.ZipFile(ipa_path) as ipa:
        names = ipa.namelist()
        if not any("/PlugIns/" in n and ".appex/" in n for n in names):
            print("resign_extensions: keine Extension, nichts zu tun"); return 0
    tool = rcodesign_path()
    work = tempfile.mkdtemp(prefix="noty-resign-")  # 0700
    try:
        os.chmod(work, stat.S_IRWXU)
        unpacked = os.path.join(work, "ipa")
        with zipfile.ZipFile(ipa_path) as ipa:
            entries = ipa.infolist()
            for entry in entries:
                target = os.path.realpath(os.path.join(unpacked, entry.filename))
                if not target.startswith(os.path.realpath(unpacked) + os.sep): fail(f"unsicherer Pfad im IPA: {entry.filename}")
            ipa.extractall(unpacked)
        apps = [d for d in os.listdir(os.path.join(unpacked, "Payload")) if d.endswith(".app")]
        if len(apps) != 1: fail("IPA enthält nicht genau eine App")
        app = os.path.join(unpacked, "Payload", apps[0])
        with open(os.path.join(app, "Info.plist"), "rb") as handle: info = plistlib.load(handle)
        with open(os.path.join(app, info["CFBundleExecutable"]), "rb") as handle: app_binary = handle.read()
        app_entitlements = {}
        for slice_entitlements in signature_entitlements(app_binary): app_entitlements.update(slice_entitlements)
        if not app_entitlements.get("application-identifier"): fail("App-Signatur ohne Entitlements")
        with open(os.path.join(app, "embedded.mobileprovision"), "rb") as handle: app_profile = read_profile(handle.read())
        plugins = sorted(d for d in os.listdir(os.path.join(app, "PlugIns")) if d.endswith(".appex"))
        jobs, profiles = [], [app_profile]
        for plugin in plugins:
            bundle = os.path.join(app, "PlugIns", plugin)
            name = plugin[:-len(".appex")]
            with open(os.path.join(bundle, "embedded.mobileprovision"), "rb") as handle: profile = read_profile(handle.read())
            requested_path = os.path.join(project, f"{name}.entitlements")
            try:
                with open(requested_path, "rb") as handle: requested = plistlib.load(handle)
            except OSError:
                fail(f"{plugin}: {name}.entitlements fehlt im Projekt")
            entitlements = appex_entitlements(profile, requested, plugin)
            plist = os.path.join(work, f"{name}.entitlements.plist")
            write_plist(plist, entitlements)
            jobs.append((plugin, bundle, plist, entitlements))
            profiles.append(profile)
        team = app_profile["TeamIdentifier"][0]
        identity = write_identity(team, profiles, work)
        common = ["--pem-file", identity, "--timestamp-url", "none"]
        for plugin, bundle, plist, _ in jobs:
            run([tool, "sign", *common, "--entitlements-xml-file", plist, bundle])
        app_plist = os.path.join(work, "app.entitlements.plist")
        write_plist(app_plist, app_entitlements)
        run([tool, "sign", "--shallow", *common, "--entitlements-xml-file", app_plist, app])
        os.remove(identity)
        # Signaturen der Programmdateien prüfen (rcodesign verify: CodeDirectory-Hashes, CMS);
        # Ressourcen und appex-cdhash in der App prüft ota_check.py.
        for plugin, bundle, _, _ in jobs: run([tool, "verify", os.path.join(bundle, bundle_executable(bundle))])
        run([tool, "verify", os.path.join(app, info["CFBundleExecutable"])])
        # Kontrolle: Entitlements stehen so in den neuen Signaturen.
        resigned = {}
        with open(os.path.join(app, info["CFBundleExecutable"]), "rb") as handle: app_binary = handle.read()
        for slice_entitlements in signature_entitlements(app_binary): resigned.update(slice_entitlements)
        if resigned != app_entitlements: fail("App-Entitlements nach dem Nachsignieren verändert")
        for plugin, bundle, _, entitlements in jobs:
            signed = {}
            with open(os.path.join(bundle, bundle_executable(bundle)), "rb") as handle: binary = handle.read()
            for slice_entitlements in signature_entitlements(binary): signed.update(slice_entitlements)
            if signed != entitlements: fail(f"{plugin}: Entitlements nicht wie vorgesehen signiert")
        # IPA neu packen: gleiche Reihenfolge, Attribute und Kompression wie xtool; atomar ersetzen.
        output = os.path.join(work, "resigned.ipa")
        with zipfile.ZipFile(output, "w") as packed:
            for entry in entries:
                source = os.path.join(unpacked, entry.filename)
                if entry.is_dir():
                    packed.writestr(entry, b"")
                else:
                    with open(source, "rb") as handle: data = handle.read()
                    clone = zipfile.ZipInfo(entry.filename, entry.date_time)
                    clone.external_attr, clone.create_system, clone.compress_type = entry.external_attr, entry.create_system, entry.compress_type
                    packed.writestr(clone, data)
            known = {e.filename for e in entries}
            for folder, _, files in os.walk(unpacked):
                for file in files:
                    relative = os.path.relpath(os.path.join(folder, file), unpacked)
                    if relative not in known: fail(f"neue Datei beim Signieren: {relative}")
        replacement = ipa_path + ".resigned"
        shutil.copyfile(output, replacement)
        os.chmod(replacement, os.stat(ipa_path).st_mode & 0o777)
        os.replace(replacement, ipa_path)
        for plugin, _, _, entitlements in jobs:
            print(f"resign_extensions: {plugin} mit eigenen Entitlements signiert ({', '.join(sorted(entitlements))}); App neu versiegelt")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3): raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "."))
