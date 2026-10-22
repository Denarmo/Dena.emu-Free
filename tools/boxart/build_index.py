#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds app/assets/boxart/index.tsv.gz from libretro-database (CC-BY-SA-4.0).

Spec: docs/specs/box-art.md. For each system, reads the No-Intro (cartridges) or Redump (discs) DAT at a pinned
commit and writes one line per ROM: system, CRC-32 (lower-case hex), game name,
and the disc serial when the DAT has one (Redump; e.g. ULUS-10489).
The game name is what the libretro thumbnail server files covers under.

Usage: python tools/boxart/build_index.py [out.tsv.gz]
"""
from __future__ import annotations

import gzip
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

COMMIT = "12c21cf79f1e20eff6ac68b80875816c717d0a7a"
BASE = f"https://raw.githubusercontent.com/libretro/libretro-database/{COMMIT}/metadat/"

# Our system id -> (DAT set, DAT name). The DAT name is also the thumbnail
# server's folder name. Disc systems use Redump DATs: their CRCs are of the
# .bin track / .iso, so a .chd or .cso only matches by name (box-art.md).
SYSTEMS = {
    "nes": ("no-intro", "Nintendo - Nintendo Entertainment System"),
    "snes": ("no-intro", "Nintendo - Super Nintendo Entertainment System"),
    "gb": ("no-intro", "Nintendo - Game Boy"),
    "gbc": ("no-intro", "Nintendo - Game Boy Color"),
    "gba": ("no-intro", "Nintendo - Game Boy Advance"),
    "nds": ("no-intro", "Nintendo - Nintendo DS"),
    "n64": ("no-intro", "Nintendo - Nintendo 64"),
    "genesis": ("no-intro", "Sega - Mega Drive - Genesis"),
    "psx": ("redump", "Sony - PlayStation"),
    "psp": ("redump", "Sony - PlayStation Portable"),
    "saturn": ("redump", "Sega - Saturn"),
    "dreamcast": ("redump", "Sega - Dreamcast"),
    "gamecube": ("redump", "Nintendo - GameCube"),
    "wii": ("redump", "Nintendo - Wii"),
    "ps2": ("redump", "Sony - PlayStation 2"),
}

GAME = re.compile(r'^game \(\s*\n\s*name "((?:[^"\\]|\\.)*)"(.*?)^\)', re.M | re.S)
CRC = re.compile(r"\bcrc ([0-9A-Fa-f]{8})\b")
SERIAL = re.compile(r'^\s*serial "([^"]+)"', re.M)


def parse(dat: str) -> list[tuple[str, str, str]]:
    out = []
    for m in GAME.finditer(dat):
        name = m.group(1)
        serial = SERIAL.search(m.group(2))
        # Some Redump entries list several serials ("SLUS-00001, SLUS-00002").
        serial = serial.group(1).split(",")[0].strip().upper() if serial else ""
        for crc in CRC.findall(m.group(2)):
            out.append((crc.lower(), name, serial))
    return out


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parents[2] / "app" / "assets" / "boxart" / "index.tsv.gz")
    lines = []
    for system, (dat_set, dat_name) in SYSTEMS.items():
        url = BASE + dat_set + "/" + urllib.parse.quote(dat_name + ".dat")
        with urllib.request.urlopen(url) as r:
            dat = r.read().decode("utf-8")
        rows = parse(dat)
        if not rows:
            raise SystemExit(f"no games parsed from {dat_name}")
        seen = set()
        for crc, name, serial in rows:
            if crc in seen:
                continue
            seen.add(crc)
            extra = f"\t{serial}" if serial else ""
            lines.append(f"{system}\t{crc}\t{name}{extra}\n")
        print(f"{system}: {len(seen)} ROMs")
    out.parent.mkdir(parents=True, exist_ok=True)
    # mtime=0 keeps the output byte-identical between runs.
    with open(out, "wb") as f, gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as g:
        g.write("".join(lines).encode("utf-8"))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
