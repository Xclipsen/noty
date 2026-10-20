#!/usr/bin/env python3
"""Read-only CRC/identity audit of an AFC copy. Never prints note contents.

ROOT is `Documents/Noty` or one `NotyWorkspaces/Areas/*/Data` root. Checks both
manifests (1–3 entries, Build 46 format) of every package (main root,
Restores/*, Library/Documents/*), checkpoints.json if present (files collected
by Build 46 are tolerated and counted), every referenced revision and, if
present, the library index and its fallback copy.

Image assets (schema 12): `Assets/` of a package must be a real directory
without symlinks; every original referenced by a checked revision must be a
regular file `Assets/<sha256>` of the right size and SHA-256. Unreferenced
assets and rests of interrupted writes (`<sha256>.partial-<UUID>`) are counted,
not rejected (the app's GC removes them); contents are never printed."""
import argparse
import hashlib
import json
import re
import zlib
from pathlib import Path
from notebook_format import (UNIX_RANGE, base64_bytes, check, foundation_date, number, strict,
                             uuid_string, valid_title, validate_notebook)

CANONICAL_UUID = r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
REVISION_FILE = re.compile(CANONICAL_UUID + r"\.json")
ASSET_FILE = re.compile(r"[0-9a-f]{64}")
PARTIAL_FILE = re.compile(r"[0-9a-f]{64}\.partial-" + CANONICAL_UUID)
PACKAGE_DIRECTORY = re.compile(CANONICAL_UUID)
MANIFEST_LIMIT = 128_000
REVISION_LIMIT = 200_000_000
INDEX_LIMIT = 4_000_000
MAXIMUM_REVISIONS = 3  # Build 46 manifest format; older states are in checkpoints.json
MAXIMUM_CHECKPOINTS = 8


def present(path):
    return path.exists() or path.is_symlink()


def regular_file(path, limit, message):
    check(not path.is_symlink() and path.is_file(), message)
    check(1 <= path.stat().st_size <= limit, message + " (size)")
    return path.read_bytes()


def real_directory(path, message):
    check(not path.is_symlink() and path.is_dir(), message)


def read_records(directory, name, key, minimum, maximum, root, checked, missing_allowed=False):
    """Validates one manifest/checkpoint list; `checked` caches verified
    revisions by file name. Returns documents and the number of missing files."""
    listing = json.loads(regular_file(directory / name, MANIFEST_LIMIT, f"Invalid {name}"))
    check(isinstance(listing, dict) and listing["formatVersion"] == 1, f"Unsupported {name} format")
    check(listing["checksumAlgorithm"] == "crc32-iso-hdlc", f"Unexpected checksum algorithm in {name}")
    records = listing[key]
    check(isinstance(records, list) and minimum <= len(records) <= maximum, f"Revision count outside limits in {name}")
    check(len({record["file"] for record in records}) == len(records), f"Duplicate revision entries in {name}")
    revisions = directory / "Revisions"
    real_directory(revisions, "Invalid Revisions directory")
    documents = []
    missing = 0
    for record in records:
        file, count, crc = record["file"], record["byteCount"], record["crc32"]
        check(isinstance(file, str) and REVISION_FILE.fullmatch(file) is not None, "Invalid revision file name")
        check(type(count) is int and 1 <= count <= REVISION_LIMIT, "Revision size outside limits")
        check(type(crc) is int and 0 <= crc <= 0xFFFF_FFFF, "Invalid revision checksum")
        saved = record.get("savedAtUnix")
        check(saved is None or (number(saved) and UNIX_RANGE[0] <= saved <= UNIX_RANGE[1]), "Revision date outside range")
        # Build 46 does not know checkpoints.json and may have collected these files.
        if missing_allowed and not present(revisions / file):
            missing += 1
            continue
        if file not in checked:
            path = revisions / file
            check(path.resolve().is_relative_to(root.resolve()), "Revision outside root")
            payload = regular_file(path, count, "Missing or invalid revision file")
            check(len(payload) == count and zlib.crc32(payload) == crc, "Revision checksum mismatch")
            document = json.loads(payload)
            references = validate_notebook(document)
            checked[file] = (count, crc, document, references)
        check(checked[file][:2] == (count, crc), "Manifests disagree about a revision")
        documents.append(checked[file][2])
    return documents, missing


def check_assets(directory, references, root):
    """Every referenced original present, right size and SHA-256 (1 MB
    blocks); returns counts of verified, unreferenced and partial files."""
    assets = directory / "Assets"
    names = []
    if present(assets):
        real_directory(assets, "Invalid Assets directory")
        for path in assets.iterdir():
            check(not path.is_symlink(), "Symlink in Assets directory")
            names.append(path.name)
    for sha, count in sorted(references.items()):
        path = assets / sha
        check(path.resolve().is_relative_to(root.resolve()), "Image asset outside root")
        check(not path.is_symlink() and path.is_file(), "Referenced image asset missing")
        check(path.stat().st_size == count, "Image asset size mismatch")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while block := stream.read(1_000_000):
                digest.update(block)
        check(digest.hexdigest() == sha, "Image asset checksum mismatch")
    return {"assets": len(references), "asset_bytes": sum(references.values()),
            "unreferenced_assets": sum(1 for n in names if ASSET_FILE.fullmatch(n) and n not in references),
            "partial_asset_files": sum(1 for n in names if PARTIAL_FILE.fullmatch(n)),
            "foreign_asset_entries": sum(1 for n in names if not ASSET_FILE.fullmatch(n) and not PARTIAL_FILE.fullmatch(n))}


def read_manifest(directory, name, root, checked):
    return read_records(directory, name, "revisions", 1, MAXIMUM_REVISIONS, root, checked)[0]


def validate_snapshot(snapshot):
    check(isinstance(snapshot, dict) and snapshot["formatVersion"] == 1, "Unsupported library index format")
    items = snapshot["items"]
    check(isinstance(items, list) and len(items) <= 10_000, "Library index too large")
    ids = [uuid_string(item["id"]) for item in items]
    check(len(set(ids)) == len(ids), "Duplicate library identities")
    lookup = dict(zip(ids, items))
    check(sum(item.get("source") == "legacyMain" for item in items) <= 1, "More than one legacy main notebook")
    for item_id, item in lookup.items():
        check(item.get("source") in (None, "legacyMain", "restored", "library"), "Unknown library source")
        check(valid_title(item["title"]), "Invalid library title")
        check(type(item["favorite"]) is bool, "Invalid favorite flag")
        for key in ("lastOpened", "deletedAt"):
            if item.get(key) is not None:
                foundation_date(item[key], "Library date outside range")
        seen = {item_id}
        parent = item.get("parentID")
        while parent is not None:
            parent = uuid_string(parent)
            check(parent not in seen and parent in lookup and lookup[parent].get("source") is None, "Invalid parent/cycle")
            seen.add(parent)
            parent = lookup[parent].get("parentID")


def read_index_file(path):
    envelope = json.loads(regular_file(path, INDEX_LIMIT, f"Invalid {path.name}"))
    check(isinstance(envelope, dict) and envelope["formatVersion"] == 1, "Unsupported library index format")
    payload = base64_bytes(envelope["payload"])
    check(type(envelope["crc32"]) is int and zlib.crc32(payload) == envelope["crc32"], "Library index checksum mismatch")
    snapshot = json.loads(payload)
    validate_snapshot(snapshot)
    return snapshot


def check_index(root, documents, locations):
    """Every indexed notebook needs its package; unindexed packages are allowed
    (the app adopts them on the next library load)."""
    library = root / "Library"
    names = [name for name in ("index.json", "index-previous.json") if present(library / name)]
    if not names:
        return None
    real_directory(library, "Invalid Library directory")
    snapshots = [read_index_file(library / name) for name in names]
    items = snapshots[0]["items"]
    expected = {"restored": root / "Restores", "library": root / "Library" / "Documents"}
    indexed = set()
    for item in items:
        source = item.get("source")
        if source is None:
            continue
        item_id = uuid_string(item["id"])
        indexed.add(item_id)
        if source == "legacyMain" and not present(root / "manifest.json"):
            check(present(root / "notebook.json") or present(root / "recovery.json"), "Indexed main notebook is missing")
            continue
        check(item_id in documents, "Indexed notebook package is missing")
        location = root if source == "legacyMain" else expected[source] / item_id
        check(locations[item_id] == location, "Indexed notebook is stored at an unexpected location")
    return {"items": len(items), "folders": sum(item.get("source") is None for item in items),
            "unindexed_packages": len(set(documents) - indexed), "checked_index_files": len(snapshots)}


@strict
def load_store(root):
    real_directory(root, "Root is not a directory")
    directories = [root]
    for relative in ("Restores", "Library/Documents"):
        parent = root / relative
        if present(parent):
            real_directory(parent, f"Invalid {relative} directory")
            directories.extend(sorted(p for p in parent.iterdir()
                                      if p.is_dir() and not p.is_symlink() and PACKAGE_DIRECTORY.fullmatch(p.name)))
    documents, locations, package_assets = {}, {}, {}
    revisions = quarantined = checkpoints = missing_checkpoints = 0
    asset_totals = {"assets": 0, "asset_bytes": 0, "unreferenced_assets": 0, "partial_asset_files": 0, "foreign_asset_entries": 0}
    for directory in directories:
        if not present(directory / "manifest.json"):
            if directory == root:
                continue
            raise ValueError("Missing document manifest")
        checked = {}
        head = read_manifest(directory, "manifest.json", root, checked)[0]
        if present(directory / "manifest-previous.json"):
            read_manifest(directory, "manifest-previous.json", root, checked)
        if present(directory / "checkpoints.json"):
            found, missing = read_records(directory, "checkpoints.json", "checkpoints", 0, MAXIMUM_CHECKPOINTS,
                                          root, checked, missing_allowed=True)
            checkpoints += len(found)
            missing_checkpoints += missing
        revisions += len(checked)
        references = {}
        for _, _, _, refs in checked.values():
            for sha, count in refs.items():
                check(references.setdefault(sha, count) == count, "Revisions disagree about an image asset")
        counts = check_assets(directory, references, root)
        for key, value in counts.items():
            asset_totals[key] += value
        head_id = uuid_string(head["id"])
        check(head_id not in documents, "Duplicate document identity")
        if directory != root:
            check(head_id == directory.name, "Package name does not match document identity")
        documents[head_id] = head
        locations[head_id] = directory
        package_assets[head_id] = references
        quarantine = directory / "Quarantine"
        if quarantine.is_dir() and not quarantine.is_symlink():
            quarantined += sum(1 for path in quarantine.rglob("*") if path.is_file() and not path.is_symlink())
    index = check_index(root, documents, locations)
    return (documents, locations, package_assets), dict({"documents": len(documents), "checked_revisions": revisions,
                       "checkpoints": checkpoints, "missing_checkpoint_files": missing_checkpoints,
                       "library_index": index, "quarantined_files": quarantined}, **asset_totals)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()
    (documents, locations, _), result = load_store(args.root)
    if args.compare:
        (previous, _, previous_assets), _ = load_store(args.compare)
        check(previous.keys() <= documents.keys(), "A previous document is missing")
        check(all(documents[key] == value for key, value in previous.items()), "A previous document changed")
        # The originals every previous revision referenced are still there.
        for key, references in previous_assets.items():
            check_assets(locations[key], references, args.root)
        result["previous_documents_unchanged"] = len(previous)
        result["previous_assets_present"] = sum(len(r) for r in previous_assets.values())
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
