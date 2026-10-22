#!/usr/bin/env bash
# Builds the mGBA libretro core (MPL-2.0) from a pinned upstream tag.
# Spec: docs/specs/latency-spike.md
#
# Usage: cores/mgba/build.sh <target> [out_dir]
#   target: host | android-arm64-v8a | android-x86_64 | linux-aarch64 (Zig)
#           | win64 (MinGW-w64) | linux-x86_64 (docs/dev/desktop-cores.md)
#   Android targets need ANDROID_NDK_HOME. --dry-run prints the commands.
# Output: <out_dir>/mgba_libretro.{so,dll,dylib}  (default out_dir: cores/build/<target>)
set -euo pipefail

MGBA_TAG=0.10.5
MGBA_COMMIT=26b7884bc25a5933960f3cdcd98bac1ae14d42e2
ANDROID_API=26

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
dena_parse_args "$@"
set -- "${dena_args[@]}"
target="${1:?usage: build.sh [--dry-run] <host|android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]}"
out="${2:-$root/cores/build/$target}"
src="$root/cores/build/src/mgba"
bld="$root/cores/build/obj/mgba-$target"

prepare_source() {
  if [ ! -d "$src/.git" ]; then
    git clone --quiet --depth 1 --branch "$MGBA_TAG" https://github.com/mgba-emu/mgba.git "$src"
  fi
  actual="$(git -C "$src" rev-parse HEAD)"
  if [ "$actual" != "$MGBA_COMMIT" ]; then
    echo "mGBA checkout is $actual, expected $MGBA_COMMIT" >&2
    exit 1
  fi

  # Link cable (docs/specs/link-cable.md): our SIO drivers, included into
  # libretro.c with three hook calls. Re-applied on every build from a pristine
  # libretro.c so edits to dena_link.inc always take effect.
  retro="$src/src/platform/libretro"
  git -C "$src" checkout -q -- src/platform/libretro/libretro.c
  cp "$here/dena_link.inc" "$retro/dena_link.inc"
  cp "$root/host/include/dena/link_api.h" "$retro/dena_link_api.h"
  sed -i.bak \
    -e 's|^#include "libretro_core_options.h"$|&\n#include "dena_link.inc"|' \
    -e 's|^void retro_run(void) {$|&\n\tdenaLinkFrame();|' \
    -e 's|^\tcore->setPeripheral(core, mPERIPH_ROTATION, &rotation);$|&\n\tdenaLinkInstall(core);|' \
    -e 's|^\tmCoreConfigDeinit(&core->config);$|\tdenaLinkRemove();\n&|' \
    "$retro/libretro.c"
  rm -f "$retro/libretro.c.bak"
  [ "$(grep -c 'denaLink\|dena_link.inc' "$retro/libretro.c")" = 4 ] || { echo "link cable hooks did not apply" >&2; exit 1; }
}
if dena_dry; then
  echo "+ fetch mGBA $MGBA_TAG into $src and apply the link cable hooks"
else
  prepare_source
fi

opts=(
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_GL=OFF
  -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DBUILD_SHARED=OFF -DBUILD_STATIC=OFF
  -DSKIP_LIBRARY=ON -DBUILD_PERF=OFF -DBUILD_TEST=OFF -DBUILD_SUITE=OFF
  -DBUILD_EXAMPLE=OFF -DBUILD_UPDATER=OFF
  -DUSE_FFMPEG=OFF -DUSE_ZLIB=OFF -DUSE_MINIZIP=OFF -DUSE_LIBZIP=OFF -DUSE_PNG=OFF
  -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LUA=OFF -DUSE_EPOXY=OFF -DUSE_DISCORD_RPC=OFF
  -DUSE_EDITLINE=OFF -DUSE_GDB_STUB=OFF -DUSE_DEBUGGERS=OFF -DENABLE_SCRIPTING=OFF
  -DM_CORE_GB=ON -DM_CORE_GBA=ON
)
case "$target" in
  host) ;;
  win64|linux-x86_64)
    dena_desktop_env "$target"
    opts+=("${X64_CMAKE[@]}")
    ;;
  linux-aarch64)
    zig="$(bash "$root/tools/toolchain/zig.sh" path)"
    opts+=(-DCMAKE_TOOLCHAIN_FILE="$root/tools/toolchain/aarch64-linux.cmake" -DDENA_ZIG="$zig")
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) opts+=(-G "MinGW Makefiles") ;; esac
    ;;
  android-*)
    abi="${target#android-}"
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    opts+=(-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
           -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$ANDROID_API")
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac
if [ -n "${CMAKE_GENERATOR:-}" ] && [ "$target" != linux-aarch64 ]; then opts+=(-G "$CMAKE_GENERATOR"); fi

dena_run cmake -S "$src" -B "$bld" "${opts[@]}"
dena_run cmake --build "$bld" --parallel "${DENA_JOBS:-$(nproc 2>/dev/null || echo 2)}" --target mgba_libretro
dena_run mkdir -p "$out"
if dena_dry; then
  lib="$bld/mgba_libretro.${X64_EXT:-so}"
else
  lib="$(find "$bld" -maxdepth 2 -name 'mgba_libretro.*' \( -name '*.so' -o -name '*.dll' -o -name '*.dylib' \) | head -1)"
fi
[ -n "$lib" ] || { echo "mgba_libretro not found in $bld" >&2; exit 1; }
dena_run cp "$lib" "$out/"
if dena_is_desktop "$target"; then dena_check_lib "$out/$(basename "$lib")" "$target"; fi
echo "built $out/$(basename "$lib")"
