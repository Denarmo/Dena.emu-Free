#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates test.nes, our own NES test ROM.

Spec: docs/specs/cores-m2.md. Behaviour: the backdrop is black, white while A is
held, and red on every 64th frame, so the picture changes over time. Each press
of Start increments battery RAM at $6000. No audio. A few 6502 instructions are
encoded here, so no toolchain is needed.

Layout: iNES, mapper 0 (NROM), 16 KiB PRG at $C000 (mirrored at $8000),
8 KiB CHR of zeros, battery-backed PRG RAM.

Usage: python make_rom.py [out.nes]
"""
from __future__ import annotations

import sys
from pathlib import Path

PRG_SIZE = 0x4000
CHR_SIZE = 0x2000
BASE = 0xC000


class Asm:
    """Tiny 6502 emitter with labels for branches and jumps."""

    def __init__(self) -> None:
        self.code = bytearray()
        self.labels: dict[str, int] = {}
        self.branches: list[tuple[int, str]] = []
        self.jumps: list[tuple[int, str]] = []

    @property
    def pc(self) -> int:
        return BASE + len(self.code)

    def label(self, name: str) -> None:
        self.labels[name] = self.pc

    def op(self, *b: int) -> None:
        self.code += bytes(b)

    def abs_(self, opcode: int, addr: int) -> None:
        self.op(opcode, addr & 0xFF, addr >> 8)

    def branch(self, opcode: int, target: str) -> None:
        self.op(opcode, 0)
        self.branches.append((len(self.code) - 1, target))

    def jmp(self, target: str) -> None:
        self.op(JMP, 0, 0)
        self.jumps.append((len(self.code) - 2, target))

    def resolve(self) -> bytes:
        for at, target in self.branches:
            rel = self.labels[target] - (BASE + at + 1)
            assert -128 <= rel <= 127, target
            self.code[at] = rel & 0xFF
        for at, target in self.jumps:
            addr = self.labels[target]
            self.code[at] = addr & 0xFF
            self.code[at + 1] = addr >> 8
        return bytes(self.code)


SEI, CLD, LDX_I, TXS, DEX, TAY = 0x78, 0xD8, 0xA2, 0x9A, 0xCA, 0xA8
LDA_I, LDA_A, STA_A, LDA_Z, STA_Z, INC_Z, INC_A = 0xA9, 0xAD, 0x8D, 0xA5, 0x85, 0xE6, 0xEE
STY_A, AND_I, LSR, ROL_Z, BIT_A = 0x8C, 0x29, 0x4A, 0x26, 0x2C
BPL, BNE, BEQ, JMP, RTI = 0x10, 0xD0, 0xF0, 0x4C, 0x40

# Zero-page variables.
FRAME, PREV, BUTTONS = 0x00, 0x01, 0x02
BATTERY = 0x6000

# NES palette indices: black, white, red.
BLACK, WHITE, RED = 0x0F, 0x30, 0x16


def write_backdrop_from_y(a: Asm) -> None:
    """Writes Y to palette entry $3F00, then resets the PPU address and scroll."""
    a.abs_(LDA_A, 0x2002)  # reset the address latch
    a.op(LDA_I, 0x3F)
    a.abs_(STA_A, 0x2006)
    a.op(LDA_I, 0x00)
    a.abs_(STA_A, 0x2006)
    a.abs_(STY_A, 0x2007)
    a.op(LDA_I, 0x00)
    a.abs_(STA_A, 0x2006)
    a.abs_(STA_A, 0x2006)
    a.abs_(STA_A, 0x2005)
    a.abs_(STA_A, 0x2005)


def build() -> bytes:
    a = Asm()
    a.label("reset")
    a.op(SEI, CLD, LDX_I, 0xFF, TXS)
    a.op(LDA_I, 0x00)
    a.abs_(STA_A, 0x2000)
    a.abs_(STA_A, 0x2001)
    for n in (1, 2):  # the PPU needs two vblanks to warm up
        a.label(f"vblank{n}")
        a.abs_(BIT_A, 0x2002)
        a.branch(BPL, f"vblank{n}")
    a.op(LDA_I, 0x00, STA_Z, FRAME, STA_Z, PREV, STA_Z, BUTTONS)
    a.op(0xA0, BLACK)  # LDY #BLACK
    write_backdrop_from_y(a)
    a.op(LDA_I, 0x80)
    a.abs_(STA_A, 0x2000)  # NMI on vblank
    a.op(LDA_I, 0x0A)
    a.abs_(STA_A, 0x2001)  # show background, including the left column
    a.label("idle")
    a.jmp("idle")

    a.label("nmi")
    # Controller 1: A, B, Select, Start, Up, Down, Left, Right -> bits 7..0.
    a.op(LDA_I, 0x01)
    a.abs_(STA_A, 0x4016)
    a.op(LDA_I, 0x00)
    a.abs_(STA_A, 0x4016)
    a.op(LDX_I, 0x08)
    a.label("pad")
    a.abs_(LDA_A, 0x4016)
    a.op(LSR, ROL_Z, BUTTONS, DEX)
    a.branch(BNE, "pad")
    a.op(INC_Z, FRAME)
    # Colour: white while A, else red every 64th frame, else black.
    a.op(LDA_Z, BUTTONS, AND_I, 0x80)
    a.branch(BEQ, "not_a")
    a.op(LDA_I, WHITE)
    a.jmp("colour")
    a.label("not_a")
    a.op(LDA_Z, FRAME, AND_I, 0x3F)
    a.branch(BNE, "black")
    a.op(LDA_I, RED)
    a.jmp("colour")
    a.label("black")
    a.op(LDA_I, BLACK)
    a.label("colour")
    a.op(TAY)
    write_backdrop_from_y(a)
    a.op(LDA_I, 0x80)
    a.abs_(STA_A, 0x2000)  # nametable 0, NMI on
    # Start pressed (not held last frame): count it in battery RAM.
    a.op(LDA_Z, BUTTONS, AND_I, 0x10)
    a.branch(BEQ, "done")
    a.op(LDA_Z, PREV, AND_I, 0x10)
    a.branch(BNE, "done")
    a.abs_(INC_A, BATTERY)
    a.label("done")
    a.op(LDA_Z, BUTTONS, STA_Z, PREV)
    a.label("irq")
    a.op(RTI)

    code = a.resolve()
    prg = bytearray(PRG_SIZE)
    prg[: len(code)] = code
    for off, name in ((0x3FFA, "nmi"), (0x3FFC, "reset"), (0x3FFE, "irq")):
        addr = a.labels[name]
        prg[off] = addr & 0xFF
        prg[off + 1] = addr >> 8

    header = bytearray(16)
    header[0:4] = b"NES\x1a"
    header[4] = PRG_SIZE // 0x4000
    header[5] = CHR_SIZE // 0x2000
    header[6] = 0x02  # battery-backed PRG RAM, mapper 0, horizontal mirroring
    return bytes(header) + bytes(prg) + bytes(CHR_SIZE)


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("test.nes")
    out.write_bytes(build())


if __name__ == "__main__":
    main()
