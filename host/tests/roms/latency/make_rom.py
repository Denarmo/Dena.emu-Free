#!/usr/bin/env python3
"""Generates latency.gba, our own GBA test ROM (GPL-3.0-or-later).

Spec: docs/specs/latency-spike.md. Behaviour: video mode 3; the whole screen is
black, and white while A is held. A 440 Hz square tone (PSG channel 2) plays
while A is held. No toolchain needed: a few ARM instructions are encoded here.
The Nintendo logo area of the header is left zeroed on purpose; emulators that
boot without the BIOS (as our cores do) do not check it.

Usage: python make_rom.py [out.gba]
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

AL, EQ, NE = 0xE, 0x0, 0x1
MOV, ORR, SUB, TST, MVN = 0b1101, 0b1100, 0b0010, 0b1000, 0b1111


def rot_imm(value: int) -> int:
    """Encodes a 32-bit constant as ARM rotate/imm8, or raises."""
    for rot in range(16):
        v = ((value << (2 * rot)) | (value >> (32 - 2 * rot))) & 0xFFFFFFFF
        if v <= 0xFF:
            return (rot << 8) | v
    raise ValueError(f"constant {value:#x} is not encodable")


def dp_imm(op: int, rd: int, rn: int, imm: int, s: int = 0, cond: int = AL) -> int:
    return (cond << 28) | (1 << 25) | (op << 21) | (s << 20) | (rn << 16) | (rd << 12) | rot_imm(imm)


def strh(rd: int, rn: int, off: int, cond: int = AL, load: bool = False) -> int:
    assert 0 <= off <= 0xFF
    return ((cond << 28) | (1 << 24) | (1 << 23) | (1 << 22) | (int(load) << 20) | (rn << 16)
            | (rd << 12) | ((off >> 4) << 8) | 0xB0 | (off & 0xF))


def str_post4(rd: int, rn: int) -> int:
    """str rd, [rn], #4"""
    return (AL << 28) | (0b01 << 26) | (1 << 23) | (rn << 16) | (rd << 12) | 4


def branch(cond: int, here: int, target: int) -> int:
    return (cond << 28) | (0b1010 << 24) | (((target - (here + 8)) >> 2) & 0xFFFFFF)


class Asm:
    def __init__(self, base: int):
        self.base = base
        self.words: list[int] = []

    @property
    def pc(self) -> int:
        return self.base + 4 * len(self.words)

    def emit(self, word: int) -> None:
        self.words.append(word)

    def const(self, rd: int, value: int) -> None:
        """mov/orr sequence loading an arbitrary 32-bit constant."""
        chunks = [(value >> s) & 0xFF for s in range(0, 32, 8)]
        first = True
        for i, c in enumerate(chunks):
            if c or (first and i == 3):
                part = c << (8 * i)
                self.emit(dp_imm(MOV, rd, 0, part) if first else dp_imm(ORR, rd, rd, part))
                first = False
        if first:
            self.emit(dp_imm(MOV, rd, 0, 0))


IO, VRAM = 0x04000000, 0x06000000
DISPCNT, KEYINPUT = 0x000, 0x130
SOUND2CNT_L, SOUND2CNT_H = 0x068, 0x06C
SOUNDCNT_L, SOUNDCNT_H, SOUNDCNT_X = 0x080, 0x082, 0x084


def program() -> bytes:
    a = Asm(0x08000000 + 0xC0)
    a.const(0, IO)                       # r0 = I/O base
    a.const(1, 0x0403)                   # mode 3, BG2 on
    a.emit(strh(1, 0, DISPCNT))
    a.const(1, 0x0080)                   # sound master enable
    a.emit(strh(1, 0, SOUNDCNT_X))
    a.const(1, 0x0002)                   # PSG at 100 %
    a.emit(strh(1, 0, SOUNDCNT_H))
    a.const(1, 0xF080)                   # ch2: 50 % duty, volume 15, no envelope
    a.emit(strh(1, 0, SOUND2CNT_L))
    a.const(1, 0x8000 | (2048 - 131072 // 440))  # ch2: 440 Hz, restart
    a.emit(strh(1, 0, SOUND2CNT_H))
    a.const(7, IO + KEYINPUT)            # r7 = &KEYINPUT
    a.const(8, 0x2277)                   # ch2 on, both sides, master volume 7
    a.const(9, 0x0077)                   # all channels off
    loop = a.pc
    a.emit(strh(2, 7, 0, load=True))     # ldrh r2, [r7]  (keys are active low)
    a.emit(dp_imm(TST, 0, 2, 1, s=1))    # tst r2, #1     (bit 0 = A)
    a.emit(dp_imm(MVN, 3, 0, 0x80000000, cond=EQ))  # pressed: r3 = 0x7fffffff (white)
    a.emit(dp_imm(MOV, 3, 0, 0, cond=NE))           # released: r3 = 0 (black)
    a.emit(strh(8, 0, SOUNDCNT_L, cond=EQ))
    a.emit(strh(9, 0, SOUNDCNT_L, cond=NE))
    a.const(4, VRAM)
    a.const(5, 240 * 160 // 2)           # words in a mode 3 frame
    fill = a.pc
    a.emit(str_post4(3, 4))
    a.emit(dp_imm(SUB, 5, 5, 1, s=1))
    a.emit(branch(NE, a.pc, fill))
    a.emit(branch(AL, a.pc, loop))
    return b"".join(struct.pack("<I", w) for w in a.words)


def header() -> bytes:
    h = bytearray(0xC0)
    struct.pack_into("<I", h, 0, branch(AL, 0x08000000, 0x080000C0))
    h[0xA0:0xAC] = b"DENA LATENCY"
    h[0xAC:0xB0] = b"ZDLT"
    h[0xB0:0xB2] = b"00"
    h[0xB2] = 0x96
    h[0xBD] = (-(sum(h[0xA0:0xBD]) + 0x19)) & 0xFF
    return bytes(h)


def build() -> bytes:
    rom = bytearray(header() + program())
    rom += b"\xff" * (-len(rom) % 1024)  # pad to 1 KiB
    return bytes(rom)


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("latency.gba")
    out.write_bytes(build())
    print(f"wrote {out} ({out.stat().st_size} bytes)")
