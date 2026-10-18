#!/usr/bin/env python3
"""Small deterministic RGBA fixture, no external dependencies or private image."""
import struct
import zlib
from pathlib import Path


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def create():
    width, height = 64, 48
    colors = [(240, 40, 20, 255), (20, 100, 240, 255), (40, 200, 60, 255), (250, 200, 30, 80)]
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(colors[(2 if y >= height // 2 else 0) + (1 if x >= width // 2 else 0)])
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b"")
    target = Path(__file__).resolve().parent.parent / "fixtures" / "Bildobjekt.png"
    target.write_bytes(png)


if __name__ == "__main__":
    create()
