#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the Dena.emu system image (``dena-system.squashfs``).

Single-card boot, docs/specs/single-card.md. The system image is the
read-only root file system the initramfs mounts from DENA-BOOT:

* base: Debian arm64 packages from ``rootfs/packages.txt``, extracted (not
  configured) by ``mmdebstrap --variant=extract`` into a tarball;
* ``rootfs/overlay``: busybox init, inittab and the Dena init scripts;
* ``/usr/lib/dena``: the boot hook and updater (os/scripts), device profiles,
  the card skeleton laid out on first boot, and the app payload
  (``os/payload.py`` output: bin/, lib/, data/) when given.

Usage: system.py --rootfs-tar base.tar --version V --out dena-system.squashfs
                 [--payload DIR] [--splash dena-splash] [--keep-staging DIR]
Needs tar and mksquashfs (Linux; run as root so ownership is kept).
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "os"))
import build_sd  # noqa: E402

# busybox-static provides the shell and the basic tools; these are linked in
# /usr/bin (merged /usr). Every command the overlay scripts run must be here
# or come from a package (tests/test_image.py checks the scripts).
BUSYBOX_APPLETS = [
    "sh", "ash", "init", "mount", "umount", "mkdir", "cat", "echo", "sleep", "poweroff",
    "reboot", "halt", "hostname", "ln", "cp", "mv", "rm", "ls", "grep", "sed", "tail",
    "head", "tee", "sync", "date", "dmesg", "ps", "kill", "killall", "free", "df", "du",
    "unzip", "sha256sum", "find", "vi", "less", "chmod", "chown", "touch", "uname",
    "wc", "sort", "uniq", "tr", "cut", "awk", "xargs", "env", "true", "false", "test",
    "[", "basename", "dirname", "readlink", "stat", "seq", "printf", "mknod", "losetup",
    "mountpoint", "pidof", "ip", "setsid", "nohup", "watch", "top", "hexdump", "md5sum", "dd", "od",
    "rmdir", "udhcpc", "ntpd", "rdate", "hwclock",
]
# Saved space: documentation and translations are never read on the handheld.
PRUNE = ["usr/share/doc", "usr/share/man", "usr/share/info", "usr/share/locale",
         "usr/share/lintian", "usr/share/bash-completion", "var/cache/apt", "var/lib/apt",
         "var/log"]
# Fixed time stamp so the same inputs give the same image.
EPOCH = 1767225600  # 2026-01-01

README = """Dena.emu
========

This card starts Dena.emu on its own: no stock firmware card is needed.

Put your own games in Roms/<system> (nes, snes, gb, gbc, gba, nds, n64, psx,
psp, pico8), PICO-8 carts in Carts, and BIOS files you dumped yourself in Bios.
Saves and States are written by Dena.emu.

The system lives on the small DENA-BOOT partition; leave it as it is. To
update the app, copy Dena-update-<version>.zip to the root of this partition
and restart: it is checked and applied at boot, and your settings in
Dena/user stay.

If something goes wrong, create an empty file named "diagnostic" in the
Dena folder and start the handheld again: it then writes its logs to
Dena/user (init.log, dmesg.log, boot.log). Delete the file to turn it off.

Dena.emu is free software under the GPL-3.0. No games or BIOS files are
included.
"""


def stage(root: Path, rootfs_tar: Path, version: str, payload: Path | None,
          splash: Path | None = None) -> None:
    """Fills root with the system image tree."""
    subprocess.run(["tar", "-xf", str(rootfs_tar), "-C", str(root), "--numeric-owner"], check=True)
    for p in PRUNE:
        shutil.rmtree(root / p, ignore_errors=True)
    merge_usr(root)
    for d in ("proc", "sys", "dev", "tmp", "run", "mnt/card", "root", "etc"):
        (root / d).mkdir(parents=True, exist_ok=True)
    link_busybox(root)
    shutil.copytree(HERE / "rootfs" / "overlay", root, dirs_exist_ok=True, symlinks=True)
    # Licences of the firmware built into the kernel (linux/firmware.txt).
    shutil.copytree(HERE / "linux" / "firmware-licences", root / "usr" / "share" / "licenses" / "firmware",
                    dirs_exist_ok=True)

    dena = root / "usr" / "lib" / "dena"
    (dena / "bin").mkdir(parents=True, exist_ok=True)
    for script in ("dena-boot.sh", "dena-update.sh"):
        lf_copy(ROOT / "os" / "scripts" / script, dena / "bin" / script)
    if splash:
        shutil.copyfile(splash, dena / "bin" / "dena-splash")
        (dena / "bin" / "dena-splash").chmod(0o755)
    for f in (dena / "system").iterdir():
        lf_copy(f, f)
    devices = dena / "devices"
    devices.mkdir(exist_ok=True)
    for conf in sorted((ROOT / "shells" / "linux" / "profiles").glob("*.conf")):
        shutil.copyfile(conf, devices / conf.name)
    if payload:
        for part in ("bin", "lib", "data"):
            if (payload / part).is_dir():
                shutil.copytree(payload / part, dena / part, dirs_exist_ok=True)
        for f in (dena / "bin").iterdir():
            f.chmod(0o755)
    card = dena / "card"
    build_sd.card_skeleton(card)
    (card / "Dena-README.txt").write_text(README, encoding="utf-8", newline="\n")
    (dena / "version.txt").write_text(version + "\n", encoding="utf-8", newline="\n")
    (root / "etc" / "dena-release").write_text(f"DENA_VERSION={version}\n", encoding="utf-8", newline="\n")
    # The packages were never configured, so libc-bin's ld.so.conf is missing.
    # No ld.so.cache is needed: Debian's loader searches the multiarch paths.
    (root / "etc" / "ld.so.conf").write_text("include /etc/ld.so.conf.d/*.conf\n", encoding="utf-8")


def merge_usr(root: Path) -> None:
    """/bin, /sbin, /lib as links into /usr, as on an installed system (the
    extract variant skips the step that sets them up; the ELF interpreter is
    /lib/ld-linux-aarch64.so.1)."""
    for d in ("bin", "sbin", "lib"):
        top, usr = root / d, root / "usr" / d
        usr.mkdir(parents=True, exist_ok=True)
        if top.is_symlink():
            continue
        if top.is_dir():
            for f in top.iterdir():
                if not (usr / f.name).exists() and not (usr / f.name).is_symlink():
                    f.rename(usr / f.name)
            shutil.rmtree(top)
        top.symlink_to(f"usr/{d}")


def link_busybox(root: Path) -> None:
    """Applet links in usr/bin, without replacing real tools from packages."""
    bb = root / "usr" / "bin" / "busybox"
    if not bb.exists():
        raise SystemExit("system.py: the base has no /usr/bin/busybox (busybox-static)")
    for applet in BUSYBOX_APPLETS:
        if any((root / d / applet).exists() or (root / d / applet).is_symlink()
               for d in ("usr/bin", "usr/sbin")):
            continue
        (root / "usr" / "bin" / applet).symlink_to("busybox")
    sbin_init = root / "usr" / "sbin" / "init"
    if not sbin_init.exists():
        sbin_init.parent.mkdir(parents=True, exist_ok=True)
        sbin_init.symlink_to("../bin/busybox")


def lf_copy(src: Path, dst: Path) -> None:
    """Scripts are LF-only (busybox sh) and executable."""
    dst.write_bytes(src.read_bytes().replace(b"\r\n", b"\n"))
    dst.chmod(0o755)


def squash(root: Path, out: Path) -> None:
    out.unlink(missing_ok=True)
    subprocess.run(["mksquashfs", str(root), str(out), "-comp", "zstd", "-noappend", "-quiet",
                    "-mkfs-time", str(EPOCH), "-all-time", str(EPOCH)], check=True)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rootfs-tar", type=Path, required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--payload", type=Path)
    ap.add_argument("--splash", type=Path, help="static dena-splash (os/image/splash)")
    ap.add_argument("--keep-staging", type=Path, help="stage here and keep it (for inspection)")
    args = ap.parse_args(argv)
    if args.keep_staging:
        shutil.rmtree(args.keep_staging, ignore_errors=True)
        args.keep_staging.mkdir(parents=True)
        root = args.keep_staging
    else:
        root = Path(tempfile.mkdtemp(prefix="dena-system-"))
    try:
        stage(root, args.rootfs_tar, args.version, args.payload, args.splash)
        squash(root, args.out)
    finally:
        if not args.keep_staging:
            shutil.rmtree(root, ignore_errors=True)
    print(f"wrote {args.out} ({args.out.stat().st_size // (1 << 20)} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
