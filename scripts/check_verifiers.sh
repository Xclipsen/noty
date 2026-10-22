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


# Schema 13: polylines (line/arrow with `points`) and polygons.
def point(x, y):
    return {"x": x, "y": y}


def shape(kind, vertices=None, start=None, end=None, **extra):
    value = {"id": uid(), "kind": kind, "start": start or vertices[0], "end": end or vertices[-1],
             "color": {"red": 0, "green": 0, "blue": 0, "alpha": 1}, "lineWidth": 2, "pattern": "solid"}
    if vertices is not None:
        value["points"] = vertices
    value.update(extra)
    return value


def shaped(version, shapes):
    return dict(valid, schemaVersion=version, pages=[dict(valid["pages"][0], shapes=shapes)] + valid["pages"][1:])


bent = [point(50, 50), point(50, 200), point(200, 200)]
triangle = [point(300, 300), point(400, 300), point(350, 380)]
straight = shape("arrow", start=point(20, 20), end=point(120, 20))
backup("shapes-schema-13.notybackup", shaped(13, [straight, shape("arrow", bent), shape("line", bent), shape("polygon", triangle)]))
backup("shapes-straight-schema-12.notybackup", shaped(12, [straight]))
backup("shapes-polyline-schema-12.notybackup", shaped(12, [shape("arrow", bent)]))
backup("shapes-polygon-schema-12.notybackup", shaped(12, [shape("polygon", triangle)]))
backup("shapes-start-mismatch.notybackup", shaped(13, [shape("line", bent, start=point(51, 50))]))
backup("shapes-two-vertices.notybackup", shaped(13, [shape("line", bent[:2])]))
backup("shapes-polygon-without-points.notybackup", shaped(13, [shape("polygon", start=point(10, 10), end=point(90, 90))]))
backup("shapes-rectangle-points.notybackup", shaped(13, [shape("rectangle", [point(10, 10), point(50, 30), point(90, 90)])]))
backup("shapes-arrow-without-head.notybackup", shaped(13, [shape("arrow", bent + [point(200, 200)])]))
backup("shapes-flat-polygon.notybackup", shaped(13, [shape("polygon", [point(10, 10), point(50, 10), point(90, 10)])]))
backup("shapes-vertex-outside.notybackup", shaped(13, [shape("line", [point(50, 50), point(700, 400), point(100, 100)])]))
backup("shapes-vertex-type.notybackup", shaped(13, [shape("line", [point(50, 50), point("70", 400), point(100, 100)])]))


# Schema 14: free text fields (rotation, automatic width, page text migrated to a field).
def text_box(**extra):
    value = {"id": uid(), "x": 40, "y": 40, "width": 200, "height": 30, "text": "Feld",
             "style": {"font": "system", "fontSize": 17, "bold": False, "italic": False, "underline": False, "color": "black"}}
    value.update(extra)
    return value


def texted(version, boxes):
    return dict(valid, schemaVersion=version, pages=[dict(valid["pages"][0], textBoxes=boxes)] + valid["pages"][1:])


backup("text-fields-schema-14.notybackup",
       texted(14, [text_box(), text_box(rotation=30.5), text_box(rotation=-180), text_box(autoWidth=True), text_box(flowRegion="left")]))
backup("text-plain-schema-13.notybackup", texted(13, [text_box()]))
backup("text-flow-schema-14.notybackup", texted(14, [text_box(flowID=uid(), flowRegion="page")]))
backup("text-rotation-schema-13.notybackup", texted(13, [text_box(rotation=30)]))
backup("text-autowidth-schema-13.notybackup", texted(13, [text_box(autoWidth=True)]))
backup("text-region-schema-13.notybackup", texted(13, [text_box(flowRegion="page")]))
backup("text-rotation-range.notybackup", texted(14, [text_box(rotation=200)]))
backup("text-rotation-type.notybackup", texted(14, [text_box(rotation="30")]))
backup("text-autowidth-false.notybackup", texted(14, [text_box(autoWidth=False)]))
backup("text-flow-rotated.notybackup", texted(14, [text_box(flowID=uid(), flowRegion="page", rotation=10)]))
backup("text-flow-autowidth.notybackup", texted(14, [text_box(flowID=uid(), flowRegion="page", autoWidth=True)]))
backup("text-flow-without-region.notybackup", texted(14, [text_box(flowID=uid())]))
backup("text-region-enum.notybackup", texted(14, [text_box(flowRegion="middle")]))
backup("text-schema-15.notybackup", texted(15, [text_box(rotation=30)]))

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


# Schema 12: the library notebook references two originals (one object twice)
# stored as Assets/<sha256>; unreferenced assets and partial files are counted.
import hashlib
ORIGINALS = [b"\x89PNG first original " * 30, b"second original"]


def with_assets(s):
    directory = other_dir(s)
    objects = []
    for index, data in enumerate(ORIGINALS + ORIGINALS[:1]):
        objects.append({"id": uid(), "asset": {"sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data)},
                        "pixelWidth": 8, "pixelHeight": 6, "x": 40 + index, "y": 40, "width": 120, "height": 90,
                        "rotation": 0, "crop": {"x": 0, "y": 0, "width": 1, "height": 1}, "locked": False})
    current = dict(s["other"], schemaVersion=12, pages=[dict(s["other"]["pages"][0], images=objects)] + s["other"]["pages"][1:])
    head = revision(directory, current, 1_800_001_000.0)
    manifest(directory, "manifest.json", [head] + s["records"]["other"][:2])
    assets = directory / "Assets"
    assets.mkdir()
    for data in ORIGINALS:
        (assets / hashlib.sha256(data).hexdigest()).write_bytes(data)
    s["assets"] = assets
    return directory, assets


def asset_store(name, mutate=None):
    def build(s):
        _, assets = with_assets(s)
        if mutate:
            mutate(s, assets)
    store(name, build)


first_hash = hashlib.sha256(ORIGINALS[0]).hexdigest()
asset_store("assets-valid", lambda s, a: ((a / (first_hash[:-1] + "0")).write_bytes(b"unreferenced"),
                                          (a / (first_hash + ".partial-" + uid())).write_bytes(b"rest")))
asset_store("asset-missing", lambda s, a: (a / first_hash).unlink())
asset_store("asset-size", lambda s, a: (a / first_hash).write_bytes(ORIGINALS[0] + b"x"))
asset_store("asset-flipped", lambda s, a: (a / first_hash).write_bytes(bytes([ORIGINALS[0][0] ^ 1]) + ORIGINALS[0][1:]))


def asset_symlink(s, a):
    target = a.parent / "elsewhere"
    target.write_bytes(ORIGINALS[0])
    (a / first_hash).unlink()
    (a / first_hash).symlink_to(target)


asset_store("asset-symlink", asset_symlink)


def assets_directory_symlink(s, a):
    import shutil
    moved = a.parent / "AssetsElsewhere"
    shutil.move(str(a), str(moved))
    a.symlink_to(moved, target_is_directory=True)


asset_store("assets-directory-symlink", assets_directory_symlink)
PY

# Archive format 2 (record stream) and format-1 library archives. The base
# notebook here has no images, so every asset record is extra; schema-12
# notebook rules follow, the archive asset rules further below.
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


# Schema 12 notebook rules: refused while validating the notebook record,
# before any asset record would be needed (sizes are declared only).
def image_object(sha, count, width=8, height=6, x=40, **extra):
    return dict({"id": uid(), "asset": {"sha256": sha, "byteCount": count}, "pixelWidth": width, "pixelHeight": height,
                 "x": x, "y": 40, "width": 120, "height": 90, "rotation": 0,
                 "crop": {"x": 0, "y": 0, "width": 1, "height": 1}, "locked": False}, **extra)


def with_images(objects, version=12):
    result = json.loads(json.dumps(document))
    result["schemaVersion"] = version
    result["pages"][0]["images"] = objects
    return result


def schema_case(name, notebook):
    write_backup(name, notebook, [data_record("notebook", compact(notebook), notebook["id"])], header=backup_header(notebook))


sha = hashlib.sha256(image).hexdigest()
embedded = base64.b64encode(image).decode()
schema_case("v2-schema12-data-and-asset.notybackup", with_images([image_object(sha, len(image), data=embedded)]))
only_data = image_object(sha, len(image), data=embedded); del only_data["asset"]
schema_case("v2-schema12-data.notybackup", with_images([only_data]))
schema_case("v2-schema11-asset.notybackup", with_images([image_object(sha, len(image))], version=11))
schema_case("v2-schema11-data-and-asset.notybackup", with_images([image_object(sha, len(image), data=embedded)], version=11))
schema_case("v2-schema12-hash-upper.notybackup", with_images([image_object(sha.upper(), len(image))]))
schema_case("v2-schema12-hash-63.notybackup", with_images([image_object(sha[:63], len(image))]))
schema_case("v2-schema12-hash-path.notybackup", with_images([image_object("../" + sha[3:], len(image))]))
schema_case("v2-schema12-asset-over-20mb.notybackup", with_images([image_object("b" * 64, 20_000_001)]))
schema_case("v2-schema12-over-500mb.notybackup",
            with_images([image_object(hashlib.sha256(bytes([n])).hexdigest(), 20_000_000, x=40 + n) for n in range(26)]))
schema_case("v2-schema12-pixel-mismatch.notybackup",
            with_images([image_object(sha, len(image)), image_object(sha, len(image), width=9, x=50)]))
schema_case("v2-schema12-size-mismatch.notybackup",
            with_images([image_object(sha, len(image)), image_object(sha, len(image) + 1, x=50)]))
schema_case("v2-schema15.notybackup", with_images([image_object(sha, len(image))], version=15))
# Format 1 has no asset records: a schema-12 notebook with images is refused.
v1_document = with_images([image_object(sha, len(image))])
v1_payload = json.dumps(v1_document).encode()
v1_header = json.dumps({"backupFormatVersion": 1, "checksumAlgorithm": "crc32-iso-hdlc", "payloadName": "notebook.json",
                        "payloadByteCount": len(v1_payload), "payloadCRC32": zlib.crc32(v1_payload), "documentID": v1_document["id"],
                        "notebookSchemaVersion": 12, "createdAt": CREATED}).encode()
(out / "backups" / "v1-schema12-asset.notybackup").write_bytes(b"NOTYBKP\n" + struct.pack(">I", len(v1_header)) + v1_header + v1_payload)
# A format-2 archive of a schema-11 notebook embeds its original: no asset record.
legacy = with_images([dict({k: v for k, v in image_object(sha, len(image)).items() if k != "asset"}, data=embedded)], version=11)
write_backup("v2-schema11-embedded.notybackup", legacy, [data_record("notebook", compact(legacy), legacy["id"])], header=backup_header(legacy))

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
accept verify_backup.py "$work/backups/shapes-schema-13.notybackup"
accept verify_backup.py "$work/backups/shapes-straight-schema-12.notybackup"
for name in polyline-schema-12 polygon-schema-12 start-mismatch two-vertices polygon-without-points rectangle-points \
            arrow-without-head flat-polygon vertex-outside vertex-type; do
    reject verify_backup.py "$work/backups/shapes-$name.notybackup"
done
for name in fields-schema-14 plain-schema-13 flow-schema-14; do
    accept verify_backup.py "$work/backups/text-$name.notybackup"
done
for name in rotation-schema-13 autowidth-schema-13 region-schema-13 rotation-range rotation-type autowidth-false \
            flow-rotated flow-autowidth flow-without-region region-enum schema-15; do
    reject verify_backup.py "$work/backups/text-$name.notybackup"
done
accept verify_backup.py "$work/backups/v2.notybackup" --compare "$work/backups/v2.json"
for name in extra-asset asset-first no-end trailing version-3 header-key crc descriptor-key wrong-id schema-99 end-totals \
            hash-upper hash-63 hash-path asset-over-20mb; do
    reject verify_backup.py "$work/backups/v2-$name.notybackup"
done
for name in schema12-data-and-asset schema12-data schema11-asset schema11-data-and-asset schema12-hash-upper schema12-hash-63 \
            schema12-hash-path schema12-asset-over-20mb schema12-over-500mb schema12-pixel-mismatch schema12-size-mismatch schema15; do
    reject verify_backup.py "$work/backups/v2-$name.notybackup"
    # The notebook rule itself must refuse (not a missing asset record afterwards).
    if grep -q "Referenced asset missing" "$work/last.log"; then
        echo "FEHLER: verify_backup.py lehnt $name erst wegen fehlender Asset-Daten ab" >&2; cat "$work/last.log" >&2; exit 1
    fi
done
reject verify_backup.py "$work/backups/v1-schema12-asset.notybackup"
# `.noty` is the same format under another extension: the verifier must not depend on it.
cp "$work/backups/v2.notybackup" "$work/backups/v2.noty"
cp "$work/backups/v2-crc.notybackup" "$work/backups/v2-crc.noty"
accept verify_backup.py "$work/backups/v2.noty" --compare "$work/backups/v2.json"
reject verify_backup.py "$work/backups/v2-crc.noty"
accept verify_backup.py "$work/backups/v2-schema11-embedded.notybackup"
accept verify_library_backup.py "$work/libraries/v2.notylibrary"
accept verify_library_backup.py "$work/libraries/v1.notylibrary"
for name in asset-first extra-asset no-end trailing version-3 entries-key missing-notebook crc toolbar-first; do
    reject verify_library_backup.py "$work/libraries/v2-$name.notylibrary"
done
# Archive asset rules with real schema-12 notebooks (image objects reference
# the originals by SHA-256).
for flags in "-B" "-B -O"; do
    # shellcheck disable=SC2086
    if ! python3 $flags - "$task_root/scripts" "$work/assets" <<'PY' > "$work/last.log" 2>&1; then
import hashlib, json, struct, sys, uuid, zlib
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import verify_backup, verify_library_backup

out = Path(sys.argv[2]); out.mkdir(exist_ok=True)
A4 = {"x": 0, "y": 0, "width": 595, "height": 842}


def uid():
    return str(uuid.uuid4()).upper()


def notebook(title, *originals):
    """Schema 12 with one image object per original (none: no images)."""
    images = [{"id": uid(), "asset": {"sha256": hashlib.sha256(p).hexdigest(), "byteCount": len(p)}, "pixelWidth": 8, "pixelHeight": 6,
               "x": 40 + i, "y": 40, "width": 120, "height": 90, "rotation": 0, "crop": {"x": 0, "y": 0, "width": 1, "height": 1},
               "locked": False} for i, p in enumerate(originals)]
    page = {"id": uid(), "drawing": "", "text": "", "paper": "lined", "geometry": {"mediaBox": A4, "cropBox": A4, "rotation": 0}}
    if images:
        page["images"] = images
    return {"schemaVersion": 12 if images else 3, "id": uid(), "title": title, "pdfSources": [], "deletedPages": [], "pages": [page]}


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


a, b = b"first original bytes" * 40, b"second original bytes"
doc = notebook("Bilder", a, b, a)
header = {"backupFormatVersion": 2, "checksumAlgorithm": "crc32-iso-hdlc", "assetHashAlgorithm": "sha256",
          "documentID": doc["id"], "notebookSchemaVersion": 12, "createdAt": "2026-10-20T08:00:00Z"}
nb = data_record("notebook", compact(doc), doc["id"])
backup = lambda name, records: (lambda: verify_backup.verify(write(name, b"NOTYBKP\n", header, records)))
result = expect("backup with assets", True, backup("ok.notybackup", [nb, asset(b), asset(a)]))
if result and (result[1]["assets"], result[1]["assetBytes"]) != (2, len(a) + len(b)):
    failures.append(f"backup asset totals: {result[1]}")
expect("backup missing asset", False, backup("missing.notybackup", [nb, asset(a)]))
expect("backup duplicate asset", False, backup("duplicate.notybackup", [nb, asset(a), asset(a), asset(b)]))
expect("backup SHA-256 mismatch", False, backup("sha.notybackup", [nb, asset(a, flip=True), asset(b)]))

one, two, three = notebook("Eins", a), notebook("Zwei", a, b), notebook("Drei")
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
# Notebook rules directly (declared sizes, no bytes needed).
from notebook_format import validate_notebook
def declared(n, count=20_000_000, width=8):
    return {"id": uid(), "asset": {"sha256": hashlib.sha256(b"declared-%d" % n).hexdigest(), "byteCount": count},
            "pixelWidth": width, "pixelHeight": 6, "x": 40, "y": 40, "width": 120, "height": 90, "rotation": 0,
            "crop": {"x": 0, "y": 0, "width": 1, "height": 1}, "locked": False}
full = notebook("Voll")
full["schemaVersion"] = 12
full["pages"][0]["images"] = [declared(n) for n in range(25)] + [declared(0), declared(1)]
result = expect("500 MB of unique originals, duplicates counted once", True, lambda: validate_notebook(full))
if result is not None and (len(result), sum(result.values())) != (25, 500_000_000):
    failures.append(f"unique references: {len(result)}, {sum(result.values())}")
over = json.loads(json.dumps(full)); over["pages"][0]["images"].append(declared(99, count=1))
expect("one byte over 500 MB", False, lambda: validate_notebook(over))
trash = json.loads(json.dumps(full)); trash["pages"][0]["images"] = trash["pages"][0]["images"][:24]
trash["deletedPages"] = [{"page": {"id": uid(), "drawing": "", "text": "", "paper": "lined",
                                   "geometry": {"mediaBox": A4, "cropBox": A4, "rotation": 0}, "images": [declared(24), declared(98, count=1)]},
                          "originalIndex": 1, "deletedAt": 800_000_000.0}]
expect("the page trash counts", False, lambda: validate_notebook(trash))
mismatch = notebook("Maße"); mismatch["schemaVersion"] = 12
mismatch["pages"][0]["images"] = [declared(1), dict(declared(1, width=9), x=50)]
expect("same hash, other pixel size", False, lambda: validate_notebook(mismatch))
if failures:
    print("\n".join(failures))
    sys.exit(1)
PY
        echo "FEHLER: Asset-Prüfung mit Schema-12-Heften ($flags)" >&2; cat "$work/last.log" >&2; exit 1
    fi
done
accept verify_device_store.py "$work/stores/valid"
accept verify_device_store.py "$work/stores/assets-valid"
python3 -B - "$task_root/scripts" "$work/stores/assets-valid" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from verify_device_store import load_store
_, result = load_store(Path(sys.argv[2]))
expected = {"assets": 2, "unreferenced_assets": 1, "partial_asset_files": 1}
if any(result[key] != value for key, value in expected.items()):
    sys.exit(f"FEHLER: Asset-Zählung des Gerätespeichers {result}")
PY
for name in source-enum title-control title-length date-range favorite-type cycle missing-package revision-crc \
            previous-missing too-many-revisions four-revisions checkpoint-crc checkpoint-format future-manifest \
            future-schema saved-range index-crc asset-missing asset-size asset-flipped asset-symlink assets-directory-symlink; do
    reject verify_device_store.py "$work/stores/$name"
done
echo "Prüfer-Negativtests bestanden (auch mit python3 -O); Fixtures: $work"
