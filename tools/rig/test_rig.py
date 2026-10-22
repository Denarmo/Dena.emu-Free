"""Acceptance tests for the hardware rig CLI (docs/specs/rig.md).

No devices, no adb, no ssh, no serial port: everything here runs against the
pure command builders and ``--dry-run``, plus a fake serial stream for the
latency statistics.

Run with::

    python -m unittest discover -s tools/rig -v
"""

from __future__ import annotations

import contextlib
import io
import random
import shlex
import sys
import tempfile
import unittest
from pathlib import Path

RIG_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(RIG_DIR))

import keymap  # noqa: E402
import rig  # noqa: E402

EXAMPLE_CONFIG = RIG_DIR / "devices.example.toml"


def run_cli(argv: list[str]) -> tuple[int, str, str]:
    """Call ``rig.main`` with argv, capturing stdout/stderr and the exit code."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = rig.main(argv)
    return code, out.getvalue(), err.getvalue()


class FakeStream:
    """A minimal stand-in for a pyserial port: canned replies, recorded writes."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.written: list[bytes] = []
        self.sleeps: list[float] = []

    def write(self, data: bytes) -> int:
        self.written.append(data)
        return len(data)

    def readline(self) -> str:
        return self.replies.pop(0) if self.replies else "T"

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)


# --------------------------------------------------------------------------- #
# Config parsing
# --------------------------------------------------------------------------- #


class ConfigTests(unittest.TestCase):
    def test_example_config_parses(self):
        config = rig.load_config(EXAMPLE_CONFIG)

        self.assertEqual(set(config.devices), {"pixel", "rg35xx"})

        pixel = config.devices["pixel"]
        self.assertEqual(pixel.cls, "android")
        self.assertEqual(pixel.serial, "emulator-5554")
        self.assertTrue(pixel.is_android)

        handheld = config.devices["rg35xx"]
        self.assertEqual(handheld.cls, "handheld")
        self.assertEqual(handheld.host, "192.168.1.50")
        self.assertEqual(handheld.user, "root")
        self.assertEqual(handheld.port, 22)
        self.assertEqual(handheld.input_device, "/dev/input/event1")
        self.assertEqual(handheld.platform, "h700")
        self.assertEqual(handheld.deploy_dir, "/mnt/SDCARD/Dena")
        self.assertEqual(handheld.ssh_target, "root@192.168.1.50")
        self.assertTrue(handheld.is_handheld)

        self.assertEqual(config.latency_port, "COM5")
        self.assertEqual(config.latency_baud, 115200)

    def test_missing_config_is_usage_error(self):
        with self.assertRaises(rig.RigError) as ctx:
            rig.load_config(RIG_DIR / "does-not-exist.toml")
        self.assertEqual(ctx.exception.code, rig.EXIT_USAGE)

    def test_bad_device_class_rejected(self):
        with self.assertRaises(rig.RigError) as ctx:
            rig.parse_config({"devices": {"x": {"class": "phone"}}})
        self.assertEqual(ctx.exception.code, rig.EXIT_USAGE)

    def test_android_needs_serial(self):
        with self.assertRaises(rig.RigError):
            rig.parse_config({"devices": {"x": {"class": "android"}}})

    def test_unknown_device_exits_2(self):
        code, _out, err = run_cli(
            ["--config", str(EXAMPLE_CONFIG), "--dry-run",
             "launch", "--device", "nope"]
        )
        self.assertEqual(code, rig.EXIT_USAGE)
        self.assertIn("nope", err)


# --------------------------------------------------------------------------- #
# Keymap
# --------------------------------------------------------------------------- #


class KeymapTests(unittest.TestCase):
    def test_generic_pad_set(self):
        expected = {
            "up": "DPAD_UP",
            "down": "DPAD_DOWN",
            "left": "DPAD_LEFT",
            "right": "DPAD_RIGHT",
            "a": "BUTTON_A",
            "b": "BUTTON_B",
            "x": "BUTTON_X",
            "y": "BUTTON_Y",
            "l1": "BUTTON_L1",
            "r1": "BUTTON_R1",
            "l2": "BUTTON_L2",
            "r2": "BUTTON_R2",
            "start": "BUTTON_START",
            "select": "BUTTON_SELECT",
        }
        self.assertEqual(keymap.KEYMAP, expected)
        self.assertEqual(keymap.android_keycode("a"), "BUTTON_A")
        self.assertEqual(keymap.android_keycode_full("up"), "KEYCODE_DPAD_UP")

    def test_unknown_key_raises(self):
        with self.assertRaises(keymap.UnknownKeyError):
            keymap.android_keycode("turbo")


# --------------------------------------------------------------------------- #
# Dry-run command plans
# --------------------------------------------------------------------------- #


class AndroidDryRunTests(unittest.TestCase):
    def dry(self, *argv: str) -> str:
        code, out, err = run_cli(
            ["--config", str(EXAMPLE_CONFIG), "--dry-run", *argv, "--device", "pixel"]
        )
        self.assertEqual(code, rig.EXIT_OK, f"stderr: {err}")
        return out

    def test_deploy(self):
        out = self.dry("deploy", "build/app.apk")
        self.assertEqual(
            out.strip(), shlex.join(["adb", "-s", "emulator-5554", "install", "-r", "build/app.apk"])
        )

    def test_launch_default_package(self):
        out = self.dry("launch")
        self.assertEqual(
            out.strip(),
            shlex.join(["adb", "-s", "emulator-5554", "shell", "monkey", "-p", "app.dena.emu", "1"]),
        )

    def test_launch_custom_package(self):
        out = self.dry("launch", "--package", "com.example.app")
        self.assertIn("com.example.app", out)
        self.assertIn("monkey", out)

    def test_input_tap(self):
        out = self.dry("input", "tap", "12", "34")
        self.assertEqual(
            out.strip(),
            shlex.join(["adb", "-s", "emulator-5554", "shell", "input", "tap", "12", "34"]),
        )

    def test_input_key(self):
        out = self.dry("input", "key", "up")
        self.assertIn("input", out)
        self.assertIn("keyevent", out)
        self.assertIn(keymap.KEYMAP["up"], out)

    def test_input_key_unknown_name(self):
        code, _out, err = run_cli(
            ["--config", str(EXAMPLE_CONFIG), "--dry-run",
             "input", "key", "turbo", "--device", "pixel"]
        )
        self.assertEqual(code, rig.EXIT_USAGE)
        self.assertIn("turbo", err)

    def test_input_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            replay = Path(tmp) / "replay.txt"
            replay.write_text(
                "# comment\n0 a down\n150 a up\n300 start down\n", encoding="utf-8"
            )
            out = self.dry("input", "replay", str(replay))
        # One keyevent per key-down; no keyevent for key-up (adb cannot hold).
        self.assertEqual(out.count("input keyevent"), 2)
        self.assertIn(keymap.KEYMAP["a"], out)
        self.assertIn(keymap.KEYMAP["start"], out)

    def test_capture(self):
        out = self.dry("capture", "shot.png")
        self.assertIn("exec-out", out)
        self.assertIn("screencap -p", out)
        self.assertIn("shot.png", out)

    def test_logs(self):
        out = self.dry("logs")
        self.assertEqual(
            out.strip(),
            shlex.join(["adb", "-s", "emulator-5554", "logcat", "-v", "time", "-s", "Dena", "-d"]),
        )

    def test_logs_follow_and_tag(self):
        out = self.dry("logs", "--follow", "--tag", "MyTag")
        self.assertIn("MyTag", out)
        self.assertNotIn(" -d", out)
        self.assertIn("logcat", out)

    def test_latency(self):
        out = self.dry("latency", "--samples", "5")
        self.assertIn("COM5", out)
        self.assertIn("115200", out)
        self.assertIn("5 samples", out)


class HandheldDryRunTests(unittest.TestCase):
    def dry(self, *argv: str) -> str:
        code, out, err = run_cli(
            ["--config", str(EXAMPLE_CONFIG), "--dry-run", *argv, "--device", "rg35xx"]
        )
        self.assertEqual(code, rig.EXIT_OK, f"stderr: {err}")
        return out

    def test_deploy_copies_then_syncs(self):
        out = self.dry("deploy", "build/dena.zip")
        lines = [line for line in out.splitlines() if line.strip()]
        self.assertEqual(
            lines[0],
            shlex.join(
                ["scp", "-P", "22", "build/dena.zip", "root@192.168.1.50:/mnt/SDCARD/Dena/"]
            ),
        )
        self.assertEqual(
            lines[1], shlex.join(["ssh", "-p", "22", "root@192.168.1.50", "sync"])
        )

    def test_deploy_directory(self):
        code, out, err = run_cli(
            ["--config", str(EXAMPLE_CONFIG), "--dry-run",
             "deploy", str(RIG_DIR), "--device", "rg35xx"]
        )
        self.assertEqual(code, rig.EXIT_OK, f"stderr: {err}")
        self.assertIn("scp -P 22 -r", out)

    def test_launch(self):
        out = self.dry("launch")
        self.assertEqual(
            out.strip(),
            shlex.join(["ssh", "-p", "22", "root@192.168.1.50", "/mnt/SDCARD/Dena/launch.sh"]),
        )

    def test_tap_not_supported_exit_2(self):
        code, _out, err = run_cli(
            ["--config", str(EXAMPLE_CONFIG), "--dry-run",
             "input", "tap", "1", "2", "--device", "rg35xx"]
        )
        self.assertEqual(code, rig.EXIT_USAGE)
        self.assertIn("not supported", err)

    def test_input_key_uses_helper(self):
        out = self.dry("input", "key", "b")
        lines = [line for line in out.splitlines() if line.strip()]
        prefix = ["ssh", "-p", "22", "root@192.168.1.50"]
        self.assertEqual(
            lines[0],
            shlex.join(prefix + ["test", "-x", "/mnt/SDCARD/Dena/rig-inject"]),
        )
        self.assertEqual(
            lines[1], shlex.join(prefix + ["/mnt/SDCARD/Dena/rig-inject", "key", "b"])
        )

    def test_input_replay_streams_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            replay = Path(tmp) / "replay.txt"
            replay.write_text("0 up down\n500 up up\n", encoding="utf-8")
            out = self.dry("input", "replay", str(replay))
        self.assertIn("rig-inject replay", out)
        self.assertIn("0 up down", out)
        self.assertIn("500 up up", out)

    def test_capture(self):
        out = self.dry("capture", "shot.png")
        prefix = shlex.join(["ssh", "-p", "22", "root@192.168.1.50"])
        self.assertIn(f"{prefix} test -x /mnt/SDCARD/Dena/rig-capture", out)
        self.assertIn("rig-capture /tmp/rig-capture.png", out)
        self.assertIn(
            shlex.join(["scp", "-P", "22", "root@192.168.1.50:/tmp/rig-capture.png", "shot.png"]),
            out,
        )

    def test_logs_and_follow(self):
        tail = shlex.join(["ssh", "-p", "22", "root@192.168.1.50"])
        out = self.dry("logs")
        self.assertEqual(
            out.strip(), f"{tail} tail -n 200 /mnt/SDCARD/Dena/logs/dena.log"
        )
        out_follow = self.dry("logs", "--follow")
        self.assertEqual(
            out_follow.strip(), f"{tail} tail -f /mnt/SDCARD/Dena/logs/dena.log"
        )

    def test_latency_ignores_device(self):
        # Latency talks to the serial probe, not to a device.
        code, out, _err = run_cli(
            ["--config", str(EXAMPLE_CONFIG), "--dry-run", "latency"]
        )
        self.assertEqual(code, rig.EXIT_OK)
        self.assertIn("COM5", out)


class ListDryRunTests(unittest.TestCase):
    def test_list_dry_run_probes_every_device(self):
        code, out, err = run_cli(["--config", str(EXAMPLE_CONFIG), "--dry-run", "list"])
        self.assertEqual(code, rig.EXIT_OK, f"stderr: {err}")
        self.assertIn(shlex.join(["adb", "-s", "emulator-5554", "get-state"]), out)
        self.assertIn(shlex.join(["ssh", "-p", "22", "root@192.168.1.50", "true"]), out)

    def test_missing_command_exits_2(self):
        code, _out, _err = run_cli(["--config", str(EXAMPLE_CONFIG)])
        self.assertEqual(code, rig.EXIT_USAGE)


# --------------------------------------------------------------------------- #
# Replay parsing
# --------------------------------------------------------------------------- #


class ReplayParsingTests(unittest.TestCase):
    def test_parse_with_comments_and_blanks(self):
        events = rig.parse_replay(
            "# a comment\n"
            "\n"
            "0 a down\n"
            "120 a up   # trailing comment\n"
            "250 start down\n"
        )
        self.assertEqual([(e.at_ms, e.key, e.action) for e in events],
                         [(0, "a", "down"), (120, "a", "up"), (250, "start", "down")])

    def test_rejects_malformed_lines(self):
        for bad in ("0 a sideways", "0 a sideways extra", "x a down", "0 turbo down"):
            with self.subTest(bad=bad):
                with self.assertRaises(rig.RigError):
                    rig.parse_replay(bad + "\n")

    def test_serialize_round_trip(self):
        text = "0 up down\n500 up up\n"
        self.assertEqual(rig.serialize_replay(rig.parse_replay(text)), text)


# --------------------------------------------------------------------------- #
# Latency statistics (fake stream)
# --------------------------------------------------------------------------- #


class LatencyStatsTests(unittest.TestCase):
    def test_median_p95_and_gate_pass(self):
        lines = [f"L {ms * 1000}" for ms in range(1, 21)]  # 1..20 ms
        stats = rig.latency_stats(lines)
        self.assertEqual(stats["samples"], 20)
        self.assertEqual(stats["timeouts"], 0)
        self.assertEqual(stats["min_ms"], 1.0)
        self.assertEqual(stats["max_ms"], 20.0)
        self.assertEqual(stats["median_ms"], 10.5)
        self.assertAlmostEqual(stats["p95_ms"], 19.05)
        self.assertEqual(rig.latency_gate(stats), rig.EXIT_OK)

    def test_timeouts_counted_and_excluded(self):
        lines = ["L 10000", "T", "L 20000", "T", "L 30000"]
        stats = rig.latency_stats(lines)
        self.assertEqual(stats["samples"], 3)
        self.assertEqual(stats["timeouts"], 2)
        self.assertEqual(stats["median_ms"], 20.0)
        self.assertEqual(rig.latency_gate(stats), rig.EXIT_OK)

    def test_gate_fails_at_50ms(self):
        self.assertEqual(rig.latency_gate(rig.latency_stats(["L 50000"])), rig.EXIT_GATE)
        self.assertEqual(rig.latency_gate(rig.latency_stats(["L 49999"])), rig.EXIT_OK)

    def test_all_timeouts_fail_the_gate(self):
        stats = rig.latency_stats(["T", "T"])
        self.assertEqual(stats["samples"], 0)
        self.assertIsNone(stats["median_ms"])
        self.assertEqual(rig.latency_gate(stats), rig.EXIT_GATE)

    def test_single_sample(self):
        stats = rig.latency_stats(["L 12345"])
        self.assertEqual(stats["median_ms"], 12.345)
        self.assertEqual(stats["p95_ms"], 12.345)

    def test_ignores_garbage_lines(self):
        stats = rig.latency_stats(["", "hello", "L", b"L 4000"])
        self.assertEqual(stats["samples"], 1)
        self.assertEqual(stats["min_ms"], 4.0)

    def test_accepts_bytes_replies(self):
        stats = rig.latency_stats([b"L 2000\r\n", b"T\r\n"])
        self.assertEqual(stats["samples"], 1)
        self.assertEqual(stats["timeouts"], 1)
        self.assertEqual(stats["median_ms"], 2.0)

    def test_stats_json_has_exact_keys(self):
        stats = rig.latency_stats(["L 1000"])
        self.assertEqual(
            list(stats),
            ["samples", "timeouts", "min_ms", "median_ms", "p95_ms", "max_ms"],
        )

    def test_fake_stream_drives_the_protocol(self):
        stream = FakeStream(["L 10000", "L 30000", "T"])
        replies = rig.collect_latency_lines(
            stream.write,
            stream.readline,
            samples=3,
            rng=random.Random(0),
            sleep=stream.sleep,
        )
        self.assertEqual(replies, ["L 10000", "L 30000", "T"])
        self.assertEqual(stream.written, [b"P\n"] * 3)
        # One random pause between samples: 100-300 ms, in seconds.
        self.assertEqual(len(stream.sleeps), 2)
        for seconds in stream.sleeps:
            self.assertGreaterEqual(seconds, 0.1)
            self.assertLessEqual(seconds, 0.3)

        stats = rig.latency_stats(replies)
        self.assertEqual(stats["samples"], 2)
        self.assertEqual(stats["timeouts"], 1)
        self.assertEqual(stats["median_ms"], 20.0)
        self.assertEqual(rig.latency_gate(stats), rig.EXIT_OK)

    def test_end_to_end_summary_from_fake_stream(self):
        # 60 samples: 55 good at 10 ms, 5 timeouts -> gate passes.
        stream = FakeStream([f"L {10 * 1000}"] * 55 + ["T"] * 5)
        replies = rig.collect_latency_lines(
            stream.write, stream.readline, samples=60,
            rng=random.Random(1), sleep=stream.sleep,
        )
        stats = rig.latency_stats(replies)
        self.assertEqual(stats["samples"], 55)
        self.assertEqual(stats["timeouts"], 5)
        self.assertEqual(stats["median_ms"], 10.0)
        self.assertEqual(rig.latency_gate(stats), rig.EXIT_OK)


# --------------------------------------------------------------------------- #
# Tool plumbing
# --------------------------------------------------------------------------- #


class StepTests(unittest.TestCase):
    def test_step_stdout_redirection_is_shown(self):
        device = rig.load_config(EXAMPLE_CONFIG).get_device("pixel")
        steps = rig.build_capture(device, "out.png")
        self.assertEqual(len(steps), 1)
        self.assertEqual(steps[0].stdout_path, "out.png")
        self.assertIn("out.png", rig.format_step(steps[0]))

    def test_helper_preflight_steps_are_flagged(self):
        device = rig.load_config(EXAMPLE_CONFIG).get_device("rg35xx")
        steps = rig.build_key(device, "a")
        self.assertTrue(steps[0].preflight)
        self.assertEqual(steps[0].helper, "rig-inject")
        self.assertFalse(steps[1].preflight)

    def test_missing_tool_on_path_is_exit_2(self):
        step = rig.Step(args=["definitely-not-a-real-tool-42", "x"])
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = rig.run_step(step, err)
        self.assertEqual(code, rig.EXIT_USAGE)
        self.assertIn("definitely-not-a-real-tool-42", err.getvalue())

    def test_missing_helper_on_device_is_exit_3(self):
        # A preflight step that fails means the Milestone 4 helper is absent.
        step = rig.Step(
            args=[sys.executable, "-c", "raise SystemExit(1)"],
            helper="rig-inject",
            preflight=True,
        )
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = rig.run_step(step, err)
        self.assertEqual(code, rig.EXIT_DEVICE)
        self.assertIn("helper missing on device", err.getvalue())
        self.assertIn("rig-inject", err.getvalue())

    def test_failing_step_propagates_its_exit_code(self):
        step = rig.Step(args=[sys.executable, "-c", "raise SystemExit(7)"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(rig.run_step(step), 7)

    def test_global_options_before_the_command_are_honoured(self):
        code, out, err = run_cli(
            ["--dry-run", "--config", str(EXAMPLE_CONFIG), "launch", "--device", "pixel"]
        )
        self.assertEqual(code, rig.EXIT_OK, err)
        self.assertIn("monkey", out)

    def test_dry_run_never_touches_the_path(self):
        # A plan for every command must render without adb/ssh present.
        device = rig.load_config(EXAMPLE_CONFIG).get_device("rg35xx")
        replay = rig.parse_replay("0 a down\n")
        plans = [
            rig.build_deploy(device, "x"),
            rig.build_launch(device),
            rig.build_key(device, "a"),
            rig.build_replay(device, replay),
            rig.build_capture(device, "x.png"),
            rig.build_logs(device),
            rig.build_reachability(device),
        ]
        for plan in plans:
            for step in plan:
                self.assertIsInstance(rig.format_step(step), str)


if __name__ == "__main__":
    unittest.main()
