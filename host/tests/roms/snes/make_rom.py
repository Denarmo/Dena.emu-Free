#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates test.sfc, our own SNES test ROM.

Spec: docs/specs/cores-m2.md. Behaviour: the backdrop is black, white while A is
held, and red on every 64th frame, so the picture changes over time. Each press
of Start increments the first byte of battery SRAM ($70:0000). No audio. A few
65816 instructions are encoded here, so no toolchain is needed.

Layout: 32 KiB LoROM, header at $7FC0 with a valid checksum, 2 KiB SRAM.

Usage: python make_rom.py [out.sfc]
"""
from __future__ import annotations

import sys
from pathlib import Path

ROM_SIZE = 0x8000
BASE = 0x8000  # bank 0 address of file offset 0


class Asm:
    """Tiny 65816 emitter (8-bit A and X/Y) with labels for branches."""

    def __init__(self) -> None:
        self.code = bytearray()
        self.labels: dict[str, int] = {}
        self.fixups: list[tuple[int, str]] = []

    @property
    def pc(self) -> int:
        return BASE + len(self.code)

    def label(self, name: str) -> None:
        self.labels[name] = self.pc

    def op(self, *b: int) -> None:
        self.code += bytes(b)

    def abs_(self, opcode: int, addr: int) -> None:
        self.op(opcode, addr & 0xFF, addr >> 8)

    def long(self, opcode: int, addr: int) -> None:
        self.op(opcode, addr & 0xFF, (addr >> 8) & 0xFF, addr >> 16)

    def branch(self, opcode: int, target: str) -> None:
        self.op(opcode, 0)
        self.fixups.append((len(self.code) - 1, target))

    def resolve(self) -> bytes:
        for at, target in self.fixups:
            rel = self.labels[target] - (BASE + at + 1)
            assert -128 <= rel <= 127, target
            self.code[at] = rel & 0xFF
        return bytes(self.code)


# Opcodes (M=1, X=1: 8-bit immediates).
SEI, CLC, XCE, SEP, LDX_I, TXS = 0x78, 0x18, 0xFB, 0xE2, 0xA2, 0x9A
LDA_I, LDA_A, STA_A, STZ_A, AND_I = 0xA9, 0xAD, 0x8D, 0x9C, 0x29
LDA_D, STA_D, INC_D, BNE, BEQ, BRA = 0xA5, 0x85, 0xE6, 0xD0, 0xF0, 0x80
LDA_L, STA_L, INC_A, RTI = 0xAF, 0x8F, 0x1A, 0x40

# Direct-page variables (WRAM).
FRAME, PREV_START, START = 0x00, 0x01, 0x02
SRAM = 0x700000

# Colours (BGR555): black, white, red.
BLACK, WHITE, RED = 0x0000, 0x7FFF, 0x001F


def backdrop(a: Asm, colour: int) -> None:
    """Writes CGRAM entry 0 (the backdrop)."""
    a.abs_(STZ_A, 0x2121)
    a.op(LDA_I, colour & 0xFF)
    a.abs_(STA_A, 0x2122)
    a.op(LDA_I, colour >> 8)
    a.abs_(STA_A, 0x2122)


def build() -> bytes:
    a = Asm()
    # RESET (emulation mode): switch to native mode, 8-bit registers.
    a.label("reset")
    a.op(SEI, CLC, XCE, SEP, 0x30, LDX_I, 0xFF, TXS)
    a.op(LDA_I, 0x80)
    a.abs_(STA_A, 0x2100)  # force blank
    a.abs_(STZ_A, 0x0000 + FRAME)
    a.abs_(STZ_A, 0x0000 + PREV_START)
    backdrop(a, BLACK)
    a.op(LDA_I, 0x0F)
    a.abs_(STA_A, 0x2100)  # screen on, full brightness
    a.op(LDA_I, 0x81)
    a.abs_(STA_A, 0x4200)  # NMI + auto joypad read
    a.label("idle")
    a.branch(BRA, "idle")

    # NMI (native mode).
    a.label("nmi")
    a.abs_(LDA_A, 0x4210)  # acknowledge
    a.label("wait_pad")
    a.abs_(LDA_A, 0x4212)
    a.op(AND_I, 0x01)
    a.branch(BNE, "wait_pad")
    a.op(INC_D, FRAME)
    # Colour: white while A ($4218 bit 7), else red every 64th frame, else black.
    a.abs_(LDA_A, 0x4218)
    a.op(AND_I, 0x80)
    a.branch(BEQ, "not_a")
    backdrop(a, WHITE)
    a.branch(BRA, "start")
    a.label("not_a")
    a.op(LDA_D, FRAME)
    a.op(AND_I, 0x3F)
    a.branch(BNE, "black")
    backdrop(a, RED)
    a.branch(BRA, "start")
    a.label("black")
    backdrop(a, BLACK)
    # Start ($4219 bit 4): count presses in battery SRAM.
    a.label("start")
    a.abs_(LDA_A, 0x4219)
    a.op(AND_I, 0x10)
    a.op(STA_D, START)
    a.branch(BEQ, "save_prev")
    a.op(LDA_D, PREV_START)
    a.branch(BNE, "save_prev")
    a.long(LDA_L, SRAM)
    a.op(INC_A)
    a.long(STA_L, SRAM)
    a.label("save_prev")
    a.op(LDA_D, START)
    a.op(STA_D, PREV_START)
    a.op(RTI)

    code = a.resolve()
    rom = bytearray(ROM_SIZE)
    rom[: len(code)] = code

    hdr = 0x7FC0
    rom[hdr : hdr + 21] = b"DENA SNES TEST       "
    rom[0x7FD5] = 0x20  # LoROM, slow
    rom[0x7FD6] = 0x02  # ROM + RAM + battery
    rom[0x7FD7] = 0x05  # 32 KiB
    rom[0x7FD8] = 0x01  # 2 KiB SRAM
    rom[0x7FD9] = 0x01  # North America
    rom[0x7FDA] = 0x00
    rom[0x7FDB] = 0x00

    def vec(off: int, addr: int) -> None:
        rom[off] = addr & 0xFF
        rom[off + 1] = addr >> 8

    idle = a.labels["idle"]
    for off in range(0x7FE4, 0x7FF0, 2):  # native COP BRK ABORT NMI - IRQ
        vec(off, idle)
    vec(0x7FEA, a.labels["nmi"])
    for off in range(0x7FF4, 0x8000, 2):  # emulation COP - ABORT NMI RESET IRQ
        vec(off, idle)
    vec(0x7FFC, a.labels["reset"])

    # Checksum over the ROM with the complement/checksum fields as FFFF 0000.
    rom[0x7FDC:0x7FE0] = b"\xff\xff\x00\x00"
    total = sum(rom) & 0xFFFF
    vec(0x7FDC, total ^ 0xFFFF)
    vec(0x7FDE, total)
    return bytes(rom)


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("test.sfc")
    out.write_bytes(build())


if __name__ == "__main__":
    main()
