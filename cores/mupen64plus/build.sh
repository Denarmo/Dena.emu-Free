#!/usr/bin/env bash
# Builds the Mupen64Plus-Next libretro core (N64, GPL-2.0) from a pinned commit,
# GLES 3 renderer (GLideN64). Its Android make target is armv7-only, so this
# drives the Makefile with the NDK's clang directly.
# Usage: cores/mupen64plus/build.sh [--dry-run] android-arm64-v8a|linux-aarch64|win64|linux-x86_64 [out_dir]
# (android-x86_64 is not built; only the emulator uses it.) Desktop targets use
# the x86_64 dynarec (needs nasm) and desktop OpenGL (docs/dev/desktop-cores.md).
# Output: <out_dir>/mupen64plus_libretro.{so,dll}. Spec: docs/specs/n64.md
set -euo pipefail
REPO=https://github.com/libretro/mupen64plus-libretro-nx.git
COMMIT=12edd2c74a517ff86dfa8cfc71ad75e4c10486d5
API=26

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
dena_parse_args "$@"
set -- "${dena_args[@]}"
target="${1:?usage: build.sh [--dry-run] android-arm64-v8a|linux-aarch64|win64|linux-x86_64 [out_dir]}"
out="${2:-$root/cores/build/$target}"
src="$root/cores/build/src/mupen64plus"

if dena_is_desktop "$target"; then
  dena_desktop_env "$target"
  if dena_dry; then
    [ -d "$src/.git" ] || echo "+ fetch $REPO $COMMIT into $src"
  else
    if [ ! -d "$src/.git" ]; then
      git init -q "$src"
      git -C "$src" fetch -q --depth 1 "$REPO" "$COMMIT"
      git -C "$src" checkout -q FETCH_HEAD
    fi
    [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "mupen64plus checkout is not $COMMIT" >&2; exit 1; }
    command -v nasm >/dev/null || { echo "missing build tool: nasm (the x86_64 dynarec)" >&2; exit 1; }
  fi
  work="$root/cores/build/obj/mupen64plus-$target"
  dena_fresh_copy "$src" "$work" "$COMMIT"
  # GLideN64 on desktop OpenGL. On win64, MSYSTEM=MINGW64 selects the
  # Makefile's 64-bit MinGW settings (WIN64 define, nasm -f win64).
  args=(platform="$X64_PLATFORM" WITH_DYNAREC=x86_64 ARCH=x86_64 HAVE_NEON=0
    CC="$X64_CC" CXX="$X64_CXX" CC_AS="$X64_CC" AR="$X64_AR")
  if [ "$target" = win64 ]; then args+=(MSYSTEM=MINGW64); fi
  dena_run make -C "$work" -j"$(nproc 2>/dev/null || echo 4)" "${args[@]}"
  dena_run mkdir -p "$out"
  dena_run cp "$work/mupen64plus_next_libretro.$X64_EXT" "$out/mupen64plus_libretro.$X64_EXT"
  dena_check_lib "$out/mupen64plus_libretro.$X64_EXT" "$target"
  echo "built $out/mupen64plus_libretro.$X64_EXT"
  exit 0
fi

if [ "$target" = linux-aarch64 ]; then
  # Handhelds (toolchain-linux.md): upstream's generic Cortex-A53 GLES 3
  # target, zig cc, EGL/GLES from the sysroot (tools/toolchain/sysroot.py).
  [ -d "$src/.git" ] || { echo "run the Android build once to fetch $src" >&2; exit 1; }
  [ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "mupen64plus checkout is not $COMMIT" >&2; exit 1; }
  sysroot="$root/tools/toolchain/sysroot"
  [ -f "$sysroot/.dena-sysroot" ] || { echo "no sysroot: run tools/toolchain/sysroot.py" >&2; exit 1; }
  DENA_ZIG="$(bash "$root/tools/toolchain/zig.sh" path)"
  export DENA_ZIG
  command -v cygpath >/dev/null && sysroot="$(cygpath -m "$sysroot")"
  # Debian's libraries need a newer glibc than we link against; they are
  # only linked against here, the device brings its own.
  export DENA_CFLAGS="-isystem $sysroot/usr/include -L$sysroot/usr/lib/aarch64-linux-gnu -Wl,--allow-shlib-undefined -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS"
  export DENA_LIBDIR="$sysroot/usr/lib/aarch64-linux-gnu"
  wrap="bash $root/tools/toolchain/zig-cc.sh"
  work="$root/cores/build/obj/mupen64plus-linux-aarch64"
  if [ "$(cat "$work/.dena-commit" 2>/dev/null)" != "$COMMIT" ]; then
    rm -rf "$work"
    mkdir -p "$work"
    git -C "$src" ls-files -z | (cd "$src" && tar --null -T - -cf -) | (cd "$work" && tar -xf -)
    echo "$COMMIT" > "$work/.dena-commit"
  fi
  make_cmd="$(command -v make || command -v mingw32-make)"
  "$make_cmd" -C "$work" -j"$(nproc 2>/dev/null || echo 4)" \
    platform=arm64_cortex_a53_gles3 UNAME=Linux \
    CC="$wrap cc" CXX="$wrap c++" CC_AS="$wrap cc" AR="$DENA_ZIG ar"
  mkdir -p "$out"
  cp "$work/mupen64plus_next_libretro.so" "$out/mupen64plus_libretro.so"
  echo "built $out/mupen64plus_libretro.so"
  exit 0
fi

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
# make passes commands through sh: Windows backslash paths must become forward slashes.
command -v cygpath >/dev/null && ANDROID_NDK_HOME="$(cygpath -m "$ANDROID_NDK_HOME")"

if [ ! -d "$src/.git" ]; then
  git init -q "$src"
  git -C "$src" fetch -q --depth 1 "$REPO" "$COMMIT"
  git -C "$src" checkout -q FETCH_HEAD
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$COMMIT" ] || { echo "mupen64plus checkout is not $COMMIT" >&2; exit 1; }

case "$target" in
  android-arm64-v8a) triple=aarch64-linux-android; dynarec=aarch64 ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac

host_tag="$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" | head -1)"
bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag/bin"
exe=""; [ -f "$bin/clang.exe" ] && exe=".exe"
cc="$bin/clang$exe --target=$triple$API"
cxx="$bin/clang++$exe --target=$triple$API"
make_bin="$ANDROID_NDK_HOME/prebuilt/$host_tag/bin/make$exe"
[ -f "$make_bin" ] || make_bin=make

# Objects land next to the sources, so each ABI builds from a clean tree.
stamp="$src/.dena-built-for"
if [ "$(cat "$stamp" 2>/dev/null)" != "$target" ]; then
  git -C "$src" clean -fdxq  # drop the other ABI's objects (make clean misses some)
fi

"$make_bin" -C "$src" -j"$(nproc 2>/dev/null || echo 4)" \
  platform=android-gles3 \
  CC="$cc" CXX="$cxx" CC_AS="$cc" AR="$bin/llvm-ar$exe" STRINGS="$bin/llvm-strings$exe" \
  WITH_DYNAREC="$dynarec" HAVE_NEON=0 PIC=1 \
  CPUFLAGS="-DANDROID -DEGL_EGLEXT_PROTOTYPES" \
  LDFLAGS="-shared -Wl,--version-script=libretro/link.T -Wl,--no-undefined -llog -lz -lEGL -landroid -static-libstdc++"
echo "$target" > "$stamp"

mkdir -p "$out"
cp "$src/mupen64plus_next_gles3_libretro_android.so" "$out/mupen64plus_libretro.so"
echo "built $out/mupen64plus_libretro.so"
