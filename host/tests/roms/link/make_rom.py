#!/usr/bin/env python3
"""Generates our own link cable test ROMs (GPL-3.0-or-later).

Spec: docs/specs/link-cable.md. Two Game Boy ROMs, one per side of the cable:
- link_master.gb drives the clock and sends 0x11, 0x22, 0x33; a byte that comes
  back as 0xFF (the other side was not ready) is sent again.
- link_slave.gb waits on the external clock and answers 0x99, 0xAA, 0xBB.
Each stores the three bytes it received at cartridge RAM 0xA000 (MBC1+RAM, so
the frontend reads them as save RAM), then spins.
Two Game Boy Advance ROMs do the same in multiplayer mode: link_parent.gba sends
0x1111, 0x2222, 0x3333 (again when 0xFFFF comes back), link_child.gba answers
0x9999, 0xAAAA, 0xBBBB; each stores the low byte of what it received in SRAM.
No toolchain needed: the SM83 code is encoded here. Only the 4-byte magic
mGBA uses to recognise a Game Boy ROM goes in the logo area (the same 4 bytes
mGBA itself writes when it creates a ROM header); the rest stays zeroed.

Usage: python make_rom.py [out_dir]
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path


def program(master: bool) -> bytes:
    out = [0x11, 0x22, 0x33] if master else [0x99, 0xAA, 0xBB]
    sc = 0x81 if master else 0x80
    code = bytearray()
    labels: dict[str, int] = {}
    fixups: list[tuple[int, str]] = []

    def emit(*b: int) -> None:
        code.extend(b)

    def jr(op: int, label: str) -> None:
        emit(op, 0)
        fixups.append((len(code) - 1, label))

    emit(0xF3)                    # di
    emit(0x31, 0xFE, 0xDF)        # ld sp, $DFFE
    emit(0x3E, 0x0A)              # ld a, $0A
    emit(0xEA, 0x00, 0x00)        # ld ($0000), a   ; enable cart RAM
    emit(0x21, 0x00, 0x02)        # ld hl, $0200    ; bytes to send
    emit(0x11, 0x00, 0xA0)        # ld de, $A000    ; bytes received
    emit(0x06, 0x03)              # ld b, 3
    labels["next"] = len(code)
    emit(0x2A)                    # ld a, (hl+)
    emit(0x4F)                    # ld c, a
    labels["retry"] = len(code)
    emit(0x79)                    # ld a, c
    emit(0xE0, 0x01)              # ldh (SB), a
    emit(0x3E, sc)                # ld a, sc
    emit(0xE0, 0x02)              # ldh (SC), a
    labels["wait"] = len(code)
    emit(0xF0, 0x02)              # ldh a, (SC)
    emit(0xCB, 0x7F)              # bit 7, a
    jr(0x20, "wait")              # jr nz, wait
    emit(0xF0, 0x01)              # ldh a, (SB)
    if master:
        emit(0xFE, 0xFF)          # cp $FF
        jr(0x28, "retry")         # jr z, retry
    emit(0x12)                    # ld (de), a
    emit(0x13)                    # inc de
    emit(0x05)                    # dec b
    jr(0x20, "next")              # jr nz, next
    labels["done"] = len(code)
    jr(0x18, "done")              # jr done
    for at, label in fixups:
        code[at] = (labels[label] - (at + 1)) & 0xFF

    rom = bytearray(0x8000)
    rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])  # nop; jp $0150
    rom[0x104:0x108] = bytes([0xCE, 0xED, 0x66, 0x66])
    title = b"DENALINK" + (b"M" if master else b"S")
    rom[0x134:0x134 + len(title)] = title
    rom[0x147] = 0x03  # MBC1 + RAM + battery
    rom[0x148] = 0x00  # 32 KiB ROM
    rom[0x149] = 0x02  # 8 KiB RAM
    rom[0x14D] = (-sum(rom[0x134:0x14D]) - (0x14D - 0x134)) & 0xFF
    rom[0x150:0x150 + len(code)] = code
    rom[0x200:0x203] = bytes(out)
    total = sum(rom) - rom[0x14E] - rom[0x14F]
    rom[0x14E:0x150] = (total & 0xFFFF).to_bytes(2, "big")
    return bytes(rom)


# --- GBA (ARM) ---
AL, EQ, NE = 0xE, 0x0, 0x1
MOV, ORR, SUB, ADD, TST, CMP = 0b1101, 0b1100, 0b0010, 0b0100, 0b1000, 0b1010


def rot_imm(value: int) -> int:
    for rot in range(16):
        v = ((value << (2 * rot)) | (value >> (32 - 2 * rot))) & 0xFFFFFFFF
        if v <= 0xFF:
            return (rot << 8) | v
    raise ValueError(f"constant {value:#x} is not encodable")


def dp_imm(op: int, rd: int, rn: int, imm: int, s: int = 0, cond: int = AL) -> int:
    return (cond << 28) | (1 << 25) | (op << 21) | (s << 20) | (rn << 16) | (rd << 12) | rot_imm(imm)


def cmp_reg(rn: int, rm: int) -> int:
    return (AL << 28) | (CMP << 21) | (1 << 20) | (rn << 16) | rm


def halfword(rd: int, rn: int, off: int, load: bool = False) -> int:
    """strh/ldrh rd, [rn, #off]"""
    assert 0 <= off <= 0xFF
    return ((AL << 28) | (1 << 24) | (1 << 23) | (1 << 22) | (int(load) << 20) | (rn << 16)
            | (rd << 12) | ((off >> 4) << 8) | 0xB0 | (off & 0xF))


def strb_post1(rd: int, rn: int) -> int:
    """strb rd, [rn], #1"""
    return (AL << 28) | (0b01 << 26) | (1 << 23) | (1 << 22) | (rn << 16) | (rd << 12) | 1


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
        chunks = [(value >> s) & 0xFF for s in range(0, 32, 8)]
        first = True
        for i, c in enumerate(chunks):
            if c:
                self.emit(dp_imm(MOV, rd, 0, c << (8 * i)) if first else dp_imm(ORR, rd, rd, c << (8 * i)))
                first = False
        if first:
            self.emit(dp_imm(MOV, rd, 0, 0))


SIOMULTI0, SIOMULTI1, SIOCNT, SIOMLT_SEND, RCNT, IF = 0x20, 0x22, 0x28, 0x2A, 0x34, 0x02


def gba_program(parent: bool) -> bytes:
    out = [0x1111, 0x2222, 0x3333] if parent else [0x9999, 0xAAAA, 0xBBBB]
    a = Asm(0x080000C0)
    a.const(1, 0x04000100)               # r1 = SIO registers
    a.const(2, 0x04000200)               # r2 = interrupt registers
    a.const(3, 0x0E000000)               # r3 = SRAM
    a.const(5, 3)                        # r5 = transfers left
    a.const(6, 0)
    a.emit(halfword(6, 1, RCNT))         # RCNT = 0: serial modes
    a.const(6, 0x6003)                   # multiplayer, IRQ, 115200 baud
    a.emit(halfword(6, 1, SIOCNT))
    a.const(8, 0xFFFF)
    a.const(10, 0x7FF0)                  # r10 = values (patched below)
    table_fix = len(a.words) - 2
    nxt = a.pc
    a.emit(halfword(7, 10, 0, load=True))  # ldrh r7, [r10]
    a.emit(dp_imm(ADD, 10, 10, 2))
    retry = a.pc
    a.emit(halfword(7, 1, SIOMLT_SEND))
    a.const(6, 0x80)
    a.emit(halfword(6, 2, IF))           # acknowledge any old serial IRQ
    if parent:
        a.const(6, 0x6083)
        a.emit(halfword(6, 1, SIOCNT))   # start
    wait = a.pc
    a.emit(halfword(6, 2, IF, load=True))
    a.emit(dp_imm(TST, 0, 6, 0x80, s=1))
    a.emit(branch(EQ, a.pc, wait))
    a.emit(halfword(6, 1, SIOMULTI1 if parent else SIOMULTI0, load=True))
    if parent:
        a.emit(cmp_reg(6, 8))
        a.emit(branch(EQ, a.pc, retry))
    a.emit(strb_post1(6, 3))
    if parent:
        a.const(9, 0x8000)               # let the child set up its next word
        delay = a.pc
        a.emit(dp_imm(SUB, 9, 9, 1, s=1))
        a.emit(branch(NE, a.pc, delay))
    a.emit(dp_imm(SUB, 5, 5, 1, s=1))
    a.emit(branch(NE, a.pc, nxt))
    done = a.pc
    a.emit(branch(AL, a.pc, done))
    table = a.pc
    # Point r10 at the table: rebuild its two-instruction constant in place.
    a.words[table_fix] = dp_imm(MOV, 10, 0, table & 0xFF000000)
    a.words[table_fix + 1] = dp_imm(ORR, 10, 10, table & 0x00FFFFFF)
    code = b"".join(struct.pack("<I", w) for w in a.words)
    code += b"".join(struct.pack("<H", v) for v in out)

    h = bytearray(0xC0)
    struct.pack_into("<I", h, 0, branch(AL, 0x08000000, 0x080000C0))
    title = b"DENA LINK " + (b"P" if parent else b"C")
    h[0xA0:0xA0 + len(title)] = title
    h[0xAC:0xB0] = b"ZDLK"
    h[0xB0:0xB2] = b"00"
    h[0xB2] = 0x96
    h[0xBD] = (-(sum(h[0xA0:0xBD]) + 0x19)) & 0xFF
    rom = bytearray(h + code)
    rom += b"SRAM_V113"                  # save type tag: battery SRAM
    rom += b"\xff" * (-len(rom) % 1024)
    return bytes(rom)


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent
    out.mkdir(parents=True, exist_ok=True)
    (out / "link_master.gb").write_bytes(program(True))
    (out / "link_slave.gb").write_bytes(program(False))
    (out / "link_parent.gba").write_bytes(gba_program(True))
    (out / "link_child.gba").write_bytes(gba_program(False))


if __name__ == "__main__":
    main()
