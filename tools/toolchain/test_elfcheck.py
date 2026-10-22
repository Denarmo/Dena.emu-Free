#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for elfcheck.py (synthetic ELF images, no toolchain needed)."""

import contextlib
import io
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import elfcheck  # noqa: E402  (path set up just above)

PT_INTERP = 3
SHT_PROGBITS = 1
SHT_STRTAB = 3
SHT_DYNAMIC = 6
SHT_GNU_VERNEED = 0x6FFFFFFE
DT_NULL = 0
DT_NEEDED = 1


def build_elf(machine=183, interp=elfcheck.AARCH64_INTERP, needed=(),
              glibc=(), verneed=True, magic=b"\x7fELF", elf_class=2,
              elf_data=1):
    """Assemble a tiny but valid 64-bit little-endian ELF image."""
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


class ReadElfTests(unittest.TestCase):
    def test_parses_fields(self):
        data = build_elf(needed=["libc.so.6", "libm.so.6"],
                         glibc=["2.17", "2.28"])
        info = elfcheck.read_elf(data)
        self.assertEqual(info["machine"], 183)
        self.assertEqual(info["interpreter"], elfcheck.AARCH64_INTERP)
        self.assertEqual(info["needed"], ["libc.so.6", "libm.so.6"])
        self.assertEqual(info["glibc_versions"], ["2.17", "2.28"])

    def test_glibc_versions_sorted_and_unique(self):
        data = build_elf(glibc=["2.28", "2.17", "2.28", "2.3"])
        self.assertEqual(elfcheck.read_elf(data)["glibc_versions"],
                         ["2.3", "2.17", "2.28"])

    def test_non_numeric_version_skipped(self):
        data = build_elf(glibc=["PRIVATE", "2.17"])
        self.assertEqual(elfcheck.read_elf(data)["glibc_versions"], ["2.17"])

    def test_static_has_no_interpreter(self):
        data = build_elf(interp=None, verneed=False)
        info = elfcheck.read_elf(data)
        self.assertIsNone(info["interpreter"])
        self.assertEqual(info["glibc_versions"], [])
        self.assertEqual(info["needed"], [])

    def test_bad_magic_raises(self):
        with self.assertRaises(ValueError):
            elfcheck.read_elf(build_elf(magic=b"\x00ELF"))

    def test_32bit_raises(self):
        with self.assertRaises(ValueError):
            elfcheck.read_elf(build_elf(elf_class=1))

    def test_big_endian_raises(self):
        with self.assertRaises(ValueError):
            elfcheck.read_elf(build_elf(elf_data=2))


class CheckTests(unittest.TestCase):
    def test_good_binary_passes(self):
        data = build_elf(needed=["libc.so.6"], glibc=["2.17", "2.28"])
        self.assertEqual(elfcheck.check(data), [])

    def test_static_binary_passes(self):
        self.assertEqual(elfcheck.check(build_elf(interp=None,
                                                  verneed=False)), [])

    def test_wrong_machine_reported(self):
        problems = elfcheck.check(build_elf(machine=62))
        self.assertTrue(any("62" in p for p in problems), problems)

    def test_wrong_interpreter_reported(self):
        problems = elfcheck.check(
            build_elf(interp="/lib/ld-linux-x86-64.so.2"))
        self.assertTrue(any("interpreter" in p for p in problems), problems)

    def test_missing_interpreter_is_fine(self):
        self.assertEqual(elfcheck.check(build_elf(interp=None)), [])

    def test_new_glibc_reported_old_versions_pass(self):
        data = build_elf(glibc=["2.17", "2.28", "2.34"])
        problems = elfcheck.check(data, "2.28")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("2.34", problems[0])

    def test_newer_version_numeric_compare(self):
        data = build_elf(glibc=["2.9"])
        self.assertEqual(elfcheck.check(data, "2.28"), [])


class MainTests(unittest.TestCase):
    def _write(self, directory, name, data):
        path = os.path.join(directory, name)
        with open(path, "wb") as handle:
            handle.write(data)
        return path

    def test_main_ok_and_bad(self):
        good = build_elf(glibc=["2.17"])
        bad = build_elf(machine=62)
        with tempfile.TemporaryDirectory() as tmp:
            good_path = self._write(tmp, "good", good)
            bad_path = self._write(tmp, "bad", bad)
            missing = os.path.join(tmp, "missing")

            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc_good = elfcheck.main([good_path])
            self.assertEqual(rc_good, 0)
            self.assertIn("OK", out.getvalue())

            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc_bad = elfcheck.main([bad_path, missing])
            self.assertEqual(rc_bad, 1)
            self.assertIn(bad_path + ":", out.getvalue())
            self.assertIn(missing + ":", out.getvalue())


if __name__ == '__main__':
    unittest.main()
