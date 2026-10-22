# SPDX-License-Identifier: GPL-3.0-or-later
"""Release engine fetch (flutter_engine.py) and the AOT app build's pure parts
(os/app_aot.py). Spec: docs/specs/toolchain-linux.md"""

import hashlib
import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import flutter_engine  # noqa: E402

_spec = importlib.util.spec_from_file_location("app_aot", HERE.parent.parent / "os" / "app_aot.py")
app_aot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app_aot)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class PinTest(unittest.TestCase):
    def test_repo_pin_has_every_key(self):
        pin = flutter_engine.read_pin()
        for key in ("flutter", "engine", "release_repo", "release_tag", "release_commit"):
            self.assertIn(key, pin)
        for _, _, key in flutter_engine.FILES:
            self.assertEqual(len(pin[key]), 64, key)
        # The tag names the engine the app's SDK uses.
        self.assertTrue(pin["release_tag"].endswith(pin["engine"]))

    def test_comments_and_blanks_are_skipped(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "pin.txt").write_text("# a=b\n\n x = y=z \n")
        self.assertEqual(flutter_engine.read_pin(tmp / "pin.txt"), {"x": "y=z"})


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cache = self.tmp / "cache"
        self.out = self.tmp / "out"
        self.pin = {}
        for src, _, key in flutter_engine.FILES:
            data = src.encode()
            (self.cache / src).parent.mkdir(parents=True, exist_ok=True)
            (self.cache / src).write_bytes(data)
            self.pin[key] = digest(data)

    def test_installs_and_is_then_up_to_date(self):
        self.assertFalse(flutter_engine.up_to_date(self.pin, self.out))
        flutter_engine.install(self.pin, self.cache, self.out)
        self.assertTrue(flutter_engine.up_to_date(self.pin, self.out))
        self.assertTrue((self.out / "gen_snapshot").stat().st_mode & 0o111)

    def test_hash_mismatch_installs_nothing(self):
        self.pin["release_engine_sha256"] = "0" * 64
        with self.assertRaises(SystemExit):
            flutter_engine.install(self.pin, self.cache, self.out)
        self.assertFalse(self.out.exists())


class AppAotTest(unittest.TestCase):
    def test_sdk_engine_must_match(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "bin" / "internal").mkdir(parents=True)
        (tmp / "bin" / "internal" / "engine.version").write_text("abc\n")
        app_aot.check_engine(tmp, {"engine": "abc", "flutter": "1"})
        with self.assertRaises(SystemExit):
            app_aot.check_engine(tmp, {"engine": "def", "flutter": "1"})

    def test_kernel_is_product_mode_aot(self):
        cmd = app_aot.kernel_command(Path("/sdk"), Path("/o/app.dill"), ["A=1"])
        for flag in ("--aot", "--tfa", "-Ddart.vm.product=true", "-DA=1"):
            self.assertIn(flag, cmd)
        self.assertTrue(cmd[-1].endswith("main.dart"))

    def test_gen_snapshot_runs_through_wsl_on_windows(self):
        with mock.patch.object(app_aot.os, "name", "nt"), \
                mock.patch.object(app_aot, "wsl_path", lambda p: "/mnt/c/" + Path(p).name):
            cmd = app_aot.snapshot_command(Path("gs"), Path("app.dill"), Path("libapp.so"))
        self.assertEqual(cmd[:3], ["wsl", "-e", "/mnt/c/gs"])
        self.assertIn("--snapshot_kind=app-aot-elf", cmd)
        self.assertIn("--elf=/mnt/c/libapp.so", cmd)


if __name__ == "__main__":
    unittest.main()
