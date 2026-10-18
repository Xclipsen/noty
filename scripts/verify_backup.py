#!/usr/bin/env python3
"""Verify a notybackup independently, without extracting or printing note text."""
import argparse
import base64
import json
from pathlib import Path
import struct
import zlib
from notebook_format import validate_notebook


def verify(path: Path) -> dict:
    with path.open("rb") as stream:
        prefix = stream.read(12)
        if len(prefix) != 12 or prefix[:8] != b"NOTYBKP\n":
            raise ValueError("Invalid magic/header")
        length = struct.unpack(">I", prefix[8:])[0]
        if not 1 <= length <= 64_000:
            raise ValueError("Header length outside limits")
        header = json.loads(stream.read(length))
        if header["backupFormatVersion"] != 1:
            raise ValueError("Unsupported backup version")
        if header["payloadName"] != "notebook.json" or header["checksumAlgorithm"] != "crc32-iso-hdlc":
            raise ValueError("Unexpected payload path or algorithm")
        count = header["payloadByteCount"]
        if type(count) is not int or not 1 <= count <= 200_000_000 - 12 - length:
            raise ValueError("Payload length outside limits")
        payload = stream.read(count)
        if len(payload) != count or stream.read(1):
            raise ValueError("Incomplete payload or trailing bytes")
        if zlib.crc32(payload) != header["payloadCRC32"]:
            raise ValueError("Checksum mismatch")
        notebook = json.loads(payload)
        if notebook["id"] != header["documentID"] or notebook["schemaVersion"] != header["notebookSchemaVersion"]:
            raise ValueError("Manifest identity/schema mismatch")
        validate_notebook(notebook)
        return notebook


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--compare", type=Path, help="Compare complete decoded contents with a Notebook JSON revision")
    args = parser.parse_args()
    notebook = verify(args.archive)
    result = {"valid": True, "schemaVersion": notebook["schemaVersion"], "pageCount": len(notebook["pages"])}
    if args.compare:
        result["complete_contents_match"] = notebook == json.loads(args.compare.read_bytes())
        if not result["complete_contents_match"]:
            raise ValueError("Complete contents do not match comparison revision")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
