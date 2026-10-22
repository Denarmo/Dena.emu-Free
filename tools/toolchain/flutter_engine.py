#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fetches the pinned release Flutter engine for the handheld launcher (spec: docs/specs/toolchain-linux.md).

Reads tools/toolchain/flutter-engine.txt, fetches the pinned commit of the
release_repo (one shallow git fetch of release_tag, checked against
release_commit) and copies three files, each checked against its sha256, into
tools/toolchain/flutter-engine/release/:

  libflutter_engine.so  the linux-arm64 release (AOT) embedder engine
  gen_snapshot          x64 Linux host tool that compiles the app to libapp.so
  icudtl.dat            ICU data for the app bundle

Usage: python tools/toolchain/flutter_engine.py [--out DIR] [--cache DIR]
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIN = HERE / "flutter-engine.txt"
OUT = HERE / "flutter-engine" / "release"
CACHE = HERE / "flutter-engine" / "release-git"

# (file in the release_repo, name in OUT, pin key of its sha256)
FILES = [
    ("arm64/libflutter_engine.so.release", "libflutter_engine.so", "release_engine_sha256"),
    ("arm64/gen_snapshot_linux_x64_release", "gen_snapshot", "release_gen_snapshot_sha256"),
    ("arm64/icudtl.dat", "icudtl.dat", "release_icu_sha256"),
]


def read_pin(path=PIN):
    """key=value lines of flutter-engine.txt, comments and blanks skipped."""
    pin = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        pin[key.strip()] = value.strip()
    return pin


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def up_to_date(pin, out):
    """True when every file is already in out/ with its pinned hash."""
    return all((out / name).is_file() and sha256(out / name) == pin[key]
               for _, name, key in FILES)


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True,
                   env={**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"})


def fetch(pin, cache):
    """The release_repo at release_commit, checked out in cache/."""
    cache.mkdir(parents=True, exist_ok=True)
    if not (cache / ".git").is_dir():
        git("init", "-q", cwd=cache)
    git("fetch", "-q", "--depth", "1", pin["release_repo"],
        "refs/tags/%s" % pin["release_tag"], cwd=cache)
    head = subprocess.run(["git", "rev-parse", "FETCH_HEAD"], cwd=cache, check=True,
                          capture_output=True, text=True).stdout.strip()
    if head != pin["release_commit"]:
        raise SystemExit("error: %s is at %s, pinned %s"
                         % (pin["release_tag"], head, pin["release_commit"]))
    git("checkout", "-q", "--force", head, cwd=cache)


def install(pin, cache, out):
    """Copies FILES from cache/ to out/, refusing any hash mismatch."""
    for src, name, key in FILES:
        got = sha256(cache / src)
        if got != pin[key]:
            raise SystemExit("error: %s has sha256 %s, pinned %s" % (src, got, pin[key]))
    out.mkdir(parents=True, exist_ok=True)
    for src, name, _ in FILES:
        shutil.copyfile(cache / src, out / name)
    (out / "gen_snapshot").chmod(0o755)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="flutter_engine.py", description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--cache", type=Path, default=CACHE)
    args = parser.parse_args(argv)
    pin = read_pin()
    if up_to_date(pin, args.out):
        print("flutter engine %s: up to date in %s" % (pin["flutter"], args.out))
        return 0
    fetch(pin, args.cache)
    install(pin, args.cache, args.out)
    print("flutter engine %s (release): %s" % (pin["flutter"], args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
