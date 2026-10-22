#!/usr/bin/env python3
"""Verify a noty notebook file independently, without extracting or printing note text.

The same format is written as `.noty` (since 22.10.2026) and `.notybackup`
(older builds); the file extension is not checked.

Format 1: magic + header + one notebook JSON (<= 200 MB). Format 2: record
stream (record_archive.py) with exactly one notebook, then exactly its unique
image assets (SHA-256 checked in 1 MB blocks), then the end record; file
<= 800 MB. The prototype's plain notebook JSON is not a notybackup.
"""
import argparse
import json
from pathlib import Path
import struct
import zlib
from notebook_format import check, strict, uuid_string, validate_notebook
from record_archive import MAXIMUM_HEADER, RecordReader, check_date, check_references

MAGIC = b"NOTYBKP\n"
NOTEBOOK_LIMIT = 200_000_000
FILE_LIMIT = 800_000_000
HEADER_KEYS = {"backupFormatVersion", "checksumAlgorithm", "assetHashAlgorithm", "documentID",
               "notebookSchemaVersion", "createdAt"}


def check_identity(notebook, header):
    check(isinstance(notebook, dict) and type(header["notebookSchemaVersion"]) is int, "Invalid payload")
    check(uuid_string(notebook["id"]) == uuid_string(header["documentID"])
          and notebook["schemaVersion"] == header["notebookSchemaVersion"], "Manifest identity/schema mismatch")


def verify_v1(stream, header, length):
    check(header["payloadName"] == "notebook.json" and header["checksumAlgorithm"] == "crc32-iso-hdlc",
          "Unexpected payload path or algorithm")
    count = header["payloadByteCount"]
    check(type(count) is int and 1 <= count <= NOTEBOOK_LIMIT - 12 - length, "Payload length outside limits")
    payload = stream.read(count)
    check(len(payload) == count and not stream.read(1), "Incomplete payload or trailing bytes")
    check(type(header["payloadCRC32"]) is int and zlib.crc32(payload) == header["payloadCRC32"], "Checksum mismatch")
    notebook = json.loads(payload)
    check_identity(notebook, header)
    # Format 1 has no asset records: only notebooks that embed their originals.
    check(not validate_notebook(notebook), "Format 1 cannot carry image assets")
    return notebook, {"formatVersion": 1, "assets": 0, "assetBytes": 0}


def verify_v2(path, size):
    check(size <= FILE_LIMIT, "Backup file exceeds 800 MB")
    with path.open("rb") as stream:
        reader = RecordReader(stream, size)
        header = reader.header(MAGIC, MAXIMUM_HEADER)
        check(set(header) == HEADER_KEYS, "Unexpected header fields")
        check(header["backupFormatVersion"] == 2 and header["checksumAlgorithm"] == "crc32-iso-hdlc"
              and header["assetHashAlgorithm"] == "sha256", "Unexpected format or algorithm")
        check_date(header["createdAt"])
        first = reader.descriptor()
        check(first["kind"] == "notebook" and first["id"] == uuid_string(header["documentID"]),
              "First record must be the notebook of the header")
        notebook = json.loads(reader.payload(first, NOTEBOOK_LIMIT))
        check_identity(notebook, header)
        references = check_references(validate_notebook(notebook))
        seen = set()
        while True:
            record = reader.descriptor()
            if record["kind"] == "end":
                reader.end(record)
                break
            check(record["kind"] == "asset", "Only assets may follow the notebook")
            check(references.get(record["sha256"]) == record["byteCount"], "Asset not referenced by the notebook")
            check(record["sha256"] not in seen, "Duplicate asset")
            seen.add(record["sha256"])
            reader.asset(record)
        check(seen == set(references), "Referenced asset missing")
        return notebook, {"formatVersion": 2, "assets": len(seen), "assetBytes": sum(references.values())}


@strict
def verify(path: Path):
    size = path.stat().st_size
    with path.open("rb") as stream:
        prefix = stream.read(12)
        check(len(prefix) == 12 and prefix[:8] == MAGIC, "Invalid magic/header")
        length = struct.unpack(">I", prefix[8:])[0]
        check(1 <= length <= 64_000, "Header length outside limits")
        header = json.loads(stream.read(length))
        check(isinstance(header, dict), "Invalid header")
        version = header["backupFormatVersion"]
        check(version in (1, 2) and type(version) is int, "Unsupported backup version")
        if version == 1:
            check(size <= NOTEBOOK_LIMIT, "Backup exceeds 200 MB")
            return verify_v1(stream, header, length)
    return verify_v2(path, size)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--compare", type=Path, help="Compare complete decoded contents with a Notebook JSON revision")
    args = parser.parse_args()
    notebook, info = verify(args.archive)
    result = {"valid": True, "formatVersion": info["formatVersion"], "schemaVersion": notebook["schemaVersion"],
              "pageCount": len(notebook["pages"]), "assets": info["assets"], "assetBytes": info["assetBytes"]}
    if args.compare:
        result["complete_contents_match"] = notebook == json.loads(args.compare.read_bytes())
        check(result["complete_contents_match"], "Complete contents do not match comparison revision")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
