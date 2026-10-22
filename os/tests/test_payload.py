# SPDX-License-Identifier: GPL-3.0-or-later
"""Payload assembler for the SD-card build. Spec: docs/specs/sd-card.md"""
from __future__ import annotations

import os
import shutil
import stat
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import payload  # noqa: E402

PT_INTERP = 3
SHT_PROGBITS = 1
SHT_STRTAB = 3
SHT_DYNAMIC = 6
SHT_GNU_VERNEED = 0x6FFFFFFE
DT_NULL = 0
DT_NEEDED = 1
AARCH64_INTERP = "/lib/ld-linux-aarch64.so.1"

# Writes a copy of its last argument, minus 16 trailing bytes, so the
# before/after sizes in assemble() differ. Stands in for llvm-strip.
FAKE_STRIP = """\
import pathlib
import sys

path = pathlib.Path(sys.argv[-1])
path.write_bytes(path.read_bytes()[:-16])
"""


def build_elf(machine=183, interp=AARCH64_INTERP, needed=(), glibc=(),
              verneed=True, magic=b"\x7fELF", elf_class=2, elf_data=1):
    """Assemble a tiny but valid 64-bit little-endian ELF image.

    Same construction as tools/toolchain/test_elfcheck.py (copied, not
    imported, so the two suites stay independent).
    """
    dynstr = bytearray(b"\0")

    def add_name(text):
        offset = len(dynstr)
        dynstr.extend(text.encode("latin-1") + b"\0")
        return offset

    dynamic = bytearray()
    for name in needed:
        dynamic.extend(struct.pack("<QQ", DT_NEEDED, add_name(name)))
    dynamic.extend(struct.pack("<QQ", DT_NULL, 0))

    verneed_data = bytearray()
    if verneed and glibc:
        verneed_data.extend(struct.pack("<HHIII", 1, len(glibc), 0, 16, 0))
        for i, version in enumerate(glibc):
            name = add_name("GLIBC_" + version)
            nxt = 16 if i < len(glibc) - 1 else 0
            verneed_data.extend(struct.pack("<IHHII", 0, 0, i + 2, name, nxt))

    sections = [{"name": "", "type": 0, "data": b"", "link": 0}]

    def add_section(name, sh_type, data, link=0):
        sections.append({"name": name, "type": sh_type,
                         "data": data, "link": link})
        return len(sections) - 1

    if interp is not None:
        add_section(".interp", SHT_PROGBITS, interp.encode("latin-1") + b"\0")
    dynstr_idx = add_section(".dynstr", SHT_STRTAB, bytes(dynstr))
    add_section(".dynamic", SHT_DYNAMIC, bytes(dynamic), dynstr_idx)
    if verneed:
        add_section(".gnu.version_r", SHT_GNU_VERNEED,
                    bytes(verneed_data), dynstr_idx)
    shstr_idx = add_section(".shstrtab", SHT_STRTAB, b"")

    shstr = bytearray(b"\0")
    for section in sections:
        if section["name"]:
            section["name_off"] = len(shstr)
            shstr.extend(section["name"].encode("latin-1") + b"\0")
        else:
            section["name_off"] = 0
    sections[shstr_idx]["data"] = bytes(shstr)

    phnum = 1 if interp is not None else 0
    offset = 64 + phnum * 56
    for section in sections:
        if section["data"]:
            offset = (offset + 7) & ~7
            section["offset"] = offset
            offset += len(section["data"])
        else:
            section["offset"] = offset
    shoff = (offset + 7) & ~7
    total = shoff + len(sections) * 64

    image = bytearray(total)
    ident = magic + bytes([elf_class, elf_data, 1, 0]) + bytes(8)
    struct.pack_into("<16sHHIQQQIHHHHHH", image, 0,
                     ident, 2, machine, 1, 0, 0 if not phnum else 64, shoff,
                     0, 64, 56, phnum, 64, len(sections), shstr_idx)

    if interp is not None:
        section = sections[1]
        struct.pack_into("<IIQQQQQQ", image, 64, PT_INTERP, 0,
                         section["offset"], 0, 0, len(section["data"]),
                         len(section["data"]), 1)

    for section in sections:
        if section["data"]:
            start = section["offset"]
            image[start:start + len(section["data"])] = section["data"]

    for i, section in enumerate(sections):
        struct.pack_into("<IIQQQQIIQQ", image, shoff + i * 64,
                         section["name_off"], section["type"], 0, 0,
                         section["offset"], len(section["data"]),
                         section["link"], 0, 1, 0)

    return bytes(image)


class PayloadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dena_payload"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = self.tmp / "out"
        script = self.tmp / "fake_strip.py"
        script.write_text(FAKE_STRIP)
        self.strip = [sys.executable, str(script)]
        self.elf = build_elf(needed=["libc.so.6"], glibc=["2.17"])
        self.root = self.make_repo()

    def make_repo(self):
        root = self.tmp / "repo"
        (root / payload.BIN_SRC).mkdir(parents=True)
        for name in payload.BIN_NAMES:
            (root / payload.BIN_SRC / name).write_bytes(self.elf)
        (root / payload.LIB_SRC).mkdir(parents=True)
        for name in ("mgba_libretro.so", "fceumm_libretro.so"):
            (root / payload.LIB_SRC / name).write_bytes(self.elf)
        return root

    def assemble(self, **kwargs):
        kwargs.setdefault("root", self.root)
        kwargs.setdefault("out", self.out)
        kwargs.setdefault("strip", self.strip)
        kwargs.setdefault("allow_missing", False)
        return payload.assemble(**kwargs)

    def test_files_land_in_bin_and_lib(self):
        self.assertEqual(self.assemble(), 0)
        self.assertEqual(sorted(p.name for p in (self.out / "bin").iterdir()),
                         sorted(payload.BIN_NAMES))
        self.assertEqual(sorted(p.name for p in (self.out / "lib").iterdir()),
                         ["fceumm_libretro.so", "mgba_libretro.so"])

    def test_debug_engine_and_app_bundle(self):
        engine = self.root / payload.ENGINE_DEBUG_SRC
        engine.parent.mkdir(parents=True)
        engine.write_bytes(self.elf)
        native = self.root / payload.NATIVE_SRC
        native.mkdir(parents=True)
        (native / "libsqlite3.so").write_bytes(self.elf)
        assets = self.root / payload.ASSETS_SRC
        (assets / "kernel_blob.bin").write_bytes(b"kernel")
        self.assertEqual(self.assemble(), 0)
        self.assertTrue((self.out / "lib" / "libflutter_engine.so").is_file())
        self.assertTrue((self.out / "lib" / "libsqlite3.so").is_file())
        app = self.out / "data" / "app" / "flutter_assets"
        self.assertEqual((app / "kernel_blob.bin").read_bytes(), b"kernel")
        self.assertFalse((app / "native_assets").exists())
        self.assertFalse((self.out / "data" / "app" / "lib").exists())

    def make_release(self, engine=True):
        if engine:
            src = self.root / payload.ENGINE_RELEASE_SRC
            src.parent.mkdir(parents=True)
            src.write_bytes(self.elf + b"release")
            (self.root / payload.ICU_RELEASE_SRC).write_bytes(b"icu")
        debug = self.root / payload.ENGINE_DEBUG_SRC
        debug.parent.mkdir(parents=True)
        debug.write_bytes(self.elf + b"debug")
        aot = self.root / payload.AOT_SRC
        aot.parent.mkdir(parents=True)
        aot.write_bytes(self.elf + b"aot")
        assets = self.root / payload.ASSETS_SRC
        assets.mkdir(parents=True, exist_ok=True)
        for name in payload.JIT_FILES:
            (assets / name).write_bytes(b"jit")
        (assets / "AssetManifest.bin").write_bytes(b"manifest")

    def test_release_bundle_takes_the_aot_app_and_release_engine(self):
        self.make_release()
        self.assertEqual(self.assemble(), 0)
        engine = (self.out / "lib" / "libflutter_engine.so").read_bytes()
        # Stripping cuts 16 bytes; the release engine's tail is still there.
        self.assertTrue((self.elf + b"release").startswith(engine))
        app = self.out / "data" / "app"
        self.assertEqual((app / "lib" / "libapp.so").read_bytes(), self.elf + b"aot")
        self.assertEqual((app / "icudtl.dat").read_bytes(), b"icu")
        self.assertTrue((app / "flutter_assets" / "AssetManifest.bin").is_file())
        for name in payload.JIT_FILES:
            self.assertFalse((app / "flutter_assets" / name).exists(), name)

    def test_release_app_without_release_engine_fails(self):
        self.make_release(engine=False)
        self.assertEqual(self.assemble(), 1)
        self.assertFalse(self.out.exists())

    def test_release_app_without_release_engine_allowed(self):
        self.make_release(engine=False)
        self.assertEqual(self.assemble(allow_missing=True), 0)
        self.assertFalse((self.out / "lib" / "libflutter_engine.so").exists())

    def test_shaders_are_copied_without_readme(self):
        src = self.root / payload.SHADERS_SRC
        (src / "crt-fast" / "shaders").mkdir(parents=True)
        (src / "crt-fast" / "crt-fast.glslp").write_text("shaders = 1\n")
        (src / "crt-fast" / "shaders" / "a.glsl").write_text("void main() {}\n")
        (src / "README.md").write_text("notes\n")
        self.assertEqual(self.assemble(), 0)
        data = self.out / "data" / "shaders"
        self.assertTrue((data / "crt-fast" / "crt-fast.glslp").is_file())
        self.assertTrue((data / "crt-fast" / "shaders" / "a.glsl").is_file())
        self.assertFalse((data / "README.md").exists())

    def test_strip_ran_on_every_file(self):
        self.assertEqual(self.assemble(), 0)
        expected = len(self.elf) - 16
        for path in self.out.rglob("*"):
            if path.is_file():
                self.assertEqual(path.stat().st_size, expected, path.name)

    def test_bin_files_are_executable(self):
        if os.name == "nt":
            self.skipTest("Windows has no POSIX execute bit")
        self.assertEqual(self.assemble(), 0)
        for name in payload.BIN_NAMES:
            mode = stat.S_IMODE((self.out / "bin" / name).stat().st_mode)
            self.assertTrue(mode & 0o111, "%s mode %o" % (name, mode))

    def test_non_elf_core_fails(self):
        (self.root / payload.LIB_SRC / "mgba_libretro.so").write_bytes(b"nope")
        self.assertEqual(self.assemble(), 1)

    def test_missing_launcher_fails(self):
        (self.root / payload.BIN_SRC / "dena-launcher").unlink()
        self.assertEqual(self.assemble(), 1)
        self.assertEqual(self.assemble(allow_missing=True), 0)
        self.assertFalse((self.out / "bin" / "dena-launcher").exists())
        self.assertTrue((self.out / "bin" / "dena-powerd").exists())

    def test_no_cores_fails(self):
        for core in (self.root / payload.LIB_SRC).glob("*_libretro.so"):
            core.unlink()
        self.assertEqual(self.assemble(), 1)
        self.assertEqual(self.assemble(allow_missing=True), 0)

    def test_strip_none_copies_unchanged(self):
        self.assertEqual(self.assemble(strip=None), 0)
        self.assertEqual((self.out / "bin" / "dena-launcher").stat().st_size,
                         len(self.elf))
        self.assertEqual((self.out / "lib" / "mgba_libretro.so").stat().st_size,
                         len(self.elf))

    def test_out_dir_is_emptied_of_stale_files(self):
        (self.out / "bin").mkdir(parents=True)
        stale = self.out / "bin" / "stale-file"
        stale.write_bytes(b"old")
        self.assertEqual(self.assemble(), 0)
        self.assertFalse(stale.exists())

    def test_main_wires_up_without_strip(self):
        out = self.tmp / "cli-out"
        with mock.patch.object(payload, "find_strip", return_value=None):
            rc = payload.main(["--out", str(out), "--root", str(self.root)])
        self.assertEqual(rc, 0)
        self.assertTrue((out / "bin" / "dena-launcher").exists())
        self.assertTrue((out / "lib" / "mgba_libretro.so").exists())

    def test_collect_relative_destinations(self):
        self.assertEqual(
            [(dest.as_posix()) for _src, dest in payload.collect(self.root)],
            ["bin/dena-launcher", "bin/dena-powerd", "bin/dena-keytest",
             "lib/fceumm_libretro.so", "lib/mgba_libretro.so"],
        )


if __name__ == "__main__":
    unittest.main()
