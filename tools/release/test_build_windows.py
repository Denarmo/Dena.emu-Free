# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks the Windows release packaging (docs/dev/release-windows.md).

Runs build-windows.ps1 -DryRun with pwsh (skipped when pwsh is missing) and
checks the portable zip's layout, the missing-core notes and, when ISCC.exe
is on the PATH, that the installer script compiles. The installer script's
settings are checked as text everywhere.
"""

import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCRIPT = HERE / "build-windows.ps1"
ISS = HERE / "windows" / "dena-emu.iss"

CORES = [
    "fceumm", "bsnes", "mgba", "fake08", "mednafen_psx_hw", "mednafen_saturn",
    "melonds", "mupen64plus", "flycast", "ppsspp", "pcsx2", "dolphin",
]


def app_version() -> str:
    text = (ROOT / "app" / "pubspec.yaml").read_text(encoding="utf-8")
    return re.search(r"^version:\s*(\d+\.\d+\.\d+)", text, re.M).group(1)


def pwsh() -> str | None:
    return shutil.which("pwsh") or shutil.which("powershell")


class InstallerScriptTest(unittest.TestCase):
    def setUp(self):
        self.iss = ISS.read_text(encoding="utf-8")

    def setting(self, name: str) -> str:
        m = re.search(rf"^{name}=(.*)$", self.iss, re.M)
        self.assertIsNotNone(m, name)
        return m.group(1).strip()

    def test_per_user_without_admin(self):
        self.assertEqual(self.setting("PrivilegesRequired"), "lowest")
        self.assertNotIn("PrivilegesRequiredOverridesAllowed", self.iss)
        self.assertIn("{autopf}", self.iss)

    def test_x64_only(self):
        self.assertEqual(self.setting("ArchitecturesInstallIn64BitMode"), "x64compatible")
        self.assertEqual(self.setting("ArchitecturesAllowed"), "x64compatible")

    def test_app_id_is_fixed(self):
        # Upgrades and the uninstaller find the install by AppId.
        self.assertEqual(self.setting("AppId"), "{{6F1D2C7A-3B8E-4E5D-9A61-D3E4A0B7C2F1}")

    def test_optional_tasks_are_off_by_default(self):
        tasks = re.findall(r'^Name: "(\w+)";.*$', self.iss.split("[Tasks]")[1].split("[")[0], re.M)
        self.assertEqual(tasks, ["desktopicon", "openwith"])
        for line in self.iss.split("[Tasks]")[1].split("[")[0].strip().splitlines():
            self.assertIn("Flags: unchecked", line)

    def test_associations_only_with_the_task(self):
        registry = self.iss.split("[Registry]")[1].split("[Run]")[0]
        entries = [l for l in registry.splitlines() if l.startswith("Root:") or "#define Ext" in l]
        self.assertTrue(entries)
        for line in entries:
            self.assertIn("Tasks: openwith", line)
        # Never takes over the default app for a type.
        self.assertNotRegex(registry, r'Subkey: "Software\\Classes\\\.\w+"; ValueType')

    def test_start_menu_and_uninstaller(self):
        self.assertIn('Name: "{autoprograms}\\{#AppName}"', self.iss)
        self.assertIn("UninstallDisplayIcon=", self.iss)
        self.assertNotIn("[UninstallDelete]", self.iss)  # user data stays

    def test_output_name(self):
        self.assertIn('"dena-emu-" + AppVersion + "-windows-x64-setup"', self.iss)


@unittest.skipUnless(pwsh(), "pwsh not installed")
class DryRunTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.out = cls.tmp / "out"
        cls.cores = cls.tmp / "cores"
        cls.cores.mkdir()
        # Every core but PPSSPP and Flycast "built".
        for c in CORES:
            if c not in ("ppsspp", "flycast"):
                (cls.cores / f"{c}_libretro.dll").write_bytes(b"MZ")
        cls.result = subprocess.run(
            [pwsh(), "-NoProfile", "-NonInteractive", "-File", str(SCRIPT), "-DryRun",
             "-OutDir", str(cls.out), "-CoresDir", str(cls.cores)],
            capture_output=True, text=True, timeout=300)
        cls.version = app_version()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_runs(self):
        self.assertEqual(self.result.returncode, 0, self.result.stdout + self.result.stderr)

    def test_zip_layout(self):
        zip_path = self.out / f"dena-emu-{self.version}-windows-x64-portable.zip"
        names = set(zipfile.ZipFile(zip_path).namelist())
        for f in ["dena_emu.exe", "flutter_windows.dll", "dena_host.dll", "portable.txt",
                  "LICENSE.txt", "SOURCE.txt", "licenses/THIRD-PARTY-LICENSES.md",
                  "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll",
                  "data/icudtl.dat", "Dena/Roms/gba/", "Dena/Bios/"]:
            self.assertIn(f"Dena.emu/{f}", names)
        shipped = sorted(n[len("Dena.emu/cores/"):] for n in names
                         if n.startswith("Dena.emu/cores/") and n.endswith(".dll"))
        self.assertEqual(shipped, sorted(f"{c}_libretro.dll" for c in CORES
                                         if c not in ("ppsspp", "flycast")))
        self.assertTrue(all("\\" not in n for n in names))

    def test_installer_stage_is_not_portable(self):
        stage = self.out / "stage" / "Dena.emu"
        self.assertTrue((stage / "dena_emu.exe").is_file())
        self.assertFalse((stage / "portable.txt").exists())
        self.assertFalse((stage / "Dena").exists())

    def test_notes_list_missing_cores(self):
        notes = (self.out / "release-notes-windows.md").read_text(encoding="utf-8-sig")
        self.assertIn("### Not in this build", notes)
        self.assertIn("PSP (PPSSPP)", notes)
        self.assertIn("Dreamcast (Flycast)", notes)
        self.assertNotIn("GB / GBC / GBA (mGBA): the core", notes)
        self.assertIn("Add a Non-Steam Game", notes)
        self.assertIn(f"dena-emu-{self.version}-windows-x64-portable.zip", notes)

    def test_require_all_cores_fails(self):
        r = subprocess.run(
            [pwsh(), "-NoProfile", "-NonInteractive", "-File", str(SCRIPT), "-DryRun",
             "-OutDir", str(self.tmp / "strict"), "-CoresDir", str(self.cores), "-RequireAllCores"],
            capture_output=True, text=True, timeout=300)
        self.assertNotEqual(r.returncode, 0)

    @unittest.skipUnless(shutil.which("ISCC.exe") or shutil.which("ISCC"), "Inno Setup not on PATH")
    def test_installer_compiles(self):
        iscc = shutil.which("ISCC.exe") or shutil.which("ISCC")
        r = subprocess.run(
            [iscc, "/Q", "/O-", f"/DAppVersion={self.version}",
             f"/DSourceDir={self.out / 'stage' / 'Dena.emu'}", f"/DRepoDir={ROOT}", str(ISS)],
            capture_output=True, text=True, timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
