# SPDX-License-Identifier: GPL-3.0-or-later
"""USB storage mode (dena-usb-storage) against a fake root: sysfs, configfs,
/proc/mounts and the splash are plain files, mount and umount are stubs.
Spec: docs/specs/single-card.md, "USB storage mode"."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

SYSTEM = (Path(__file__).resolve().parent.parent / "image" / "rootfs" / "overlay" / "usr" /
          "lib" / "dena" / "system")
SH = shutil.which("sh")
UDC = "musb-hdrc.5.auto"
DEV = "/dev/mmcblk0p2"

STUBS = {
    # Fails while umount.busy holds a number above 0 (counted down per try).
    "umount": """#!/bin/sh
n=$(cat "$DENA_TEST_ROOT/umount.busy" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$DENA_TEST_ROOT/umount.busy"; exit 1; fi
grep -v " $1 " "$DENA_TEST_ROOT/proc/mounts" > "$DENA_TEST_ROOT/m.new"
mv "$DENA_TEST_ROOT/m.new" "$DENA_TEST_ROOT/proc/mounts"
""",
    "mount": """#!/bin/sh
while [ $# -gt 2 ]; do shift; done
[ "$1" = configfs ] && exit 0
echo "$1 $2 exfat rw 0 0" >> "$DENA_TEST_ROOT/proc/mounts"
""",
    "mountpoint": "#!/bin/sh\nexit 0\n",
    "sync": "#!/bin/sh\nexit 0\n",
}


@unittest.skipUnless(SH and os.name == "posix", "needs a POSIX sh")
class UsbStorageTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="dena_usb"))
        r = self.root
        self.card = r / "mnt" / "card"
        self.card.mkdir(parents=True)
        (r / "run" / "dena").mkdir(parents=True)
        (r / "proc").mkdir()
        (r / "proc" / "mounts").write_text(f"{DEV} {self.card} exfat rw 0 0\n")
        self.udc = r / "sys" / "class" / "udc" / UDC
        self.udc.mkdir(parents=True)
        (self.udc / "state").write_text("not attached\n")
        (r / "sys" / "kernel" / "config").mkdir(parents=True)
        cid = r / "sys" / "class" / "block" / "mmcblk0" / "device"
        cid.mkdir(parents=True)
        (cid / "cid").write_text("035344534430324780ffffffff0123\n")
        bins = r / "bin"
        bins.mkdir()
        for name, body in STUBS.items():
            (bins / name).write_text(body)
            (bins / name).chmod(0o755)
        splash = r / "usr" / "lib" / "dena" / "bin" / "dena-splash"
        splash.parent.mkdir(parents=True)
        splash.write_text('#!/bin/sh\necho "$*" >> "$DENA_TEST_ROOT/splash.log"\n')
        splash.chmod(0o755)
        self.gadget = r / "sys" / "kernel" / "config" / "usb_gadget" / "dena"
        self.lun = self.gadget / "functions" / "mass_storage.0" / "lun.0"
        self.lun.mkdir(parents=True)  # configfs makes lun.0 with the function

    def tearDown(self):
        shutil.rmtree(self.root, True)

    def request(self):
        (self.root / "run" / "dena" / "usb-storage").write_text("")

    def run_helper(self, host=None, timeout=30):
        """Runs dena-usb-storage; host(test) plays the computer meanwhile."""
        env = dict(os.environ, DENA_TEST_ROOT=str(self.root), DENA_TEST_PATH=str(self.root / "bin"),
                   DENA_TEST_TICK="0.02")
        p = subprocess.Popen([SH, str(SYSTEM / "dena-usb-storage")], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        t = None
        if host:
            t = threading.Thread(target=host, daemon=True)
            t.start()
        out, _ = p.communicate(timeout=timeout)
        if t:
            t.join(5)
        return p.returncode, out

    def wait_served(self):
        udc = self.gadget / "UDC"
        deadline = time.time() + 10
        while time.time() < deadline:
            if udc.exists() and udc.read_text().strip() == UDC:
                return
            time.sleep(0.01)
        self.fail("gadget never bound")

    def wait_splash(self, line):
        deadline = time.time() + 10
        while line not in self.splash():
            self.assertLess(time.time(), deadline, f"never showed {line}")
            time.sleep(0.01)

    def log(self):
        return (self.root / "run" / "dena" / "init.log").read_text()

    def splash(self):
        p = self.root / "splash.log"
        return p.read_text().splitlines() if p.exists() else []

    def mounted(self):
        return f" {self.card} " in (self.root / "proc" / "mounts").read_text()

    def test_does_nothing_without_a_request(self):
        code, _ = self.run_helper()
        self.assertEqual(code, 2)
        self.assertTrue(self.mounted())
        self.assertFalse((self.gadget / "UDC").exists())
        self.assertEqual(self.splash(), [])

    def test_request_is_used_up(self):
        self.request()

        def host():
            self.wait_served()
            (self.lun / "file").write_text("")
        self.run_helper(host)
        self.assertFalse((self.root / "run" / "dena" / "usb-storage").exists())
        code, _ = self.run_helper()
        self.assertEqual(code, 2)

    def test_eject_returns_and_remounts(self):
        self.request()

        def host():
            self.wait_served()
            self.assertEqual((self.lun / "file").read_text().strip(), DEV)
            self.assertEqual((self.lun / "removable").read_text().strip(), "1")
            self.assertEqual((self.gadget / "idVendor").read_text().strip(), "0x1d6b")
            self.assertFalse(self.mounted())  # never mounted while served
            self.wait_splash("message CONNECT USB-C TO A COMPUTER")
            (self.udc / "state").write_text("configured\n")
            time.sleep(0.2)
            (self.lun / "file").write_text("")
        code, out = self.run_helper(host)
        self.assertEqual(code, 0, out)
        self.assertIn("ejected by the computer", self.log())
        self.assertTrue(self.mounted())
        self.assertEqual((self.gadget / "UDC").read_text().strip(), "")
        s = self.splash()
        self.assertEqual(s[0], "message STARTING USB STORAGE")
        self.assertIn("message CONNECT USB-C TO A COMPUTER", s)
        self.assertIn("message USB DRIVE ON. EJECT IT TO RETURN", s)
        self.assertEqual(s[-1], "message RETURNING TO DENA.EMU")
        for line in s:
            self.assertLessEqual(len(line.removeprefix("message ")), 35, line)
        self.assertEqual((self.gadget / "strings" / "0x409" / "serialnumber").read_text().strip(),
                         "035344534430324780ffffff")

    def test_unplug_seen_from_vbus(self):
        supply = self.root / "sys" / "class" / "power_supply" / "axp20x-usb"
        supply.mkdir(parents=True)
        (supply / "type").write_text("USB\n")
        (supply / "present").write_text("1\n")
        self.request()

        def host():
            self.wait_served()
            (self.udc / "state").write_text("configured\n")
            time.sleep(0.2)
            (supply / "present").write_text("0\n")  # the UDC state stays put
        code, out = self.run_helper(host)
        self.assertEqual(code, 0, out)
        self.assertIn("cable unplugged", self.log())
        self.assertTrue(self.mounted())

    def test_unplug_seen_from_the_udc(self):
        self.request()

        def host():
            self.wait_served()
            (self.udc / "state").write_text("configured\n")
            time.sleep(0.2)
            (self.udc / "state").write_text("not attached\n")
        code, _ = self.run_helper(host)
        self.assertEqual(code, 0)
        self.assertIn("cable unplugged", self.log())

    def test_no_computer_times_out(self):
        self.request()
        code, _ = self.run_helper()
        self.assertEqual(code, 0)
        self.assertIn("no computer connected", self.log())
        self.assertTrue(self.mounted())

    def test_power_key_returns(self):
        ev = self.root / "sys" / "class" / "input" / "event0" / "device"
        ev.mkdir(parents=True)
        (ev / "name").write_text("axp20x-pek\n")
        (self.root / "dev" / "input").mkdir(parents=True)
        fifo = self.root / "dev" / "input" / "event0"
        os.mkfifo(fifo)
        self.request()

        def host():
            self.wait_served()
            (self.udc / "state").write_text("configured\n")
            with open(fifo, "wb") as f:
                f.write(bytes(24))
        code, _ = self.run_helper(host)
        self.assertEqual(code, 0)
        self.assertIn("power key", self.log())
        self.assertTrue(self.mounted())

    def test_busy_card_waits_then_gives_up(self):
        (self.root / "umount.busy").write_text("3")
        self.request()

        def host():
            self.wait_served()
            (self.lun / "file").write_text("")
        code, _ = self.run_helper(host)
        self.assertEqual(code, 0)  # free after three tries
        (self.root / "umount.busy").write_text("1000")
        self.request()
        code, _ = self.run_helper()
        self.assertEqual(code, 1)
        self.assertIn("games partition busy", self.log())
        self.assertIn("message CARD BUSY. TRY AGAIN", self.splash())
        self.assertTrue(self.mounted())

    def test_no_controller(self):
        shutil.rmtree(self.udc)
        self.request()
        code, _ = self.run_helper()
        self.assertEqual(code, 1)
        self.assertIn("message USB STORAGE NOT AVAILABLE", self.splash())
        self.assertTrue(self.mounted())


if __name__ == "__main__":
    unittest.main()
