#!/usr/bin/env bash
# Negative tests for the independent Python verifiers with small generated
# fixtures under .tools/. Every case also runs with `python3 -O`, which drops
# `assert`: rejections must come from explicit checks (ValueError).
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
mkdir -p .tools
work="$(mktemp -d "$task_root/.tools/verifier-check-XXXXXX")"

python3 -B - "$work" <<'PY'
import base64, json, struct, sys, uuid, zlib
from pathlib import Path

out = Path(sys.argv[1])
A4 = {"x": 0, "y": 0, "width": 595, "height": 842}


def uid():
    return str(uuid.uuid4()).upper()


def notebook(title="Prüfheft"):
    source = uid()
    return {"schemaVersion": 3, "id": uid(), "title": title,
            "pages": [{"id": uid(), "drawing": "", "text": "", "paper": "lined",
                       "geometry": {"mediaBox": A4, "cropBox": A4, "rotation": 0}},
                      {"id": uid(), "drawing": "", "text": "", "geometry": {"mediaBox": A4, "cropBox": A4, "rotation": 0},
                       "pdfReference": {"sourceID": source, "pageIndex": 0}}],
            "pdfSources": [{"id": source, "data": base64.b64encode(b"%PDF-1.4 Testquelle").decode(), "pageCount": 1}],
            "deletedPages": []}


def backup(name, document, mutate_bytes=None):
    payload = json.dumps(document).encode()
    header = json.dumps({"backupFormatVersion": 1, "checksumAlgorithm": "crc32-iso-hdlc", "payloadName": "notebook.json",
                         "payloadByteCount": len(payload), "payloadCRC32": zlib.crc32(payload),
                         "documentID": document["id"], "notebookSchemaVersion": document["schemaVersion"],
                         "createdAt": "2026-10-20T08:00:00Z"}).encode()
    data = bytearray(b"NOTYBKP\n" + struct.pack(">I", len(header)) + header + payload)
    if mutate_bytes:
        mutate_bytes(data)
    (out / "backups").mkdir(exist_ok=True)
    (out / "backups" / name).write_bytes(bytes(data))


def revision(directory, document, saved):
    payload = json.dumps(document).encode()
    name = uid() + ".json"
    (directory / "Revisions").mkdir(parents=True, exist_ok=True)
    (directory / "Revisions" / name).write_bytes(payload)
    return {"file": name, "byteCount": len(payload), "crc32": zlib.crc32(payload), "savedAtUnix": saved}


def manifest(directory, name, records, version=1):
    (directory / name).write_text(json.dumps({"formatVersion": version, "checksumAlgorithm": "crc32-iso-hdlc", "revisions": records}))


def checkpoint_list(directory, records, version=1):
    (directory / "checkpoints.json").write_text(json.dumps({"formatVersion": version, "checksumAlgorithm": "crc32-iso-hdlc",
                                                            "checkpoints": records}))


def package(directory, document):
    older = dict(document, title=document["title"] + " (älter)")
    first = revision(directory, older, 1_800_000_000.0)
    second = revision(directory, document, 1_800_000_700.5)
    manifest(directory, "manifest-previous.json", [first])
    manifest(directory, "manifest.json", [second, first])
    # One existing checkpoint, one whose file Build 46 already collected.
    kept = revision(directory, dict(older, title=document["title"] + " (Zwischenstand)"), 1_799_990_000.0)
    checkpoint_list(directory, [kept, dict(kept, file=uid() + ".json")])
    return [second, first, kept]


def envelope(snapshot):
    payload = json.dumps(snapshot).encode()
    return {"formatVersion": 1, "crc32": zlib.crc32(payload), "payload": base64.b64encode(payload).decode()}


def store(name, mutate=None):
    """Main package in the root, one library package, index + fallback index."""
    root = out / "stores" / name
    root.mkdir(parents=True)
    main, other = notebook("Hauptheft"), notebook("Bibliotheksheft")
    records = {"main": package(root, main), "other": package(root / "Library" / "Documents" / other["id"], other)}
    folder = uid()
    items = [{"id": main["id"], "title": "Hauptheft", "source": "legacyMain", "favorite": False},
             {"id": folder, "title": "Ordner · Ä", "favorite": False, "deletedAt": 800_000_000.0},
             {"id": other["id"], "title": "é" * 120, "parentID": folder, "source": "library", "favorite": True,
              "lastOpened": 800_000_000.0}]
    state = {"root": root, "main": main, "other": other, "items": items, "records": records}
    if mutate:
        mutate(state)
    library = root / "Library"
    (library / "index.json").write_text(json.dumps(envelope({"formatVersion": 1, "items": state["items"]})))
    (library / "index-previous.json").write_text(json.dumps(envelope({"formatVersion": 1, "items": items[:2]})))


def other_dir(s):
    return s["root"] / "Library" / "Documents" / s["other"]["id"]


def flip_revision(s):
    path = other_dir(s) / "Revisions" / s["records"]["other"][0]["file"]
    data = bytearray(path.read_bytes()); data[-2] ^= 1; path.write_bytes(bytes(data))


def missing_previous(s):
    manifest(other_dir(s), "manifest-previous.json", [dict(s["records"]["other"][1], file=uid() + ".json")])


def too_many(s):
    directory = other_dir(s)
    manifest(directory, "manifest.json", [revision(directory, s["other"], 1_800_000_000.0 + i) for i in range(9)])


valid = notebook()
backup("valid.notybackup", valid)
(out / "backups" / "valid.json").write_text(json.dumps(valid))
backup("schema-99.notybackup", dict(valid, schemaVersion=99))
backup("crc.notybackup", valid, lambda data: data.__setitem__(len(data) - 3, data[len(data) - 3] ^ 1))
backup("trailing.notybackup", valid, lambda data: data.extend(b" "))
backup("title-type.notybackup", dict(valid, title=5))
backup("urn-page-id.notybackup", dict(valid, pages=[dict(valid["pages"][0], id="urn:uuid:" + uid().lower())] + valid["pages"][1:]))
backup("page-count-type.notybackup", dict(valid, pdfSources=[dict(valid["pdfSources"][0], pageCount="1")]))
backup("source-enum.notybackup", dict(valid, pages=[dict(valid["pages"][0], paper="glossy")] + valid["pages"][1:]))
# Sources above 20 MB need schema 10, so Build 46 refuses instead of falling back.
large = [dict(valid["pdfSources"][0], data=base64.b64encode(bytes(20_000_001)).decode())]
backup("large-source-schema-9.notybackup", dict(valid, schemaVersion=9, pdfSources=large))
backup("large-source-schema-10.notybackup", dict(valid, schemaVersion=10, pdfSources=large))

store("valid")
store("source-enum", lambda s: s["items"][2].update(source="bogus"))
store("title-control", lambda s: s["items"][1].update(title="Ordner\u0007"))
store("title-length", lambda s: s["items"][1].update(title="x" * 121))
store("date-range", lambda s: s["items"][2].update(lastOpened=1e13))
store("favorite-type", lambda s: s["items"][0].update(favorite="ja"))
store("cycle", lambda s: s["items"][1].update(parentID=s["items"][1]["id"]))
store("missing-package", lambda s: s["items"].append({"id": uid(), "title": "Weg", "source": "library", "favorite": False}))
store("revision-crc", flip_revision)
store("previous-missing", missing_previous)
store("too-many-revisions", too_many)
store("four-revisions", lambda s: manifest(other_dir(s), "manifest.json",
                                           [revision(other_dir(s), s["other"], 1_800_000_000.0 + i) for i in range(4)]))
store("checkpoint-crc", lambda s: checkpoint_list(other_dir(s), [dict(s["records"]["other"][2], crc32=s["records"]["other"][2]["crc32"] ^ 1)]))
store("checkpoint-format", lambda s: checkpoint_list(other_dir(s), [], version=2))
store("future-manifest", lambda s: manifest(other_dir(s), "manifest.json", s["records"]["other"], version=2))
store("future-schema", lambda s: manifest(other_dir(s), "manifest.json",
                                          [revision(other_dir(s), dict(s["other"], schemaVersion=99), 1_800_000_900.0)]))
store("saved-range", lambda s: manifest(other_dir(s), "manifest.json", [dict(s["records"]["other"][0], savedAtUnix=1e13)]))
PY

# Archive format 2 (record stream) and format-1 library archives. Schema <= 11
# references no external assets, so every asset record here is extra; the
# harness further below attaches synthetic references for the asset rules.
python3 -B - "$work" <<'PY'
import base64, hashlib, json, struct, sys, uuid, zlib
from pathlib import Path

out = Path(sys.argv[1])
(out / "backups").mkdir(exist_ok=True)
(out / "libraries").mkdir(exist_ok=True)
A4 = {"x": 0, "y": 0, "width": 595, "height": 842}
CREATED = "2026-10-20T08:00:00Z"
TOOLBAR = {"formatVersion": 1, "order": ["pen", "marker", "strokeEraser", "precisionEraser", "inkSelection", "text", "read"],
           "dock": "top", "presets": []}


def uid():
    return str(uuid.uuid4()).upper()


def notebook(title):
    return {"schemaVersion": 3, "id": uid(), "title": title, "pdfSources": [], "deletedPages": [],
            "pages": [{"id": uid(), "drawing": "", "text": "", "paper": "lined",
                       "geometry": {"mediaBox": A4, "cropBox": A4, "rotation": 0}}]}


def compact(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def data_record(kind, payload, identity=None):
    descriptor = {"kind": kind, "byteCount": len(payload), "crc32": zlib.crc32(payload)}
    if identity:
        descriptor["id"] = identity
    return descriptor, payload


def asset_record(payload):
    return {"kind": "asset", "sha256": hashlib.sha256(payload).hexdigest(), "byteCount": len(payload)}, payload


def end_record(records):
    return {"kind": "end", "records": len(records), "payloadBytes": sum(len(p) for _, p in records)}, b""


def stream(magic, header, records, end=True):
    head = compact(header)
    data = bytearray(magic + struct.pack(">I", len(head)) + head)
    for descriptor, payload in records + ([end_record(records)] if end else []):
        encoded = compact(descriptor)
        data += struct.pack(">I", len(encoded)) + encoded + payload
    return bytes(data)


def backup_header(document, **changes):
    return dict({"backupFormatVersion": 2, "checksumAlgorithm": "crc32-iso-hdlc", "assetHashAlgorithm": "sha256",
                 "documentID": document["id"], "notebookSchemaVersion": document["schemaVersion"], "createdAt": CREATED}, **changes)


def write_backup(name, document, records=None, header=None, end=True, mutate=None):
    records = [data_record("notebook", compact(document), document["id"])] if records is None else records
    data = bytearray(stream(b"NOTYBKP\n", header or backup_header(document), records, end))
    if mutate:
        mutate(data)
    (out / "backups" / name).write_bytes(bytes(data))


document = notebook("Format 2 · Ä")
(out / "backups" / "v2.json").write_text(json.dumps(document))
notebook_record = data_record("notebook", compact(document), document["id"])
image = b"\x89PNG synthetic asset bytes"
write_backup("v2.notybackup", document)
write_backup("v2-extra-asset.notybackup", document, [notebook_record, asset_record(image)])
write_backup("v2-asset-first.notybackup", document, [asset_record(image), notebook_record])
write_backup("v2-no-end.notybackup", document, end=False)
write_backup("v2-trailing.notybackup", document, mutate=lambda d: d.extend(b"\0"))
write_backup("v2-version-3.notybackup", document, header=backup_header(document, backupFormatVersion=3))
write_backup("v2-header-key.notybackup", document, header=backup_header(document, payloadName="notebook.json"))
write_backup("v2-crc.notybackup", document, [(notebook_record[0], notebook_record[1][:-2] + b"x}")])
write_backup("v2-descriptor-key.notybackup", document, [(dict(notebook_record[0], sha256="0" * 64), notebook_record[1])])
write_backup("v2-wrong-id.notybackup", document, [(dict(notebook_record[0], id=uid()), notebook_record[1])])
write_backup("v2-schema-99.notybackup", dict(document, schemaVersion=99),
             [data_record("notebook", compact(dict(document, schemaVersion=99)), document["id"])])
records = [notebook_record]
counts = end_record(records)
write_backup("v2-end-totals.notybackup", document, records + [(dict(counts[0], records=2), b"")], end=False)
upper = asset_record(image); upper = (dict(upper[0], sha256=upper[0]["sha256"].upper()), image)
write_backup("v2-hash-upper.notybackup", document, [notebook_record, upper])
short = asset_record(image); short = (dict(short[0], sha256=short[0]["sha256"][:63]), image)
write_backup("v2-hash-63.notybackup", document, [notebook_record, short])
path = asset_record(image); path = (dict(path[0], sha256="../" + "a" * 61), image)
write_backup("v2-hash-path.notybackup", document, [notebook_record, path])
# Declared only: the record is refused before any payload is read.
write_backup("v2-asset-over-20mb.notybackup", document,
             [notebook_record, ({"kind": "asset", "sha256": "a" * 64, "byteCount": 20_000_001}, b"")], end=False)

first, second = notebook("Eins"), notebook("Zwei")
items = [{"id": first["id"], "title": first["title"], "source": "library", "favorite": False},
         {"id": second["id"], "title": second["title"], "source": "library", "favorite": False}]
index = compact({"formatVersion": 1, "items": items})
toolbar = compact(TOOLBAR)
library_header = {"libraryBackupVersion": 2, "checksumAlgorithm": "crc32-iso-hdlc", "assetHashAlgorithm": "sha256", "createdAt": CREATED}
head = [data_record("index", index), data_record("toolbar", toolbar)]
groups = [data_record("notebook", compact(first), first["id"]), data_record("notebook", compact(second), second["id"])]


def write_library(name, records, header=library_header, end=True, mutate=None):
    data = bytearray(stream(b"NOTYLIB\n", header, records, end))
    if mutate:
        mutate(data)
    (out / "libraries" / name).write_bytes(bytes(data))


write_library("v2.notylibrary", head + groups)
write_library("v2-asset-first.notylibrary", head + [asset_record(image)] + groups)
write_library("v2-extra-asset.notylibrary", head + groups[:1] + [asset_record(image)] + groups[1:])
write_library("v2-no-end.notylibrary", head + groups, end=False)
write_library("v2-trailing.notylibrary", head + groups, mutate=lambda d: d.extend(b"\0\0\0\0"))
write_library("v2-version-3.notylibrary", head + groups, header=dict(library_header, libraryBackupVersion=3))
write_library("v2-entries-key.notylibrary", head + groups, header=dict(library_header, entries=[]))
write_library("v2-missing-notebook.notylibrary", head + groups[:1])
write_library("v2-crc.notylibrary", head + [(groups[0][0], groups[0][1][:-2] + b"x}")] + groups[1:])
write_library("v2-toolbar-first.notylibrary", head[::-1] + groups)

# Format 1 as written up to Build 53: reserved manifest padded with spaces.
chunks = [index, toolbar, compact(first), compact(second)]
entries = [{"kind": "index", "byteCount": len(index), "crc32": zlib.crc32(index)},
           {"kind": "toolbar", "byteCount": len(toolbar), "crc32": zlib.crc32(toolbar)}]
entries += [{"kind": "notebook", "id": doc["id"], "byteCount": len(chunk), "crc32": zlib.crc32(chunk)}
            for doc, chunk in zip((first, second), chunks[2:])]
manifest = json.dumps({"libraryBackupVersion": 1, "checksumAlgorithm": "crc32-iso-hdlc", "createdAt": CREATED,
                       "entries": entries}).encode() + b"   "
(out / "libraries" / "v1.notylibrary").write_bytes(b"NOTYLIB\n" + struct.pack(">I", len(manifest)) + manifest + b"".join(chunks))
PY

# A wrong index checksum is easiest to produce after writing.
cp -R "$work/stores/valid" "$work/stores/index-crc"
python3 -B - "$work/stores/index-crc/Library/index.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.loads(open(path, encoding="utf-8").read())
value["crc32"] ^= 1
open(path, "w", encoding="utf-8").write(json.dumps(value))
PY

run() { # flags verifier arguments...
    local flags="$1"; shift
    # shellcheck disable=SC2086
    python3 $flags "scripts/$1" "${@:2}" > "$work/last.log" 2>&1
}
accept() {
    for flags in "-B" "-B -O"; do
        if ! run "$flags" "$@"; then
            echo "FEHLER: $1 lehnt gültige Testdaten ab ($flags): ${*:2}" >&2; cat "$work/last.log" >&2; exit 1
        fi
    done
}
reject() {
    for flags in "-B" "-B -O"; do
        if run "$flags" "$@"; then
            echo "FEHLER: $1 akzeptiert ungültige Testdaten ($flags): ${*:2}" >&2; exit 1
        fi
        # verify_library_backup.py names the type: VerificationError is a ValueError.
        if ! grep -Eq "ValueError|VerificationError" "$work/last.log"; then
            echo "FEHLER: $1 bricht ohne Prüfmeldung ab ($flags): ${*:2}" >&2; cat "$work/last.log" >&2; exit 1
        fi
    done
}

accept verify_backup.py "$work/backups/valid.notybackup" --compare "$work/backups/valid.json"
accept verify_backup.py "$work/backups/large-source-schema-10.notybackup"
for name in schema-99 crc trailing title-type urn-page-id page-count-type source-enum large-source-schema-9; do
    reject verify_backup.py "$work/backups/$name.notybackup"
done
accept verify_backup.py "$work/backups/v2.notybackup" --compare "$work/backups/v2.json"
for name in extra-asset asset-first no-end trailing version-3 header-key crc descriptor-key wrong-id schema-99 end-totals \
            hash-upper hash-63 hash-path asset-over-20mb; do
    reject verify_backup.py "$work/backups/v2-$name.notybackup"
done
accept verify_library_backup.py "$work/libraries/v2.notylibrary"
accept verify_library_backup.py "$work/libraries/v1.notylibrary"
for name in asset-first extra-asset no-end trailing version-3 entries-key missing-notebook crc toolbar-first; do
    reject verify_library_backup.py "$work/libraries/v2-$name.notylibrary"
done
# Asset rules with synthetic references (schema 12 does not exist yet): the
# harness patches validate_notebook to report references for given notebooks.
for flags in "-B" "-B -O"; do
    # shellcheck disable=SC2086
    if ! python3 $flags - "$task_root/scripts" "$work/assets" <<'PY' > "$work/last.log" 2>&1; then
import hashlib, json, struct, sys, uuid, zlib
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import verify_backup, verify_library_backup

out = Path(sys.argv[2]); out.mkdir(exist_ok=True)
references = {}
for module in (verify_backup, verify_library_backup):
    module.validate_notebook = (lambda original: lambda doc: (original(doc), references.get(doc["id"].upper(), {}))[1])(module.validate_notebook)
A4 = {"x": 0, "y": 0, "width": 595, "height": 842}


def uid():
    return str(uuid.uuid4()).upper()


def notebook(title):
    return {"schemaVersion": 3, "id": uid(), "title": title, "pdfSources": [], "deletedPages": [],
            "pages": [{"id": uid(), "drawing": "", "text": "", "paper": "lined", "geometry": {"mediaBox": A4, "cropBox": A4, "rotation": 0}}]}


def compact(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def data_record(kind, payload, identity=None):
    descriptor = {"kind": kind, "byteCount": len(payload), "crc32": zlib.crc32(payload)}
    if identity:
        descriptor["id"] = identity
    return descriptor, payload


def asset(payload, flip=False):
    descriptor = {"kind": "asset", "sha256": hashlib.sha256(payload).hexdigest(), "byteCount": len(payload)}
    return descriptor, (payload[:-1] + bytes([payload[-1] ^ 1])) if flip else payload


def write(name, magic, header, records):
    records = records + [({"kind": "end", "records": len(records), "payloadBytes": sum(len(p) for _, p in records)}, b"")]
    head = compact(header)
    data = bytearray(magic + struct.pack(">I", len(head)) + head)
    for descriptor, payload in records:
        encoded = compact(descriptor)
        data += struct.pack(">I", len(encoded)) + encoded + payload
    (out / name).write_bytes(bytes(data))
    return out / name


def refs(*payloads):
    return {hashlib.sha256(p).hexdigest(): len(p) for p in payloads}


failures = []


def expect(name, valid, run):
    try:
        result = run()
    except ValueError as error:
        if valid:
            failures.append(f"{name}: rejected ({error})")
        return None
    if not valid:
        failures.append(f"{name}: accepted")
    return result


a, b = b"first synthetic original" * 40, b"second synthetic original"
doc = notebook("Bilder")
references[doc["id"]] = refs(a, b)
header = {"backupFormatVersion": 2, "checksumAlgorithm": "crc32-iso-hdlc", "assetHashAlgorithm": "sha256",
          "documentID": doc["id"], "notebookSchemaVersion": 3, "createdAt": "2026-10-20T08:00:00Z"}
nb = data_record("notebook", compact(doc), doc["id"])
backup = lambda name, records: (lambda: verify_backup.verify(write(name, b"NOTYBKP\n", header, records)))
result = expect("backup with assets", True, backup("ok.notybackup", [nb, asset(b), asset(a)]))
if result and (result[1]["assets"], result[1]["assetBytes"]) != (2, len(a) + len(b)):
    failures.append(f"backup asset totals: {result[1]}")
expect("backup missing asset", False, backup("missing.notybackup", [nb, asset(a)]))
expect("backup duplicate asset", False, backup("duplicate.notybackup", [nb, asset(a), asset(a), asset(b)]))
expect("backup SHA-256 mismatch", False, backup("sha.notybackup", [nb, asset(a, flip=True), asset(b)]))

one, two, three = notebook("Eins"), notebook("Zwei"), notebook("Drei")
references[one["id"]] = refs(a)
references[two["id"]] = refs(a, b)
items = [{"id": n["id"], "title": n["title"], "source": "library", "favorite": False} for n in (one, two, three)]
toolbar = {"formatVersion": 1, "order": ["pen", "marker", "strokeEraser", "precisionEraser", "inkSelection", "text", "read"],
           "dock": "top", "presets": []}
head = [data_record("index", compact({"formatVersion": 1, "items": items})), data_record("toolbar", compact(toolbar))]
library_header = {"libraryBackupVersion": 2, "checksumAlgorithm": "crc32-iso-hdlc", "assetHashAlgorithm": "sha256",
                  "createdAt": "2026-10-20T08:00:00Z"}
n1, n2, n3 = (data_record("notebook", compact(n), n["id"]) for n in (one, two, three))
library = lambda name, records: (lambda: verify_library_backup.verify(write(name, b"NOTYLIB\n", library_header, head + records)))
result = expect("library with shared asset", True, library("ok.notylibrary", [n1, asset(a), n2, asset(b), n3]))
if result and (result["assets"], result["sharedAssets"], result["assetBytes"]) != (2, 1, len(a) + len(b)):
    failures.append(f"library asset totals: {result}")
expect("library asset of a later notebook", False, library("foreign.notylibrary", [n1, asset(a), asset(b), n2, n3]))
expect("library reference carried too late", False, library("late.notylibrary", [n1, n2, asset(a), asset(b), n3]))
expect("library reference never carried", False, library("missing.notylibrary", [n1, asset(a), n2, n3]))
expect("library same hash twice", False, library("twice.notylibrary", [n1, asset(a), n2, asset(a), asset(b), n3]))
expect("library SHA-256 mismatch", False, library("sha.notylibrary", [n1, asset(a), n2, asset(b, flip=True), n3]))
expect("library asset after the last notebook's group", False, library("unreferenced.notylibrary", [n1, asset(a), n2, asset(b), n3, asset(b"x")]))
if failures:
    print("\n".join(failures))
    sys.exit(1)
PY
        echo "FEHLER: Asset-Prüfung mit synthetischen Verweisen ($flags)" >&2; cat "$work/last.log" >&2; exit 1
    fi
done
accept verify_device_store.py "$work/stores/valid"
for name in source-enum title-control title-length date-range favorite-type cycle missing-package revision-crc \
            previous-missing too-many-revisions four-revisions checkpoint-crc checkpoint-format future-manifest \
            future-schema saved-range index-crc; do
    reject verify_device_store.py "$work/stores/$name"
done
echo "Prüfer-Negativtests bestanden (auch mit python3 -O); Fixtures: $work"
