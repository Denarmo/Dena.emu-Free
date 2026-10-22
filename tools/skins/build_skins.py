#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the bundled console-style `.deltaskin` files (docs/specs/skins.md, 8c).

All artwork is drawn here from plain shapes: no logos, brand names, trademarks
or traced official art. Each skin evokes its console through colour palette,
button layout and button shapes only.

Usage: python3 tools/skins/build_skins.py [--previews DIR]
Writes app/assets/skins/<id>.deltaskin. Needs Pillow and NumPy.
"""
from __future__ import annotations

import argparse
import io
import json
import math
import os
import sys
import zipfile
from dataclasses import dataclass, field

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "app", "assets", "skins")

# Pixels per mapping point in the shipped PNGs (Delta's "large" tier is 3x),
# and the supersampling factor used while drawing.
SCALE = 3
SS = 2

# Mapping sizes in points: (device display type, orientation) -> (w, h).
REPRESENTATIONS = {
    ("standard", "portrait"): (414, 736),
    ("edgeToEdge", "portrait"): (414, 896),
    ("standard", "landscape"): (736, 414),
    ("edgeToEdge", "landscape"): (896, 414),
}

FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
]


def font(px: float) -> ImageFont.FreeTypeFont:
    for path in FONT_PATHS:
        if os.path.exists(path):
            return ImageFont.truetype(path, max(1, int(px)))
    return ImageFont.load_default(size=max(1, int(px)))


# ---------------------------------------------------------------- geometry


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float

    @staticmethod
    def centered(cx: float, cy: float, w: float, h: float | None = None) -> "Rect":
        h = w if h is None else h
        return Rect(cx - w / 2, cy - h / 2, w, h)

    @property
    def cx(self) -> float:
        return self.x + self.w / 2

    @property
    def cy(self) -> float:
        return self.y + self.h / 2

    @property
    def right(self) -> float:
        return self.x + self.w

    @property
    def bottom(self) -> float:
        return self.y + self.h

    def inflate(self, d: float) -> "Rect":
        return Rect(self.x - d, self.y - d, self.w + 2 * d, self.h + 2 * d)

    def overlaps(self, o: "Rect") -> bool:
        return (
            self.x < o.right and o.x < self.right and self.y < o.bottom and o.y < self.bottom
        )

    def json(self) -> dict:
        return {k: round(v, 2) for k, v in
                (("x", self.x), ("y", self.y), ("width", self.w), ("height", self.h))}


@dataclass
class Item:
    role: str  # drawing role: dpad, stick, face, shoulder, pill, menu, cbutton, ...
    frame: Rect
    inputs: object  # list of names, or a direction map for dpad / thumbstick
    label: str = ""
    style: dict = field(default_factory=dict)
    thumbstick: bool = False


@dataclass
class Layout:
    width: float
    height: float
    landscape: bool
    screen: Rect
    bezel: Rect | None
    controls_top: float
    items: list[Item]
    # The console shell. Edges that meet the screen's edges run past the
    # canvas, so the art fills the screen without rounded corners there.
    body: Rect
    body_radius: float


# How far the shell runs past the canvas where it meets the screen's edges.
BLEED = 60

DPAD_INPUTS = {"up": "up", "down": "down", "left": "left", "right": "right"}
STICK_INPUTS = {
    "up": "analogStickUp",
    "down": "analogStickDown",
    "left": "analogStickLeft",
    "right": "analogStickRight",
}

# ---------------------------------------------------------------- skin specs


@dataclass
class Skin:
    key: str
    name: str
    game_type: str  # last segment of gameTypeIdentifier
    systems: list[str]  # our system ids this skin becomes the default for
    aspect: float
    handheld: bool  # screen in a bezel (handheld) or edge-to-edge TV (home)
    face: str  # face-button arrangement
    shoulders: str = "none"  # none | lr | lr2
    select: bool = True
    palette: dict = field(default_factory=dict)
    # Plastics (all optional): texture = rough shell bumps (0..1); metallic =
    # sparkle and gloss (0..1); clear_shell / clear_keys / clear_shoulders =
    # see-through plastic; grip = cross-hatched analog nub.
    material: dict = field(default_factory=dict)
    model: str = ""  # the console this skin is drawn as; defaults to key

    def __post_init__(self):
        self.model = self.model or self.key


C = lambda h: tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))  # noqa: E731

SKINS = [
    Skin(
        "nes", "Graphite Brick", "nes", ["nes"], 4 / 3, False, "pair_flat",
        palette=dict(body=C("#cfccc6"), body2=C("#bdbab3"), plate=C("#2a2a2c"),
                     stripe=C("#8b8984"), dpad=C("#18181a"), socket=C("#dcd9d2"),
                     face=C("#c42433"), label=C("#c42433"), pill=C("#1d1d1f"),
                     top=C("#101012")),
    ),
    Skin(
        "snes", "Four Color Pad", "snes", ["snes"], 4 / 3, False, "diamond",
        shoulders="lr",
        palette=dict(body=C("#cdccd3"), body2=C("#b9b8c1"), dish=C("#b3b2bb"),
                     dpad=C("#3a3a40"), x=C("#3651b0"), a=C("#c42f3b"),
                     b=C("#e0b31f"), y=C("#2e9650"), shoulder=C("#a3a2ab"),
                     pill=C("#5d5c64"), label=C("#5d5c66"), top=C("#101012"),
                     plate=C("#77767f"), tray=C("#c3c2ca"), plate_text=C("#dcdbe2")),
    ),
    Skin(
        "gb", "Pocket Classic", "gbc", ["gb"], 10 / 9, True, "pair_diag",
        palette=dict(body=C("#c9c5bb"), body2=C("#bbb7ac"), bezel=C("#5c5e6c"),
                     bezel_line=C("#4a4c58"), dpad=C("#1c1c1f"), face=C("#9b2a5d"),
                     pill=C("#8a8a90"), label=C("#3c3a72"), grille=C("#a8a49a"),
                     led=C("#d83a2e")),
        material=dict(texture=1.0),
    ),
    Skin(
        "gbc", "Pocket Grape", "gbc", ["gbc"], 10 / 9, True, "pair_diag",
        palette=dict(body=C("#6a4b9e"), body2=C("#5a3e8a"), bezel=C("#1f1d26"),
                     bezel_line=C("#2c2935"), dpad=C("#2a2238"), face=C("#3d2f58"),
                     pill=C("#7d7a86"), label=C("#d9d2ec"), grille=C("#4d3676"),
                     led=C("#e65a3a"), circuit=(210, 190, 255)),
        material=dict(texture=0.4, clear_shell=True),
    ),
    Skin(
        "gba", "Indigo Wide", "gba", ["gba"], 3 / 2, True, "pair_diag",
        shoulders="lr",
        palette=dict(body=C("#4b3f98"), body2=C("#3f3484"), bezel=C("#17171c"),
                     bezel_line=C("#2b2b33"), dpad=C("#2b2b31"), face=C("#c9c9d0"),
                     face_text=C("#4b3f98"), pill=C("#c9c9d0"), label=C("#c7c2ee"),
                     shoulder=C("#5a4fae"), grille=C("#362c74"), led=C("#5fd36b")),
    ),
    Skin(
        "n64", "Three Grip", "n64", ["n64"], 4 / 3, False, "n64", shoulders="lr",
        select=False,
        palette=dict(body=C("#a2a4a8"), body2=C("#8f9196"), dish=C("#7f8186"),
                     stick=C("#b9bbbf"), gate=C("#2d2e31"), a=C("#2f4fb4"),
                     b=C("#2c9a4c"), c=C("#e7c11c"), c_text=C("#4b3e05"),
                     start=C("#c2262f"), z=C("#3b3c40"), shoulder=C("#8b8d92"),
                     label=C("#3d3e43"), top=C("#101012")),
    ),
    Skin(
        "nds", "Dual Slate", "ds", ["nds"], 256 / 384, True, "diamond",
        shoulders="lr",
        palette=dict(body=C("#2c3037"), body2=C("#23262c"), bezel=C("#16181c"),
                     bezel_line=C("#3a3f48"), dpad=C("#15171a"), face=C("#d9dbe0"),
                     face_text=C("#2c3037"), pill=C("#d9dbe0"), label=C("#9aa1ad"),
                     shoulder=C("#3a3f48"), hinge=C("#1b1d22"), led=C("#43c2ff")),
    ),
    Skin(
        "psx", "Gray Disc Pad", "psx", ["psx"], 4 / 3, False, "shapes",
        shoulders="lr2",
        palette=dict(body=C("#c8c8c5"), body2=C("#b4b4b1"), dish=C("#b7b7b3"),
                     dpad=C("#4b4b4e"), face=C("#4b4b4e"), tri=C("#35b48c"),
                     cir=C("#e2535b"), crs=C("#7096dc"), sqr=C("#dc8cc4"),
                     shoulder=C("#9c9c9a"), pill=C("#5a5a5d"), label=C("#6a6a6c"),
                     top=C("#101012")),
    ),
    Skin(
        "psp", "Gloss Black Portable", "psp", ["psp"], 480 / 272, True, "shapes_mono",
        shoulders="lr",
        palette=dict(body=C("#141518"), body2=C("#0c0d0f"), bezel=C("#08090a"),
                     bezel_line=C("#55585f"), dpad=C("#26272b"), face=C("#26272b"),
                     symbol=C("#c9ccd3"), stick=C("#8d9097"), pill=C("#b8bbc2"),
                     label=C("#7e828b"), shoulder=C("#c9ced6"), sheen=(255, 255, 255)),
        material=dict(clear_shoulders=True, grip=True),
    ),
    Skin(
        "pico8", "Pixel Cart", "pico8", ["pico8"], 1.0, True, "pico", select=False,
        palette=dict(body=C("#1d2b53"), body2=C("#253666"), bezel=C("#000000"),
                     bezel_line=C("#5f574f"), shadow=C("#0b1024"), dpad=C("#5f574f"),
                     pip=C("#c2c3c7"), o=C("#ff004d"), x=C("#29adff"),
                     glyph=C("#fff1e8"), label=C("#ffa300"), pill=C("#7e2553"),
                     led=C("#00e436")),
    ),
]


def variant(base_key: str, key: str, name: str, material=None, **colors) -> Skin:
    """An alternate edition: the same console drawn in other colours and
    plastics (our own palettes; no logos or names from any real edition)."""
    base = next(s for s in SKINS if s.key == base_key)
    return Skin(base.key + "_" + key, name, base.game_type, [], base.aspect, base.handheld,
                base.face, base.shoulders, base.select,
                {**base.palette, **{k: C(v) if isinstance(v, str) else v
                                    for k, v in colors.items()}},
                {**base.material, **(material or {})}, base.model)


SKINS += [
    variant("nes", "cream", "Cream & Crimson", body="#e8e1cf", body2="#d6cdb8",
            plate="#8c1d2a", stripe="#c8a55a", label="#e9cf8a", socket="#efe9da"),
    variant("snes", "lavender", "Lavender Concave", body="#cfced6", body2="#bdbcc6",
            x="#b4a7dc", y="#b4a7dc", a="#4b3a8f", b="#4b3a8f", plate="#6e6b7d",
            tray="#bab8c6"),
    variant("gb", "clear", "Clear Pocket", dict(texture=0.3, clear_shell=True),
            body="#d9dfe1", body2="#c3cbce", circuit=(90, 120, 110), grille="#b9c2c5"),
    variant("gb", "sunshine", "Pocket Sunshine", body="#f2c512", body2="#dcae08",
            face="#2b2b30", label="#2b2b30", grille="#cf9f05", pill="#6a6a70"),
    variant("gbc", "teal", "Pocket Teal", dict(clear_shell=False), body="#15a3a6",
            body2="#0f8b8e", face="#0d5c5e", dpad="#0e3b3c", label="#e3fbfb",
            grille="#0a6c6e"),
    variant("gbc", "berry", "Pocket Berry", dict(clear_shell=False), body="#c41f4e",
            body2="#a7173e", face="#6b0f27", dpad="#45091a", label="#ffe1e9",
            grille="#87122f"),
    variant("gbc", "dandelion", "Pocket Dandelion", dict(clear_shell=False),
            body="#f2c21c", body2="#dbab0e", face="#3a3a3f", dpad="#2a2a2e",
            label="#3a3a3f", grille="#c89a08"),
    variant("gba", "glacier", "Glacier Wide", dict(clear_shell=True), body="#a7d2e9",
            body2="#8bbdd9", face="#eef3f7", face_text="#3a7aa1", shoulder="#b9dcee",
            label="#2b5a77", grille="#7fb0cc", circuit=(40, 90, 120)),
    variant("gba", "fuchsia", "Fuchsia Wide", dict(clear_shell=True), body="#c3227a",
            body2="#a41a65", face="#ececf0", face_text="#c3227a", shoulder="#d2448f",
            label="#ffd6ea", grille="#8f1556", circuit=(255, 190, 225)),
    variant("n64", "smoke", "Smoke Grip", dict(clear_shell=True), body="#43464c",
            body2="#33353a", dish="#2b2c30", stick="#71747a", shoulder="#55585e",
            z="#26272b", label="#c6c8ce", circuit=(160, 170, 185)),
    variant("n64", "jungle", "Jungle Grip", dict(clear_shell=True), body="#2f6c4b",
            body2="#245a3d", dish="#204a33", stick="#a3bcad", shoulder="#3d7c59",
            label="#d9f0e3", circuit=(170, 230, 190)),
    variant("nds", "polar", "Polar Dual", dict(metallic=0.25), body="#eef0f3",
            body2="#d8dbe1", dpad="#2c2f35", face="#f7f8fa", face_text="#4a4f58",
            pill="#f7f8fa", label="#7a808b", shoulder="#dfe2e7", hinge="#c7cad1",
            bezel_line="#5a5f68"),
    variant("nds", "ice", "Ice Dual", dict(metallic=0.25), body="#b6d8ee",
            body2="#9bc6e2", dpad="#2c3a46", face="#f3f8fb", face_text="#3e7ca7",
            pill="#f3f8fb", label="#3d6b8a", shoulder="#a6cee8", hinge="#8db8d4",
            bezel_line="#5b7f99"),
    variant("psx", "midnight", "Midnight Pad", body="#2b2c2f", body2="#1f2023",
            dish="#232427", dpad="#3d3e42", face="#3d3e42", shoulder="#3b3c40",
            pill="#4b4c50", label="#9b9ca1"),
    variant("psp", "blue", "Vibrant Blue Portable", dict(clear_keys=True, metallic=1.0),
            body="#1b90d8", body2="#0f6eb0", dpad="#1576bd", face="#1576bd",
            symbol="#c4e6fb", stick="#0f5e95", pill="#47a7e3", label="#d3eefc",
            shoulder="#c9ced6"),
    variant("psp", "white", "Ceramic White Portable", dict(clear_keys=True, metallic=0.5),
            body="#f1f1ef", body2="#dadad8", dpad="#e6e6e4", face="#e6e6e4",
            symbol="#8f939a", stick="#d4d4d2", pill="#dcdcda", label="#8a8d92",
            shoulder="#d9dde3"),
    variant("psp", "red", "Radiant Red Portable", dict(clear_keys=True, metallic=1.0),
            body="#c5171d", body2="#9b0f14", dpad="#b11419", face="#b11419",
            symbol="#ffd0d2", stick="#7c0b0f", pill="#de4247", label="#ffd5d7",
            shoulder="#c9ced6"),
]

# ---------------------------------------------------------------- layout


def layout(skin: Skin, w: float, h: float, landscape: bool) -> Layout:
    items: list[Item] = []
    bezel = None
    if not landscape:
        if skin.handheld:
            pad, bottom_pad = (16, 28) if skin.model in ("gb", "gbc") else (14, 14)
            margin = 12
            avail_w = w - 2 * (margin + pad)
            frac = 0.56 if skin.model == "nds" else 0.47
            sh = min(avail_w / skin.aspect, h * frac)
            sw = sh * skin.aspect
            top = 16
            screen = Rect((w - sw) / 2, top + pad, sw, sh)
            bezel = Rect(margin, top, w - 2 * margin, sh + pad + bottom_pad)
            ct = bezel.bottom + 6
        else:
            sw = w
            sh = min(sw / skin.aspect, h * 0.45)
            sw = sh * skin.aspect
            screen = Rect((w - sw) / 2, 0, sw, sh)
            ct = sh + 8
        area = h - ct
        d = min(w * 0.34, area * 0.42, 150)
        cy = ct + area * {"psp": 0.34, "nds": 0.46}.get(skin.model, 0.4)
        left = (w * 0.25, cy)
        right = (w * 0.75, cy)
        sh_w, sh_h = min(w * 0.26, 116), 32
        shoulder_y = ct + 10
        pill_w, pill_h = 62, 22
        pill_y = min(h - pill_h - 24, cy + d * 0.5 + max(70, area * 0.2))
        select_at = Rect(w / 2 - pill_w - 14, pill_y, pill_w, pill_h)
        start_at = Rect(w / 2 + 14, pill_y, pill_w, pill_h)
        menu_at = Rect.centered(w / 2, ct + 28, 34)
        if skin.handheld:
            body, body_r = Rect(-BLEED, -BLEED, w + 2 * BLEED, h + 2 * BLEED), 30
        else:
            # The pad under the picture: flat top, sides and bottom bleed.
            body, body_r = Rect(-BLEED, ct, w + 2 * BLEED, h - ct + BLEED), 40
            shoulder_y = body.y
        # Bumpers are moulded into the shell, flush with the screen's edges.
        lshoulder = Rect(0, shoulder_y, sh_w, sh_h)
        rshoulder = Rect(w - sh_w, shoulder_y, sh_w, sh_h)
    else:
        side = min(max((w - (h - 28) * skin.aspect) / 2, 150), 230)
        pad = 10 if skin.handheld else 6
        sh = min(h - 28, (w - 2 * side - 2 * pad) / skin.aspect)
        sw = sh * skin.aspect
        screen = Rect((w - sw) / 2, (h - sh) / 2, sw, sh)
        bezel = screen.inflate(pad) if skin.handheld else None
        ct = 0
        d = min(side * 0.72, 128)
        cy = h * (0.44 if skin.model == "psp" else 0.56)
        left = (side / 2 + 2, cy)
        right = (w - side / 2 - 2, cy)
        body, body_r = Rect(-BLEED, -BLEED, w + 2 * BLEED, h + 2 * BLEED), 30
        sh_w, sh_h = side - 14, 32
        lshoulder = Rect(0, 0, sh_w, sh_h)
        rshoulder = Rect(w - sh_w, 0, sh_w, sh_h)
        pill_w, pill_h = 62, 22
        select_at = Rect(left[0] - pill_w / 2, h - pill_h - 20, pill_w, pill_h)
        start_at = Rect(right[0] - pill_w / 2, h - pill_h - 20, pill_w, pill_h)
        menu_at = Rect.centered(left[0], 70, 32)

    # Left cluster: D-pad, or the N64 stick.
    if skin.model == "n64":
        items.append(Item("stick", Rect.centered(*left, d * 0.9), STICK_INPUTS,
                          thumbstick=True))
    else:
        items.append(Item("dpad", Rect.centered(*left, d), DPAD_INPUTS))
    if skin.model == "psp":
        s = d * 0.42
        # Well clear of the D-pad so a thumb on one doesn't catch the other.
        at = (left[0] - d * 0.1, left[1] + d * 1.02)
        items.append(Item("nub", Rect.centered(*at, s), STICK_INPUTS, thumbstick=True))

    # Face buttons.
    cx, cy = right
    if skin.face in ("diamond", "shapes", "shapes_mono"):
        f = d * 0.38
        k = f * 1.08
        pos = {"x": (0, -k), "y": (-k, 0), "a": (k, 0), "b": (0, k)}
        labels = {"diamond": {"x": "X", "y": "Y", "a": "A", "b": "B"}}.get(
            skin.face, {"x": "tri", "y": "sqr", "a": "cir", "b": "crs"})
        for inp, (dx, dy) in pos.items():
            items.append(Item("face", Rect.centered(cx + dx, cy + dy, f), [inp],
                              labels[inp], {"key": inp}))
    elif skin.face == "pair_flat":
        g = d * 0.42
        for inp, dx, lab in (("b", -0.62, "B"), ("a", 0.62, "A")):
            items.append(Item("face", Rect.centered(cx + dx * g * 1.25, cy, g), [inp],
                              lab, {"key": inp}))
    elif skin.face == "pair_diag":
        g = d * 0.44
        for inp, dx, dy, lab in (("b", -0.68, 0.36, "B"), ("a", 0.68, -0.36, "A")):
            items.append(Item("face", Rect.centered(cx + dx * g * 1.2, cy + dy * g * 1.2, g),
                              [inp], lab, {"key": inp}))
    elif skin.face == "pico":
        # PICO-8: O on RetroPad B, X on A (pico8.md), placed like pair_diag.
        g = d * 0.44
        for inp, dx, dy, lab in (("b", -0.68, 0.36, "O"), ("a", 0.68, -0.36, "X")):
            items.append(Item("face", Rect.centered(cx + dx * g * 1.2, cy + dy * g * 1.2, g),
                              [inp], lab, {"key": inp}))
    elif skin.face == "n64":
        f = d * 0.42
        items.append(Item("face", Rect.centered(cx + 0.35 * f, cy + 0.75 * f, f * 1.05),
                          ["a"], "A", {"key": "a"}))
        items.append(Item("face", Rect.centered(cx - 0.8 * f, cy + 0.15 * f, f * 0.95),
                          ["b"], "B", {"key": "b"}))
        c = f * 0.6
        cc = (cx + 0.45 * f, cy - 1.12 * f)
        for inp, dx, dy, lab in (("cUp", 0, -1, "up"), ("cDown", 0, 1, "down"),
                                 ("cLeft", -1, 0, "left"), ("cRight", 1, 0, "right")):
            items.append(Item("cbutton", Rect.centered(cc[0] + dx * c * 1.15,
                                                       cc[1] + dy * c * 1.15, c),
                              [inp], lab))

    # Shoulders.
    if skin.shoulders == "lr":
        items.append(Item("shoulder", lshoulder, ["l"], "L"))
        items.append(Item("shoulder", rshoulder, ["r"], "R"))
    elif skin.shoulders == "lr2":
        half = (lshoulder.w - 4) / 2
        items.append(Item("shoulder", Rect(lshoulder.x, lshoulder.y, half, lshoulder.h),
                          ["l2"], "L2"))
        items.append(Item("shoulder", Rect(lshoulder.x + half + 4, lshoulder.y, half,
                                           lshoulder.h), ["l"], "L1"))
        items.append(Item("shoulder", Rect(rshoulder.x, rshoulder.y, half, rshoulder.h),
                          ["r"], "R1"))
        items.append(Item("shoulder", Rect(rshoulder.x + half + 4, rshoulder.y, half,
                                           rshoulder.h), ["r2"], "R2"))
    if skin.model == "n64":
        z = Rect(lshoulder.x, lshoulder.bottom + 10, lshoulder.w * 0.62, 30)
        items.append(Item("z", z, ["z"], "Z"))

    # Select / Start, menu.
    if skin.select:
        items.append(Item("pill", select_at, ["select"], "SELECT"))
        items.append(Item("pill", start_at, ["start"], "START"))
    elif skin.model == "pico8":
        # No Select; Start is the cart's pause menu, centred.
        items.append(Item("pill", Rect.centered(w / 2 if not landscape else start_at.cx,
                                                start_at.cy, start_at.w, start_at.h),
                          ["start"], "PAUSE"))
    else:
        start = Rect(start_at.x - start_at.w / 2 - 7, start_at.y, start_at.w, start_at.h) \
            if not landscape else start_at
        start = Rect.centered(start.cx, start.cy, 34) if skin.model == "n64" else start
        items.append(Item("start_round", start, ["start"], "START"))
    if skin.model == "n64" and landscape:
        menu_at = Rect.centered(left[0], select_at.cy - 4, 32)
    items.append(Item("menu", menu_at, ["menu"]))

    return Layout(w, h, landscape, screen, bezel, ct, items, body, body_r)


def validate(skin: Skin, lay: Layout, where: str) -> list[str]:
    errs = []
    bounds = Rect(0, 0, lay.width, lay.height)
    keep_clear = lay.screen
    for i, it in enumerate(lay.items):
        f = it.frame
        if f.x < 0 or f.y < 0 or f.right > bounds.right or f.bottom > bounds.bottom:
            errs.append(f"{where}: {it.role} {it.inputs} out of bounds")
        if f.overlaps(keep_clear):
            errs.append(f"{where}: {it.role} {it.inputs} covers the screen")
        for o in lay.items[i + 1:]:
            if f.overlaps(o.frame):
                errs.append(f"{where}: {it.role} {it.inputs} overlaps {o.role} {o.inputs}")
    if abs(lay.screen.w / lay.screen.h - skin.aspect) > 0.01:
        errs.append(f"{where}: screen aspect {lay.screen.w / lay.screen.h:.3f}")
    return errs


# ---------------------------------------------------------------- drawing
# Every part is shaded from a height map: its outline gives a bevel profile,
# the profile's slope gives surface normals, and a key light from the top left
# plus a soft fill light and a specular term turn those into moulded plastic.
# Recesses (sockets, dishes, slots) are the same with the height inverted.


def _norm(v):
    v = np.asarray(v, dtype=np.float32)
    return v / np.linalg.norm(v)


GRAIN = 0.0
LIGHT = _norm((-0.42, -0.62, 0.66))
FILL = _norm((0.15, -0.3, 0.94))
HALF = _norm(LIGHT + np.array((0, 0, 1), dtype=np.float32))


def _box(a: np.ndarray, r: int, axis: int) -> np.ndarray:
    pad = [(0, 0), (0, 0)]
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis, dtype=np.float64)
    hi = np.take(c, range(2 * r + 1, c.shape[axis]), axis=axis)
    lo = np.take(c, range(0, c.shape[axis] - 2 * r - 1), axis=axis)
    return ((hi - lo) / (2 * r + 1)).astype(np.float32)


def blur(a: np.ndarray, sigma: float) -> np.ndarray:
    """Gaussian blur approximated by three box passes per axis."""
    if sigma < 0.5:
        return a
    r = max(1, int(round((math.sqrt(4 * sigma * sigma + 1) - 1) / 2)))
    for axis in (0, 1):
        for _ in range(3):
            a = _box(a, r, axis)
    return a


def shift(a: np.ndarray, dx: int, dy: int) -> np.ndarray:
    out = np.zeros_like(a)
    h, w = a.shape
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    out[yd, xd] = a[ys, xs]
    return out


def height(m: np.ndarray, bevel: float, profile: str = "round") -> np.ndarray:
    """0 at the outline rising to 1 about [bevel] px inside it."""
    t = np.clip((blur(m, bevel / 2) - 0.5) * 2, 0, 1) * (m > 0.5)
    if profile == "round":
        return np.sqrt(1 - (1 - t) ** 2)
    return t * t * (3 - 2 * t)  # "soft"


def light(h: np.ndarray, depth: float, base, gloss: float = 0.3, shin: float = 30,
          amb: float = 0.4) -> np.ndarray:
    """RGB (0..1) for a surface of colour [base] with heights [h] (depth px)."""
    gy, gx = np.gradient(h * depth)
    n = np.stack([-gx, -gy, np.ones_like(h)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    diff = np.clip(n @ LIGHT, 0, 1)
    fill = np.clip(n @ FILL, 0, 1)
    kd = (1 - amb) * 0.8 / LIGHT[2]
    kf = (1 - amb) * 0.2 / FILL[2]
    lum = amb + kd * diff + kf * fill
    nh = np.clip(n @ HALF, 0, 1)
    spec = gloss * nh ** shin + gloss * 0.18 * nh ** 4
    # Contact darkening where the part meets the shell.
    ao = 0.84 + 0.16 * np.clip(np.abs(h) * 1.6, 0, 1)
    col = np.asarray(base[:3], dtype=np.float32) / 255
    rgb = col[None, None, :] * (lum * ao)[..., None] + spec[..., None] * 0.9
    return np.clip(rgb, 0, 1)


class Painter:
    """Draws in mapping points onto a supersampled RGBA canvas, part by part
    in small regions so the shading stays cheap."""

    def __init__(self, w: float, h: float):
        self.k = SCALE * SS
        self.img = Image.new("RGBA", (round(w * self.k), round(h * self.k)), (0, 0, 0, 0))
        self.ox = self.oy = 0
        self.rw, self.rh = self.img.size

    def p(self, v: float) -> int:
        return round(v * self.k)

    def px(self, x: float) -> int:
        return round(x * self.k) - self.ox

    def py(self, y: float) -> int:
        return round(y * self.k) - self.oy

    def box(self, r: Rect) -> tuple[int, int, int, int]:
        return (self.px(r.x), self.py(r.y), self.px(r.right), self.py(r.bottom))

    def pts(self, pts):
        return [(self.px(x), self.py(y)) for x, y in pts]

    def region(self, r: Rect, margin: float) -> None:
        """Later masks and puts work in [r] grown by [margin] points."""
        x0 = max(0, self.p(r.x - margin))
        y0 = max(0, self.p(r.y - margin))
        x1 = min(self.img.width, self.p(r.right + margin))
        y1 = min(self.img.height, self.p(r.bottom + margin))
        self.ox, self.oy, self.rw, self.rh = x0, y0, max(1, x1 - x0), max(1, y1 - y0)

    def mask(self, shape) -> np.ndarray:
        m = Image.new("L", (self.rw, self.rh), 0)
        shape(ImageDraw.Draw(m), 255)
        return np.asarray(m, dtype=np.float32) / 255

    def put(self, rgb: np.ndarray, alpha: np.ndarray) -> None:
        a = np.clip(alpha, 0, 1)
        layer = np.concatenate([rgb, a[..., None]], axis=-1)
        im = Image.fromarray((layer * 255 + 0.5).astype(np.uint8), "RGBA")
        box = (self.ox, self.oy, self.ox + self.rw, self.oy + self.rh)
        self.img.paste(Image.alpha_composite(self.img.crop(box), im), box)

    def put_color(self, color, alpha: np.ndarray) -> None:
        rgb = np.broadcast_to(np.asarray(color[:3], np.float32) / 255,
                              alpha.shape + (3,))
        self.put(rgb, alpha)

    def shadow(self, m: np.ndarray, size: float, strength: float = 1.0) -> None:
        """A tight contact shadow and a soft cast one, down and to the right."""
        k = self.k
        contact = blur(shift(m, round(0.3 * k), round(0.7 * k)), 0.9 * k)
        cast = blur(shift(m, round(size * 0.05 * k), round(size * 0.1 * k)),
                    max(1.0, size * 0.09) * k)
        a = 1 - (1 - contact * 0.5 * strength) * (1 - cast * 0.32 * strength)
        self.put_color((0, 0, 0), a * (1 - m))

    def grain(self, amount: float, alpha_from: np.ndarray | None = None) -> None:
        """Fine moulding texture over the current region (off unless GRAIN is
        set: per-pixel noise makes the PNGs about ten times larger)."""
        amount *= GRAIN
        if not amount:
            return
        box = (self.ox, self.oy, self.ox + self.rw, self.oy + self.rh)
        crop = np.asarray(self.img.crop(box), dtype=np.float32)
        rng = np.random.default_rng(1234 + self.ox * 7 + self.oy)
        noise = rng.normal(0, 1, (self.rh // 2 + 1, self.rw // 2 + 1)).astype(np.float32)
        noise = np.asarray(Image.fromarray(noise, "F").resize((self.rw, self.rh),
                                                            Image.BILINEAR))
        f = 1 + noise * amount
        if alpha_from is not None:
            f = 1 + (f - 1) * alpha_from
        crop[..., :3] = np.clip(crop[..., :3] * f[..., None], 0, 255)
        self.img.paste(Image.fromarray(crop.astype(np.uint8), "RGBA"), box)

    def text_mask(self, cx: float, cy: float, s: str, size: float, rotate: float = 0):
        f = font(size * self.k)
        bb = f.getbbox(s)
        t = Image.new("L", (bb[2] - bb[0] + 8, bb[3] - bb[1] + 8), 0)
        ImageDraw.Draw(t).text((4 - bb[0], 4 - bb[1]), s, font=f, fill=255)
        if rotate:
            t = t.rotate(rotate, resample=Image.BICUBIC, expand=True)
        m = Image.new("L", (self.rw, self.rh), 0)
        m.paste(t, (self.px(cx) - t.width // 2, self.py(cy) - t.height // 2))
        return np.asarray(m, dtype=np.float32) / 255

    def result(self) -> Image.Image:
        return self.img.resize((self.img.width // SS, self.img.height // SS), Image.LANCZOS)


def _rgba(c) -> tuple[int, int, int, int]:
    return tuple(c) + (255,) if len(c) == 3 else tuple(c)


def shade(c, f: float):
    """Lightens (f > 0) or darkens (f < 0) an RGB colour."""
    if f >= 0:
        return tuple(round(v + (255 - v) * f) for v in c[:3])
    return tuple(round(v * (1 + f)) for v in c[:3])


def rrect(P: Painter, r: Rect, rad: float):
    return lambda d, v: d.rounded_rectangle(P.box(r), radius=P.p(rad), fill=v)


def ellipse(P: Painter, r: Rect):
    return lambda d, v: d.ellipse(P.box(r), fill=v)


def poly(P: Painter, pts):
    return lambda d, v: d.polygon(P.pts(pts), fill=v)


def raised(P: Painter, shape, r: Rect, color, *, bevel: float, depth: float = 6,
           gloss: float = 0.35, shin: float = 40, profile: str = "round",
           details=(), shadow: float = 1.0, grain: float = 0.0, clear: float = 0.0,
           bump=None):
    """A moulded part standing out of the shell. [bevel]/[depth] in points;
    [details] are (shape, height change, bevel) added on top (negative for
    engraving)."""
    P.region(r, max(r.w, r.h) * 0.25 + 8)
    m = P.mask(shape)
    if shadow:
        P.shadow(m, max(r.w, r.h), shadow)
    h = height(m, bevel * P.k, profile)
    for dshape, dh, dbevel in details:
        dm = P.mask(dshape)
        h = h + dh * height(dm, dbevel * P.k, "soft")
    if bump is not None:
        h = h + bump(P, m)
    rgb = light(h, depth * P.k, color, gloss + clear * 0.3, shin)
    if clear:
        rgb, m = see_through(P, rgb, m, h, color, clear)
    P.put(rgb, m)
    if grain:
        P.grain(grain, m)
    return m


def see_through(P: Painter, rgb, m, h, color, clear: float):
    """Clear plastic: thinner (more see-through) at the edges, with light
    gathering along the lower inside edge as it does in a clear key."""
    yy = np.linspace(-1, 1, P.rh, dtype=np.float32)[:, None]
    ys = np.where(m > 0.5, yy, np.nan)
    with np.errstate(all="ignore"):
        top, bottom = np.nanmin(ys), np.nanmax(ys)
    t = np.clip((yy - top) / max(1e-3, bottom - top), 0, 1)
    rim = np.clip(1 - h, 0, 1) * t ** 2
    glow = np.asarray(shade(color, 0.55), np.float32) / 255
    rgb = rgb + glow[None, None, :] * (rim * 0.45 * clear)[..., None]
    alpha = m * (1 - clear * 0.55 * (1 - np.clip(h, 0, 1)) - clear * 0.18)
    return np.clip(rgb, 0, 1), alpha


def rough(amount: float, size: float = 0.45):
    """A bump map of fine random grain (spark-eroded plastic)."""
    def bump(P: Painter, m):
        rng = np.random.default_rng(7 + P.ox * 3 + P.oy)
        cell = max(1, round(size * P.k))
        n = rng.normal(0, 1, (P.rh // cell + 2, P.rw // cell + 2)).astype(np.float32)
        n = np.asarray(Image.fromarray(n, "F").resize(((P.rw // cell + 2) * cell,
                                                      (P.rh // cell + 2) * cell),
                                                     Image.BICUBIC))[:P.rh, :P.rw]
        return n * amount * m
    return bump


def crosshatch(cap: Rect, pitch: float = 1.7, amount: float = 0.09):
    """A grid of tiny pyramids on an analog cap's top, for grip."""
    def bump(P: Painter, m):
        x = (np.arange(P.rw, dtype=np.float32) + P.ox) / P.k
        y = (np.arange(P.rh, dtype=np.float32) + P.oy) / P.k
        gx = np.abs(((x / pitch) % 1) - 0.5)[None, :]
        gy = np.abs(((y / pitch) % 1) - 0.5)[:, None]
        g = (0.5 - np.maximum(gx, gy)) * 2  # 1 in the middle of each cell
        inner = P.mask(ellipse(P, cap.inflate(-cap.w * 0.12)))
        return blur(g, 0.25 * P.k) * amount * blur(inner, 1.5 * P.k)
    return bump


def recessed(P: Painter, shape, r: Rect, color, *, bevel: float, depth: float = 4,
             occlusion: float = 0.45, gloss: float = 0.08):
    """A dish or socket moulded into the shell."""
    P.region(r, 4)
    m = P.mask(shape)
    h = -height(m, bevel * P.k, "soft")
    rgb = light(h, depth * P.k, color, gloss, 12)
    # The rim shades the upper part of the hollow.
    occ = blur(shift(1 - m, round(0.8 * P.k), round(1.6 * P.k)), 1.6 * P.k) * m
    rgb *= (1 - occ * occlusion)[..., None]
    P.put(rgb, m)
    return m


def label(P: Painter, cx: float, cy: float, s: str, size: float, color,
          style: str = "print", rotate: float = 0):
    """Text printed on the shell, or engraved into a part."""
    P.region(Rect.centered(cx, cy, size * len(s) + 20, size * 3), 2)
    m = P.text_mask(cx, cy, s, size, rotate)
    if style == "engrave":
        P.put_color((255, 255, 255), shift(m, 0, round(0.6 * P.k)) * 0.28)
        P.put_color((0, 0, 0), shift(m, 0, -round(0.4 * P.k)) * 0.45)
    else:
        P.put_color((255, 255, 255), shift(m, 0, round(0.5 * P.k)) * 0.12)
    P.put_color(color, m)


def glyph(P: Painter, shape, r: Rect, color, style: str = "engrave"):
    """A printed or engraved mark (arrow, symbol) inside [r]."""
    P.region(r, 3)
    m = P.mask(shape)
    if style == "engrave":
        P.put_color((255, 255, 255), shift(m, 0, round(0.6 * P.k)) * 0.25)
        P.put_color((0, 0, 0), shift(m, 0, -round(0.4 * P.k)) * 0.4)
    P.put_color(color, m)


def triangle(cx, cy, s, direction):
    ang = {"up": -90, "down": 90, "left": 180, "right": 0}[direction]
    pts = []
    for a in (0, 140, 220):
        t = math.radians(ang + a)
        pts.append((cx + math.cos(t) * s, cy + math.sin(t) * s))
    return pts


def cross_pts(r: Rect, arm: float):
    a = arm / 2
    cx, cy = r.cx, r.cy
    return [
        (cx - a, r.y), (cx + a, r.y), (cx + a, cy - a), (r.right, cy - a),
        (r.right, cy + a), (cx + a, cy + a), (cx + a, r.bottom), (cx - a, r.bottom),
        (cx - a, cy + a), (r.x, cy + a), (r.x, cy - a), (cx - a, cy - a),
    ]


def stadium_pts(cx, cy, w, h, angle_deg=0.0, n=16):
    hw, hh = w / 2, h / 2
    ang = math.radians(angle_deg)
    pts = []
    for side, ox in ((0, hw - hh), (1, -hw + hh)):
        for i in range(n + 1):
            t = -math.pi / 2 + math.pi * i / n + side * math.pi
            x, y = ox + math.cos(t) * hh, math.sin(t) * hh
            pts.append((cx + x * math.cos(ang) - y * math.sin(ang),
                        cy + x * math.sin(ang) + y * math.cos(ang)))
    return pts


# ---------------------------------------------------------------- per-part art


def body_mask(P: Painter, skin: Skin, lay: Layout) -> np.ndarray:
    """The shell outline over the whole canvas, with every corner rounded
    (concave ones too, so the outline never has a hard kink)."""
    P.region(Rect(0, 0, lay.width, lay.height), 0)
    b, rad = lay.body, lay.body_radius
    if skin.model == "snes" and not lay.landscape:
        # Two grips: a gentle notch in the middle of the lower edge.
        notch = Rect.centered(b.cx, b.bottom + 14, b.w * 0.34, 64)
        def shape(d, v):
            d.rounded_rectangle(P.box(b), radius=P.p(rad), fill=v)
            d.ellipse(P.box(notch), fill=0)
    else:
        shape = rrect(P, b, rad)
    m = P.mask(shape)
    # A blur-and-threshold rounds concave corners as well as convex ones.
    m = (blur(m, 10 * P.k) > 0.5).astype(np.float32)
    return blur(m, 0.7 * P.k)


def draw_body(P: Painter, skin: Skin, lay: Layout):
    pal = skin.palette
    W, H = lay.width, lay.height
    full = Rect(0, 0, W, H)
    m = body_mask(P, skin, lay)
    P.body = m
    P.region(full, 0)
    yy = np.linspace(0, 1, P.rh, dtype=np.float32)[:, None]
    xx = np.linspace(-1, 1, P.rw, dtype=np.float32)[None, :]
    if skin.handheld:
        P.put_color((10, 10, 12), np.ones((P.rh, P.rw), np.float32))
    else:
        # A dark backdrop for the TV picture.
        P.put_color(pal["top"], np.ones((P.rh, P.rw), np.float32))
    P.shadow(m, 40, 0.8)
    mat = skin.material
    h = height(m, 20 * P.k, "round")
    if mat.get("texture"):
        h = h + rough(0.009 * mat["texture"])(P, m)
    gloss, shin = 0.07, 10
    if mat.get("clear_shell"):
        gloss, shin = 0.22, 30
    if mat.get("metallic"):
        gloss, shin = 0.07 + 0.3 * mat["metallic"], 24
    rgb = light(h, 9 * P.k, shade(pal["body"], 0.04), gloss=gloss, shin=shin)
    # Darker towards the bottom, like the body curving away from the light.
    bot = np.asarray(pal["body2"], np.float32) / np.maximum(
        1, np.asarray(shade(pal["body"], 0.04), np.float32))
    tint = 1 + (bot - 1) * yy[..., None] * np.ones((1, P.rw, 1), np.float32)
    rgb = rgb * tint * (1 - 0.06 * xx ** 4)[..., None]
    if skin.model == "psp":
        # Gloss: a broad diagonal reflection.
        band = np.exp(-((xx * 0.6 + yy * 1.4 - 0.35) ** 2) / 0.02) * 0.07
        rgb = rgb + band[..., None]
    if mat.get("metallic"):
        # Metal flake: sparse bright specks.
        rng = np.random.default_rng(11)
        flake = (rng.random((P.rh, P.rw), dtype=np.float32) > 0.985) * 0.09
        rgb = rgb + (blur(flake, 0.4 * P.k) * mat["metallic"] * 2.2)[..., None]
    if mat.get("clear_shell"):
        # Depth: the inside of the shell shows as a softer, darker core.
        core = blur(m, 30 * P.k)
        rgb = rgb * (1 - 0.12 * core)[..., None]
    P.put(np.clip(rgb, 0, 1), m)
    if "circuit" in pal and mat.get("clear_shell", True):
        draw_circuit(P, lay, pal["circuit"])
    if skin.model == "nes":
        draw_nes_plate(P, skin, lay)


def draw_circuit(P: Painter, lay: Layout, color):
    """Faint traces suggesting a see-through shell."""
    W, H = lay.width, lay.height
    P.region(Rect(0, 0, W, H), 0)
    im = Image.new("L", (P.rw, P.rh), 0)
    d = ImageDraw.Draw(im)
    rows = [0.62, 0.71, 0.8, 0.9] if not lay.landscape else [0.2, 0.5, 0.82]
    for i, fy in enumerate(rows):
        y = H * fy
        x0 = 20 + i * 17
        pts = [(x0, y), (W * 0.3, y), (W * 0.36, y + 14), (W * 0.62, y + 14),
               (W * 0.68, y), (W - 20 - i * 11, y)]
        d.line(P.pts(pts), fill=255, width=P.p(1.6))
        for x, yy in (pts[0], pts[-1]):
            d.ellipse(P.box(Rect.centered(x, yy, 6)), outline=255, width=P.p(1.4))
    m = np.asarray(im, np.float32) / 255
    P.put_color((0, 0, 0), shift(m, P.p(0.6), P.p(0.8)) * 0.12)
    P.put_color(color, m * 0.12)


def draw_nes_plate(P: Painter, skin: Skin, lay: Layout):
    pal = skin.palette
    W, H = lay.width, lay.height
    if lay.landscape:
        plates = [Rect(10, 52, lay.screen.x - 22, H - 62),
                  Rect(lay.screen.right + 12, 52, W - lay.screen.right - 22, H - 62)]
    else:
        plates = [Rect(18, lay.controls_top + 52, W - 36, H - lay.controls_top - 72)]
    for pl in plates:
        recessed(P, rrect(P, pl, 10), pl, pal["plate"], bevel=3, depth=2, occlusion=0.5)
        P.region(pl, 0)
        P.grain(0.02)
    if not lay.landscape:
        # Raised ribs behind Select / Start.
        pills = [it.frame for it in lay.items if it.role == "pill"]
        sx0, sx1 = pills[0].x - 12, pills[-1].right + 12
        for i in range(4):
            rib = Rect(sx0, pills[0].y - 30 - i * 22, sx1 - sx0, 12)
            raised(P, rrect(P, rib, 3), rib, pal["stripe"], bevel=4, depth=3, gloss=0.12,
                   shin=12, shadow=0.5)


def draw_bezel(P: Painter, skin: Skin, lay: Layout):
    pal = skin.palette
    if lay.bezel is None:
        if lay.landscape:
            fr = lay.screen.inflate(5)
            recessed(P, rrect(P, fr, 7), fr, (14, 14, 16), bevel=4, depth=3, occlusion=0.6)
        return
    b = lay.bezel
    big = 46 if skin.model in ("gb", "gbc") and not lay.landscape else 14
    if big > 14:
        # Pocket style: one large rounded corner, bottom right.
        def shape(d, v):
            d.rounded_rectangle(P.box(b), radius=P.p(12), fill=v)
            corner = Rect(b.right - big * 2, b.bottom - big * 2, big * 2, big * 2)
            d.rectangle(P.box(Rect(b.right - big, b.bottom - big, big, big)), fill=0)
            d.pieslice(P.box(corner), 0, 90, fill=v)
    else:
        shape = rrect(P, b, big)
    # The bezel is a glossy window set slightly into the shell.
    raised(P, shape, b, pal["bezel"], bevel=2.5, depth=1.5, gloss=0.45, shin=60,
           shadow=0.35)
    window = lay.screen.inflate(3)
    recessed(P, rrect(P, window, 4), window, shade(pal["bezel"], -0.4), bevel=2.5,
             depth=2, occlusion=0.7)
    # A glassy sheen across the top of the bezel.
    P.region(b, 0)
    m = P.mask(shape)
    yy = np.linspace(0, 1, P.rh, dtype=np.float32)[:, None]
    xx = np.linspace(0, 1, P.rw, dtype=np.float32)[None, :]
    sheen = np.clip(1 - (yy * 2.2 + xx * 0.6), 0, 1) ** 2 * 0.1
    P.put_color((255, 255, 255), m * sheen)
    if skin.model in ("gb", "gbc") and not lay.landscape:
        # Two thin rules above the picture and a power lamp to its left.
        for dy in (7, 11):
            rule = Rect(b.x + 14, b.y + dy - 0.75, b.w - 28, 1.5)
            P.region(rule, 1)
            P.put_color(pal["bezel_line"], P.mask(lambda d, v, r=rule: d.rectangle(P.box(r),
                                                                                  fill=v)))
        lamp = Rect.centered((b.x + lay.screen.x) / 2, lay.screen.y + lay.screen.h * 0.32, 6)
        draw_lamp(P, lamp, pal["led"])
    elif "led" in pal:
        lamp = Rect.centered(b.x + 8 if not lay.landscape else b.x - 8,
                             b.y + 10 if not lay.landscape else b.bottom - 10, 5)
        if lamp.x > 0:
            draw_lamp(P, lamp, pal["led"])
    if skin.model == "nds":
        mid = lay.screen.cy
        for x in (b.x - 4, b.right - 8):
            hinge = Rect(x, mid - 22, 12, 44)
            raised(P, rrect(P, hinge, 5), hinge, pal["hinge"], bevel=5, depth=4, gloss=0.3,
                   shadow=0.6)
        seam = Rect(lay.screen.x, mid - 0.5, lay.screen.w, 1)
        P.region(seam, 1)
        P.put_color(pal["bezel"], P.mask(lambda d, v: d.rectangle(P.box(seam), fill=v)))


def draw_lamp(P: Painter, r: Rect, color):
    """A lit LED with a soft glow."""
    P.region(r, 8)
    m = P.mask(ellipse(P, r))
    P.put_color(color, blur(m, 3 * P.k) * 0.55)
    raised(P, ellipse(P, r), r, shade(color, 0.15), bevel=r.w / 2, depth=3, gloss=0.8,
           shin=60, shadow=0)


def draw_grille(P: Painter, skin: Skin, lay: Layout):
    pal = skin.palette
    if "grille" not in pal or lay.landscape:
        return
    W, H = lay.width, lay.height
    dark = shade(pal["grille"], -0.55)
    if skin.model in ("gb", "gbc"):
        for i in range(6):
            x, y = W - 92 + i * 13, H - 34
            pts = stadium_pts(x + 11, y - 20, 46, 6, -61.2)
            box = Rect(x - 4, y - 46, 32, 52)
            recessed(P, poly(P, pts), box, dark, bevel=2.5, depth=3, occlusion=0.7)
    else:
        for row in range(3):
            for col in range(3 + row % 2):
                hole = Rect.centered(W - 58 + col * 11 - (row % 2) * 5.5, H - 70 + row * 10,
                                     5)
                recessed(P, ellipse(P, hole), hole, dark, bevel=2, depth=2, occlusion=0.7)


def well(P: Painter, r: Rect, body, round_: bool = True, rad: float = 0, depth=3):
    """The opening in the shell a button sits in."""
    shape = ellipse(P, r) if round_ else rrect(P, r, rad)
    recessed(P, shape, r, shade(body, -0.28), bevel=min(r.w, r.h) * 0.12, depth=depth,
             occlusion=0.5)


def draw_dpad(P: Painter, skin: Skin, it: Item):
    pal = skin.palette
    r = it.frame
    body = pal["body"]
    if skin.model in ("psx", "psp"):
        # Four separate arrow keys in a shallow dish.
        dish = r.inflate(5)
        recessed(P, ellipse(P, dish), dish,
                 shade(body, -0.06 if skin.model == "psx" else 0.08), bevel=dish.w * 0.3,
                 depth=7, occlusion=0.35)
        arm = r.w * 0.3
        for dir_, (dx, dy) in {"up": (0, -1), "down": (0, 1), "left": (-1, 0),
                               "right": (1, 0)}.items():
            cx, cy = r.cx + dx * r.w * 0.3, r.cy + dy * r.w * 0.3
            ln = r.w * 0.36
            if dx:
                key = Rect.centered(cx, cy, ln, arm)
                tip = (r.cx + dx * r.w * 0.1, cy)
                pts = [(key.x if dx > 0 else key.right, key.y),
                       (key.right if dx > 0 else key.x, key.y),
                       (key.right if dx > 0 else key.x, key.bottom),
                       (key.x if dx > 0 else key.right, key.bottom), tip]
            else:
                key = Rect.centered(cx, cy, arm, ln)
                tip = (cx, r.cy + dy * r.w * 0.1)
                pts = [(key.x, key.y if dy > 0 else key.bottom),
                       (key.x, key.bottom if dy > 0 else key.y),
                       (key.right, key.bottom if dy > 0 else key.y),
                       (key.right, key.y if dy > 0 else key.bottom), tip]
            raised(P, poly(P, pts), key, pal["dpad"], bevel=arm * 0.3, depth=5, gloss=0.4,
                   shin=45, shadow=0.9, clear=0.6 if skin.material.get("clear_keys") else 0)
            sym = pal.get("symbol", shade(pal["dpad"], 0.5))
            t = triangle(cx + dx * r.w * 0.04, cy + dy * r.w * 0.04, arm * 0.2, dir_)
            glyph(P, poly(P, t), key, sym)
        return
    if skin.model == "nes":
        sock = r.inflate(6)
        recessed(P, rrect(P, sock, 8), sock, shade(pal["plate"], 0.12), bevel=5, depth=4,
                 occlusion=0.55)
    else:
        dish = r.inflate(10)
        recessed(P, ellipse(P, dish), dish, pal.get("dish", shade(body, -0.06)),
                 bevel=dish.w * 0.32, depth=8, occlusion=0.35)
    arm = r.w / 3
    socket = r.inflate(2.5)
    recessed(P, poly(P, cross_pts(socket, arm + 5)), socket, shade(body, -0.35),
             bevel=3, depth=3, occlusion=0.6)
    centre = Rect.centered(r.cx, r.cy, arm * 0.5)
    details = [(ellipse(P, centre), -0.35, arm * 0.25)]
    for dir_, (dx, dy) in {"up": (0, -1), "down": (0, 1), "left": (-1, 0),
                           "right": (1, 0)}.items():
        t = triangle(r.cx + dx * r.w * 0.36, r.cy + dy * r.w * 0.36, arm * 0.17, dir_)
        details.append((poly(P, t), -0.18, arm * 0.06))
    # Arms rise towards their tips, like a rocking cross.
    raised(P, poly(P, cross_pts(r, arm)), r, pal["dpad"], bevel=arm * 0.22, depth=6,
           gloss=0.32, shin=35, details=details, shadow=1.0)


def draw_stick(P: Painter, skin: Skin, it: Item):
    pal = skin.palette
    r = it.frame
    if it.role == "nub":
        well_r = r.inflate(4)
        recessed(P, ellipse(P, well_r), well_r, shade(pal["body"], 0.1), bevel=well_r.w * 0.3,
                 depth=6, occlusion=0.6)
        cap = r.inflate(-3)
        inner = cap.inflate(-cap.w * 0.2)
        raised(P, ellipse(P, cap), cap, pal["stick"], bevel=cap.w * 0.18, depth=5,
               gloss=0.1, shin=12, details=[(ellipse(P, inner), -0.3, cap.w * 0.25)],
               shadow=0.8, bump=crosshatch(cap) if skin.material.get("grip") else None)
        return
    dish = r.inflate(8)
    recessed(P, ellipse(P, dish), dish, pal["dish"], bevel=dish.w * 0.25, depth=7,
             occlusion=0.4)
    gate = r.inflate(-r.w * 0.04)
    pts = [(gate.cx + math.cos(math.radians(22.5 + 45 * i)) * gate.w / 2,
            gate.cy + math.sin(math.radians(22.5 + 45 * i)) * gate.w / 2) for i in range(8)]
    recessed(P, poly(P, pts), gate, pal["gate"], bevel=gate.w * 0.12, depth=8,
             occlusion=0.7)
    cap = Rect.centered(r.cx, r.cy, r.w * 0.52)
    rings = [(lambda d, v, rr=cap.inflate(-cap.w * f): d.ellipse(
        P.box(rr), outline=v, width=P.p(1.2)), -0.08, 0.8) for f in (0.1, 0.2, 0.3)]
    raised(P, ellipse(P, cap), cap, pal["stick"], bevel=cap.w * 0.35, depth=8, gloss=0.2,
           shin=20, details=rings, shadow=1.2, grain=0.025)


def draw_face(P: Painter, skin: Skin, it: Item, landscape: bool):
    pal = skin.palette
    r = it.frame
    key = it.style.get("key")
    body = pal["body"]
    if skin.model == "nes":
        sock = r.inflate(5)
        raised(P, rrect(P, sock, 6), sock, pal["socket"], bevel=2.5, depth=2, gloss=0.15,
               shin=15, shadow=0.6)
        well(P, r.inflate(1.5), pal["socket"])
        raised(P, ellipse(P, r), r, pal["face"], bevel=r.w * 0.16, depth=5, gloss=0.3,
               shin=35, details=[(ellipse(P, r.inflate(-r.w * 0.12)), -0.12, r.w * 0.3)],
               shadow=0.6)
        lx = r.right - 2 if not landscape else r.cx
        label(P, lx, sock.bottom + 10, it.label, 11, pal["label"])
        return
    well(P, r.inflate(2.5), body)
    if skin.face in ("shapes", "shapes_mono"):
        raised(P, ellipse(P, r), r, pal["face"], bevel=r.w * 0.3, depth=6, gloss=0.4,
               shin=45, clear=0.6 if skin.material.get("clear_keys") else 0)
        color = pal["symbol"] if skin.face == "shapes_mono" else pal[it.label]
        draw_symbol(P, it.label, r, color)
        return
    color = pal.get(key, pal.get("face")) if skin.model in ("snes", "n64") else pal["face"]
    raised(P, ellipse(P, r), r, color, bevel=r.w * 0.34, depth=7, gloss=0.55, shin=55)
    if skin.model == "snes":
        return  # lettered on the plate (draw_snes_plate)
    if skin.model == "n64":
        label(P, r.cx, r.cy, it.label, r.h * 0.36, shade(color, -0.4), "engrave")
    elif pal.get("face_text") is not None:
        label(P, r.cx, r.cy, it.label, r.h * 0.4, pal["face_text"], "engrave")
    else:
        label(P, r.cx, r.bottom + 11, it.label, 12, pal["label"])


def draw_snes_plate(P: Painter, skin: Skin, lay: Layout):
    """A dark round plate under the four face buttons, with two lighter
    diagonal trays (Y with X, B with A) and the letters printed beside."""
    pal = skin.palette
    faces = {it.style["key"]: it.frame for it in lay.items if it.role == "face"}
    cx = sum(f.cx for f in faces.values()) / 4
    cy = sum(f.cy for f in faces.values()) / 4
    bw = faces["a"].w
    reach = max(math.hypot(f.cx - cx, f.cy - cy) for f in faces.values())
    plate = Rect.centered(cx, cy, 2 * (reach + bw * 0.5 + 7))
    recessed(P, ellipse(P, plate), plate, pal["plate"], bevel=plate.w * 0.06, depth=3,
             occlusion=0.45)
    for a, b in (("y", "x"), ("b", "a")):
        fa, fb = faces[a], faces[b]
        mx, my = (fa.cx + fb.cx) / 2, (fa.cy + fb.cy) / 2
        ln = math.hypot(fb.cx - fa.cx, fb.cy - fa.cy) + bw * 1.32
        ang = math.degrees(math.atan2(fb.cy - fa.cy, fb.cx - fa.cx))
        tray = stadium_pts(mx, my, ln, bw * 1.32, ang)
        box = Rect.centered(mx, my, ln, ln)
        recessed(P, poly(P, tray), box, pal["tray"], bevel=bw * 0.12, depth=3,
                 occlusion=0.5)
    for key, f in faces.items():
        dx, dy = f.cx - cx, f.cy - cy
        d = math.hypot(dx, dy) or 1
        # Beside the button, turned a little clockwise like a dial.
        t = math.atan2(dy, dx) + math.radians(-28)
        lx = cx + math.cos(t) * (d + bw * 0.5 + 2)
        ly = cy + math.sin(t) * (d + bw * 0.5 + 2)
        label(P, lx, ly, key.upper(), bw * 0.3, pal["plate_text"])


def draw_symbol(P: Painter, kind: str, r: Rect, color):
    """Plain geometric outlines (triangle, circle, cross, square)."""
    s = r.w * 0.24
    wdt = P.p(max(1.6, r.w * 0.06))
    cx, cy = r.cx, r.cy
    if kind == "tri":
        pts = [(cx, cy - s * 1.05), (cx + s * 1.0, cy + s * 0.68), (cx - s * 1.0, cy + s * 0.68)]
        shape = lambda d, v: d.polygon(P.pts(pts), outline=v, width=wdt)  # noqa: E731
    elif kind == "cir":
        shape = lambda d, v: d.ellipse(P.box(Rect.centered(cx, cy, s * 1.9)),  # noqa: E731
                                       outline=v, width=wdt)
    elif kind == "crs":
        def shape(d, v):
            for a, b in (((-1, -1), (1, 1)), ((-1, 1), (1, -1))):
                d.line(P.pts([(cx + a[0] * s * 0.85, cy + a[1] * s * 0.85),
                              (cx + b[0] * s * 0.85, cy + b[1] * s * 0.85)]),
                       fill=v, width=wdt)
    else:
        shape = lambda d, v: d.rectangle(P.box(Rect.centered(cx, cy, s * 1.6)),  # noqa: E731
                                         outline=v, width=wdt)
    glyph(P, shape, r, color, style="print")


def draw_cbutton(P: Painter, skin: Skin, it: Item):
    pal = skin.palette
    r = it.frame
    well(P, r.inflate(2), pal["body"])
    raised(P, ellipse(P, r), r, pal["c"], bevel=r.w * 0.32, depth=6, gloss=0.55, shin=55)
    glyph(P, poly(P, triangle(r.cx, r.cy, r.w * 0.24, it.label)), r, pal["c_text"])


def draw_shoulder(P: Painter, skin: Skin, it: Item, lay: Layout):
    """A bumper moulded into the shell: flush with every shell edge it
    touches, with a seam where it meets the rest of the body."""
    pal = skin.palette
    r = it.frame
    color = pal.get("shoulder", shade(pal["body"], -0.15))
    b = lay.body
    out = 40.0
    left = r.x - max(b.x, 0) < 1
    right = min(b.right, lay.width) - r.right < 1
    top = r.y - max(b.y, 0) < 1
    ext = Rect(r.x - (out if left else 0), r.y - (out if top else 0),
               r.w + (out if left else 0) + (out if right else 0),
               r.h + (out if top else 0))
    P.region(r, 14)
    shell = P.body[P.oy:P.oy + P.rh, P.ox:P.ox + P.rw]
    m = P.mask(rrect(P, ext, r.h * 0.5)) * shell
    seam = P.mask(rrect(P, ext.inflate(1.6), r.h * 0.5 + 1.6)) * shell
    P.put_color((0, 0, 0), np.clip(seam - m, 0, 1) * 0.55)
    # Soft shadow onto the shell below the bumper.
    sh = blur(shift(m, 0, round(1.5 * P.k)), 2.5 * P.k) * (1 - m) * shell
    P.put_color((0, 0, 0), sh * 0.35)
    h = np.minimum(height(m, r.h * 0.45 * P.k, "round"),
                   height(shell, 20 * P.k, "round") + 0.0)
    rgb = light(h, 6 * P.k, color, 0.3, 30)
    if skin.material.get("clear_shoulders"):
        rgb, m = see_through(P, light(h, 6 * P.k, color, 0.6, 60), m, h, color, 0.8)
    P.put(rgb, m)
    vis = Rect(r.x + (4 if left else 0), r.y + (3 if top else 0),
               r.w - (4 if left else 0) - (4 if right else 0), r.h - (3 if top else 0))
    label(P, vis.cx, vis.cy, it.label, r.h * 0.4,
          shade(color, -0.45 if sum(color) > 300 else 0.55), "engrave")


def draw_pill(P: Painter, skin: Skin, it: Item, landscape: bool):
    pal = skin.palette
    r = it.frame
    slanted = skin.model in ("gb", "gbc", "snes") and not landscape
    inner = Rect.centered(r.cx, r.cy, r.w * 0.78, r.h * 0.62)
    if skin.model in ("gba", "nds"):
        dot = Rect.centered(r.cx, r.cy - 2, 15)
        well(P, dot.inflate(2), pal["body"])
        raised(P, ellipse(P, dot), dot, pal["pill"], bevel=dot.w * 0.35, depth=5,
               gloss=0.5, shin=50)
        label(P, r.cx, r.bottom + 3, it.label, 9, pal["label"])
        return
    ang = -24 if slanted else 0
    socket_bg = pal["plate"] if skin.model == "nes" else pal["body"]
    outer = stadium_pts(r.cx, r.cy, inner.w + 5, inner.h + 5, ang)
    recessed(P, poly(P, outer), r.inflate(3), shade(socket_bg, -0.3), bevel=2.5, depth=3,
             occlusion=0.6)
    # Rubber keys: matte, softly rounded.
    raised(P, poly(P, stadium_pts(r.cx, r.cy, inner.w, inner.h, ang)), inner, pal["pill"],
           bevel=inner.h * 0.5, depth=5, gloss=0.12, shin=12, shadow=0.7, grain=0.03)
    label_y = r.bottom + 7 if skin.model != "nes" else r.y - 7
    label(P, r.cx, label_y, it.label, 9, pal["label"], rotate=24 if slanted else 0)


def draw_round_start(P: Painter, skin: Skin, it: Item):
    pal = skin.palette
    r = it.frame
    well(P, r.inflate(2.5), pal["body"])
    raised(P, ellipse(P, r), r, pal["start"], bevel=r.w * 0.34, depth=6, gloss=0.55,
           shin=55)
    label(P, r.cx, r.bottom + 9, "START", 9, pal["label"])


def draw_z(P: Painter, skin: Skin, it: Item):
    pal = skin.palette
    r = it.frame
    well(P, r.inflate(2), pal["body"], round_=False, rad=r.h * 0.3)
    raised(P, rrect(P, r, r.h * 0.3), r, pal["z"], bevel=r.h * 0.35, depth=5, gloss=0.3,
           shin=30)
    label(P, r.cx, r.cy, "Z", r.h * 0.45, shade(pal["z"], 0.6), "engrave")


def draw_menu(P: Painter, skin: Skin, it: Item):
    pal = skin.palette
    r = it.frame.inflate(-3)
    base = pal["body"]
    dark = sum(base) < 300
    color = shade(base, 0.1 if dark else -0.06)
    well(P, r.inflate(2), base)
    lines = [(lambda d, v, y=r.cy + i * r.h * 0.17: d.line(
        P.pts([(r.cx - r.w * 0.22, y), (r.cx + r.w * 0.22, y)]), fill=v, width=P.p(1.8)),
        -0.25, 0.6) for i in (-1, 0, 1)]
    raised(P, ellipse(P, r), r, color, bevel=r.w * 0.3, depth=4, gloss=0.25, shin=30,
           details=lines, shadow=0.7)


# ---------------------------------------------------------------- pixel art (PICO-8)

# One art pixel is PIX mapping points: chunky, like the fantasy console's own
# 128x128 screen. Colours come from the public 16-colour PICO-8 palette.
PIX = 3

# 3x5 pixel glyphs for the few labels the skin needs (our own drawing).
GLYPHS = {
    "O": ["111", "101", "101", "101", "111"],
    "X": ["101", "101", "010", "101", "101"],
    "P": ["111", "101", "111", "100", "100"],
    "A": ["010", "101", "111", "101", "101"],
    "U": ["101", "101", "101", "101", "111"],
    "S": ["011", "100", "010", "001", "110"],
    "E": ["111", "100", "110", "100", "111"],
}


class Pixels:
    """A low-resolution canvas in art pixels, scaled up without smoothing."""

    def __init__(self, w: float, h: float):
        self.w, self.h = math.ceil(w / PIX), math.ceil(h / PIX)
        self.img = Image.new("RGBA", (self.w, self.h), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.img)

    def g(self, v: float) -> int:
        return round(v / PIX)

    def rect(self, x0, y0, x1, y1, c):
        if x1 >= x0 and y1 >= y0:
            self.d.rectangle((x0, y0, x1, y1), fill=_rgba(c))

    def disc(self, cx, cy, r, c):
        for y in range(-r, r + 1):
            span = int(math.sqrt(max(0, (r + 0.5) ** 2 - y * y)))
            self.rect(cx - span, cy + y, cx + span, cy + y, c)

    def text(self, cx, cy, s, c, scale=1):
        tw = (len(s) * 4 - 1) * scale
        x = cx - tw // 2
        y = cy - (5 * scale) // 2
        for ch in s:
            for j, row in enumerate(GLYPHS.get(ch, ["000"] * 5)):
                for i, bit in enumerate(row):
                    if bit == "1":
                        self.rect(x + i * scale, y + j * scale, x + i * scale + scale - 1,
                                  y + j * scale + scale - 1, c)
            x += 4 * scale

    def result(self, w: float, h: float) -> Image.Image:
        big = self.img.resize((self.w * PIX * SCALE, self.h * PIX * SCALE), Image.NEAREST)
        return big.crop((0, 0, round(w * SCALE), round(h * SCALE)))


def render_pixel(skin: Skin, lay: Layout) -> Image.Image:
    pal = skin.palette
    X = Pixels(lay.width, lay.height)
    # Shell: flat colour with a sparse dither, like a two-tone sprite.
    X.rect(0, 0, X.w, X.h, pal["body"])
    for y in range(0, X.h, 2):
        for x in range((y // 2) % 2 * 2, X.w, 4):
            X.rect(x, y, x, y, pal["body2"])
    # Screen frame: dark bezel with a lit top-left edge and a shadow.
    sc = lay.bezel or lay.screen.inflate(4)
    x0, y0, x1, y1 = X.g(sc.x), X.g(sc.y), X.g(sc.right) - 1, X.g(sc.bottom) - 1
    X.rect(x0 + 1, y0 + 1, x1 + 1, y1 + 1, pal["shadow"])
    X.rect(x0, y0, x1, y1, pal["bezel"])
    X.rect(x0, y0, x1, y0, pal["bezel_line"])
    X.rect(x0, y0, x0, y1, pal["bezel_line"])
    if lay.bezel and not lay.landscape:
        # Power lamp under the picture, bottom left of the frame.
        X.rect(x0 + 3, y1 - 3, x0 + 4, y1 - 2, pal["led"])

    def key(r: Rect, color, round_: bool, depth=1):
        """A raised key: shadow, face, top-left highlight; returns its centre."""
        a, b, c2, d2 = X.g(r.x), X.g(r.y), X.g(r.right) - 1, X.g(r.bottom) - 1
        cx, cy = (a + c2) // 2, (b + d2) // 2
        hi, lo = shade(color, 0.35), shade(color, -0.4)
        if round_:
            rad = (c2 - a) // 2
            X.disc(cx + 1, cy + depth + 1, rad, pal["shadow"])
            X.disc(cx, cy + depth, rad, lo)
            X.disc(cx, cy, rad, color)
            X.disc(cx - rad // 3, cy - rad // 3, max(1, rad // 3), hi)
        else:
            X.rect(a + 1, b + depth + 1, c2 + 1, d2 + depth + 1, pal["shadow"])
            X.rect(a, b + depth, c2, d2 + depth, lo)
            X.rect(a, b, c2, d2, color)
            X.rect(a, b, c2, b, hi)
            X.rect(a, b, a, d2, hi)
        return cx, cy

    for it in lay.items:
        r = it.frame
        if it.role == "dpad":
            a, b, c2, d2 = X.g(r.x), X.g(r.y), X.g(r.right) - 1, X.g(r.bottom) - 1
            t = (c2 - a + 1) // 3
            arms = [(a + t, b, c2 - t, d2), (a, b + t, c2, d2 - t)]
            for (p, q, s2, u) in arms:
                X.rect(p + 1, q + 3, s2 + 1, u + 3, pal["shadow"])
            for (p, q, s2, u) in arms:
                X.rect(p, q + 2, s2, u + 2, shade(pal["dpad"], -0.45))
            for (p, q, s2, u) in arms:
                X.rect(p, q, s2, u, pal["dpad"])
            hi = shade(pal["dpad"], 0.4)
            X.rect(a + t, b, c2 - t, b, hi)
            X.rect(a, b + t, a, d2 - t, hi)
            X.rect(a, b + t, a + t, b + t, hi)
            X.rect(c2 - t, b + t, c2, b + t, hi)
            # Arrow pips on each arm.
            m = (a + c2) // 2
            n = (b + d2) // 2
            pip = pal["pip"]
            for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
                px, py = m + dx * t, n + dy * t
                X.rect(px - 1 + (dx != 0), py - 1 + (dy != 0), px + 1 - (dx != 0),
                       py + 1 - (dy != 0), pip)
        elif it.role == "face":
            color = pal["o"] if it.label == "O" else pal["x"]
            cx, cy = key(r, color, True, depth=2)
            X.text(cx, cy, it.label, pal["glyph"], scale=2)
            X.text(cx, X.g(r.bottom) + 6, it.label, pal["label"])
        elif it.role == "pill":
            cx, cy = key(r, pal["pill"], False)
            X.text(cx, cy, it.label, pal["glyph"])
        elif it.role == "menu":
            cx, cy = key(r.inflate(-4), pal["pill"], False)
            for k in (-2, 0, 2):
                X.rect(cx - 2, cy + k, cx + 2, cy + k, pal["glyph"])
    img = X.result(lay.width, lay.height)
    hole = Image.new("RGBA", img.size, (0, 0, 0, 0))
    s = lay.screen
    box = (round(s.x * SCALE), round(s.y * SCALE), round(s.right * SCALE),
           round(s.bottom * SCALE))
    img.paste(hole.crop(box), box)
    return img


def render(skin: Skin, lay: Layout) -> Image.Image:
    if skin.model == "pico8":
        return render_pixel(skin, lay)
    P = Painter(lay.width, lay.height)
    draw_body(P, skin, lay)
    draw_bezel(P, skin, lay)
    draw_grille(P, skin, lay)
    if skin.model == "snes":
        draw_snes_plate(P, skin, lay)
    for it in lay.items:
        if it.role == "dpad":
            draw_dpad(P, skin, it)
        elif it.role in ("stick", "nub"):
            draw_stick(P, skin, it)
        elif it.role == "face":
            draw_face(P, skin, it, lay.landscape)
        elif it.role == "cbutton":
            draw_cbutton(P, skin, it)
        elif it.role == "shoulder":
            draw_shoulder(P, skin, it, lay)
        elif it.role == "pill":
            draw_pill(P, skin, it, lay.landscape)
        elif it.role == "start_round":
            draw_round_start(P, skin, it)
        elif it.role == "z":
            draw_z(P, skin, it)
        elif it.role == "menu":
            draw_menu(P, skin, it)
    img = P.result()
    # The game picture is drawn over this area; keep it empty.
    hole = Image.new("RGBA", img.size, (0, 0, 0, 0))
    s = lay.screen
    box = (round(s.x * SCALE), round(s.y * SCALE), round(s.right * SCALE),
           round(s.bottom * SCALE))
    img.paste(hole.crop(box), box)
    return img


def thumbstick_png(skin: Skin) -> bytes:
    """Delta draws a thumbstick image over the stick; ours is a plain knob."""
    color = skin.palette.get("stick", (180, 180, 180))
    P = Painter(60, 60)
    r = Rect(6, 6, 48, 48)
    raised(P, ellipse(P, r), r, color, bevel=16, depth=8, gloss=0.2, shin=20)
    buf = io.BytesIO()
    P.result().save(buf, "PNG", optimize=True)
    return buf.getvalue()


# ---------------------------------------------------------------- packaging


def item_json(it: Item) -> dict:
    j = {"inputs": it.inputs, "frame": it.frame.json(),
         "extendedEdges": {"top": 6, "bottom": 6, "left": 6, "right": 6}}
    if it.role in ("dpad", "stick"):
        e = it.frame.w * 0.15
        j["extendedEdges"] = {"top": e, "bottom": e, "left": e, "right": e}
    if it.thumbstick:
        j["thumbstick"] = {"name": "thumbstick.png", "width": round(it.frame.w * 0.5, 2),
                           "height": round(it.frame.w * 0.5, 2)}
    return j


def build(skin: Skin, previews: str | None) -> tuple[bytes, list[str]]:
    errs: list[str] = []
    files: dict[str, bytes] = {}
    reps: dict = {"iphone": {}}
    preview_imgs = {}
    for (display, orient), (w, h) in REPRESENTATIONS.items():
        lay = layout(skin, w, h, orient == "landscape")
        errs += validate(skin, lay, f"{skin.key} {display} {orient}")
        img = render(skin, lay)
        # WebP keeps textured plastics small; the app decodes it like PNG.
        name = f"{skin.key}_{display}_{orient}.webp"
        buf = io.BytesIO()
        img.save(buf, "WEBP", quality=84 if skin.material.get("texture") else 90, method=6,
                 alpha_quality=100)
        files[name] = buf.getvalue()
        reps["iphone"].setdefault(display, {})[orient] = {
            "assets": {"large": name},
            "items": [item_json(it) for it in lay.items],
            "screens": [{"outputFrame": lay.screen.json()}],
            "mappingSize": {"width": w, "height": h},
            "extendedEdges": {"top": 6, "bottom": 6, "left": 6, "right": 6},
            "translucent": False,
        }
        preview_imgs[(display, orient)] = (img, lay)
    if any(it.thumbstick for it in lay.items):
        files["thumbstick.png"] = thumbstick_png(skin)
    info = {
        "name": skin.name,
        "identifier": f"com.denaemu.skins.{skin.key}",
        "gameTypeIdentifier": f"com.denaemu.game.{skin.game_type}",
        "debug": False,
        "representations": reps,
    }
    buf = io.BytesIO()
    # Fixed timestamps so rebuilding unchanged art gives identical files.
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in [("info.json", json.dumps(info, indent=2).encode())] + \
                sorted(files.items()):
            zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    if previews:
        write_preview(skin, preview_imgs, previews)
    return buf.getvalue(), errs


def test_pattern(w: int, h: int) -> Image.Image:
    """Stands in for the game picture in previews."""
    im = Image.new("RGB", (w, h), (20, 22, 30))
    d = ImageDraw.Draw(im)
    bars = [(192, 192, 192), (192, 192, 0), (0, 192, 192), (0, 192, 0), (192, 0, 192),
            (192, 0, 0), (0, 0, 192)]
    bw = w / len(bars)
    for i, c in enumerate(bars):
        d.rectangle((round(i * bw), 0, round((i + 1) * bw), round(h * 0.7)), fill=c)
    return im


def write_preview(skin: Skin, imgs: dict, out: str):
    os.makedirs(out, exist_ok=True)
    s = 2 / SCALE  # previews at 2 px per point, scaled down
    port, pl = imgs[("edgeToEdge", "portrait")]
    land, ll = imgs[("edgeToEdge", "landscape")]
    def compose(img, lay):
        base = Image.new("RGBA", img.size, (0, 0, 0, 255))
        sc = lay.screen
        tp = test_pattern(round(sc.w * SCALE), round(sc.h * SCALE))
        base.paste(tp, (round(sc.x * SCALE), round(sc.y * SCALE)))
        base = Image.alpha_composite(base, img)
        return base.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    a, b = compose(port, pl), compose(land, ll)
    gap = 24
    sheet = Image.new("RGB", (a.width + gap + b.width + 2 * gap, a.height + 2 * gap + 40),
                      (245, 245, 247))
    sheet.paste(a, (gap, gap + 40))
    sheet.paste(b, (2 * gap + a.width, gap + 40 + (a.height - b.height) // 2))
    ImageDraw.Draw(sheet).text((gap, 14), f"{skin.name}  ({skin.key})", font=font(26),
                               fill=(30, 30, 35))
    sheet.save(os.path.join(out, f"{skin.key}.png"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--previews", help="also write preview sheets to this folder")
    ap.add_argument("--only", nargs="*", help="skin keys to build")
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    errors = []
    for skin in SKINS:
        if args.only and skin.key not in args.only:
            continue
        data, errs = build(skin, args.previews)
        errors += errs
        with open(os.path.join(OUT, f"{skin.key}.deltaskin"), "wb") as f:
            f.write(data)
        print(f"{skin.key}.deltaskin  {len(data) // 1024} KB")
    for e in errors:
        print("layout:", e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
