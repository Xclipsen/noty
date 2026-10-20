#!/usr/bin/env python3
"""Read-only CRC/identity audit of an AFC copy. Never prints note contents."""
import argparse
import base64
import json
import re
import zlib
from pathlib import Path
from uuid import UUID
from notebook_format import validate_notebook


def load_store(root):
    directories = [root]
    for relative in ("Restores", "Library/Documents"):
        parent = root / relative
        if parent.exists():
            directories.extend(p for p in parent.iterdir() if p.is_dir() and re.fullmatch(r"[0-9A-F-]{36}", p.name))
    documents = {}
    revisions = 0
    for directory in directories:
        if not (directory / "manifest.json").exists():
            if directory == root:
                continue
            raise ValueError("Missing document manifest")
        manifest = json.loads((directory / "manifest.json").read_bytes())
        assert manifest["formatVersion"] == 1 and manifest["checksumAlgorithm"] == "crc32-iso-hdlc"
        assert 1 <= len(manifest["revisions"]) <= 8
        head = None
        for record in manifest["revisions"]:
            assert re.fullmatch(r"[0-9A-F-]{36}\.json", record["file"])
            file = directory / "Revisions" / record["file"]
            assert not file.is_symlink() and file.resolve().is_relative_to(root.resolve())
            payload = file.read_bytes()
            assert len(payload) == record["byteCount"] and zlib.crc32(payload) == record["crc32"]
            document = json.loads(payload)
            validate_notebook(document)
            if head is None:
                head = document
            revisions += 1
        assert head["id"] not in documents
        if directory != root:
            assert head["id"] == directory.name
        documents[head["id"]] = head
    return documents, revisions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()
    documents, revisions = load_store(args.root)
    result = {"documents": len(documents), "checked_revisions": revisions}
    if args.compare:
        previous, _ = load_store(args.compare)
        assert previous.keys() <= documents.keys(), "A previous document is missing"
        assert all(documents[key] == value for key, value in previous.items()), "A previous document changed"
        result["previous_documents_unchanged"] = len(previous)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
