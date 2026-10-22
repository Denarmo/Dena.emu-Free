#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds app/assets/cheats/index.tsv.gz from libretro-database (CC-BY-SA-4.0).

Spec: docs/specs/cheats.md. Reads the repository tree at a pinned commit and
writes one line per cheat file the cht/ folder holds: system, file name (without
the .cht extension). The app matches games against these names and downloads
the files themselves on demand.

Usage: python tools/cheats/build_index.py [out.tsv.gz]
"""
from __future__ import annotations

import gzip
import json
import os
import sys
import urllib.request
from pathlib import Path

COMMIT = "12c21cf79f1e20eff6ac68b80875816c717d0a7a"
TREE = f"https://api.github.com/repos/libretro/libretro-database/git/trees/{COMMIT}?recursive=1"

# Our system id -> the cht/ folder name holding that system's cheats.
SYSTEMS = {
    "nes": "Nintendo - Nintendo Entertainment System",
    "snes": "Nintendo - Super Nintendo Entertainment System",
    "gb": "Nintendo - Game Boy",
    "gbc": "Nintendo - Game Boy Color",
    "gba": "Nintendo - Game Boy Advance",
    "n64": "Nintendo - Nintendo 64",
    "nds": "Nintendo - Nintendo DS",
    "psx": "Sony - PlayStation",
    "psp": "Sony - PlayStation Portable",
}


def fetch_tree() -> dict:
    req = urllib.request.Request(TREE)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "dena-emu-build")
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parents[2] / "app" / "assets" / "cheats" / "index.tsv.gz")

    tree = fetch_tree()
    if tree.get("truncated"):
        raise SystemExit("GitHub tree listing was truncated; cannot build a complete index")

    prefixes = {f"cht/{folder}/": system for system, folder in SYSTEMS.items()}
    names: dict[str, list[str]] = {system: [] for system in SYSTEMS}
    for entry in tree.get("tree", []):
        if entry.get("type") != "blob":
            continue
        path = entry.get("path", "")
        for prefix, system in prefixes.items():
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix):]
            # Only files directly in the folder: no deeper subfolders.
            if "/" in rest or not rest.endswith(".cht"):
                break
            name = rest[: -len(".cht")]
            if not name or "\t" in name or "\n" in name:
                break
            names[system].append(name)
            break

    lines = []
    for system in SYSTEMS:
        files = sorted(names[system])
        if not files:
            raise SystemExit(f"no cheat files found for {system}")
        lines.extend(f"{system}\t{name}\n" for name in files)
        print(f"{system}: {len(files)} files")

    out.parent.mkdir(parents=True, exist_ok=True)
    # mtime=0 keeps the output byte-identical between runs.
    with open(out, "wb") as f, gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as g:
        g.write("".join(lines).encode("utf-8"))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
