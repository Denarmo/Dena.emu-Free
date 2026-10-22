# SPDX-License-Identifier: GPL-3.0-or-later
"""SD-card builder, update-by-file and boot hook. Spec: docs/specs/sd-card.md"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import build_sd  # noqa: E402

SH = shutil.which("bash") or shutil.which("sh")
HAVE_TOOLS = SH and shutil.which("unzip") and shutil.which("sha256sum")


def run_sh(script: Path, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(
        [SH, str(script), *args], capture_output=True, text=True, env=e,
        stdin=subprocess.DEVNULL, timeout=60,
    )


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dena_sd"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def build(self, version="1.0.0", payload=None):
        return build_sd.build_tree(self.tmp / f"out-{version}", version, payload)

    def test_layout(self):
        card = self.build()
        for s in build_sd.SYSTEMS:
            self.assertTrue((card / "Roms" / s).is_dir(), s)
        for f in ("Bios", "Saves", "States", "Carts"):
            self.assertTrue((card / f).is_dir(), f)
        self.assertEqual((card / "Dena" / "version.txt").read_text().strip(), "1.0.0")
        self.assertEqual(
            sorted(p.name for p in (card / "Dena" / "devices").iterdir()),
            ["a133p.conf", "h700.conf", "rk3566.conf"],
        )
        boot = (card / "Dena" / "bin" / "dena-boot.sh").read_bytes()
        self.assertNotIn(b"\r\n", boot)
        self.assertTrue(boot.startswith(b"#!/bin/sh"))

    def test_payload_and_zips(self):
        payload = self.tmp / "payload"
        (payload / "bin").mkdir(parents=True)
        (payload / "bin" / "dena-launcher").write_text("#!/bin/sh\n")
        (payload / "lib").mkdir()
        (payload / "lib" / "mgba_libretro.so").write_bytes(b"\x7fELF")
        card = self.build(payload=payload)
        self.assertTrue((card / "Dena" / "lib" / "mgba_libretro.so").exists())
        full = self.tmp / "full.zip"
        build_sd.zip_tree(card, full)
        with zipfile.ZipFile(full) as z:
            names = z.namelist()
            self.assertIn("Roms/gba/.keep", names)
            self.assertIn("Dena/bin/dena-launcher", names)
            mode = z.getinfo("Dena/bin/dena-launcher").external_attr >> 16
            self.assertEqual(mode & 0o111, 0o111)
        update = self.tmp / "update.zip"
        build_sd.build_update(card, update)
        with zipfile.ZipFile(update) as z:
            manifest = z.read("manifest.sha256").decode()
            self.assertIn("  Dena/lib/mgba_libretro.so\n", manifest)
            self.assertFalse(any(n.startswith("Dena/user/") for n in z.namelist()))
            self.assertFalse(any("Dena/user" in line for line in manifest.splitlines()))


@unittest.skipUnless(HAVE_TOOLS, "needs sh, unzip and sha256sum")
class DeviceScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dena_card"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        old = build_sd.build_tree(self.tmp / "old", "1.0.0", None)
        self.card = self.tmp / "sd"
        shutil.copytree(old, self.card)
        (self.card / "Dena" / "user" / "settings.json").write_text('{"keep": true}')
        new = build_sd.build_tree(self.tmp / "new", "2.0.0", None)
        self.update = self.card / "Dena-update-2.0.0.zip"
        build_sd.build_update(new, self.update)
        # Run a copy, as the boot hook does (the update replaces Dena/bin).
        self.script = self.tmp / "dena-update.sh"
        shutil.copyfile(self.card / "Dena" / "bin" / "dena-update.sh", self.script)

    def version(self):
        return (self.card / "Dena" / "version.txt").read_text().strip()

    def test_update_replaces_dena_and_keeps_user(self):
        r = run_sh(self.script, str(self.card))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.version(), "2.0.0")
        self.assertEqual((self.card / "Dena" / "user" / "settings.json").read_text(), '{"keep": true}')
        self.assertTrue((self.card / "Dena-update-2.0.0.zip.applied").exists())
        self.assertFalse((self.card / "Dena.old").exists())
        self.assertFalse((self.card / ".dena-update-tmp").exists())
        # Nothing left to apply: a second run is a no-op.
        self.assertEqual(run_sh(self.script, str(self.card)).returncode, 0)
        self.assertEqual(self.version(), "2.0.0")

    def test_tampered_update_changes_nothing(self):
        with zipfile.ZipFile(self.update, "a") as z:
            z.writestr("Dena/version.txt", "evil\n")  # duplicate entry wins on unzip
        r = run_sh(self.script, str(self.card))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.version(), "1.0.0")
        self.assertTrue((self.card / "Dena-update-2.0.0.zip.failed").exists())
        self.assertTrue((self.card / "Dena" / "user" / "settings.json").exists())

    def test_not_an_update_zip(self):
        self.update.unlink()
        with zipfile.ZipFile(self.card / "Dena-update-3.zip", "w") as z:
            z.writestr("hello.txt", "hi")
        r = run_sh(self.script, str(self.card))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.version(), "1.0.0")

    def test_boot_without_launcher_returns_to_stock(self):
        boot = self.card / "Dena" / "bin" / "dena-boot.sh"
        r = run_sh(boot, env={"DENA_CARD": str(self.card)})
        self.assertEqual(r.returncode, 0, r.stderr)
        log = (self.card / "Dena" / "user" / "boot.log").read_text()
        self.assertIn("no launcher", log)
        self.assertIn("dena-update: applying", log)
        if os.name != "nt":
            # Windows locks the running script's folder; Linux doesn't.
            self.assertEqual(self.version(), "2.0.0", "the update ran first")

    def test_boot_runs_the_launcher_in_handheld_mode(self):
        launcher = self.card / "Dena" / "bin" / "dena-launcher"
        launcher.write_text('#!/bin/sh\necho "mode=$DENA_HANDHELD card=$DENA_CARD args=$*" > "$DENA_CARD/ran.txt"\n')
        launcher.chmod(0o755)
        self.update.unlink()
        boot = self.card / "Dena" / "bin" / "dena-boot.sh"
        r = run_sh(boot, env={"DENA_CARD": str(self.card)})
        self.assertEqual(r.returncode, 0, r.stderr)
        ran = (self.card / "ran.txt").read_text()
        self.assertIn("mode=1", ran)
        self.assertIn("args=" + str(self.card).replace("\\", "/") + "/Dena/data/app", ran.replace("\\", "/"))


if __name__ == "__main__":
    unittest.main()
