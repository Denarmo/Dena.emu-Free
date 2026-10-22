#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assembles the cross-built payload directory for ``os/build_sd.py``.

Spec: docs/specs/sd-card.md (``Builder``, ``--payload``). ``build_sd.py``
copies a payload's ``bin/`` and ``lib/`` straight into ``Dena/`` on the card,
so this script gathers what the aarch64 cross build produced: the launcher
binaries (``shells/linux/build-aarch64/``) and the libretro cores
(``cores/build/linux-aarch64/*_libretro.so``), plus the Flutter engine and
the app bundle when built (release: ``os/app_aot.py``). Each file is validated with
``tools/toolchain/elfcheck.py`` and then stripped (``llvm-strip``) to keep the
card small.

Usage: python os/payload.py --out DIR [--root REPO] [--strip PATH]
                            [--allow-missing]
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# What build_sd.py's payload expects (sd-card.md, Layout: Dena/bin, Dena/lib).
BIN_NAMES = ("dena-launcher", "dena-powerd", "dena-keytest")
BIN_SRC = Path("shells") / "linux" / "build-aarch64"
LIB_SRC = Path("cores") / "build" / "linux-aarch64"
LIB_GLOB = "*_libretro.so"
ELFCHECK = Path("tools") / "toolchain" / "elfcheck.py"
# Bundled shader presets (shaders.md) -> data/shaders/<id>/<id>.glslp.
SHADERS_SRC = Path("host") / "shaders"
# The app (embedder.md). Release, what the handheld ships: the release engine
# (tools/toolchain/flutter_engine.py) and the AOT app from os/app_aot.py
# (app/build/linux-aot/libapp.so, assets in app/build/flutter_assets).
# Debug, development only: Google's debug/JIT embedder engine and the bundle
# from `flutter build bundle --debug --target-platform=linux-arm64`
# (kernel_blob.bin, compiled on the device at every start). All optional.
ENGINE_DIR = Path("tools") / "toolchain" / "flutter-engine"
ENGINE_RELEASE_SRC = ENGINE_DIR / "release" / "libflutter_engine.so"
ICU_RELEASE_SRC = ENGINE_DIR / "release" / "icudtl.dat"
ENGINE_DEBUG_SRC = ENGINE_DIR / "debug-embedder" / "libflutter_engine.so"
AOT_SRC = Path("app") / "build" / "linux-aot" / "libapp.so"
ASSETS_SRC = Path("app") / "build" / "flutter_assets"
# What a release bundle leaves out of flutter_assets: the JIT kernel and
# snapshots (the AOT app replaces them) and the host's native assets (lib/).
JIT_FILES = ("kernel_blob.bin", "vm_snapshot_data", "isolate_snapshot_data")
NATIVE_SRC = ASSETS_SRC / "native_assets" / "linux"


def find_icu():
    """icudtl.dat from the Flutter SDK cache (the same file on every host)."""
    flutter = shutil.which("flutter")
    if not flutter:
        return None
    engine = Path(flutter).resolve().parent / "cache" / "artifacts" / "engine"
    found = sorted(engine.glob("*/icudtl.dat")) if engine.is_dir() else []
    return found[0] if found else None


def load_elfcheck():
    """Import tools/toolchain/elfcheck.py from this repo checkout."""
    path = ROOT / ELFCHECK
    spec = importlib.util.spec_from_file_location("payload_elfcheck", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _version_key(name):
    """Sort key for NDK directory names such as '26.1.10909125'."""
    parts = []
    for token in name.replace("-", ".").split("."):
        parts.append(int(token) if token.isdigit() else 0)
    return tuple(parts)


def _ndk_roots():
    roots = []
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(var)
        if value:
            roots.append(Path(value))
    local = os.environ.get("LOCALAPPDATA")
    if local:
        roots.append(Path(local) / "Android" / "Sdk")
    return roots


def _ndk_strip():
    """Newest llvm-strip under an Android NDK, or None."""
    found = []
    for root in _ndk_roots():
        ndk = root / "ndk"
        if not ndk.is_dir():
            continue
        for version in ndk.iterdir():
            prebuilt = version / "toolchains" / "llvm" / "prebuilt"
            if not prebuilt.is_dir():
                continue
            for host in prebuilt.iterdir():
                for name in ("llvm-strip", "llvm-strip.exe"):
                    candidate = host / "bin" / name
                    if candidate.is_file():
                        found.append((_version_key(version.name), str(candidate)))
    if not found:
        return None
    found.sort(key=lambda item: item[0])
    return found[-1][1]


def find_strip():
    """Path to llvm-strip: LLVM_STRIP, PATH, then the newest Android NDK."""
    env = os.environ.get("LLVM_STRIP")
    if env:
        return env
    on_path = shutil.which("llvm-strip")
    if on_path:
        return on_path
    return _ndk_strip()


def app_mode(root: Path):
    """'release' with an AOT app, 'debug' with only a JIT bundle, else None."""
    if (root / AOT_SRC).is_file():
        return "release"
    if (root / ASSETS_SRC / "kernel_blob.bin").is_file():
        return "debug"
    return None


def engine_src(root: Path):
    """The engine matching the app: release for AOT, debug for JIT."""
    return ENGINE_DEBUG_SRC if app_mode(root) == "debug" else ENGINE_RELEASE_SRC


def collect(root: Path) -> list:
    """Return [(src Path, dest relative Path)] for the files that exist."""
    files = []
    for name in BIN_NAMES:
        src = root / BIN_SRC / name
        if src.is_file():
            files.append((src, Path("bin") / name))
    for src in sorted((root / LIB_SRC).glob(LIB_GLOB)):
        files.append((src, Path("lib") / src.name))
    engine = engine_src(root)
    if (root / engine).is_file():
        files.append((root / engine, Path("lib") / engine.name))
    for src in sorted((root / NATIVE_SRC).glob("*.so")):  # e.g. libsqlite3.so
        files.append((src, Path("lib") / src.name))
    return files


def assemble(root: Path, out: Path, strip, allow_missing: bool) -> int:
    """Build out/ from root/; *strip* is a command as a list, or None."""
    elfcheck = load_elfcheck()
    root = Path(root)
    out = Path(out)

    missing = [n for n in BIN_NAMES if not (root / BIN_SRC / n).is_file()]
    cores = sorted((root / LIB_SRC).glob(LIB_GLOB))
    if not allow_missing:
        if missing:
            print("error: missing binaries: %s" % ", ".join(missing),
                  file=sys.stderr)
            return 1
        if not cores:
            print("error: no libretro cores found under %s" % (root / LIB_SRC),
                  file=sys.stderr)
            return 1
    else:
        if missing:
            print("skipping missing binaries: %s" % ", ".join(missing))
        if not cores:
            print("skipping: no libretro cores found under %s" % (root / LIB_SRC))

    mode = app_mode(root)
    if mode == "release" and not (root / ENGINE_RELEASE_SRC).is_file():
        print("%s: no release engine %s (run python tools/toolchain/flutter_engine.py)"
              % ("warning" if allow_missing else "error", ENGINE_RELEASE_SRC.as_posix()),
              file=sys.stderr)
        if not allow_missing:
            return 1
    if mode == "release" and not (root / ASSETS_SRC).is_dir():
        print("error: AOT app without %s (run python os/app_aot.py)" % ASSETS_SRC.as_posix(),
              file=sys.stderr)
        return 1
    if mode == "debug":
        print("warning: debug (JIT) app bundle: slow start and slow UI on the "
              "handheld; build the release app with python os/app_aot.py",
              file=sys.stderr)

    # Validate everything before touching out/.
    entries = collect(root)
    aot = [(root / AOT_SRC, Path("data") / "app" / "lib" / "libapp.so")] if mode == "release" else []
    for src, dest in entries + aot:
        try:
            problems = elfcheck.check(src.read_bytes())
        except (OSError, ValueError) as exc:
            problems = [str(exc)]
        if problems:
            for problem in problems:
                print("%s: %s" % (dest.as_posix(), problem), file=sys.stderr)
            return 1

    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    total_before = 0
    total_after = 0
    for src, dest in entries:
        target = out / dest
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, target)
        before = target.stat().st_size
        if strip:
            subprocess.run([*strip, "--strip-unneeded", str(target)], check=True)
        after = target.stat().st_size
        if dest.parent.name == "bin":
            target.chmod(0o755)
        total_before += before
        total_after += after
        print("%s  %d -> %d bytes" % (dest.as_posix(), before, after))
    shaders = root / SHADERS_SRC
    if shaders.is_dir():
        shutil.copytree(shaders, out / "data" / "shaders",
                        ignore=shutil.ignore_patterns("README*"))
        count = sum(1 for p in (out / "data" / "shaders").iterdir() if p.is_dir())
        print("data/shaders  %d presets" % count)
    assets = root / ASSETS_SRC
    if mode:
        app = out / "data" / "app"
        ignore = ["native_assets"] + (list(JIT_FILES) if mode == "release" else [])
        shutil.copytree(assets, app / "flutter_assets",
                        ignore=shutil.ignore_patterns(*ignore))
        for src, dest in aot:  # not stripped: the engine reads its symbols
            (out / dest).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, out / dest)
            print("%s  %d bytes" % (dest.as_posix(), (out / dest).stat().st_size))
        icu = root / ICU_RELEASE_SRC
        icu = icu if icu.is_file() else find_icu()
        if icu:
            shutil.copyfile(icu, app / "icudtl.dat")
        else:
            print("warning: no icudtl.dat (release engine or Flutter SDK cache)",
                  file=sys.stderr)
        print("data/app  %s: flutter_assets%s" % (
            "release (AOT)" if mode == "release" else "debug (JIT)",
            " + icudtl.dat" if icu else ""))
    else:
        print("skipping the app bundle: run python os/app_aot.py")
    if not (root / engine_src(root)).is_file():
        print("skipping the engine: no %s" % engine_src(root).as_posix())
    print("total  %d -> %d bytes (%d files)"
          % (total_before, total_after, len(entries)))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="payload.py", description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True,
                        help="payload directory to (re)create")
    parser.add_argument("--root", type=Path, default=ROOT,
                        help="repo root to read the build outputs from")
    parser.add_argument("--strip", type=Path,
                        help="strip tool to run (default: llvm-strip)")
    parser.add_argument("--allow-missing", action="store_true",
                        help="warn and continue instead of erroring")
    args = parser.parse_args(argv)

    if args.strip:
        strip = [str(args.strip)]
    else:
        found = find_strip()
        if found:
            strip = [found]
        else:
            print("warning: no llvm-strip found; copying without stripping",
                  file=sys.stderr)
            strip = None
    return assemble(args.root, args.out, strip, args.allow_missing)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
