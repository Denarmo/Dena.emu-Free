#!/usr/bin/env bash
# Builds the PPSSPP libretro core (PSP, GPL-2.0-or-later) from a pinned tag,
# with its CMake LIBRETRO target (GLES 3 through the libretro HW context).
# Usage: cores/ppsspp/build.sh [--dry-run] <android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/ppsspp_libretro.{so,dll}. Spec: docs/specs/psp.md
# Desktop targets (docs/dev/desktop-cores.md): x86_64 JIT, desktop OpenGL and
# Vulkan. win64 has no FFmpeg (PPSSPP's prebuilt FFmpeg does not link with
# MinGW), so PSP video cutscenes stay black there until that is solved.
set -euo pipefail
REPO=https://github.com/hrydgard/ppsspp.git
TAG=v1.19.3
COMMIT=e49c0bd8836a8a8f678565357773386f1174d3f5
API=26
# Only what the libretro build needs (no tests, SDL, iOS, VR, debugger UI).
SUBMODULES=(libretro/libretro-common ffmpeg ext/armips ext/glslang
  ext/SPIRV-Cross ext/rapidjson ext/miniupnp ext/zstd ext/cpu_features
  ext/rcheevos ext/naett ext/libchdr ext/libadrenotools ext/lua ext/discord-rpc
  ext/OpenXR-SDK)

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
dena_parse_args "$@"
set -- "${dena_args[@]}"
target="${1:?usage: build.sh [--dry-run] <android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]}"
out="${2:-$root/cores/build/$target}"
src="$root/cores/build/src/ppsspp"
bld="$root/cores/build/obj/ppsspp-$target"

prepare_source() {
  if [ ! -d "$src/.git" ]; then
    git clone -q --depth 1 --branch "$TAG" "$REPO" "$src"
  fi
  [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "ppsspp checkout is not $COMMIT" >&2; exit 1; }
  git -C "$src" submodule update --init --recursive --depth 1 -q "${SUBMODULES[@]}"
  # Our fixes on top of the tag (psp.md, Core). Idempotent: skipped once applied.
  for patch in "$root"/cores/ppsspp/patches/*.patch; do
    if git -C "$src" apply --check --ignore-whitespace "$patch" 2>/dev/null; then
      git -C "$src" apply --ignore-whitespace "$patch"
    elif ! git -C "$src" apply --reverse --check --ignore-whitespace "$patch" 2>/dev/null; then
      echo "cannot apply $patch" >&2
      exit 1
    fi
  done
}
if dena_dry; then
  echo "+ fetch PPSSPP $TAG with its submodules into $src and apply cores/ppsspp/patches"
else
  prepare_source
fi

opts=(
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DLIBRETRO=ON -DUSE_DISCORD=OFF -DUSE_MINIUPNPC=OFF
  -DUSE_SYSTEM_FFMPEG=OFF -DUNITTEST=OFF -DHEADLESS=OFF
)
case "$target" in
  android-*)
    abi="${target#android-}"
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    opts+=(-DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API"
      -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
      -DANDROID_ARM_NEON=ON)
    if [ -n "${CMAKE_GENERATOR:-}" ]; then opts+=(-G "$CMAKE_GENERATOR"); fi
    ;;
  linux-aarch64)
    # Handhelds (toolchain-linux.md): GLES through EGL, headers and link-only
    # libraries from the sysroot (tools/toolchain/sysroot.py).
    sysroot="$root/tools/toolchain/sysroot"
    [ -f "$sysroot/.dena-sysroot" ] || { echo "no sysroot: run tools/toolchain/sysroot.py" >&2; exit 1; }
    zig="$(bash "$root/tools/toolchain/zig.sh" path)"
    command -v cygpath >/dev/null && sysroot="$(cygpath -m "$sysroot")"
    sysflags="-isystem $sysroot/usr/include -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS -Wno-date-time"
    opts+=(-DCMAKE_TOOLCHAIN_FILE="$root/tools/toolchain/aarch64-linux.cmake" -DDENA_ZIG="$zig"
      -DCMAKE_FIND_ROOT_PATH="$sysroot" -DDENA_LIBDIR="$sysroot/usr/lib/aarch64-linux-gnu" -DUSING_GLES2=ON -DUSING_EGL=ON -DUSE_CCACHE=OFF
      -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON
      -DUSING_X11_VULKAN=OFF -DUSE_WAYLAND_WSI=OFF -DUSE_VULKAN_DISPLAY_KHR=OFF
      "-DCMAKE_C_FLAGS=$sysflags" "-DCMAKE_CXX_FLAGS=$sysflags"
      "-DCMAKE_SHARED_LINKER_FLAGS=-L$sysroot/usr/lib/aarch64-linux-gnu -Wl,--allow-shlib-undefined -s")
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) opts+=(-G "MinGW Makefiles") ;; esac
    ;;
  win64|linux-x86_64)
    dena_desktop_env "$target"
    opts+=("${X64_CMAKE[@]}" -DUSE_CCACHE=OFF -DUSING_GLES2=OFF -DUSING_EGL=OFF)
    # win64: GLEW is built static, but only its own target gets GLEW_STATIC;
    # Common's GL code then links against __imp_ symbols that do not exist.
    if [ "$target" = win64 ]; then
      opts+=(-DUSE_FFMPEG=OFF "-DCMAKE_C_FLAGS=-DGLEW_STATIC" "-DCMAKE_CXX_FLAGS=-DGLEW_STATIC")
    fi
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac

ext=so
if dena_is_desktop "$target"; then ext="$X64_EXT"; fi
dena_run cmake -S "$src" -B "$bld" "${opts[@]}"
dena_run cmake --build "$bld" --parallel "${DENA_JOBS:-$(nproc 2>/dev/null || echo 2)}" --target ppsspp_libretro
dena_run mkdir -p "$out"
if dena_dry; then
  lib="$bld/lib/ppsspp_libretro.$ext"
else
  lib="$(find "$bld" -maxdepth 2 -name "ppsspp_libretro*.$ext" | head -1)"
fi
[ -n "$lib" ] || { echo "ppsspp_libretro not found in $bld" >&2; exit 1; }
dena_run cp "$lib" "$out/ppsspp_libretro.$ext"
# The release build keeps debug info (~150 MB); strip it to ~18 MB.
if dena_is_desktop "$target"; then
  dena_check_lib "$out/ppsspp_libretro.$ext" "$target"
elif [ "$target" = linux-aarch64 ]; then
  :  # stripped by the linker (-s)
else
  host_tag="$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" | head -1)"
  strip_bin="$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag/bin/"llvm-strip* | head -1)"
  "$strip_bin" --strip-unneeded "$out/ppsspp_libretro.so"
fi
# Desktop: PPSSPP's support files ship beside the core in cores/PPSSPP; the
# host copies them to <system>/PPSSPP on first start (psp.md, Core). The same
# subset as the Android assets (shells/android/android/build.gradle.kts).
if dena_is_desktop "$target"; then
  dena_run rm -rf "$out/PPSSPP"
  for item in flash0 vfpu compat.ini knownfuncs.ini langregion.ini lang/en_US.ini       ppge_atlas.zim ppge_atlas.meta font_atlas.zim font_atlas.meta asciifont_atlas.zim       asciifont_atlas.meta; do
    [ -e "$src/assets/$item" ] || dena_dry || continue
    dena_run mkdir -p "$out/PPSSPP/$(dirname "$item")"
    dena_run cp -r "$src/assets/$item" "$out/PPSSPP/$item"
  done
  dena_dry || printf '%s' "$TAG" > "$out/PPSSPP/dena-assets.txt"
fi
echo "built $out/ppsspp_libretro.$ext"
