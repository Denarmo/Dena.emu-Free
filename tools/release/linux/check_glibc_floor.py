# SPDX-License-Identifier: GPL-3.0-or-later
"""Fails when a portable Linux bundle needs a newer glibc or libstdc++ than
the stated floor (docs/dev/release-linux.md, "Oldest supported system").

Usage: check_glibc_floor.py --glibc 2.36 --glibcxx 3.4.30 <file or folder>...

Every ELF file under the given paths is read with `readelf -V`; the highest
GLIBC_x.y and GLIBCXX_x.y.z versions it needs are compared with the floors.
Prints the floors, the highest version found and every file above a floor.
Exit status: 0 within the floors, 1 above a floor, 2 on usage errors.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

# Only the "Version needs" part of readelf -V: what the file imports.
_NEEDS = re.compile(r"Name:\s+(GLIBC|GLIBCXX)_([0-9][0-9.]*)\b")


def parse_version(text: str) -> tuple:
    return tuple(int(p) for p in text.split(".") if p)


def needed_versions(readelf_output: str) -> dict:
    """Highest GLIBC and GLIBCXX version per family in readelf -V output."""
    best = {}
    in_needs = False
    for line in readelf_output.splitlines():
        if line.startswith("Version needs section"):
            in_needs = True
            continue
        if line.startswith("Version ") and "section" in line:
            in_needs = False  # symbols or definitions section
            continue
        if not in_needs:
            continue
        m = _NEEDS.search(line)
        if m:
            family, ver = m.group(1), parse_version(m.group(2))
            if ver > best.get(family, ()):
                best[family] = ver
    return best


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def elf_files(paths):
    for p in paths:
        p = Path(p)
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and not f.is_symlink() and is_elf(f):
                    yield f
        elif p.is_file() and is_elf(p):
            yield p


def fmt(ver: tuple) -> str:
    return ".".join(str(v) for v in ver)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--glibc", required=True, help="highest GLIBC version allowed, e.g. 2.36")
    ap.add_argument("--glibcxx", required=True, help="highest GLIBCXX version allowed, e.g. 3.4.30")
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args(argv)
    floors = {"GLIBC": parse_version(args.glibc), "GLIBCXX": parse_version(args.glibcxx)}

    print(f"glibc floor: GLIBC_{args.glibc}, GLIBCXX_{args.glibcxx} "
          "(the portable build must run on systems this old)")
    files = list(elf_files(args.paths))
    if not files:
        print("check_glibc_floor: no ELF files in " + " ".join(args.paths), file=sys.stderr)
        return 2
    highest = {}
    too_new = []
    for f in files:
        out = subprocess.run(["readelf", "-V", "-W", str(f)], check=True,
                             capture_output=True, text=True).stdout
        for family, ver in needed_versions(out).items():
            if ver > highest.get(family, ()):
                highest[family] = ver
            if ver > floors[family]:
                too_new.append(f"{f}: needs {family}_{fmt(ver)}")
    found = ", ".join(f"{k}_{fmt(v)}" for k, v in sorted(highest.items())) or "none"
    print(f"{len(files)} ELF files, highest needed: {found}")
    if too_new:
        print("\n".join(too_new), file=sys.stderr)
        print(f"check_glibc_floor: {len(too_new)} files need more than the floor", file=sys.stderr)
        return 1
    print("all files within the floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
