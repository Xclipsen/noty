#!/usr/bin/env python3
"""Independently verify a .notylibrary archive, without extracting paths/text."""
import argparse
import base64
import json
import struct
import zlib
from pathlib import Path
from uuid import UUID
from notebook_format import validate_notebook


def verify(path):
    with path.open("rb") as stream:
        data = stream.read(200_000_001)
    assert len(data) <= 200_000_000, "Archive exceeds size limit"
    assert data[:8] == b"NOTYLIB\n" and len(data) >= 12, "Wrong header"
    length, = struct.unpack(">I", data[8:12])
    assert 1 <= length <= 2_000_000 and len(data) >= length + 12, "Wrong header length"
    manifest = json.loads(data[12:12 + length])
    assert manifest["libraryBackupVersion"] == 1 and manifest["checksumAlgorithm"] == "crc32-iso-hdlc"
    entries = manifest["entries"]
    assert 2 <= len(entries) <= 10_002
    offset = 12 + length
    chunks = []
    for entry in entries:
        count = entry["byteCount"]
        assert 1 <= count <= len(data) - offset, "Wrong payload length"
        payload = data[offset:offset + count]
        assert zlib.crc32(payload) == entry["crc32"], "Payload checksum mismatch"
        chunks.append(json.loads(payload))
        offset += count
    assert offset == len(data), "Trailing data"
    assert entries[0]["kind"] == "index" and entries[0].get("id") is None
    assert entries[1]["kind"] == "toolbar" and entries[1].get("id") is None
    index, toolbar = chunks[:2]
    assert index["formatVersion"] == 1 and toolbar["formatVersion"] in (1, 2, 3, 4, 5, 6, 7)
    tools = {"pen", "marker", "strokeEraser", "precisionEraser", "inkSelection", "text", "read"}
    if toolbar["formatVersion"] >= 2:
        tools.add("image")
    if toolbar["formatVersion"] >= 3:
        tools.update(("shape", "selection"))
    assert len(toolbar["order"]) == len(tools) and set(toolbar["order"]) == tools
    assert toolbar["dock"] in (("top", "bottom", "left", "right", "floating") if toolbar["formatVersion"] >= 4 else ("top", "left", "right", "floating"))
    for key in ("autoPen", "pencilPreview", "paging", "eraserPrecision"):
        assert toolbar.get(key) is None or (toolbar["formatVersion"] >= 4 and type(toolbar[key]) is bool)
    assert toolbar.get("floatingAxis") is None or (toolbar["formatVersion"] >= 5 and toolbar["floatingAxis"] in ("horizontal", "vertical"))
    assert toolbar.get("dockOnly") is None or (toolbar["formatVersion"] >= 6 and type(toolbar["dockOnly"]) is bool)
    assert toolbar.get("normalizePageWidths") is None or (toolbar["formatVersion"] >= 7 and type(toolbar["normalizePageWidths"]) is bool)
    items = index["items"]
    assert len(items) <= 10_000 and len({i["id"] for i in items}) == len(items)
    lookup = {i["id"]: i for i in items}
    for item in items:
        UUID(item["id"])
        seen = {item["id"]}
        parent = item.get("parentID")
        while parent is not None:
            assert parent not in seen and parent in lookup and lookup[parent].get("source") is None, "Invalid parent/cycle"
            seen.add(parent)
            parent = lookup[parent].get("parentID")
    expected = {i["id"] for i in items if i.get("source") is not None}
    found = set()
    for entry, document in zip(entries[2:], chunks[2:]):
        assert entry["kind"] == "notebook" and entry["id"] == document["id"]
        assert document["id"] not in found and document["id"] in expected
        found.add(document["id"])
        validate_notebook(document)
        assert document["title"] == lookup[document["id"]]["title"]
    assert expected == found, "Incomplete document set"
    return {"documents": len(found), "folders": len(items) - len(found),
            "explicitly_trashed": sum(i.get("deletedAt") is not None for i in items),
            "presets": len(toolbar["presets"]), "all_payload_checksums_valid": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.archive)))
