#!/usr/bin/env bash
# Builds the Dolphin libretro core (GameCube, Wii; GPL-2.0-or-later) from a
# pinned commit of the libretro fork, with its CMake LIBRETRO target: x86_64
# JIT, OpenGL and Vulkan renderers, every library bundled. Desktop only
# (docs/specs/gamecube-wii.md). The Windows DLL is built with MSVC on Windows
# by cores/dolphin/build-msvc.ps1, not here.
# Usage: cores/dolphin/build.sh [--dry-run] <host|linux-x86_64> [out_dir]
# Output: <out_dir>/dolphin_libretro.so and <out_dir>/dolphin-emu/Sys (the
# core's data files, copied to <system>/dolphin-emu by the host).
# Builds: docs/dev/desktop-cores.md
set -euo pipefail
REPO=https://github.com/libretro/dolphin.git
COMMIT=5466da350f2fd143ee3e7b921e8c33aee64f7065
# Submodules the libretro build never uses (Qt, prebuilt FFmpeg, tests,
# Android GPU drivers); every other one is fetched. mGBA stays: the libretro
# boot code sets up the GameCube's Game Boy Player with it.
SKIP_SUBMODULES=(Externals/Qt Externals/FFmpeg-bin Externals/gtest
  Externals/libadrenotools)
# Dolphin needs CMake 3.25; the portable SDK (22.08) has an older one, so a
# pinned Kitware build is fetched into cores/build/tools when needed.
CMAKE_VERSION=3.31.6
CMAKE_SHA256=5a1133ff103c71eb5120e2cc3de922733e7d8a26a98ae716397e8676adb367bf

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
dena_parse_args "$@"
set -- "${dena_args[@]}"
target="${1:?usage: build.sh [--dry-run] <host|linux-x86_64> [out_dir]}"
out="${2:-$root/cores/build/$target}"
src="$root/cores/build/src/dolphin"
bld="$root/cores/build/obj/dolphin-$target"

if [ "$target" = win64 ]; then
  echo "dolphin: the win64 DLL is built with MSVC on Windows: cores\\dolphin\\build-msvc.ps1 (docs/dev/desktop-cores.md)" >&2
  exit 3
fi

prepare_source() {
  if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" remote add origin "$REPO"
  fi
  if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null)" != "$COMMIT" ]; then
    git -C "$src" fetch -q --depth 1 origin "$COMMIT"
    git -C "$src" checkout -q --detach FETCH_HEAD
  fi
  [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "dolphin checkout is not $COMMIT" >&2; exit 1; }
  mapfile -t subs < <(git -C "$src" config -f .gitmodules --get-regexp '\.path$' |
    awk '{ print $2 }' | grep -vxF -f <(printf '%s\n' "${SKIP_SUBMODULES[@]}"))
  git -C "$src" submodule update --init --recursive --depth 1 -q "${subs[@]}"
  # Our fixes on top of the pin (gamecube-wii.md, Core). Idempotent.
  for patch in "$root"/cores/dolphin/patches/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$src" apply --check --ignore-whitespace "$patch" 2>/dev/null; then
      git -C "$src" apply --ignore-whitespace "$patch"
    elif ! git -C "$src" apply --reverse --check --ignore-whitespace "$patch" 2>/dev/null; then
      echo "cannot apply $patch" >&2
      exit 1
    fi
  done
}

# CMake 3.25 or newer: the one on the PATH, else the pinned Kitware build.
cmake_bin() {
  local have tools="$root/cores/build/tools/cmake-$CMAKE_VERSION"
  have="$(cmake --version 2>/dev/null | sed -n 's/^cmake version \([0-9]*\.[0-9]*\).*/\1/p')"
  if [ -n "$have" ] && printf '%s\n' 3.25 "$have" | sort -C -V; then
    echo cmake
    return 0
  fi
  if dena_dry; then echo "$tools/bin/cmake"; return 0; fi
  if [ ! -x "$tools/bin/cmake" ]; then
    local tgz="$tools.tar.gz"
    mkdir -p "$(dirname "$tools")"
    curl -fsSL -o "$tgz" "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-x86_64.tar.gz" >&2
    echo "$CMAKE_SHA256  $tgz" | sha256sum -c --quiet - >&2 || { rm -f "$tgz"; echo "cmake download does not match its SHA-256" >&2; return 1; }
    mkdir -p "$tools"
    tar -xzf "$tgz" -C "$tools" --strip-components=1
    rm -f "$tgz"
  fi
  echo "$tools/bin/cmake"
}

if dena_dry; then
  echo "+ fetch Dolphin $COMMIT with its submodules into $src and apply cores/dolphin/patches"
else
  prepare_source
fi

# Everything bundled (USE_SYSTEM_LIBS=OFF), so the core needs only libc and
# GL from the runtime: the frontend gives it the GL context, audio and input,
# so no X11, audio or controller backends, and no tests.
opts=(-DLIBRETRO=ON -DUSE_SYSTEM_LIBS=OFF -DUSE_MGBA=ON -DENABLE_TESTS=OFF
  -DENABLE_QT=OFF -DENABLE_NOGUI=OFF -DENABLE_LTO=OFF -DENABLE_VULKAN=ON
  -DENABLE_HWDB=OFF -DENABLE_EVDEV=OFF -DENABLE_BLUEZ=OFF -DUSE_DISCORD_PRESENCE=OFF -DENABLE_AUTOUPDATE=OFF
  -DENABLE_ANALYTICS=OFF -DUSE_UPNP=OFF -DENCODE_FRAMEDUMPS=OFF -DENABLE_LLVM=OFF
  -DENABLE_X11=OFF -DENABLE_ALSA=OFF -DENABLE_PULSEAUDIO=OFF -DENABLE_CUBEB=OFF -DENABLE_SDL=OFF)
ext=so
case "$target" in
  host) opts+=(-DCMAKE_BUILD_TYPE=Release) ;;
  linux-x86_64)
    dena_desktop_env "$target"
    opts+=("${X64_CMAKE[@]}")
    ext="$X64_EXT"
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac

cm="$(cmake_bin)"
dena_run "$cm" -S "$src" -B "$bld" -G Ninja "${opts[@]}"
dena_run "$cm" --build "$bld" --parallel "${DENA_JOBS:-$(nproc 2>/dev/null || echo 2)}" --target dolphin_libretro
dena_run mkdir -p "$out"
lib="$bld/dolphin_libretro.$ext"
if ! dena_dry; then
  [ -f "$lib" ] || lib="$(find "$bld" -name "dolphin_libretro.$ext" | head -1)"
  [ -n "$lib" ] && [ -f "$lib" ] || { echo "dolphin_libretro.$ext not found in $bld" >&2; exit 1; }
fi
dena_run cp "$lib" "$out/dolphin_libretro.$ext"
if dena_is_desktop "$target"; then dena_check_lib "$out/dolphin_libretro.$ext" "$target"; fi
# Data/Sys (game settings, shaders, fonts, Wii resources) ships beside the
# core in dolphin-emu/Sys; the host copies it to <system>/dolphin-emu on the
# first start (gamecube-wii.md, Core).
dena_run rm -rf "$out/dolphin-emu"
dena_run mkdir -p "$out/dolphin-emu"
dena_run cp -r "$src/Data/Sys" "$out/dolphin-emu/Sys"
dena_dry || printf '%s' "${COMMIT:0:12}" > "$out/dolphin-emu/dena-assets.txt"
echo "built $out/dolphin_libretro.$ext"
