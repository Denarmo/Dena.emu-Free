#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds panel-mipi firmware files (``panels/<compatible>.panel``).

The H700 handhelds' RGB panels are driven by the kernel's generic
``panel-mipi`` driver (os/image/linux/patches/0110-*), which reads the panel
timings and its init sequence from a firmware file. The binary layout is the
one documented at the top of ``drivers/gpu/drm/panel/panel-mipi.c``; we keep
each panel as readable JSON (``<compatible>.json``) and generate the binary at
build time. Spec: docs/specs/single-card.md.

Usage:
  panelgen.py build <json>... --out DIR     writes DIR/panels/<compatible>.panel
  panelgen.py decode <panel> [--compatible NAME]   prints the JSON source
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path

MAGIC = b"PANEL-FIRMWARE\x00"
VERSION = 1
# struct panel_firmware_config, big-endian, 56 bytes.
CONFIG = struct.Struct(">HHH2s8sHHHH8sHHII2sBB")
# struct panel_firmware_panel_timing, big-endian, 32 bytes.
TIMING = struct.Struct(">HHHHHHHHII8s")
TIMING_KEYS = ["hactive", "hfp", "hslen", "hbp", "vactive", "vfp", "vslen", "vbp", "dclk_khz", "flags"]
CONFIG_KEYS = ["width_mm", "height_mm", "rotation", "reset_delay", "init_delay", "sleep_delay",
               "backlight_delay", "dsi_lanes", "dsi_format", "dsi_mode_flags", "bus_flags",
               "preferred_timing"]


def encode(panel: dict) -> bytes:
    """JSON panel description -> firmware bytes."""
    c = panel["config"]
    timings = panel["timings"]
    if not timings:
        raise ValueError("a panel needs at least one timing")
    if not 0 <= c.get("preferred_timing", 0) < len(timings):
        raise ValueError("preferred_timing out of range")
    out = bytearray(MAGIC + bytes([VERSION]))
    out += CONFIG.pack(c["width_mm"], c["height_mm"], c.get("rotation", 0), b"\0" * 2, b"\0" * 8,
                       c.get("reset_delay", 0), c.get("init_delay", 0), c.get("sleep_delay", 0),
                       c.get("backlight_delay", 0), b"\0" * 8, c.get("dsi_lanes", 0),
                       c.get("dsi_format", 0), c.get("dsi_mode_flags", 0), c.get("bus_flags", 0),
                       b"\0" * 2, c.get("preferred_timing", 0), len(timings))
    for t in timings:
        out += TIMING.pack(*(t[k] for k in TIMING_KEYS[:8]), t["dclk_khz"], t.get("flags", 0), b"\0" * 8)
    out += encode_init(panel["init"])
    return bytes(out)


def encode_init(steps: list) -> bytes:
    """Init steps: "sleep <ms>" (a multiple of 10 ms) or "<cmd> <arg>..." in hex."""
    out = bytearray()
    for step in steps:
        words = step.split()
        if words[0] == "sleep":
            ms = int(words[1])
            if ms % 10:
                raise ValueError(f"sleep {ms} ms: only multiples of 10 ms can be encoded")
            out += b"\x80" * (ms // 100) + b"\x00" * ((ms % 100) // 10)
            continue
        data = bytes(int(x, 16) for x in words)
        if not 1 <= len(data) <= 0x7F:
            raise ValueError(f"command {step!r} must have 1-127 bytes")
        out += bytes([len(data)]) + data
    return bytes(out)


def decode(blob: bytes) -> dict:
    """Firmware bytes -> JSON panel description (inverse of encode)."""
    if blob[:15] != MAGIC or blob[15] != VERSION:
        raise ValueError("not a version 1 panel-mipi firmware file")
    off = 16
    f = CONFIG.unpack_from(blob, off)
    off += CONFIG.size
    config = dict(zip(CONFIG_KEYS, [f[0], f[1], f[2], f[5], f[6], f[7], f[8], f[10], f[11], f[12], f[13], f[15]]))
    timings = []
    for _ in range(f[16]):
        t = TIMING.unpack_from(blob, off)
        off += TIMING.size
        timings.append(dict(zip(TIMING_KEYS, t[:10])))
    init, sleep = [], 0
    while off < len(blob):
        inst = blob[off]
        off += 1
        if inst & 0x7F == 0:
            sleep += 100 if inst & 0x80 else 10
            continue
        if inst & 0x80:
            raise ValueError(f"reserved instruction 0x{inst:02x}")
        if sleep:
            init.append(f"sleep {sleep}")
            sleep = 0
        if off + inst > len(blob):
            raise ValueError("truncated command")
        init.append(" ".join(f"{b:02x}" for b in blob[off:off + inst]))
        off += inst
    if sleep:
        init.append(f"sleep {sleep}")
    return {"config": config, "timings": timings, "init": init}


def dumps(panel: dict) -> str:
    """JSON with one timing and one init step per line."""
    text = json.dumps(panel, indent=1)
    # Collapse the small objects and the init strings onto single lines.
    text = re.sub(r"\{\n\s+(\"hactive[^}]*)\n\s+\}", lambda m: "{" + re.sub(r"\s*\n\s*", " ", m.group(1)) + "}", text)
    return text


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("json", nargs="+", type=Path)
    b.add_argument("--out", type=Path, required=True)
    d = sub.add_parser("decode")
    d.add_argument("panel", type=Path)
    d.add_argument("--compatible")
    args = ap.parse_args(argv)
    if args.cmd == "build":
        dest = args.out / "panels"
        dest.mkdir(parents=True, exist_ok=True)
        for src in args.json:
            panel = json.loads(src.read_text(encoding="utf-8"))
            (dest / f"{panel['compatible']}.panel").write_bytes(encode(panel))
        return 0
    panel = decode(args.panel.read_bytes())
    name = args.compatible or args.panel.name.removesuffix(".panel")
    print(dumps({"compatible": name, **panel}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
