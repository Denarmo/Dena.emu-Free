#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates test.nds, our own Nintendo DS test ROM.

Spec: docs/specs/ds.md. Behaviour: the top screen shows one 3D triangle with a
red, green and blue corner (Gouraud shading) on a dark grey clear colour,
drawn by the 3D engine every frame; the bottom screen is blank. The triangle's
edges are slanted, so a renderer at 2x-4x internal resolution draws stair
steps that a 1x picture scaled up cannot have (ds_gles_tests). The ARM7 idles.
No audio, no input. A few ARM instructions are encoded here, so no toolchain
is needed.

Layout: 128 KiB, header at 0 (arm9 code below 0x4000: homebrew, no secure
area), ARM9 code at file 0x200 loaded to 0x02000000, ARM7 code at 0x1000
loaded to 0x02380000.

Usage: python make_rom.py [out.nds]
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

ROM_SIZE = 0x20000
ARM9_OFF, ARM9_RAM = 0x200, 0x02000000
ARM7_OFF, ARM7_RAM = 0x1000, 0x02380000

COND = {"eq": 0x0, "ne": 0x1, "al": 0xE}


class Arm:
    """Tiny ARM (A32) emitter: literal loads, stores, compares, branches."""

    def __init__(self, base: int) -> None:
        self.base = base
        self.words: list[int] = []
        self.labels: dict[str, int] = {}
        self.branches: list[tuple[int, str, int]] = []
        self.literals: list[tuple[int, int, int]] = []  # (index, rd, value)

    def label(self, name: str) -> None:
        self.labels[name] = len(self.words)

    def ldr_imm32(self, rd: int, value: int) -> None:  # ldr rd, =value
        self.literals.append((len(self.words), rd, value))
        self.words.append(0)

    def str_(self, rd: int, rn: int) -> None:  # str rd, [rn]
        self.words.append(0xE5800000 | rn << 16 | rd << 12)

    def ldrh(self, rd: int, rn: int) -> None:  # ldrh rd, [rn]
        self.words.append(0xE1D000B0 | rn << 16 | rd << 12)

    def cmp_imm(self, rn: int, imm8: int) -> None:  # cmp rn, #imm8
        assert 0 <= imm8 < 256
        self.words.append(0xE3500000 | rn << 16 | imm8)

    def b(self, cond: str, target: str) -> None:
        self.branches.append((len(self.words), target, COND[cond]))
        self.words.append(0)

    def poke(self, addr: int, value: int) -> None:  # *(u32 *)addr = value
        self.ldr_imm32(0, addr)
        self.ldr_imm32(1, value)
        self.str_(1, 0)

    def assemble(self) -> bytes:
        for i, target, cond in self.branches:
            off = (self.labels[target] - (i + 2)) & 0xFFFFFF
            self.words[i] = cond << 28 | 0x0A000000 | off
        pool = len(self.words)
        values: list[int] = []
        for i, rd, value in self.literals:
            if value not in values:
                values.append(value)
            off = (pool + values.index(value) - (i + 2)) * 4
            assert 0 <= off < 0x1000
            self.words[i] = 0xE59F0000 | rd << 12 | off
        return struct.pack(f"<{pool + len(values)}I", *self.words, *values)


def fx(v: float) -> int:
    """1.3.12 fixed point, 16 bits."""
    return int(round(v * 4096)) & 0xFFFF


def rgb15(r: int, g: int, b: int) -> int:
    return r | g << 5 | b << 10


TRIANGLE = [  # (x, y, colour); clip space, the projection is the identity
    (-0.75, -0.80, rgb15(31, 0, 0)),
    (0.75, -0.55, rgb15(0, 31, 0)),
    (0.10, 0.85, rgb15(0, 0, 31)),
]


def arm9() -> bytes:
    a = Arm(ARM9_RAM)
    a.poke(0x04000304, 0x820F)      # POWCNT1: LCDs, 2D A, 3D render+geometry, 2D B, A on top
    a.poke(0x04000000, 0x00010108)  # DISPCNT A: display on, BG0 on, BG0 is 3D
    a.poke(0x04000060, 0)           # DISP3DCNT: no textures, no fog, no edges
    a.poke(0x04000350, rgb15(4, 4, 4) | 31 << 16)  # CLEAR_COLOR, opaque
    a.poke(0x04000354, 0x7FFF)      # CLEAR_DEPTH: far
    a.label("frame")
    a.ldr_imm32(2, 0x04000006)      # VCOUNT
    a.label("wait_vblank")
    a.ldrh(3, 2)
    a.cmp_imm(3, 192)
    a.b("ne", "wait_vblank")
    a.poke(0x04000580, 0xBFFF0000)  # VIEWPORT 0,0 - 255,191
    a.poke(0x04000440, 0)           # MTX_MODE projection
    a.poke(0x04000454, 0)           # MTX_IDENTITY
    a.poke(0x04000440, 2)           # MTX_MODE position & vector
    a.poke(0x04000454, 0)           # MTX_IDENTITY
    a.poke(0x040004A4, 0x001F00C0)  # POLYGON_ATTR: modulate, both sides, alpha 31
    a.poke(0x04000500, 0)           # BEGIN_VTXS triangles
    for x, y, colour in TRIANGLE:
        a.poke(0x04000480, colour)  # COLOR
        a.poke(0x0400048C, fx(x) | fx(y) << 16)  # VTX_16 x, y
        a.poke(0x0400048C, fx(0.0))  # VTX_16 z
    a.poke(0x04000504, 0)           # END_VTXS
    a.poke(0x04000540, 0)           # SWAP_BUFFERS (auto sort, Z buffer)
    a.label("wait_line")            # leave line 192 before the next frame
    a.ldrh(3, 2)
    a.cmp_imm(3, 192)
    a.b("eq", "wait_line")
    a.b("al", "frame")
    return a.assemble()


def arm7() -> bytes:
    a = Arm(ARM7_RAM)
    a.label("idle")
    a.b("al", "idle")
    return a.assemble()


def build() -> bytes:
    rom = bytearray(ROM_SIZE)
    code9, code7 = arm9(), arm7()
    assert ARM9_OFF + len(code9) <= ARM7_OFF
    rom[ARM9_OFF:ARM9_OFF + len(code9)] = code9
    rom[ARM7_OFF:ARM7_OFF + len(code7)] = code7
    rom[0x00:0x0C] = b"DENA TEST 3D"
    rom[0x0C:0x10] = b"DENA"         # game code
    rom[0x10:0x12] = b"00"           # maker code
    rom[0x14] = 0                    # capacity: 128 KiB (0x20000 << 0)
    struct.pack_into("<4I", rom, 0x20, ARM9_OFF, ARM9_RAM, ARM9_RAM, len(code9))
    struct.pack_into("<4I", rom, 0x30, ARM7_OFF, ARM7_RAM, ARM7_RAM, len(code7))
    struct.pack_into("<II", rom, 0x80, ROM_SIZE, 0x4000)  # used size, header size
    struct.pack_into("<H", rom, 0x15E, crc16(rom[:0x15E]))
    return bytes(rom)


def crc16(data: bytes) -> int:
    """The DS header CRC (CRC-16/MODBUS)."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("test.nds")
    out.write_bytes(build())


if __name__ == "__main__":
    main()
