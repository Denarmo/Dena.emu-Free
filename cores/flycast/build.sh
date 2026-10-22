#!/usr/bin/env bash
# Builds the Flycast libretro core (Dreamcast, NAOMI, Atomiswave;
# GPL-2.0-or-later, with GPL-3.0 xBRZ, so the core as built is GPL-3.0) from a
# pinned upstream tag, with its CMake LIBRETRO target: x86_64 SH4 dynarec,
# OpenGL and Vulkan renderers. Desktop only for now.
# Usage: cores/flycast/build.sh [--dry-run] <host|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/flycast_libretro.{so,dll}. Builds: docs/dev/desktop-cores.md
set -euo pipefail
REPO=https://github.com/flyinghead/flycast.git
TAG=v2.7
COMMIT=5aa091fde632fb332c8d8c34e280d62dc951954c
# Submodules the desktop libretro build never uses (Android, macOS, Windows
# Store, crash reporter, Discord, tests); every other one is fetched.
SKIP_SUBMODULES=(core/deps/oboe core/deps/Syphon core/deps/Spout core/deps/gamesdk
  core/deps/libadrenotools core/deps/breakpad core/deps/googletest core/deps/discord-rpc)

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
dena_parse_args "$@"
set -- "${dena_args[@]}"
target="${1:?usage: build.sh [--dry-run] <host|win64|linux-x86_64> [out_dir]}"
out="${2:-$root/cores/build/$target}"
src="$root/cores/build/src/flycast"
bld="$root/cores/build/obj/flycast-$target"

if dena_dry; then
  echo "+ fetch Flycast $TAG with its submodules into $src"
else
  if [ ! -d "$src/.git" ]; then
    git clone -q --depth 1 --branch "$TAG" "$REPO" "$src"
  fi
  [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "flycast checkout is not $COMMIT" >&2; exit 1; }
  mapfile -t subs < <(git -C "$src" config -f .gitmodules --get-regexp '\.path$' |
    awk '{ print $2 }' | grep -vxF -f <(printf '%s\n' "${SKIP_SUBMODULES[@]}"))
  git -C "$src" submodule update --init --recursive --depth 1 -q "${subs[@]}"
fi

# The bundled libzip and libchdr, no OpenMP (its DLL would have to ship too),
# no Lua scripting, crash reporter or Discord.
opts=(-DLIBRETRO=ON -DUSE_HOST_LIBZIP=OFF -DUSE_HOST_LIBCHDR=OFF -DUSE_OPENMP=OFF
  -DUSE_LUA=OFF -DUSE_BREAKPAD=OFF -DUSE_DISCORD=OFF -DENABLE_CTEST=OFF)
ext=so
case "$target" in
  host) opts+=(-DCMAKE_BUILD_TYPE=Release) ;;
  win64|linux-x86_64)
    dena_desktop_env "$target"
    opts+=("${X64_CMAKE[@]}")
    ext="$X64_EXT"
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac

dena_run cmake -S "$src" -B "$bld" "${opts[@]}"
dena_run cmake --build "$bld" --parallel "${DENA_JOBS:-$(nproc 2>/dev/null || echo 2)}" --target flycast_libretro
dena_run mkdir -p "$out"
lib="$bld/flycast_libretro.$ext"
dena_dry || [ -f "$lib" ] || { echo "$lib not found" >&2; exit 1; }
dena_run cp "$lib" "$out/"
if dena_is_desktop "$target"; then dena_check_lib "$out/flycast_libretro.$ext" "$target"; fi
echo "built $out/flycast_libretro.$ext"
