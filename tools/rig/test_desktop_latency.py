"""Tests for the desktop latency log summary (docs/specs/desktop-shell.md).

    python -m unittest discover -s tools/rig -v
"""

from __future__ import annotations

import json
import unittest

import desktop_latency


def line(p95: float, frame: float = 16.67, missed: int = 0, ahead: int | None = None,
         **fields) -> str:
    extra = {} if ahead is None else {"run_ahead": ahead}
    extra.update(fields)
    return json.dumps({**extra,
        "t_ms": 1, "frames": 60,
        "input_to_post_ms": {"p50": p95 / 2, "p95": p95, "max": p95},
        "present_ms": None,
        "frame_interval_ms": {"p50": frame, "p99": frame, "max": frame},
        "missed_frames": missed, "audio_xruns": 0, "audio_underruns": 0,
        "audio_buffer_ms": 40.0, "audio_rate": 48000,
    })


class SummaryTest(unittest.TestCase):
    def test_worst_window_plus_two_frames(self):
        s = desktop_latency.summarise([line(8.0), line(12.0), line(10.0)])
        self.assertEqual(s.lines, 3)
        self.assertEqual(s.input_p95_ms, 12.0)
        self.assertAlmostEqual(s.estimate_ms, 12.0 + 2 * 16.67)
        self.assertTrue(s.passed)

    def test_over_the_gate_fails(self):
        s = desktop_latency.summarise([line(20.0, frame=16.67)])
        self.assertFalse(s.passed)

    def test_run_ahead_takes_off_game_lag_frames(self):
        # The first desktop pass: Tetris at 17.0 ms p95 failed by 1 ms.
        plain = desktop_latency.summarise([line(17.0, ahead=0)])
        self.assertFalse(plain.passed)
        s = desktop_latency.summarise([line(17.0, ahead=1), line(16.0, ahead=1)])
        self.assertEqual(s.run_ahead_frames, 1)
        self.assertAlmostEqual(s.raw_estimate_ms, 17.0 + 2 * 16.67)
        self.assertAlmostEqual(s.estimate_ms, 17.0 + 16.67)
        self.assertTrue(s.passed)
        # The least run-ahead in the log counts (it was off for a while).
        mixed = desktop_latency.summarise([line(16.5, ahead=2), line(16.0, ahead=0)])
        self.assertEqual(mixed.run_ahead_frames, 0)

    def test_frame_generation_adds_the_hold(self):
        # 120 Hz screen, 60 fps game, frame generation on: the hold (about
        # one refresh) counts, composite frames are 120 Hz ones.
        fg = dict(display_hz=120.0, frame_generation=1, frame_generation_off="",
                  frame_generation_added_ms={"p50": 8.0, "p95": 9.0, "max": 9.5},
                  frame_generation_gpu_ms={"p50": 0.6, "p95": 0.9, "max": 1.2},
                  generated_frames=600, generated_skipped=3)
        s = desktop_latency.summarise([line(20.0, **fg), line(22.0, **fg)])
        self.assertEqual(s.display_hz, 120.0)
        self.assertEqual(s.frame_generation, 1)
        self.assertAlmostEqual(s.estimate_ms, 22.0 + 2 * 1000 / 120 + 9.0)
        self.assertEqual(s.generated_skipped, 3)
        self.assertAlmostEqual(s.gpu_p95_ms, 0.9)
        self.assertTrue(s.passed)
        # With one frame of run-ahead.
        r = desktop_latency.summarise([line(30.0, ahead=1, **fg)])
        self.assertAlmostEqual(r.estimate_ms, 30.0 + 2 * 1000 / 120 + 9.0 - 16.67)

    def test_frame_generation_start_up_set_up(self):
        # Pass 3 at 175 Hz: the GL set-up ran inside the first frame, so the
        # first window's p95 was ~110 ms and the worst-window gate failed.
        fg = dict(display_hz=175.0, frame_generation=1, frame_generation_off="",
                  frame_generation_added_ms={"p50": 5.0, "p95": 6.0, "max": 6.5})
        before = desktop_latency.summarise(
            [line(108.0, frame_generation_setup_ms=97.4, **fg),
             line(16.6, frame_generation_setup_ms=97.4, **fg)])
        self.assertAlmostEqual(before.setup_ms, 97.4)
        self.assertFalse(before.passed)
        # Fixed: the set-up runs before the first frame and reads 0.
        after = desktop_latency.summarise(
            [line(16.6, frame_generation_setup_ms=0.0, **fg), line(16.6, **fg)])
        self.assertEqual(after.setup_ms, 0.0)
        self.assertTrue(after.passed)

    def test_frame_generation_off_reason(self):
        off = dict(display_hz=60.0, frame_generation=0, frame_generation_off="refresh",
                   frame_generation_added_ms=None)
        s = desktop_latency.summarise([line(10.0, **off)])
        self.assertEqual(s.frame_generation_off, "refresh")
        self.assertEqual(s.added_p95_ms, 0.0)
        self.assertAlmostEqual(s.estimate_ms, 10.0 + 2 * 1000 / 60)

    def test_no_input_samples(self):
        quiet = json.dumps({"t_ms": 1, "input_to_post_ms": None,
                            "frame_interval_ms": {"p50": 16.7}})
        s = desktop_latency.summarise([quiet, "", "{broken"])
        self.assertEqual(s.lines, 1)
        self.assertIsNone(s.passed)


if __name__ == "__main__":
    unittest.main()
