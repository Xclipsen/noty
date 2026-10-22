#!/usr/bin/env python3
"""Independently verify a .notylibrary archive, without extracting paths/text.

Reads the archive chunk by chunk (one notebook in memory at a time) and checks
the same limits as noty: archive <= 4 GB, notebook chunk <= 200 MB, index
<= 4 MB, preferences <= 64 KB; format 1 manifest <= 2 MB. Format 2 is the
record stream of record_archive.py: index, toolbar, then per notebook its
record followed by those of its image assets no earlier group carried, then
the end record. Each asset hash occurs once, is referenced by the notebook of
its group and is checked with SHA-256. Exit code 1 on any violation.
"""
import argparse
import json
import struct
import sys
import zlib
from pathlib import Path
from uuid import UUID
from notebook_format import appearance, uuid_string, validate_notebook
from record_archive import ASSET_LIMIT, MAXIMUM_HEADER as RECORD_HEADER, RecordReader, check_date, check_references

MAXIMUM_BYTES = 4_000_000_000
MAXIMUM_NOTEBOOK = 200_000_000
MAXIMUM_HEADER = 2_000_000
MAXIMUM_INDEX = 4_000_000
MAXIMUM_TOOLBAR = 64_000


class VerificationError(ValueError):
    pass


def require(condition, message):
    # Explicit checks instead of assert: they must also hold under `python -O`.
    if not condition:
        raise VerificationError(message)


def number(value, low, high):
    return type(value) in (int, float) and low <= value <= high


def color(value):
    return type(value) is dict and all(number(value.get(key), 0, 1) for key in ("red", "green", "blue", "alpha"))


def verify_toolbar(toolbar):
    require(type(toolbar) is dict and toolbar.get("formatVersion") in (1, 2, 3, 4, 5, 6, 7, 8), "Unsupported toolbar format")
    tools = {"pen", "marker", "strokeEraser", "precisionEraser", "inkSelection", "text", "read"}
    if toolbar["formatVersion"] >= 2:
        tools.add("image")
    if toolbar["formatVersion"] >= 3:
        tools.update(("shape", "selection"))
    if toolbar["formatVersion"] >= 8:
        tools.update(("pencil", "laser"))
    require(len(toolbar["order"]) == len(tools) and set(toolbar["order"]) == tools, "Invalid tool order")
    docks = ("top", "bottom", "left", "right", "floating") if toolbar["formatVersion"] >= 4 else ("top", "left", "right", "floating")
    require(toolbar["dock"] in docks, "Invalid dock")
    for key in ("autoPen", "pencilPreview", "paging", "eraserPrecision"):
        require(toolbar.get(key) is None or (toolbar["formatVersion"] >= 4 and type(toolbar[key]) is bool), "Invalid " + key)
    require(toolbar.get("floatingAxis") is None or (toolbar["formatVersion"] >= 5 and toolbar["floatingAxis"] in ("horizontal", "vertical")), "Invalid floatingAxis")
    require(toolbar.get("dockOnly") is None or (toolbar["formatVersion"] >= 6 and type(toolbar["dockOnly"]) is bool), "Invalid dockOnly")
    for key in ("markerStraight", "scribbleErase"):
        require(toolbar.get(key) is None or type(toolbar[key]) is bool, "Invalid " + key)
    require(toolbar.get("defaultAppearance") is None or type(toolbar["defaultAppearance"]) is dict, "Invalid defaultAppearance")
    appearance(toolbar.get("defaultAppearance"))
    require(toolbar.get("normalizePageWidths") is None or (toolbar["formatVersion"] >= 7 and type(toolbar["normalizePageWidths"]) is bool), "Invalid normalizePageWidths")
    format8 = toolbar["formatVersion"] >= 8
    for key in ("pencilColor", "laserColor"):
        require(toolbar.get(key) is None or (format8 and color(toolbar[key])), "Invalid " + key)
    require(toolbar.get("pencilWidth") is None or (format8 and number(toolbar["pencilWidth"], 1, 16)), "Invalid pencilWidth")
    require(toolbar.get("autoPencil") is None or (format8 and type(toolbar["autoPencil"]) is bool), "Invalid autoPencil")
    require(toolbar.get("laserMode") is None or (format8 and toolbar["laserMode"] in ("dot", "trail")), "Invalid laserMode")
    require(toolbar.get("laserFade") is None or (format8 and toolbar["laserFade"] in ("short", "medium", "long", "untilLift")), "Invalid laserFade")
    # Build 45: optional highlighter tip (format 8, absent = round).
    require(toolbar.get("markerTip") is None or (format8 and toolbar["markerTip"] in ("round", "chisel")), "Invalid markerTip")
    # 22.10.2026: optional fill of new shapes (own colour, strength 10-100 %).
    require(toolbar.get("shapeFillColor") is None or (format8 and color(toolbar["shapeFillColor"])), "Invalid shapeFillColor")
    require(toolbar.get("shapeFillOpacity") is None or (format8 and number(toolbar["shapeFillOpacity"], 0.1, 1)), "Invalid shapeFillOpacity")
    widths = {"pen": (1, 12), "marker": (4, 40), "pencil": (1, 16)} if format8 else {"pen": (1, 12), "marker": (4, 40)}
    require(len(toolbar["presets"]) <= 12, "Too many presets")
    for preset in toolbar["presets"]:
        require(preset["tool"] in widths and number(preset["width"], *widths[preset["tool"]]) and color(preset["color"]), "Invalid preset")
        require(preset.get("markerTip") is None or (format8 and preset["tool"] == "marker" and preset["markerTip"] in ("round", "chisel")), "Invalid preset tip")


def verify_index(index):
    require(type(index) is dict and index.get("formatVersion") == 1, "Unsupported index format")
    items = index["items"]
    require(len(items) <= 10_000 and len({i["id"] for i in items}) == len(items), "Invalid index items")
    lookup = {i["id"]: i for i in items}
    for item in items:
        UUID(item["id"])
        seen = {item["id"]}
        parent = item.get("parentID")
        while parent is not None:
            require(parent not in seen and parent in lookup and lookup[parent].get("source") is None, "Invalid parent/cycle")
            seen.add(parent)
            parent = lookup[parent].get("parentID")
    return items, lookup


HEADER_KEYS = {"libraryBackupVersion", "checksumAlgorithm", "assetHashAlgorithm", "createdAt"}


def verify(path):
    require(path.is_file() and not path.is_symlink(), "Not a regular file")
    size = path.stat().st_size
    require(size <= MAXIMUM_BYTES, "Archive exceeds size limit")
    with path.open("rb") as stream:
        prefix = stream.read(12)
        require(len(prefix) == 12 and prefix[:8] == b"NOTYLIB\n", "Wrong header")
        length, = struct.unpack(">I", prefix[8:12])
        require(1 <= length <= MAXIMUM_HEADER and size - 12 >= length, "Wrong header length")
        header = json.loads(stream.read(length))
        require(isinstance(header, dict), "Invalid header")
        version = header.get("libraryBackupVersion")
    require(version in (1, 2) and type(version) is int, "Unsupported archive version")
    return verify_v1(path, size) if version == 1 else verify_v2(path, size)


def verify_v2(path, size):
    with path.open("rb") as stream:
        reader = RecordReader(stream, size)
        header = reader.header(b"NOTYLIB\n", RECORD_HEADER)
        require(set(header) == HEADER_KEYS, "Unexpected header fields")
        require(header["libraryBackupVersion"] == 2 and header["checksumAlgorithm"] == "crc32-iso-hdlc"
                and header["assetHashAlgorithm"] == "sha256", "Unexpected format or algorithm")
        check_date(header["createdAt"])
        first = reader.descriptor()
        require(first["kind"] == "index", "First record must be the index")
        items, lookup = verify_index(json.loads(reader.payload(first, MAXIMUM_INDEX)))
        second = reader.descriptor()
        require(second["kind"] == "toolbar", "Second record must be the toolbar")
        toolbar = json.loads(reader.payload(second, MAXIMUM_TOOLBAR))
        verify_toolbar(toolbar)
        expected = {uuid_string(i["id"]): i["id"] for i in items if i.get("source") is not None}
        emitted, ids, shared = {}, set(), set()
        group = None  # references of the current notebook

        def finish(group):
            if group is not None:
                require(all(emitted.get(sha) == count for sha, count in group.items()), "Referenced asset missing")

        while True:
            record = reader.descriptor()
            kind = record["kind"]
            if kind == "notebook":
                finish(group)
                require(record["id"] in expected and record["id"] not in ids, "Wrong notebook entry")
                ids.add(record["id"])
                document = json.loads(reader.payload(record, MAXIMUM_NOTEBOOK))
                require(isinstance(document, dict) and uuid_string(document["id"]) == record["id"], "Notebook identity mismatch")
                group = check_references(validate_notebook(document))
                require(document["title"] == lookup[expected[record["id"]]]["title"], "Notebook title differs from index")
                shared.update(sha for sha in group if sha in emitted)
                del document
            elif kind == "asset":
                require(group is not None, "Asset before any notebook")
                require(group.get(record["sha256"]) == record["byteCount"], "Asset not referenced by its notebook")
                require(record["sha256"] not in emitted and record["byteCount"] <= ASSET_LIMIT, "Duplicate asset")
                reader.asset(record)
                emitted[record["sha256"]] = record["byteCount"]
            elif kind == "end":
                finish(group)
                reader.end(record)
                break
            else:
                require(False, "Index or toolbar record out of place")
        require(ids == set(expected), "Incomplete document set")
    return {"formatVersion": 2, "documents": len(expected), "folders": len(items) - len(expected),
            "explicitly_trashed": sum(i.get("deletedAt") is not None for i in items),
            "presets": len(toolbar["presets"]), "assets": len(emitted), "assetBytes": sum(emitted.values()),
            "sharedAssets": len(shared), "bytes": size, "crc32": reader.crc, "all_payload_checksums_valid": True}


def verify_v1(path, size):
    total_crc = 0
    with path.open("rb") as stream:
        def read(count):
            nonlocal total_crc
            data = stream.read(count)
            require(len(data) == count, "Truncated archive")
            total_crc = zlib.crc32(data, total_crc)
            return data

        require(size >= 12, "Wrong header")
        prefix = read(12)
        require(prefix[:8] == b"NOTYLIB\n", "Wrong header")
        length, = struct.unpack(">I", prefix[8:12])
        require(1 <= length <= MAXIMUM_HEADER and size - 12 >= length, "Wrong header length")
        # The manifest may be padded with trailing spaces (valid JSON whitespace).
        manifest = json.loads(read(length))
        require(manifest.get("libraryBackupVersion") == 1, "Unsupported archive version")
        require(manifest.get("checksumAlgorithm") == "crc32-iso-hdlc", "Unknown checksum algorithm")
        entries = manifest["entries"]
        require(2 <= len(entries) <= 10_002, "Wrong entry count")
        require(entries[0]["kind"] == "index" and entries[0].get("id") is None, "First entry must be the index")
        require(entries[1]["kind"] == "toolbar" and entries[1].get("id") is None, "Second entry must be the toolbar")
        ids = set()
        for position, entry in enumerate(entries):
            limit = MAXIMUM_INDEX if position == 0 else (MAXIMUM_TOOLBAR if position == 1 else MAXIMUM_NOTEBOOK)
            require(type(entry["byteCount"]) is int and 1 <= entry["byteCount"] <= limit, "Wrong payload length")
            if position >= 2:
                require(entry["kind"] == "notebook" and entry.get("id") is not None and entry["id"] not in ids, "Wrong notebook entry")
                ids.add(entry["id"])
        require(sum(e["byteCount"] for e in entries) == size - 12 - length, "Trailing or missing data")

        def chunk(entry):
            payload = read(entry["byteCount"])
            require(zlib.crc32(payload) == entry["crc32"], "Payload checksum mismatch")
            return json.loads(payload)

        items, lookup = verify_index(chunk(entries[0]))
        toolbar = chunk(entries[1])
        verify_toolbar(toolbar)
        expected = {i["id"] for i in items if i.get("source") is not None}
        require({e["id"] for e in entries[2:]} == expected, "Incomplete document set")
        for entry in entries[2:]:
            document = chunk(entry)
            require(entry["id"] == document["id"], "Notebook identity mismatch")
            require(not validate_notebook(document), "Format 1 cannot carry image assets")
            require(document["title"] == lookup[document["id"]]["title"], "Notebook title differs from index")
            del document
        require(stream.read(1) == b"", "Trailing data")
    return {"formatVersion": 1, "documents": len(expected), "folders": len(items) - len(expected),
            "explicitly_trashed": sum(i.get("deletedAt") is not None for i in items),
            "presets": len(toolbar["presets"]), "assets": 0, "assetBytes": 0, "sharedAssets": 0,
            "bytes": size, "crc32": total_crc, "all_payload_checksums_valid": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("archive", type=Path)
    arguments = parser.parse_args()
    try:
        print(json.dumps(verify(arguments.archive)))
    except Exception as error:  # noqa: BLE001 - any malformed input must fail closed
        # The type tells explicit checks (VerificationError/ValueError) from crashes.
        print("FEHLER: " + (str(error) or type(error).__name__) + " (" + type(error).__name__ + ")", file=sys.stderr)
        sys.exit(1)
