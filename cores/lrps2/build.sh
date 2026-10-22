#!/usr/bin/env bash
# Builds the LRPS2 libretro core (PlayStation 2; the PCSX2 libretro fork,
# GPL-3.0-or-later) from a pinned commit with its CMake build: x86_64 EE/IOP
# recompilers, OpenGL and Vulkan renderers. Desktop only (docs/specs/ps2.md).
# Usage: cores/lrps2/build.sh [--dry-run] <host|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/pcsx2_libretro.so. Builds: docs/dev/desktop-cores.md
#
# win64 is built with MSVC on Windows (cores/lrps2/build-msvc.ps1, which
# tools/release/build-windows.ps1 runs): libretro builds LRPS2 for Windows
# with MSVC only, so the MinGW cross build skips it.
set -euo pipefail
REPO=https://github.com/libretro/ps2.git
COMMIT=d4908f40fb32f43c5055852ecaed3c52aa725dce

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
dena_parse_args "$@"
set -- "${dena_args[@]}"
target="${1:?usage: build.sh [--dry-run] <host|win64|linux-x86_64> [out_dir]}"
out="${2:-$root/cores/build/$target}"
src="$root/cores/build/src/lrps2"
bld="$root/cores/build/obj/lrps2-$target"

if [ "$target" = win64 ]; then
  echo "lrps2: skipped for win64; it is built with MSVC by cores/lrps2/build-msvc.ps1 on Windows"
  exit 0
fi

if dena_dry; then
  echo "+ fetch $REPO $COMMIT into $src"
else
  if [ ! -d "$src/.git" ]; then
    mkdir -p "$src"
    git -C "$src" init -q
  fi
  if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$COMMIT" ]; then
    git -C "$src" fetch -q --depth 1 "$REPO" "$COMMIT"
    git -C "$src" checkout -q FETCH_HEAD
  fi
  [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "lrps2 checkout is not $COMMIT" >&2; exit 1; }
fi

# Everything LRPS2 needs is vendored (libretro-common decodes CHD, CSO and
# zip), so there is nothing to find on the system but threads. No pcap.
opts=(-DLIBRETRO=ON -DPCAP=OFF -DUSE_OPENGL=ON -DUSE_VULKAN=ON)
case "$target" in
  host) opts+=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.18) ;;
  linux-x86_64)
    dena_desktop_env "$target"
    # LRPS2's CMakeLists puts ccache in front of the compilers itself.
    for o in "${X64_CMAKE[@]}"; do
      case "$o" in -DCMAKE_*_COMPILER_LAUNCHER=*) ;; *) opts+=("$o") ;; esac
    done
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac

dena_run cmake -S "$src" -B "$bld" "${opts[@]}"
dena_run cmake --build "$bld" --parallel "${DENA_JOBS:-$(nproc 2>/dev/null || echo 2)}" --target pcsx2_libretro
dena_run mkdir -p "$out"
lib="$bld/bin/pcsx2_libretro.so"
dena_dry || [ -f "$lib" ] || { echo "$lib not found" >&2; exit 1; }
dena_run cp "$lib" "$out/"
if dena_is_desktop "$target"; then dena_check_lib "$out/pcsx2_libretro.so" "$target"; fi
echo "built $out/pcsx2_libretro.so"
