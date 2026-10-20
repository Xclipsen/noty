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
        if ! grep -q "ValueError" "$work/last.log"; then
            echo "FEHLER: $1 bricht ohne Prüfmeldung ab ($flags): ${*:2}" >&2; cat "$work/last.log" >&2; exit 1
        fi
    done
}

accept verify_backup.py "$work/backups/valid.notybackup" --compare "$work/backups/valid.json"
for name in schema-99 crc trailing title-type urn-page-id page-count-type source-enum; do
    reject verify_backup.py "$work/backups/$name.notybackup"
done
accept verify_device_store.py "$work/stores/valid"
for name in source-enum title-control title-length date-range favorite-type cycle missing-package revision-crc \
            previous-missing too-many-revisions four-revisions checkpoint-crc checkpoint-format future-manifest \
            future-schema saved-range index-crc; do
    reject verify_device_store.py "$work/stores/$name"
done
echo "Prüfer-Negativtests bestanden (auch mit python3 -O); Fixtures: $work"
