#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks cross-built binaries for Linux handhelds (spec: docs/specs/toolchain-linux.md)."""

import argparse
import struct
import sys

EM_AARCH64 = 183
AARCH64_INTERP = "/lib/ld-linux-aarch64.so.1"

PT_INTERP = 3
DT_NULL = 0
DT_NEEDED = 1

SHT_STRTAB = 3
SHT_DYNAMIC = 6
SHT_GNU_VERNEED = 0x6FFFFFFE

_ELF_MAGIC = b"\x7fELF"


def _cstr(data, offset):
    """Return the NUL-terminated (or run-to-end) string at *offset*."""
    end = data.find(b"\0", offset)
    if end < 0:
        end = len(data)
    return data[offset:end].decode("latin-1")


def _version_key(text):
    """Return a numeric version tuple for '2.17', or None if not numeric."""
    parts = text.split(".")
    if not parts or not all(p.isdigit() for p in parts):
        return None
    return tuple(int(p) for p in parts)


def _sections(data, shoff, shentsize, shnum):
    sections = []
    for i in range(shnum):
        fmt = "<IIQQQQIIQQ"
        (sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size,
         sh_link, sh_info, sh_addralign, sh_entsize) = struct.unpack_from(
            fmt, data, shoff + i * shentsize)
        sections.append({
            "name": sh_name, "type": sh_type, "offset": sh_offset,
            "size": sh_size, "link": sh_link, "entsize": sh_entsize,
        })
    return sections


def _interpreter(data, phoff, phentsize, phnum):
    for i in range(phnum):
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
            struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize)
        if p_type == PT_INTERP:
            raw = data[p_offset:p_offset + p_filesz]
            return raw.split(b"\0", 1)[0].decode("latin-1")
    return None


def _needed(data, sections):
    names = []
    for sh in sections:
        if sh["type"] != SHT_DYNAMIC or sh["link"] >= len(sections):
            continue
        strtab = sections[sh["link"]]["offset"]
        for off in range(sh["offset"], sh["offset"] + sh["size"], 16):
            tag, val = struct.unpack_from("<QQ", data, off)
            if tag == DT_NULL:
                break
            if tag == DT_NEEDED:
                names.append(_cstr(data, strtab + val))
    return names


def _glibc_versions(data, sections):
    found = set()
    for sh in sections:
        if sh["type"] != SHT_GNU_VERNEED or sh["link"] >= len(sections):
            continue
        strtab = sections[sh["link"]]["offset"]
        off = sh["offset"]
        end = sh["offset"] + sh["size"]
        while off < end:
            _ver, cnt, _file, aux, nxt = struct.unpack_from("<HHIII", data, off)
            aux_off = sh["offset"] + aux
            for _ in range(cnt):
                _hash, _flags, _other, name, aux_nxt = struct.unpack_from(
                    "<IHHII", data, aux_off)
                text = _cstr(data, strtab + name)
                if text.startswith("GLIBC_"):
                    key = _version_key(text[len("GLIBC_"):])
                    if key is not None:
                        found.add(text[len("GLIBC_"):])
                if aux_nxt == 0:
                    break
                aux_off += aux_nxt
            if nxt == 0:
                break
            off += nxt
    return sorted(found, key=_version_key)


def read_elf(data: bytes) -> dict:
    """Parse a 64-bit little-endian ELF image into the fields we check."""
    if len(data) < 64 or data[:4] != _ELF_MAGIC:
        raise ValueError("not an ELF file (bad magic)")
    if data[4] != 2:
        raise ValueError("unsupported ELF class %d (need 64-bit)" % data[4])
    if data[5] != 1:
        raise ValueError("unsupported ELF data encoding %d (need little-endian)" % data[5])

    machine = struct.unpack_from("<H", data, 18)[0]
    phoff = struct.unpack_from("<Q", data, 32)[0]
    shoff = struct.unpack_from("<Q", data, 40)[0]
    phentsize = struct.unpack_from("<H", data, 54)[0]
    phnum = struct.unpack_from("<H", data, 56)[0]
    shentsize = struct.unpack_from("<H", data, 58)[0]
    shnum = struct.unpack_from("<H", data, 60)[0]

    sections = _sections(data, shoff, shentsize, shnum) if shnum else []
    return {
        "machine": machine,
        "interpreter": _interpreter(data, phoff, phentsize, phnum) if phnum else None,
        "glibc_versions": _glibc_versions(data, sections),
        "needed": _needed(data, sections),
    }


def check(data: bytes, max_glibc: str = "2.28") -> list:
    """Return the list of problems with *data* (empty means it is fine)."""
    info = read_elf(data)
    problems = []

    if info["machine"] != EM_AARCH64:
        problems.append(
            "machine is %d, expected %d (EM_AARCH64)" % (info["machine"], EM_AARCH64))

    interp = info["interpreter"]
    if interp is not None and interp != AARCH64_INTERP:
        problems.append("interpreter is %r, expected %r" % (interp, AARCH64_INTERP))

    limit = _version_key(max_glibc)
    for version in info["glibc_versions"]:
        if _version_key(version) > limit:
            problems.append("needs GLIBC_%s, newer than %s" % (version, max_glibc))

    return problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="elfcheck.py", description=__doc__.splitlines()[0])
    parser.add_argument("--max-glibc", default="2.28",
                        help="oldest glibc the target may need (default: 2.28)")
    parser.add_argument("files", nargs="+", metavar="FILE")
    args = parser.parse_args(argv)

    ok = True
    for path in args.files:
        try:
            with open(path, "rb") as handle:
                problems = check(handle.read(), args.max_glibc)
        except (OSError, ValueError) as exc:
            problems = [str(exc)]
        if problems:
            ok = False
            for problem in problems:
                print("%s: %s" % (path, problem))
        else:
            print("OK %s" % path)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
