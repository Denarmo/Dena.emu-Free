#!/usr/bin/env bash
# Builds the melonDS libretro core (Nintendo DS, GPL-3.0) from a pinned commit.
# It falls back to its bundled FreeBIOS (BSD-2-Clause) when no BIOS is supplied.
# Usage: cores/melonds/build.sh <host|android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/melonds_libretro.{so,dll,dylib}. Spec: docs/specs/ds.md
# Android builds the OpenGL renderer on OpenGL ES 3.2 (patches/gles3.patch,
# ours) for 2x-4x internal resolution. MELONDS_HOST_MAKE=GLES=1 does the same
# for the host build, which host/tests/ds_gles_tests.cpp needs.
NAME=melonds
REPO=https://github.com/libretro/melonDS.git
COMMIT=66b5d2634cd0a79030562811e6e05f5532f800ba
HOST_DIR=.
HOST_MAKE="${MELONDS_HOST_MAKE:-}"
# Handhelds: ARM JIT, no desktop OpenGL (GLES comes with the embedder).
LINUX_MAKE="ARCH=arm64"
# Desktop: the x86_64 JIT and the desktop OpenGL renderer (both targets).
X64_MAKE="JIT_ARCH=x64"
# Selects the Makefile's 64-bit MinGW settings (-DWIN64 for the JIT's assembly).
WIN64_MAKE="MSYSTEM=MINGW64"
JNI_DIR=.
fixup_source() {
  # Our patches (ds.md, Internal resolution). Idempotent: skipped once applied.
  local patch
  for patch in "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"/patches/*.patch; do
    if git -C "$1" apply --check "$patch" 2>/dev/null; then
      git -C "$1" apply "$patch"
    elif ! git -C "$1" apply --reverse --check "$patch" 2>/dev/null; then
      echo "cannot apply $patch" >&2
      exit 1
    fi
  done
  # Android's bionic has the GNU strerror_r (returns char *), which the bundled
  # Dolphin helper only expects with glibc.
  sed -i 's/#if defined(__GLIBC__) \&\& (_GNU_SOURCE/#if (defined(__GLIBC__) || defined(__ANDROID__)) \&\& (_GNU_SOURCE/' \
    "$1/src/dolphin/CommonFuncs.cpp"
}
source "$(dirname "$0")/../libretro-make.sh"
