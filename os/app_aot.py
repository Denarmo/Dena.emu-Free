#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the handheld app as a release (AOT) bundle for the launcher.

Spec: docs/specs/embedder.md (Build inputs), toolchain-linux.md. Three steps,
with the app's own Flutter SDK and the release engine fetched by
``tools/toolchain/flutter_engine.py``:

1. ``flutter build bundle --target-platform=linux-arm64`` for the assets
   (fonts, images, shaders, native assets); its JIT files are not used.
2. The SDK's frontend server compiles ``lib/main.dart`` to a product-mode
   kernel (``--aot --tfa``, ``dart.vm.product=true``, so ``kReleaseMode``).
3. The engine's ``gen_snapshot`` turns that kernel into ``libapp.so``, an
   AArch64 ELF the release engine loads (``dena-launcher`` reads
   ``<bundle>/lib/libapp.so``). gen_snapshot is an x64 Linux binary: on
   Windows it runs through WSL.

Output: ``app/build/flutter_assets`` (assets) and
``app/build/linux-aot/libapp.so``, which ``os/payload.py`` picks up.

Usage: python os/app_aot.py [--flutter SDK] [--dart-define K=V ...]
                            [--skip-bundle]
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
PIN = ROOT / "tools" / "toolchain" / "flutter-engine.txt"
GEN_SNAPSHOT = ROOT / "tools" / "toolchain" / "flutter-engine" / "release" / "gen_snapshot"
OUT = APP / "build" / "linux-aot"
ENTRY = "lib/main.dart"


def read_pin(path=PIN):
    pin = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            pin[key.strip()] = value.strip()
    return pin


def find_sdk(given=None):
    """The Flutter SDK root: --flutter, FLUTTER_ROOT, or flutter on PATH."""
    if given:
        return Path(given)
    if os.environ.get("FLUTTER_ROOT"):
        return Path(os.environ["FLUTTER_ROOT"])
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("error: no Flutter SDK (pass --flutter or set FLUTTER_ROOT)")
    return Path(flutter).resolve().parent.parent


def check_engine(sdk: Path, pin) -> None:
    """The SDK must be the one the release engine was built for."""
    version = sdk / "bin" / "internal" / "engine.version"
    got = version.read_text().strip() if version.is_file() else "unknown"
    if got != pin["engine"]:
        raise SystemExit("error: Flutter SDK engine %s, the handheld engine is %s "
                         "(Flutter %s); switch SDKs or bump tools/toolchain/flutter-engine.txt"
                         % (got, pin["engine"], pin["flutter"]))


def wsl_path(path: Path) -> str:
    """C:\\a\\b -> /mnt/c/a/b, for running gen_snapshot through WSL."""
    p = Path(path).resolve()
    drive = p.drive.rstrip(":").lower()
    rest = p.as_posix()[len(p.drive):]
    return "/mnt/%s%s" % (drive, rest)


def kernel_command(sdk: Path, dill: Path, defines) -> list:
    dart = sdk / "bin" / "cache" / "dart-sdk" / "bin"
    runtime = dart / ("dartaotruntime.exe" if os.name == "nt" else "dartaotruntime")
    snapshot = dart / "snapshots" / "frontend_server_aot.dart.snapshot"
    patched = sdk / "bin" / "cache" / "artifacts" / "engine" / "common" / "flutter_patched_sdk_product"
    cmd = [str(runtime), str(snapshot),
           "--sdk-root", str(patched) + os.sep,
           "--target=flutter", "--aot", "--tfa", "--no-print-incremental-dependencies",
           "-Ddart.vm.product=true", "-Ddart.vm.profile=false",
           "--packages", str(APP / ".dart_tool" / "package_config.json"),
           "--output-dill", str(dill)]
    cmd += ["-D%s" % d for d in defines]
    cmd.append(str(APP / ENTRY))
    return cmd


def snapshot_command(gen_snapshot: Path, dill: Path, elf: Path) -> list:
    args = ["--deterministic", "--snapshot_kind=app-aot-elf", "--strip"]
    if os.name == "nt":
        return ["wsl", "-e", wsl_path(gen_snapshot), *args,
                "--elf=" + wsl_path(elf), wsl_path(dill)]
    return [str(gen_snapshot), *args, "--elf=" + str(elf), str(dill)]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="app_aot.py", description=__doc__.splitlines()[0])
    parser.add_argument("--flutter", help="Flutter SDK root")
    parser.add_argument("--dart-define", action="append", default=[], metavar="K=V")
    parser.add_argument("--skip-bundle", action="store_true",
                        help="reuse app/build/flutter_assets")
    args = parser.parse_args(argv)

    pin = read_pin()
    sdk = find_sdk(args.flutter)
    check_engine(sdk, pin)
    if not GEN_SNAPSHOT.is_file():
        raise SystemExit("error: no %s; run python tools/toolchain/flutter_engine.py"
                         % GEN_SNAPSHOT.relative_to(ROOT).as_posix())
    flutter = sdk / "bin" / ("flutter.bat" if os.name == "nt" else "flutter")
    if not args.skip_bundle:
        cmd = [str(flutter), "build", "bundle", "--target-platform=linux-arm64"]
        cmd += ["--dart-define=%s" % d for d in args.dart_define]
        subprocess.run(cmd, cwd=APP, check=True)
    OUT.mkdir(parents=True, exist_ok=True)
    dill = OUT / "app.dill"
    elf = OUT / "libapp.so"
    subprocess.run(kernel_command(sdk, dill, args.dart_define), cwd=APP, check=True)
    subprocess.run(snapshot_command(GEN_SNAPSHOT, dill, elf), check=True)
    print("app (AOT, Flutter %s): %s, %d bytes"
          % (pin["flutter"], elf.relative_to(ROOT).as_posix(), elf.stat().st_size))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
