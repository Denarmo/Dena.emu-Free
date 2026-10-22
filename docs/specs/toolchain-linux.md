# Spec: aarch64 Linux cross toolchain

Status: in progress (Milestone 4, package 5). Zig installed on the dev PC
with the user's yes (2026-10-16); daemon, tools and emulator host
cross-build and pass the ELF check, and so do all cores. The embedder
comes next.

## What it builds

- `dena-powerd`, `dena-keytest` (`shells/linux`) and the emulator host
  (`host`) for aarch64 Linux, linked against glibc 2.28: the oldest stock
  firmware we target is unverified, so an old glibc keeps us safe.
- The libretro cores, from the same pinned commits as Android:
  `cores/<name>/build.sh linux-aarch64` into `cores/build/linux-aarch64`.
  Make-based cores build from a copy of the tracked sources in
  `cores/build/obj/<name>-linux-aarch64` (the host build's objects live in
  the checkout). The copy is made again when the pinned commit or the
  recipe changes (the core's `build.sh` and its fixup files, and
  `libretro-make.sh`), so a source fixup added later always reaches the
  handheld core (a stale copy once shipped fake-08 without the system RAM
  fixup, and Dena Explore never heard the app). Per-core settings are `LINUX_MAKE`, `LINUX_CC`,
  `LINUX_CFLAGS` in each `build.sh` (PCSX ReARMed: ari64 dynarec;
  melonDS: ARM JIT, no desktop GL; fake-08: its Lua is C++; bsnes: a
  libc++ strictness flag). mGBA uses the CMake toolchain file.
  N64 (Mupen64Plus-Next, upstream's generic Cortex-A53 GLES 3 target) and
  PSP (PPSSPP, GLES through EGL, no ccache) link EGL/GLES from the sysroot.
  Debian's libraries need a newer glibc than ours, so links use
  `--allow-shlib-undefined`; the device's own EGL/GLES are used at run time.
- Next: `dena-launcher` (embedder.md).

## Tools

- **Zig** (MIT) as the C/C++ cross compiler, target `aarch64-linux-gnu.2.28`.
  Version and per-host checksums pinned in `tools/toolchain/zig.txt`;
  `tools/toolchain/zig.sh install` downloads, verifies and unpacks it into
  the user's folder (no admin), `zig.sh path` finds it (`DENA_ZIG` wins).
- **`tools/toolchain/zig-cc.sh`** wraps `zig cc` for Makefiles: GNU-ld
  spellings zig rejects (`-Wl,-no-undefined`), GCC CPU names
  (`-mcpu=cortex-a53` becomes `cortex_a53`, `-mtune` dropped), extra flags
  (`DENA_CFLAGS`), sysroot libraries named as files (`DENA_LIBDIR`: zig's
  `-l:<path>` hand-off to lld fails on Windows), and C sources compiled as
  C++ when `c++` is the C compiler.
- **CMake toolchain file** `tools/toolchain/aarch64-linux.cmake`: writes
  small `zig cc` / `c++` / `ar` / `ranlib` wrappers into the build folder
  (CMake can't pass a subcommand). Builds go to `<project>/build-aarch64`.
- **Sysroot** (`tools/toolchain/sysroot.py`, user's yes 2026-10-16): libdrm,
  gbm, EGL/GLES (libglvnd), KHR and ALSA headers plus link-only libraries
  from 12 pinned Debian 12 arm64 packages (sha256-checked, about 1 MB;
  MIT / MIT / MIT-style Khronos / LGPL-2.1). Unpacked into
  `tools/toolchain/sysroot` (cache in `sysroot-cache`), not committed, never
  shipped. Windows has no symlinks, so `libfoo.so` links become copies,
  also across packages (runtime packages are listed first). Written by
  OpenCode (DeepSeek) and reviewed; unit tests use synthetic .deb files
  (`test_sysroot.py`).
- **Flutter AOT for linux-arm64**: `python tools/toolchain/flutter_engine.py`
  fetches the pinned release engine, `gen_snapshot` and `icudtl.dat` (one
  shallow git fetch, sha256-checked) into `tools/toolchain/flutter-engine/release/`;
  `python os/app_aot.py [--dart-define K=V]` then builds the assets and
  `app/build/linux-aot/libapp.so`. gen_snapshot is an x64 Linux binary, so on
  Windows it runs through WSL (installed on DENA-PC 2026-10-17); the rest uses
  the Windows Flutter SDK. Unit tests: `test_flutter_engine.py`.

## ELF check (`tools/toolchain/elfcheck.py`)

Every cross-built binary must be AArch64, use the interpreter
`/lib/ld-linux-aarch64.so.1` if it has one, and need no glibc symbol
version newer than 2.28. Unit-tested with synthetic ELF images
(`tools/toolchain/test_elfcheck.py`).

## Checks (`tools/ci/local.sh`)

- `linux`: with Zig, cross-builds `shells/linux` and `host` and runs the
  ELF check on `dena-powerd`, `dena-keytest`, `dena-harness` and
  `dena_testcore.so`. Without Zig: the NDK syntax check of the device-only
  sources.
- `rig`: also runs the toolchain unit tests.
- `cores/<name>/build.sh linux-aarch64` is run by hand (like the Android
  core builds); the ELF check runs on whatever is in `cores/build/linux-aarch64`.
- Running the binaries needs a device (or qemu-user, which this PC lacks).
