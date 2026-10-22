#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks a PNG from dena_frame_write_png against a PPM of the same frame.

Verifies the signature, every chunk CRC, the zlib stream (Adler-32 included)
and that the RGB pixels match. Spec: docs/specs/save-states.md
Usage: check_png.py <file.png> <file.ppm>
"""
import struct
import sys
import zlib


def main() -> int:
    png = open(sys.argv[1], "rb").read()
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "bad signature"
    pos, chunks = 8, {}
    while pos < len(png):
        (n,) = struct.unpack(">I", png[pos : pos + 4])
        kind = png[pos + 4 : pos + 8]
        data = png[pos + 8 : pos + 8 + n]
        (crc,) = struct.unpack(">I", png[pos + 8 + n : pos + 12 + n])
        assert zlib.crc32(kind + data) == crc, f"bad CRC in {kind!r}"
        chunks.setdefault(kind, b"")
        chunks[kind] += data
        pos += 12 + n
    assert b"IEND" in chunks, "no IEND"
    w, h, depth, colour, _, _, _ = struct.unpack(">IIBBBBB", chunks[b"IHDR"])
    assert (depth, colour) == (8, 2), "not 8-bit RGB"
    raw = zlib.decompress(chunks[b"IDAT"])  # checks Adler-32
    row = 1 + 3 * w
    assert len(raw) == row * h, "wrong image size"
    pixels = b"".join(raw[y * row + 1 : (y + 1) * row] for y in range(h))
    assert all(raw[y * row] == 0 for y in range(h)), "unexpected filter"

    ppm = open(sys.argv[2], "rb").read()
    header, body = ppm.split(b"\n255\n", 1)
    pw, ph = map(int, header.split()[1:3])
    assert (pw, ph) == (w, h), "size differs from PPM"
    assert body == pixels, "pixels differ from PPM"
    print(f"png ok: {w}x{h}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
