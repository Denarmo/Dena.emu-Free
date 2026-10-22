# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks the portable Linux glibc floor check (docs/dev/release-linux.md,
"Oldest supported system"): readelf parsing, and a real run on this
machine's binaries when readelf exists. Also checks the floor pins."""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE / "linux"))
import check_glibc_floor as floor  # noqa: E402

READELF = """
Version symbols section '.gnu.version' contains 4 entries:
 Addr: 0x0000000000000500  Offset: 0x000500  Link: 5 (.dynsym)
  000:   0 (*local*)       2 (GLIBC_2.99)    3 (GLIBCXX_3.4.99)

Version definition section '.gnu.version_d' contains 1 entry:
  000000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  Name: libx.so
  0x001c: Rev: 1  Flags: none  Index: 2  Cnt: 1  Name: GLIBC_2.50

Version needs section '.gnu.version_r' contains 2 entries:
 Addr: 0x0000000000000600  Offset: 0x000600  Link: 6 (.dynstr)
  000000: Version: 1  File: libstdc++.so.6  Cnt: 2
  0x0010:   Name: GLIBCXX_3.4.9  Flags: none  Version: 5
  0x0020:   Name: GLIBCXX_3.4.30  Flags: none  Version: 4
  0x0030: Version: 1  File: libc.so.6  Cnt: 3
  0x0040:   Name: GLIBC_2.2.5  Flags: none  Version: 3
  0x0050:   Name: GLIBC_2.34  Flags: none  Version: 2
  0x0060:   Name: GLIBC_2.4  Flags: none  Version: 6
"""


class ParseTest(unittest.TestCase):
    def test_highest_needed_only_from_needs_section(self):
        self.assertEqual(floor.needed_versions(READELF),
                         {"GLIBC": (2, 34), "GLIBCXX": (3, 4, 30)})

    def test_versions_compare_numerically(self):
        self.assertGreater(floor.parse_version("2.43"), floor.parse_version("2.5"))
        self.assertGreater(floor.parse_version("3.4.30"), floor.parse_version("3.4.9"))

    def test_no_needs_section(self):
        self.assertEqual(floor.needed_versions("nothing here"), {})


@unittest.skipUnless(shutil.which("readelf"), "no readelf")
class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(sys.executable, self.tmp / "elf")
        (self.tmp / "notes.txt").write_text("not an ELF file")

    def test_generous_floor_passes(self):
        self.assertEqual(floor.main(["--glibc", "99.0", "--glibcxx", "99.0", str(self.tmp)]), 0)

    def test_old_floor_fails(self):
        self.assertEqual(floor.main(["--glibc", "2.0", "--glibcxx", "3.4", str(self.tmp)]), 1)

    def test_no_elf_files_is_an_error(self):
        (self.tmp / "elf").unlink()
        self.assertEqual(floor.main(["--glibc", "2.35", "--glibcxx", "3.4.30", str(self.tmp)]), 2)


class PinsTest(unittest.TestCase):
    def test_runtime_file_states_the_portable_floor(self):
        pins = dict(line.split("=", 1) for line in
                    (ROOT / "cores" / "desktop-runtime.txt").read_text().splitlines()
                    if "=" in line and not line.startswith("#"))
        for key in ("portable_sdk", "portable_llvm", "portable_glibc", "portable_glibcxx"):
            self.assertIn(key, pins)
        doc = (ROOT / "docs" / "dev" / "release-linux.md").read_text()
        self.assertIn(f"glibc {pins['portable_glibc']} or newer", doc)
        self.assertIn(f"GLIBCXX_{pins['portable_glibcxx']}", doc)
        self.assertIn(pins["portable_sdk"].split("/")[-1], doc)

    def test_build_script_runs_the_check(self):
        script = (HERE / "build-linux.sh").read_text()
        self.assertIn("check_glibc_floor.py", script)
        self.assertIn('--glibc "$portable_glibc"', script)


if __name__ == "__main__":
    unittest.main()
