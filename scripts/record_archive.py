"""Archive format 2 record stream, shared by verify_backup.py and
verify_library_backup.py. Independent of the Swift code: zlib CRC-32,
hashlib SHA-256, explicit checks raising ValueError (also under python -O).

    magic (8) | uint32 BE header length | header JSON (<= 64 KB)
    { uint32 BE descriptor length | descriptor JSON (<= 4 KB) | payload }*
    end descriptor {"kind": "end", "records", "payloadBytes"}, then end of file

Data records (index, toolbar, notebook) carry byteCount and the CRC-32 of
their payload; an asset record carries sha256 and byteCount, and its payload
must hash to exactly that name. Payloads are never written anywhere.
"""
import hashlib
import json
import re
import struct
import zlib

from notebook_format import check, uuid_string

MAXIMUM_HEADER = 64_000
MAXIMUM_DESCRIPTOR = 4_096
ASSET_LIMIT = 20_000_000
HASH_PATTERN = re.compile(r"[0-9a-f]{64}")
DATE_PATTERN = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
BLOCK = 1024 * 1024
KEYS = {
    "index": {"kind", "byteCount", "crc32"},
    "toolbar": {"kind", "byteCount", "crc32"},
    "notebook": {"kind", "id", "byteCount", "crc32"},
    "asset": {"kind", "sha256", "byteCount"},
    "end": {"kind", "records", "payloadBytes"},
}


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def valid_asset(sha256, byte_count):
    return isinstance(sha256, str) and HASH_PATTERN.fullmatch(sha256) is not None and integer(byte_count, 1, ASSET_LIMIT)


def check_date(value):
    check(isinstance(value, str) and DATE_PATTERN.fullmatch(value) is not None, "Invalid createdAt")


class RecordReader:
    """Reads one archive front to back; every length is checked against the
    remaining file size before anything is read."""

    def __init__(self, stream, size):
        self.stream, self.size = stream, size
        self.consumed = 0
        self.crc = 0
        self.records = 0
        self.payload_bytes = 0

    @property
    def remaining(self):
        return self.size - self.consumed

    def read(self, count):
        check(0 <= count <= self.remaining, "Truncated archive or length beyond the file")
        data = self.stream.read(count)
        check(len(data) == count, "Truncated archive")
        self.crc = zlib.crc32(data, self.crc)
        self.consumed += count
        return data

    def header(self, magic, maximum):
        prefix = self.read(12)
        check(prefix[:8] == magic, "Invalid magic/header")
        length = struct.unpack(">I", prefix[8:])[0]
        check(1 <= length <= maximum, "Header length outside limits")
        raw = self.read(length)
        header = json.loads(raw)
        check(isinstance(header, dict), "Invalid header")
        return header

    def descriptor(self):
        length = struct.unpack(">I", self.read(4))[0]
        check(1 <= length <= MAXIMUM_DESCRIPTOR, "Descriptor length outside limits")
        value = json.loads(self.read(length))
        check(isinstance(value, dict) and value.get("kind") in KEYS, "Unknown record kind")
        check(set(value) == KEYS[value["kind"]], "Unexpected record fields")
        kind = value["kind"]
        if kind in ("index", "toolbar", "notebook"):
            check(integer(value["byteCount"], 1, self.size) and integer(value["crc32"], 0, 2**32 - 1), "Invalid data record")
            if kind == "notebook":
                value["id"] = uuid_string(value["id"])
        elif kind == "asset":
            check(valid_asset(value["sha256"], value["byteCount"]), "Invalid asset record")
        else:
            check(integer(value["records"], 0, 2**62) and integer(value["payloadBytes"], 0, 2**62), "Invalid end record")
        return value

    def payload(self, descriptor, limit):
        check(descriptor["byteCount"] <= limit, "Record exceeds its limit")
        data = self.read(descriptor["byteCount"])
        check(zlib.crc32(data) == descriptor["crc32"], "Payload checksum mismatch")
        self.records += 1
        self.payload_bytes += len(data)
        return data

    def asset(self, descriptor):
        """Streams the payload through SHA-256 in 1 MB blocks."""
        count = descriptor["byteCount"]
        check(count <= self.remaining, "Truncated asset")
        digest, left = hashlib.sha256(), count
        while left:
            block = self.read(min(BLOCK, left))
            digest.update(block)
            left -= len(block)
        check(digest.hexdigest() == descriptor["sha256"], "Asset SHA-256 mismatch")
        self.records += 1
        self.payload_bytes += count

    def end(self, descriptor):
        check(descriptor["kind"] == "end", "Missing end record")
        check(descriptor["records"] == self.records and descriptor["payloadBytes"] == self.payload_bytes,
              "End record totals do not match")
        check(self.remaining == 0 and self.stream.read(1) == b"", "Trailing data after the end record")


def check_references(references):
    """{sha256: byteCount} from validate_notebook, each a valid asset reference."""
    check(isinstance(references, dict), "Invalid asset references")
    for sha256, byte_count in references.items():
        check(valid_asset(sha256, byte_count), "Invalid asset reference")
    return references
