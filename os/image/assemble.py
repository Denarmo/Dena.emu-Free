#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assembles the Dena.emu single-card SD image for the H700 handhelds.

Spec: docs/specs/single-card.md. Layout of the image (MBR):

  0          MBR (one partition; partition 2 is created on the first boot)
  8 KiB      u-boot-sunxi-with-spl.bin (SPL + TF-A BL31 + U-Boot), read by the
             SoC's boot ROM from this fixed offset
  16 MiB     partition 1: FAT32 "DENA-BOOT" with Image, initramfs, dtbs/,
             extlinux/extlinux.conf and dena-system.squashfs

Usage:
  assemble.py --uboot u-boot-sunxi-with-spl.bin --kernel Image
              --initramfs initramfs.cpio.gz --system dena-system.squashfs
              --dtb a.dtb [--dtb b.dtb ...] --fdt a.dtb --version V --out card.img
Needs mkfs.vfat (dosfstools) and mcopy (mtools).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

MIB = 1 << 20
SECTOR = 512
UBOOT_OFFSET = 8 * 1024
BOOT_START = 16 * MIB
BOOT_LABEL = "DENA-BOOT"
SYSTEM_NAME = "dena-system.squashfs"
DTB_DIR = "dtbs/allwinner"
# Kernel command line. Release: the kernel and init talk only to the serial
# port (UART0 on the handhelds' test pads, the rig's console), quietly; the
# panel shows nothing but the Dena splash (no text, no logo, no cursor).
CMDLINE = (f"console=ttyS0,115200 quiet loglevel=3 logo.nologo vt.global_cursor_default=0 "
           f"consoleblank=0 dena.boot=LABEL={BOOT_LABEL}")
# Diagnostic (build.sh --diagnostic): kernel messages on the panel (tty1) too,
# no splash, logs on the card (dena.diag) and a shell instead of power off
# (dena.debug).
DIAG_CMDLINE = f"console=tty1 console=ttyS0,115200 loglevel=7 dena.diag dena.debug dena.boot=LABEL={BOOT_LABEL}"
PART_FAT32_LBA = 0x0C
EGON_MAGIC = b"eGON.BT0"
# File times on DENA-BOOT (mkfs.vfat and mtools honour it): same inputs, same image.
FAT_ENV = {**os.environ, "SOURCE_DATE_EPOCH": "1767225600"}  # 2026-01-01


def check_spl(uboot: bytes) -> None:
    """The boot ROM only runs an SPL with the eGON header and a valid checksum."""
    if uboot[4:12] != EGON_MAGIC:
        raise ValueError("not a sunxi SPL image (no eGON.BT0 header)")
    length = struct.unpack_from("<I", uboot, 16)[0]
    if length > len(uboot) or length % 4:
        raise ValueError("bad SPL length in the eGON header")
    stored = struct.unpack_from("<I", uboot, 12)[0]
    words = struct.unpack_from(f"<{length // 4}I", uboot[:12] + struct.pack("<I", 0x5F0A6C39) + uboot[16:length])
    if sum(words) & 0xFFFFFFFF != stored:
        raise ValueError("SPL checksum mismatch")
    if UBOOT_OFFSET + len(uboot) > BOOT_START:
        raise ValueError("U-Boot does not fit before the first partition")


def extlinux(fdt: str, cmdline: str) -> str:
    return f"""# Dena.emu boot entry (docs/specs/single-card.md).
# FDT picks the device tree for your model, see {DTB_DIR}/: for example an
# RG35XX SP with a black screen may have the newer panel, then use
# sun50i-h700-anbernic-rg35xx-sp-v2-panel.dtb. Diagnostics: an empty file
# Dena/diagnostic on the games partition writes logs to Dena/user; adding
# dena.diag to APPEND also shows kernel messages instead of the splash, and
# dena.debug keeps a shell on the serial console instead of powering off.
DEFAULT dena
LABEL dena
  KERNEL /Image
  INITRD /initramfs.cpio.gz
  FDT /{DTB_DIR}/{fdt}
  APPEND {cmdline}
"""


def mbr(disk_id: int, start: int, sectors: int) -> bytes:
    """A DOS partition table with one bootable FAT32 (LBA) partition."""
    entry = struct.pack("<B3sB3sII", 0x80, b"\xfe\xff\xff", PART_FAT32_LBA, b"\xfe\xff\xff",
                        start, sectors)
    out = bytearray(SECTOR)
    struct.pack_into("<I", out, 440, disk_id)
    out[446:462] = entry
    out[510:512] = b"\x55\xaa"
    return bytes(out)


def make_fat(path: Path, size: int, volume_id: str, files: dict[str, Path | bytes]) -> None:
    """FAT32 file system image with the given files (name -> source)."""
    with open(path, "wb") as f:
        f.truncate(size)
    subprocess.run(["mkfs.vfat", "--invariant", "-F", "32", "-n", BOOT_LABEL, "-i", volume_id,
                    "-S", "512", "-s", "8", str(path)], check=True, stdout=subprocess.DEVNULL, env=FAT_ENV)
    with tempfile.TemporaryDirectory(prefix="dena-fat-") as tmp:
        dirs = sorted({str(Path(n).parent) for n in files} - {"."}, key=len)
        for d in dirs:
            parts = Path(d).parts
            for i in range(1, len(parts) + 1):
                sub = "/".join(parts[:i])
                subprocess.run(["mmd", "-i", str(path), f"::/{sub}"],
                               stderr=subprocess.DEVNULL, check=False, env=FAT_ENV)
        for name, src in sorted(files.items()):
            if isinstance(src, bytes):
                tmpfile = Path(tmp) / Path(name).name
                tmpfile.write_bytes(src)
                src = tmpfile
            subprocess.run(["mcopy", "-o", "-i", str(path), str(src), f"::/{name}"], check=True, env=FAT_ENV)


def assemble(out: Path, uboot: Path, kernel: Path, initramfs: Path, system: Path,
             dtbs: list[Path], fdt: str, version: str, boot_mib: int, cmdline: str) -> None:
    spl = uboot.read_bytes()
    check_spl(spl)
    names = {d.name for d in dtbs}
    if fdt not in names:
        raise ValueError(f"--fdt {fdt} is not one of the --dtb files")
    files: dict[str, Path | bytes] = {
        "Image": kernel,
        "initramfs.cpio.gz": initramfs,
        SYSTEM_NAME: system,
        "extlinux/extlinux.conf": extlinux(fdt, cmdline).encode(),
        "VERSION": f"{version}\n".encode(),
    }
    for d in dtbs:
        files[f"{DTB_DIR}/{d.name}"] = d
    payload = sum(len(v) if isinstance(v, bytes) else v.stat().st_size for v in files.values())
    size = boot_mib * MIB
    if payload > size * 0.45:
        # Room for a second system image during an update (spec, Updates).
        raise ValueError(f"boot files ({payload // MIB} MiB) need a bigger --boot-mib")
    seed = hashlib.sha256(version.encode() + spl).digest()
    volume_id = seed[:4].hex().upper()
    disk_id = struct.unpack("<I", seed[4:8])[0]
    with tempfile.TemporaryDirectory(prefix="dena-img-") as tmp:
        fat = Path(tmp) / "boot.fat"
        make_fat(fat, size, volume_id, files)
        with open(out, "wb") as img:
            img.write(mbr(disk_id, BOOT_START // SECTOR, size // SECTOR))
            img.seek(UBOOT_OFFSET)
            img.write(spl)
            img.seek(BOOT_START)
            with open(fat, "rb") as src:
                shutil.copyfileobj(src, img, 4 * MIB)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--uboot", type=Path, required=True)
    ap.add_argument("--kernel", type=Path, required=True)
    ap.add_argument("--initramfs", type=Path, required=True)
    ap.add_argument("--system", type=Path, required=True)
    ap.add_argument("--dtb", type=Path, action="append", required=True)
    ap.add_argument("--fdt", required=True, help="file name of the default device tree")
    ap.add_argument("--version", required=True)
    ap.add_argument("--boot-mib", type=int, default=512)
    ap.add_argument("--cmdline", default=CMDLINE)
    ap.add_argument("--diagnostic", action="store_true", help="use the diagnostic command line")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args(argv)
    try:
        assemble(args.out, args.uboot, args.kernel, args.initramfs, args.system, args.dtb,
                 args.fdt, args.version, args.boot_mib,
                 DIAG_CMDLINE if args.diagnostic else args.cmdline)
    except ValueError as e:
        print(f"assemble.py: {e}", file=sys.stderr)
        return 1
    print(f"wrote {args.out} ({args.out.stat().st_size // MIB} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
