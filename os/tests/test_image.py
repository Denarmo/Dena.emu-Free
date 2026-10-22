# SPDX-License-Identifier: GPL-3.0-or-later
"""Single-card image tools: panel firmware, initramfs, system image staging
and the card image layout. Spec: docs/specs/single-card.md

The full build (kernel, U-Boot, packages) and the QEMU boot test run with
``os/image/build.sh --test`` on a Linux host; these tests cover the parts
that can be checked anywhere, with synthetic inputs."""
from __future__ import annotations

import gzip
import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

IMAGE = Path(__file__).resolve().parent.parent / "image"
sys.path.insert(0, str(IMAGE))
sys.path.insert(0, str(IMAGE / "linux" / "panels"))
import assemble  # noqa: E402
import initramfs  # noqa: E402
import panelgen  # noqa: E402
import system  # noqa: E402

SH = shutil.which("sh")
HAVE_FAT_TOOLS = shutil.which("mkfs.vfat") and shutil.which("mcopy") and shutil.which("mtype")
SCRIPTS = [IMAGE / "initramfs" / "init", *sorted((IMAGE / "rootfs" / "overlay" / "usr" / "lib" / "dena" / "system").iterdir())]
# Tools the overlay scripts may run besides busybox applets (from packages.txt).
PACKAGE_TOOLS = {"sfdisk", "partx", "mkfs.exfat", "wpa_supplicant"}
# Functions the system scripts share (rootfs/.../system/dena-lib.sh).
LIB_FUNCTIONS = {"log", "splash", "splash_now", "save_diag", "diag", "cmdline_diag"}
CC = shutil.which("cc") or shutil.which("gcc")
SHELL_WORDS = {"if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case",
               "esac", "exit", "exec", "set", "export", "local", "return", "shift", "read",
               "cd", "trap", ".", "log", "fail", "blank", "break", "continue", "[", "]"}


def fake_spl(size: int = 32 * 1024) -> bytes:
    """An image with a valid eGON header, as U-Boot's mksunxiboot writes it."""
    body = bytearray(size)
    body[4:12] = assemble.EGON_MAGIC
    struct.pack_into("<I", body, 12, 0x5F0A6C39)
    struct.pack_into("<I", body, 16, size)
    body[64:] = bytes(i % 251 for i in range(size - 64))
    checksum = sum(struct.unpack_from(f"<{size // 4}I", body)) & 0xFFFFFFFF
    struct.pack_into("<I", body, 12, checksum)
    return bytes(body)


def commands(script: Path) -> set[str]:
    """The first word of each simple command in a shell script (good enough
    for our scripts: no functions named like tools, no aliases). The
    script's own functions are not tools."""
    found = set()
    text = script.read_text()
    functions = set(re.findall(r"^\s*([a-z_][a-z0-9_]*)\(\)", text, re.M))
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        line = re.sub(r"'[^']*'", "''", line)  # sed programs and the like
        line = re.sub(r'"(?:[^"$]|\$(?!\())*"', '""', line)  # strings without $(...)
        line = re.sub(r"\$\(\(\s*\w+\s*[-+*/]\s*\w+\s*\)\)", "0", line)  # $((i + 1))
        line = line.replace("$((", " ").replace("))", " ")  # arithmetic
        line = re.sub(r"^\s*[^\s()]+\)", "", line)  # case patterns
        line = re.sub(r"\s#.*", "", line)
        for part in re.split(r"[|;&]+|\$\(|\(|\)|`|\bthen\b|\bdo\b|\belse\b", line):
            words = part.strip().split()
            while words and (words[0] in ("exec", "if", "elif", "while", "until", "!") or ("=" in words[0] and not words[0].startswith("="))):
                words = words[1:]  # keywords and VAR=value prefixes
            if not words:
                continue
            w = words[0].strip("\"'{}")
            if re.fullmatch(r"[a-z][a-z0-9_.-]*|\[", w) and w not in SHELL_WORDS:
                found.add(w)
    return found - functions


class PanelTest(unittest.TestCase):
    def test_sources_round_trip(self):
        for src in sorted((IMAGE / "linux" / "panels").glob("*.json")):
            panel = json.loads(src.read_text())
            blob = panelgen.encode(panel)
            self.assertTrue(blob.startswith(b"PANEL-FIRMWARE\x00\x01"), src.name)
            again = panelgen.decode(blob)
            self.assertEqual(again["timings"], panel["timings"], src.name)
            self.assertEqual(again["init"], panel["init"], src.name)

    def test_encoding(self):
        self.assertEqual(panelgen.encode_init(["11", "sleep 130", "b1 01 2c 2d", "29"]),
                         b"\x01\x11\x80\x00\x00\x00\x04\xb1\x01\x2c\x2d\x01\x29")
        with self.assertRaises(ValueError):
            panelgen.encode_init(["sleep 15"])
        with self.assertRaises(ValueError):
            panelgen.encode_init([" ".join(["00"] * 128)])

    def test_kernel_config_embeds_every_panel(self):
        config = (IMAGE / "linux" / "dena-h700.config").read_text()
        embedded = re.search(r'CONFIG_EXTRA_FIRMWARE="([^"]*)"', config).group(1).split()
        names = {f"panels/{json.loads(p.read_text())['compatible']}.panel"
                 for p in (IMAGE / "linux" / "panels").glob("*.json")}
        self.assertLessEqual(names, set(embedded))

    def test_kernel_config_embeds_wifi_firmware(self):
        config = (IMAGE / "linux" / "dena-h700.config").read_text()
        embedded = set(re.search(r'CONFIG_EXTRA_FIRMWARE="([^"]*)"', config).group(1).split())
        pinned = {line.split()[0] for line in (IMAGE / "linux" / "firmware.txt").read_text().splitlines()
                  if line.strip() and not line.startswith("#")}
        self.assertLessEqual(pinned, embedded)
        self.assertLessEqual({"regulatory.db", "regulatory.db.p7s"}, embedded)
        panels = {e for e in embedded if e.startswith("panels/")}
        self.assertEqual(embedded, panels | pinned | {"regulatory.db", "regulatory.db.p7s"})
        for line in (IMAGE / "linux" / "firmware.txt").read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                path, url, sha = line.split()
                self.assertTrue(url.startswith("https://") and url.endswith("/" + path), line)
                self.assertRegex(sha, r"^[0-9a-f]{64}$")

    def test_kernel_config_wifi_and_usb(self):
        config = (IMAGE / "linux" / "dena-h700.config").read_text().splitlines()
        for want in ("CONFIG_RTW88_8821CS=y", "CONFIG_USB_CONFIGFS_MASS_STORAGE=y",
                     "# CONFIG_RESET_GPIO is not set", "# CONFIG_USB_MASS_STORAGE is not set"):
            self.assertIn(want, config)


class InitramfsTest(unittest.TestCase):
    def test_archive(self):
        archive = initramfs.build(b"\x7fELF-busybox", b"#!/bin/sh\r\necho hi\r\n")
        entries = {}
        off = 0
        while True:
            self.assertEqual(archive[off:off + 6], b"070701")
            f = [int(archive[off + 6 + 8 * i:off + 14 + 8 * i], 16) for i in range(13)]
            mode, size, namesize = f[1], f[6], f[11]
            name = archive[off + 110:off + 110 + namesize - 1].decode()
            off += 110 + namesize
            off += -off % 4
            data = archive[off:off + size]
            off += size
            off += -off % 4
            if name == "TRAILER!!!":
                break
            entries[name] = (mode, data)
        self.assertEqual(entries["init"], (0o100755, b"#!/bin/sh\necho hi\n"))
        self.assertEqual(entries["bin/busybox"][1], b"\x7fELF-busybox")
        self.assertEqual(entries["bin/sh"], (0o120777, b"busybox"))
        self.assertEqual(entries["dev/console"][0], 0o020600)

    def test_reproducible(self):
        a = gzip.compress(initramfs.build(b"x", b"y"), 9, mtime=0)
        b = gzip.compress(initramfs.build(b"x", b"y"), 9, mtime=0)
        self.assertEqual(a, b)

    def test_init_uses_only_packed_applets(self):
        used = commands(IMAGE / "initramfs" / "init")
        self.assertTrue({"mount", "switch_root", "findfs"} <= used)
        self.assertLessEqual(used, set(initramfs.APPLETS))


class ScriptTest(unittest.TestCase):
    @unittest.skipUnless(SH, "no sh")
    def test_syntax(self):
        for script in SCRIPTS:
            r = subprocess.run([SH, "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, f"{script.name}: {r.stderr}")

    def test_lf_only(self):
        for script in [*SCRIPTS, IMAGE / "build.sh", IMAGE / "qemu-test.sh"]:
            self.assertNotIn(b"\r\n", script.read_bytes(), script.name)

    def test_system_scripts_use_known_tools(self):
        allowed = set(system.BUSYBOX_APPLETS) | PACKAGE_TOOLS
        lib = SCRIPTS[0].parent.parent / "rootfs" / "overlay" / "usr" / "lib" / "dena" / "system" / "dena-lib.sh"
        defined = set(re.findall(r"^([a-z_]+)\(\)", lib.read_text(), re.M))
        self.assertEqual(defined, LIB_FUNCTIONS)
        for script in SCRIPTS[1:]:
            self.assertLessEqual(commands(script) - {"sh"} - LIB_FUNCTIONS, allowed, script.name)

    def test_tools_come_from_listed_packages(self):
        pkgs = (IMAGE / "rootfs" / "packages.txt").read_text().split()
        for pkg in ("busybox-static", "fdisk", "util-linux", "exfatprogs", "wpasupplicant",
                    "wireless-regdb"):
            self.assertIn(pkg, pkgs)


def _can_symlink() -> bool:
    """Windows needs Developer Mode or admin rights for symlinks."""
    probe = Path(tempfile.mkdtemp(prefix="dena_link"))
    try:
        (probe / "l").symlink_to("t")
        return True
    except OSError:
        return False
    finally:
        shutil.rmtree(probe, True)


class MergeUsrTest(unittest.TestCase):
    @unittest.skipUnless(_can_symlink(), "symlinks need privileges on this host")
    def test_links_and_moves(self):
        root = Path(tempfile.mkdtemp(prefix="dena_usr"))
        self.addCleanup(shutil.rmtree, root, True)
        (root / "bin").mkdir()
        (root / "bin" / "static-sh").write_text("x")
        (root / "usr" / "lib").mkdir(parents=True)
        system.merge_usr(root)
        for d in ("bin", "sbin", "lib"):
            self.assertTrue((root / d).is_symlink(), d)
            self.assertEqual(str((root / d).readlink()), f"usr/{d}")
        self.assertTrue((root / "usr" / "bin" / "static-sh").exists())


@unittest.skipUnless(CC, "needs a C compiler")
class SplashTest(unittest.TestCase):
    """dena-splash renders into a raw XRGB8888 file with --size."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="dena_splash"))
        cls.bin = cls.tmp / "dena-splash"
        subprocess.run([CC, "-O2", "-Wall", "-Werror", "-o", str(cls.bin),
                        str(IMAGE / "splash" / "dena-splash.c"), "-lm"], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def render(self, *cmd: str, size=(640, 480)) -> list[int]:
        out = self.tmp / "fb.raw"
        r = subprocess.run([str(self.bin), "--fb", str(out), "--size", f"{size[0]}x{size[1]}", *cmd],
                           capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = out.read_bytes()
        self.assertEqual(len(data), size[0] * size[1] * 4)
        return list(struct.unpack(f"<{size[0] * size[1]}I", data))

    def test_logo(self):
        px = self.render("logo")
        self.assertEqual(px[0] & 0xFFFFFF, 0x202024)  # Dark Anthracite
        colours = {p & 0xFFFFFF for p in px}
        self.assertIn(0xF1C40F, colours)  # the gold dot
        self.assertIn(0xF5F6F7, colours)  # the D

    def test_progress(self):
        px = self.render("progress", "50", "PREPARING YOUR CARD")
        row = [p & 0xFFFFFF for p in px[int(480 * 0.8) * 640:int(480 * 0.8) * 640 + 640]]
        gold, track = row.count(0xF1C40F), row.count(0x3A3A41)
        self.assertEqual(gold + track, 320)  # half the width
        self.assertEqual(gold, 160)
        self.assertIn(0xC9CAD0, {p & 0xFFFFFF for p in px})  # the text

    def test_square_panel_and_unknown(self):
        self.render("message", "SHUTTING DOWN", size=(720, 720))
        r = subprocess.run([str(self.bin), "--fb", str(self.tmp / "x"), "--size", "8x8", "nope"],
                           capture_output=True)
        self.assertEqual(r.returncode, 2)

    def test_daemon_follows_state_and_quits(self):
        state = self.tmp / "state"
        state.write_text("quit\n")
        r = subprocess.run([str(self.bin), "--fb", str(self.tmp / "none"), "--daemon", str(state),
                            "--wait", "1"], capture_output=True, timeout=10)
        self.assertEqual(r.returncode, 0)
        state.write_text("logo\n")
        r = subprocess.run([str(self.bin), "--fb", str(self.tmp / "none"), "--daemon", str(state),
                            "--wait", "0.2"], capture_output=True, timeout=10)
        self.assertEqual(r.returncode, 0)  # no framebuffer: gives up quietly
        self.assertIn(b"no framebuffer", r.stderr)


class SplTest(unittest.TestCase):
    def test_valid(self):
        assemble.check_spl(fake_spl())

    def test_rejects(self):
        spl = bytearray(fake_spl())
        spl[100] ^= 1
        with self.assertRaisesRegex(ValueError, "checksum"):
            assemble.check_spl(bytes(spl))
        with self.assertRaisesRegex(ValueError, "eGON"):
            assemble.check_spl(b"\0" * 64)
        with self.assertRaisesRegex(ValueError, "fit"):
            assemble.check_spl(fake_spl(16 * 1024 * 1024))


class ImageTest(unittest.TestCase):
    def test_mbr(self):
        m = assemble.mbr(0x12345678, 32768, 1048576)
        self.assertEqual(len(m), 512)
        self.assertEqual(m[510:], b"\x55\xaa")
        self.assertEqual(struct.unpack_from("<I", m, 440)[0], 0x12345678)
        boot, ptype, start, size = m[446], m[450], *struct.unpack_from("<II", m, 454)
        self.assertEqual((boot, ptype, start, size), (0x80, 0x0C, 32768, 1048576))
        self.assertEqual(m[462:510], bytes(48))  # partition 2 is made on first boot

    def test_extlinux(self):
        text = assemble.extlinux("x.dtb", assemble.CMDLINE)
        self.assertIn("FDT /dtbs/allwinner/x.dtb", text)
        self.assertIn("INITRD /initramfs.cpio.gz", text)
        self.assertIn("dena.boot=LABEL=DENA-BOOT", text)

    def test_cmdlines(self):
        release = assemble.CMDLINE.split()
        for flag in ("quiet", "logo.nologo", "vt.global_cursor_default=0", "console=ttyS0,115200"):
            self.assertIn(flag, release)
        self.assertNotIn("console=tty1", release)  # no kernel text on the panel
        self.assertNotIn("dena.diag", release)
        diag = assemble.DIAG_CMDLINE.split()
        self.assertIn("dena.diag", diag)
        self.assertNotIn("quiet", diag)
        # /dev/console stays the serial port (the last console= wins).
        self.assertEqual([a for a in diag if a.startswith("console=")][-1], "console=ttyS0,115200")

    @unittest.skipUnless(HAVE_FAT_TOOLS, "needs dosfstools and mtools")
    def test_card_image(self):
        tmp = Path(tempfile.mkdtemp(prefix="dena_img"))
        self.addCleanup(shutil.rmtree, tmp, True)
        spl = fake_spl()
        files = {"u-boot.bin": spl, "Image": b"kernel" * 1000, "initramfs.cpio.gz": b"initrd",
                 "sys.squashfs": b"hsqs" + bytes(1000), "a.dtb": b"\xd0\x0d\xfe\xed",
                 "b.dtb": b"\xd0\x0d\xfe\xee"}
        for name, data in files.items():
            (tmp / name).write_bytes(data)
        out = tmp / "card.img"
        assemble.assemble(out, tmp / "u-boot.bin", tmp / "Image", tmp / "initramfs.cpio.gz",
                          tmp / "sys.squashfs", [tmp / "a.dtb", tmp / "b.dtb"], "b.dtb",
                          "1.2.3", 64, assemble.CMDLINE)
        img = out.read_bytes()
        self.assertEqual(len(img), 16 * assemble.MIB + 64 * assemble.MIB)
        self.assertEqual(img[8192:8192 + len(spl)], spl)
        self.assertEqual(img[510:512], b"\x55\xaa")
        fat = img[16 * assemble.MIB:]
        self.assertEqual(fat[71:82], b"DENA-BOOT  ")  # FAT32 volume label
        part = f"{out}@@16M"

        def mtype(name: str) -> bytes:
            return subprocess.run(["mtype", "-i", part, f"::/{name}"], capture_output=True,
                                  check=True).stdout
        self.assertEqual(mtype("Image"), files["Image"])
        self.assertEqual(mtype(assemble.SYSTEM_NAME), files["sys.squashfs"])
        self.assertEqual(mtype("dtbs/allwinner/a.dtb"), files["a.dtb"])
        self.assertEqual(mtype("VERSION"), b"1.2.3\n")
        self.assertIn(b"FDT /dtbs/allwinner/b.dtb", mtype("extlinux/extlinux.conf"))
        # Same inputs, same image.
        again = tmp / "again.img"
        assemble.assemble(again, tmp / "u-boot.bin", tmp / "Image", tmp / "initramfs.cpio.gz",
                          tmp / "sys.squashfs", [tmp / "a.dtb", tmp / "b.dtb"], "b.dtb",
                          "1.2.3", 64, assemble.CMDLINE)
        self.assertEqual(again.read_bytes(), img)

    def test_unknown_fdt(self):
        with self.assertRaisesRegex(ValueError, "--fdt"):
            tmp = Path(tempfile.mkdtemp(prefix="dena_img"))
            self.addCleanup(shutil.rmtree, tmp, True)
            (tmp / "u").write_bytes(fake_spl())
            assemble.assemble(tmp / "o.img", tmp / "u", tmp / "u", tmp / "u", tmp / "u",
                              [tmp / "a.dtb"], "b.dtb", "1", 64, "")


if __name__ == "__main__":
    unittest.main()
