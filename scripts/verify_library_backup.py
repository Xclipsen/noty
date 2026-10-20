#!/usr/bin/env python3
"""Independently verify a .notylibrary archive, without extracting paths/text.

Reads the archive chunk by chunk (one notebook in memory at a time) and checks
the same limits as noty: archive <= 4 GB, notebook chunk <= 200 MB, manifest
<= 2 MB, index <= 4 MB, preferences <= 64 KB. Exit code 1 on any violation.
"""
import argparse
import json
import struct
import sys
import zlib
from pathlib import Path
from uuid import UUID
from notebook_format import appearance, validate_notebook

MAXIMUM_BYTES = 4_000_000_000
MAXIMUM_NOTEBOOK = 200_000_000
MAXIMUM_HEADER = 2_000_000
MAXIMUM_INDEX = 4_000_000
MAXIMUM_TOOLBAR = 64_000


class VerificationError(Exception):
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


def verify(path):
    require(path.is_file() and not path.is_symlink(), "Not a regular file")
    size = path.stat().st_size
    require(size <= MAXIMUM_BYTES, "Archive exceeds size limit")
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
            validate_notebook(document)
            require(document["title"] == lookup[document["id"]]["title"], "Notebook title differs from index")
            del document
        require(stream.read(1) == b"", "Trailing data")
    return {"documents": len(expected), "folders": len(items) - len(expected),
            "explicitly_trashed": sum(i.get("deletedAt") is not None for i in items),
            "presets": len(toolbar["presets"]), "bytes": size, "crc32": total_crc,
            "all_payload_checksums_valid": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("archive", type=Path)
    arguments = parser.parse_args()
    try:
        print(json.dumps(verify(arguments.archive)))
    except Exception as error:  # noqa: BLE001 - any malformed input must fail closed
        print("FEHLER: " + (str(error) or type(error).__name__), file=sys.stderr)
        sys.exit(1)
