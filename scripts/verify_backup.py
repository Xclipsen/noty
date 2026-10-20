#!/usr/bin/env python3
"""Verify a notybackup independently, without extracting or printing note text."""
import argparse
import json
from pathlib import Path
import struct
import zlib
from notebook_format import check, strict, uuid_string, validate_notebook


@strict
def verify(path: Path) -> dict:
    with path.open("rb") as stream:
        prefix = stream.read(12)
        check(len(prefix) == 12 and prefix[:8] == b"NOTYBKP\n", "Invalid magic/header")
        length = struct.unpack(">I", prefix[8:])[0]
        check(1 <= length <= 64_000, "Header length outside limits")
        header = json.loads(stream.read(length))
        check(isinstance(header, dict), "Invalid header")
        check(header["backupFormatVersion"] == 1, "Unsupported backup version")
        check(header["payloadName"] == "notebook.json" and header["checksumAlgorithm"] == "crc32-iso-hdlc",
              "Unexpected payload path or algorithm")
        count = header["payloadByteCount"]
        check(type(count) is int and 1 <= count <= 200_000_000 - 12 - length, "Payload length outside limits")
        payload = stream.read(count)
        check(len(payload) == count and not stream.read(1), "Incomplete payload or trailing bytes")
        check(type(header["payloadCRC32"]) is int and zlib.crc32(payload) == header["payloadCRC32"], "Checksum mismatch")
        notebook = json.loads(payload)
        check(isinstance(notebook, dict) and type(header["notebookSchemaVersion"]) is int, "Invalid payload")
        check(uuid_string(notebook["id"]) == uuid_string(header["documentID"])
              and notebook["schemaVersion"] == header["notebookSchemaVersion"], "Manifest identity/schema mismatch")
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
        check(result["complete_contents_match"], "Complete contents do not match comparison revision")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
