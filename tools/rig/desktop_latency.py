"""Summarise a desktop latency log against the 50 ms gate.

The desktop host library appends one metrics line per second while a game
plays when an empty ``latency`` file sits in the storage root, or with
``DENA_LATENCY_LOG=1`` (docs/specs/desktop-shell.md, Latency). This reads
``<root>/logs/latency.jsonl`` and prints the worst one-second windows.

The software numbers stop at the frame handed to Flutter; Flutter then needs
up to two display frames to composite and show it, and the panel adds its
scan-out. So the estimate is ``p95 input_to_post + 2 frames``, a lower bound
for input-to-photon. The probe (docs/specs/rig.md) gives the real figure.

The game's own input lag (usually one frame or more) is not in that figure
at all. Run-ahead (docs/specs/run-ahead.md) hides ``run_ahead`` frames of
it, so those frames are taken off: the verdict uses the estimate minus
``run_ahead`` frames (the least run-ahead seen in the log), and the plain
figure is printed beside it.

Frame generation (docs/specs/frame-generation.md) holds every real frame
back for about one screen refresh: the worst p95 ``frame_generation_added_ms``
is added to the estimate, and with ``display_hz`` in the log the two
composite frames are counted at the screen's refresh instead of the game's
frame time. ``frame_generation_setup_ms`` (the GL set-up time that ran
inside a playing game, 0 when it ran before the first frame) is printed on
the frame generation line.

    python tools/rig/desktop_latency.py %APPDATA%\\Dena.emu\\logs\\latency.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass

GATE_MS = 50.0
COMPOSITE_FRAMES = 2


@dataclass
class Summary:
    lines: int
    input_p95_ms: float | None
    frame_ms: float | None
    missed_frames: int
    audio_underruns: int
    estimate_ms: float | None
    run_ahead_frames: int = 0
    raw_estimate_ms: float | None = None
    display_hz: float | None = None
    frame_generation: int = 0
    frame_generation_off: str = ""
    added_p95_ms: float = 0.0
    gpu_p95_ms: float | None = None
    generated_frames: int = 0
    generated_skipped: int = 0
    setup_ms: float = 0.0

    @property
    def passed(self) -> bool | None:
        return None if self.estimate_ms is None else self.estimate_ms < GATE_MS


def summarise(lines: list[str]) -> Summary:
    rows = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue  # a line cut short when the app closed
    inputs = [r["input_to_post_ms"]["p95"] for r in rows if r.get("input_to_post_ms")]
    frames = [r["frame_interval_ms"]["p50"] for r in rows if r.get("frame_interval_ms")]
    input_p95 = max(inputs) if inputs else None
    frame = sorted(frames)[len(frames) // 2] if frames else None
    last = rows[-1] if rows else {}
    hz = [float(r["display_hz"]) for r in rows if r.get("display_hz")]
    display_hz = sorted(hz)[len(hz) // 2] if hz else None
    composite = None if frame is None else (1000.0 / display_hz if display_hz else frame)
    added = [r["frame_generation_added_ms"]["p95"] for r in rows
             if r.get("frame_generation_added_ms")]
    gpu = [r["frame_generation_gpu_ms"]["p95"] for r in rows if r.get("frame_generation_gpu_ms")]
    added_p95 = max(added) if added else 0.0
    raw = (
        None if input_p95 is None or composite is None
        else input_p95 + COMPOSITE_FRAMES * composite + added_p95
    )
    ahead = min((int(r.get("run_ahead") or 0) for r in rows), default=0)
    estimate = None if raw is None or frame is None else raw - ahead * frame
    offs = [r.get("frame_generation_off") for r in rows if r.get("frame_generation_off")]
    return Summary(
        lines=len(rows),
        input_p95_ms=input_p95,
        frame_ms=frame,
        missed_frames=int(last.get("missed_frames", 0)),
        audio_underruns=int(last.get("audio_underruns", 0)),
        estimate_ms=estimate,
        run_ahead_frames=ahead,
        raw_estimate_ms=raw,
        display_hz=display_hz,
        frame_generation=max((int(r.get("frame_generation") or 0) for r in rows), default=0),
        frame_generation_off=offs[-1] if offs else "",
        added_p95_ms=added_p95,
        gpu_p95_ms=max(gpu) if gpu else None,
        generated_frames=int(last.get("generated_frames", 0)),
        generated_skipped=int(last.get("generated_skipped", 0)),
        setup_ms=max((float(r.get("frame_generation_setup_ms") or 0) for r in rows), default=0.0),
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log", help="latency.jsonl from the storage root's logs folder")
    args = ap.parse_args(argv)
    with open(args.log, encoding="utf-8") as f:
        s = summarise(f.readlines())
    if s.estimate_ms is None:
        print(f"{s.lines} lines, no input samples: press buttons while the game runs")
        return 2
    print(f"lines {s.lines}  worst p95 input-to-post {s.input_p95_ms:.1f} ms  "
          f"frame {s.frame_ms:.2f} ms  missed {s.missed_frames}  "
          f"audio underruns {s.audio_underruns}")
    verdict = "PASS" if s.passed else "FAIL"
    if s.frame_generation or s.frame_generation_off:
        mode = {1: "interpolate", 2: "pixel-art"}.get(s.frame_generation, "off")
        gpu = "n/a" if s.gpu_p95_ms is None else f"{s.gpu_p95_ms:.2f} ms"
        off = f"  turned off: {s.frame_generation_off}" if s.frame_generation_off else ""
        print(f"frame generation {mode}  added p95 {s.added_p95_ms:.1f} ms  GPU p95 {gpu}  "
              f"generated {s.generated_frames}  skipped {s.generated_skipped}  "
              f"set-up in game {s.setup_ms:.1f} ms{off}")
    if s.run_ahead_frames:
        print(f"without run-ahead {s.raw_estimate_ms:.1f} ms; run-ahead hides "
              f"{s.run_ahead_frames} frame(s) of game lag")
    at = f" at {s.display_hz:.0f} Hz" if s.display_hz else ""
    gen = f", +{s.added_p95_ms:.1f} frame generation" if s.added_p95_ms else ""
    print(f"estimate {s.estimate_ms:.1f} ms (+{COMPOSITE_FRAMES} frames to composite{at}{gen}"
          f"{f', -{s.run_ahead_frames} run-ahead' if s.run_ahead_frames else ''}) "
          f"vs gate {GATE_MS:.0f} ms: {verdict}")
    return 0 if s.passed else 1


if __name__ == "__main__":
    sys.exit(main())
