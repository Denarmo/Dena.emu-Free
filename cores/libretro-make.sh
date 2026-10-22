#!/usr/bin/env bash
# Shared builder for libretro cores that ship their own Makefile (host) and
# jni/Android.mk (Android). Sourced by cores/<name>/build.sh, which sets:
#   NAME        output base name, e.g. fceumm (-> fceumm_libretro.so)
#   REPO        git URL;  COMMIT  pinned commit
#   HOST_DIR    dir (in the checkout) to run make in;  HOST_MAKE  extra make args
#   JNI_DIR     dir (in the checkout) holding jni/Android.mk
#   ANDROID_CPPFLAGS  optional extra C++ flags for ndk-build
#   ANDROID_OPT       optimisation flags for ndk-build (default -O3; performance.md)
#   ANDROID_MODULE    LOCAL_MODULE of jni/Android.mk (default: retro)
#   LINUX_MAKE        extra make args for linux-aarch64 (handhelds)
#   LINUX_CC          cc or c++ as the C compiler there (default cc)
#   LINUX_CFLAGS      extra compiler flags there
#   X64_MAKE          extra make args for both desktop targets (win64, linux-x86_64)
#   WIN64_MAKE        extra make args for win64 only;  LINUX64_MAKE  for linux-x86_64 only
#   WIN64_CFLAGS      extra compiler flags for win64 only (added to CC and CXX,
#                     so the core's own CFLAGS stay intact)
#   DESKTOP_SKIP      set when the core has no desktop build: the reason, printed
#   fixup_source      optional function run on the checkout before building
# Usage of the caller:
#   build.sh [--dry-run] [--target] <host|android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]
# Spec: docs/specs/cores-m2.md; desktop targets: docs/dev/desktop-cores.md
set -euo pipefail

ANDROID_API=26
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
dena_parse_args "$@"
set -- "${dena_args[@]}"
target="${1:?usage: build.sh [--dry-run] <host|android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]}"
out="${2:-$root/cores/build/$target}"
src="$root/cores/build/src/$NAME"

if dena_is_desktop "$target" && [ -n "${DESKTOP_SKIP:-}" ]; then
  echo "$NAME has no $target build: $DESKTOP_SKIP" >&2
  exit 3
fi

if dena_dry; then
  # Print what would happen; the checkout is neither fetched nor changed.
  [ -d "$src/.git" ] || echo "+ fetch $REPO $COMMIT into $src"
  declare -F fixup_source >/dev/null && echo "+ fixup_source $src"
else
  if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 "$REPO" "$COMMIT"
    git -C "$src" checkout -q FETCH_HEAD
  fi
  actual="$(git -C "$src" rev-parse HEAD)"
  if [ "$actual" != "$COMMIT" ]; then
    echo "$NAME checkout is $actual, expected $COMMIT" >&2
    exit 1
  fi

  # Optional per-core source fix (a function the caller defines), idempotent.
  if declare -F fixup_source >/dev/null; then fixup_source "$src"; fi
fi

make_cmd="${MAKE:-$(command -v make || command -v mingw32-make || echo make)}"
jobs="${DENA_JOBS:-$(nproc 2>/dev/null || echo 2)}"
dena_dry || mkdir -p "$out"
case "$target" in
  host)
    # shellcheck disable=SC2086
    "$make_cmd" -C "$src/$HOST_DIR" -j"$jobs" $HOST_MAKE
    lib="$(find "$src/$HOST_DIR" -maxdepth 1 -name "${NAME}_libretro.*" \
      \( -name '*.so' -o -name '*.dll' -o -name '*.dylib' \) | head -1)"
    ;;
  win64|linux-x86_64)
    # Desktop (docs/dev/desktop-cores.md): the core's own Makefile, MinGW-w64
    # or the native gcc, from a copy per target like linux-aarch64 below.
    dena_desktop_env "$target"
    work="$root/cores/build/obj/$NAME-$target"
    recipe_dir="$(cd "$(dirname "$0")" && pwd)"
    stamp="$COMMIT $(find "$recipe_dir" -maxdepth 1 -type f -print0 | sort -z |
      xargs -0 cat "${BASH_SOURCE[0]}" "$root/cores/desktop.sh" | sha256sum | cut -d' ' -f1)"
    dena_fresh_copy "$src" "$work" "$stamp"
    extra="${LINUX64_MAKE:-}"
    cflags=""
    [ "$target" = win64 ] && extra="${WIN64_MAKE:-}" && cflags="${WIN64_CFLAGS:-}"
    # shellcheck disable=SC2086
    dena_run "$make_cmd" -C "$work/$HOST_DIR" -j"$jobs" platform="$X64_PLATFORM" \
      CC="$X64_CC${cflags:+ $cflags}" CXX="$X64_CXX${cflags:+ $cflags}" AR="$X64_AR" \
      ${X64_MAKE:-} $extra $HOST_MAKE
    lib="$work/$HOST_DIR/${NAME}_libretro.$X64_EXT"
    dena_dry || [ -f "$lib" ] || { echo "$lib not found" >&2; exit 1; }
    dena_run mkdir -p "$out"
    dena_run cp "$lib" "$out/"
    dena_check_lib "$out/$(basename "$lib")" "$target"
    echo "built $out/$(basename "$lib")"
    exit 0
    ;;
  linux-aarch64)
    # Handhelds (toolchain-linux.md): the core's own Makefile with zig cc.
    zig="$(bash "$root/tools/toolchain/zig.sh" path)" || {
      echo "no Zig: run tools/toolchain/zig.sh install" >&2; exit 1; }
    export DENA_ZIG="$zig" DENA_CFLAGS="${LINUX_CFLAGS:-}"
    wrap="bash $root/tools/toolchain/zig-cc.sh"
    # Objects land next to the sources, so this target builds from a copy of
    # the tracked files (the host build's objects stay behind).
    # The copy is keyed to the commit and to this recipe (the core's
    # build.sh, its fixup inputs and this file): a fixup added later must
    # reach the copy, or the core ships without it.
    work="$root/cores/build/obj/$NAME-linux-aarch64"
    recipe_dir="$(cd "$(dirname "$0")" && pwd)"
    stamp="$COMMIT $(find "$recipe_dir" -maxdepth 1 -type f -print0 | sort -z |
      xargs -0 cat "${BASH_SOURCE[0]}" | sha256sum | cut -d' ' -f1)"
    if [ ! -f "$work/.dena-commit" ] || [ "$(cat "$work/.dena-commit")" != "$stamp" ]; then
      rm -rf "$work"
      mkdir -p "$work"
      git -C "$src" ls-files --recurse-submodules -z |
        (cd "$src" && tar --null -T - -cf -) | (cd "$work" && tar -xf -)
      echo "$stamp" > "$work/.dena-commit"
    fi
    # shellcheck disable=SC2086
    "$make_cmd" -C "$work/$HOST_DIR" -j"$jobs" platform=unix \
      CC="$wrap ${LINUX_CC:-cc}" CXX="$wrap c++" AR="$zig ar" \
      ${LINUX_MAKE:-} $HOST_MAKE
    lib="$(find "$work/$HOST_DIR" -maxdepth 1 -name "${NAME}_libretro.so" | head -1)"
    [ -n "$lib" ] || { echo "${NAME}_libretro.so not found in $work/$HOST_DIR" >&2; exit 1; }
    cp "$lib" "$out/"
    echo "built $out/$(basename "$lib")"
    exit 0
    ;;
  android-*)
    abi="${target#android-}"
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    ndk_build="$ANDROID_NDK_HOME/ndk-build"
    [ -f "$ndk_build" ] || ndk_build="$ndk_build.cmd"   # Windows NDK
    # Run from inside jni/, as upstream does: Android.mk paths are relative to it.
    "$ndk_build" -C "$src/$JNI_DIR/jni" -j"$jobs" \
      NDK_PROJECT_PATH=.. APP_BUILD_SCRIPT=Android.mk \
      NDK_APPLICATION_MK=Application.mk APP_SHORT_COMMANDS=true \
      APP_ABI="$abi" APP_PLATFORM="android-$ANDROID_API" APP_CPPFLAGS="${ANDROID_CPPFLAGS:-}" \
      APP_OPTIM=release APP_CFLAGS="${ANDROID_OPT:--O3}" \
      NDK_OUT="$root/cores/build/obj/$NAME-$abi" NDK_LIBS_OUT="$root/cores/build/obj/$NAME-$abi/libs"
    built="$root/cores/build/obj/$NAME-$abi/libs/$abi/lib${ANDROID_MODULE:-retro}.so"
    [ -f "$built" ] || { echo "$built not found" >&2; exit 1; }
    lib="$out/${NAME}_libretro.so"
    cp "$built" "$lib"
    echo "built $lib"
    exit 0
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac
[ -n "$lib" ] || { echo "${NAME}_libretro not found in $src/$HOST_DIR" >&2; exit 1; }
cp "$lib" "$out/"
echo "built $out/$(basename "$lib")"
