#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Packs the Dena.emu initramfs (single-card boot, docs/specs/single-card.md).

The initramfs is a static busybox plus ``os/image/initramfs/init``: it finds
the DENA-BOOT partition, mounts the system image from it and switches to it.
Written as a gzip'd ``newc`` cpio archive directly (no cpio tool needed, and
the output is byte-for-byte reproducible: fixed owners, modes and times).

Usage: initramfs.py --busybox <static aarch64 busybox> --out initramfs.cpio.gz
"""
from __future__ import annotations

import argparse
import gzip
import io
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Applets the init script uses (tests/test_image.py checks the script against it).
APPLETS = [
    "sh", "mount", "umount", "mkdir", "cat", "echo", "sleep", "findfs", "poweroff",
    "switch_root", "ls", "dmesg",
]

S_IFDIR, S_IFREG, S_IFLNK, S_IFCHR = 0o040000, 0o100000, 0o120000, 0o020000


class Cpio:
    """Minimal newc writer."""

    def __init__(self) -> None:
        self.buf = io.BytesIO()
        self.ino = 1

    def add(self, name: str, mode: int, data: bytes = b"", rdev: tuple[int, int] = (0, 0)) -> None:
        nlink = 2 if mode & 0o170000 == S_IFDIR else 1
        fields = [self.ino, mode, 0, 0, nlink, 0, len(data), 0, 0, rdev[0], rdev[1], len(name) + 1, 0]
        self.ino += 1
        self.buf.write(b"070701" + b"".join(b"%08X" % f for f in fields))
        self.buf.write(name.encode() + b"\0")
        self._pad()
        self.buf.write(data)
        self._pad()

    def _pad(self) -> None:
        self.buf.write(b"\0" * (-self.buf.tell() % 4))

    def finish(self) -> bytes:
        self.add("TRAILER!!!", 0)
        self.buf.write(b"\0" * (-self.buf.tell() % 512))
        return self.buf.getvalue()


def build(busybox: bytes, init: bytes) -> bytes:
    """The uncompressed cpio archive."""
    c = Cpio()
    for d in ("bin", "dev", "proc", "sys", "boot", "lower", "upper", "newroot", "run"):
        c.add(d, S_IFDIR | 0o755)
    # The kernel opens /dev/console before init runs; devtmpfs replaces /dev later.
    c.add("dev/console", S_IFCHR | 0o600, rdev=(5, 1))
    c.add("bin/busybox", S_IFREG | 0o755, busybox)
    for applet in APPLETS:
        c.add(f"bin/{applet}", S_IFLNK | 0o777, b"busybox")
    c.add("init", S_IFREG | 0o755, init.replace(b"\r\n", b"\n"))
    return c.finish()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--busybox", type=Path, required=True)
    ap.add_argument("--init", type=Path, default=HERE / "initramfs" / "init")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args(argv)
    archive = build(args.busybox.read_bytes(), args.init.read_bytes())
    args.out.write_bytes(gzip.compress(archive, 9, mtime=0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
