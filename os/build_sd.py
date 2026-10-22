#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the Dena.emu SD-card payload for Linux handhelds.

Spec: docs/specs/sd-card.md. Two outputs from one tree:

* ``Dena-<version>.zip``: unpack onto a card that already carries the stock
  firmware. It adds the fixed folders and ``Dena/`` (nothing of the vendor's
  is touched or redistributed).
* ``Dena-update-<version>.zip``: ``Dena/`` plus ``manifest.sha256``; copied to
  the card root, the boot hook applies it (update by file replacement).

Usage: python os/build_sd.py --version 1.0.1 --out dist [--payload DIR]
``--payload`` holds what the cross build produced (``bin/``, ``lib/``,
``data/``); without it the card gets scripts, profiles and layout only.
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Card folders (sd-card.md, Layout). Roms/<id> uses the app's system ids.
SYSTEMS = ["nes", "snes", "gb", "gbc", "gba", "nds", "n64", "psx", "psp", "pico8"]
TOP_FOLDERS = ["Bios", "Saves", "States", "Carts"]

README = """Dena.emu
========

Put your own games in Roms/<system> (nes, snes, gb, gbc, gba, nds, n64, psx,
psp, pico8), PICO-8 carts in Carts, and BIOS files you dumped yourself in Bios.
Saves and States are written by Dena.emu.

Dena/ holds the launcher. To update, copy Dena-update-<version>.zip to the
root of this card and restart: it is checked and applied at boot, and your
settings in Dena/user stay.

Without this card the handheld starts its own system as before.
Dena.emu is free software under the GPL-3.0. No games or BIOS files are
included.
"""


def card_skeleton(card: Path) -> None:
    """The fixed user folders (sd-card.md, Layout), shared with the single-card
    system image (os/image/system.py), which lays them out on first boot."""
    for s in SYSTEMS:
        keep(card / "Roms" / s)
    for f in TOP_FOLDERS:
        keep(card / f)
    keep(card / "Dena" / "user" / "devices")


def build_tree(out: Path, version: str, payload: Path | None) -> Path:
    """Writes the card tree to out/card and returns it."""
    card = out / "card"
    if card.exists():
        shutil.rmtree(card)
    card_skeleton(card)
    dena = card / "Dena"
    (dena / "bin").mkdir()
    for script in ("dena-boot.sh", "dena-update.sh"):
        dst = dena / "bin" / script
        # LF only: busybox sh can't run CRLF scripts.
        dst.write_bytes((ROOT / "os" / "scripts" / script).read_bytes().replace(b"\r\n", b"\n"))
    devices = dena / "devices"
    devices.mkdir()
    for conf in sorted((ROOT / "shells" / "linux" / "profiles").glob("*.conf")):
        shutil.copyfile(conf, devices / conf.name)
    if payload:
        for part in ("bin", "lib", "data"):
            src = payload / part
            if src.is_dir():
                shutil.copytree(src, dena / part, dirs_exist_ok=True)
    (dena / "version.txt").write_text(version + "\n", encoding="utf-8", newline="\n")
    (card / "Dena-README.txt").write_text(README, encoding="utf-8", newline="\n")
    return card


def keep(folder: Path) -> None:
    """Creates an empty folder that survives zipping."""
    folder.mkdir(parents=True, exist_ok=True)
    (folder / ".keep").write_bytes(b"")


def zip_tree(src: Path, dest: Path, prefix: str = "") -> None:
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(p for p in src.rglob("*") if p.is_file()):
            info = zipfile.ZipInfo(prefix + f.relative_to(src).as_posix(), (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            # Scripts and binaries keep their execute bit.
            executable = f.parent.name == "bin"
            info.external_attr = (0o755 if executable else 0o644) << 16
            z.writestr(info, f.read_bytes())


def build_update(card: Path, dest: Path) -> None:
    """Dena/ without user/, plus manifest.sha256 over every file."""
    lines = []
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(p for p in (card / "Dena").rglob("*") if p.is_file()):
            rel = f.relative_to(card).as_posix()
            if rel.startswith("Dena/user/"):
                continue
            data = f.read_bytes()
            lines.append(f"{hashlib.sha256(data).hexdigest()}  {rel}\n")
            info = zipfile.ZipInfo(rel, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if f.parent.name == "bin" else 0o644) << 16
            z.writestr(info, data)
        z.writestr(zipfile.ZipInfo("manifest.sha256", (2026, 1, 1, 0, 0, 0)), "".join(lines))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", type=Path, default=ROOT / "os" / "dist")
    ap.add_argument("--payload", type=Path)
    args = ap.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    card = build_tree(args.out, args.version, args.payload)
    full = args.out / f"Dena-{args.version}.zip"
    update = args.out / f"Dena-update-{args.version}.zip"
    zip_tree(card, full)
    build_update(card, update)
    print(f"wrote {full}\nwrote {update}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
