#!/usr/bin/env bash
# Shared by cores/*/build.sh for the desktop targets (docs/dev/desktop-cores.md):
#   win64          Windows x86_64 .dll, cross-built with MinGW-w64 (posix threads)
#   linux-x86_64   Linux x86_64 .so, built natively (inside the Flatpak SDK for
#                  releases: cores/build-desktop.sh does that)
# Sourced, not run. It gives the caller:
#   dena_parse_args "$@"; set -- "${dena_args[@]}"
#                  accepts `--target <t>` as well as the positional target, and
#                  `--dry-run` (or DENA_DRY_RUN=1): print commands, change nothing
#   dena_dry       true in dry-run mode
#   dena_run cmd…  runs cmd, or prints it in dry-run mode
#   dena_desktop_env <target>
#                  sets X64_CC X64_CXX X64_AR X64_STRIP X64_OBJDUMP X64_EXT
#                  X64_PLATFORM (libretro Makefile platform=) and X64_CMAKE
#                  (array of cmake -D options); ccache in front of the compilers
#                  unless DENA_CCACHE=0
#   dena_check_lib <lib> <target>
#                  strips the library and fails when a win64 DLL still imports
#                  the MinGW runtime DLLs; prints the Linux .so's NEEDED list
#   dena_fresh_copy <src> <work> <stamp>
#                  copies the tracked files of <src> to <work> unless <work>
#                  already holds <stamp> (objects land next to the sources)

# shellcheck disable=SC2034  # the X64_* variables are for the sourcing scripts
DENA_DESKTOP_TARGETS="win64 linux-x86_64"

dena_parse_args() {
  dena_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DENA_DRY_RUN=1 ;;
      --target) dena_args+=("${2:?--target needs a value}"); shift ;;
      --target=*) dena_args+=("${1#--target=}") ;;
      *) dena_args+=("$1") ;;
    esac
    shift
  done
  export DENA_DRY_RUN="${DENA_DRY_RUN:-0}"
}

dena_dry() { [ "${DENA_DRY_RUN:-0}" = 1 ]; }

dena_run() {
  if dena_dry; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

dena_is_desktop() { case " $DENA_DESKTOP_TARGETS " in *" $1 "*) return 0 ;; esac; return 1; }

# First of the names that exists (or the first name in dry-run mode).
_dena_tool() {
  local t
  for t in "$@"; do
    if command -v "$t" >/dev/null 2>&1; then echo "$t"; return 0; fi
  done
  if dena_dry; then echo "$1"; return 0; fi
  echo "missing build tool: $1 (docs/dev/desktop-cores.md, Setup)" >&2
  return 1
}

dena_desktop_env() {
  local target="$1" root_dir
  root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local launcher=""
  if [ "${DENA_CCACHE:-1}" != 0 ] && { command -v ccache >/dev/null 2>&1 || dena_dry; }; then
    launcher="ccache "
  fi
  X64_CMAKE=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
  [ -n "$launcher" ] && X64_CMAKE+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
  case "$target" in
    win64)
      local t=x86_64-w64-mingw32 cc cxx
      cc="$(_dena_tool $t-gcc-posix $t-gcc)" || return 1
      cxx="$(_dena_tool $t-g++-posix $t-g++)" || return 1
      # -static: no libgcc_s/libstdc++/libwinpthread DLLs next to the core.
      X64_CC="$launcher$cc -static"
      X64_CXX="$launcher$cxx -static"
      X64_AR="$(_dena_tool $t-gcc-ar-posix $t-ar)" || return 1
      X64_STRIP="$(_dena_tool $t-strip)" || return 1
      X64_OBJDUMP="$(_dena_tool $t-objdump)" || return 1
      X64_EXT=dll
      # Any platform name the Makefiles do not know selects their generic
      # MinGW branch (TARGET := <name>_libretro.dll); "win" is the usual one.
      X64_PLATFORM=win
      X64_CMAKE+=(-DCMAKE_TOOLCHAIN_FILE="$root_dir/tools/toolchain/x86_64-w64-mingw32.cmake")
      ;;
    linux-x86_64)
      if ! dena_dry && [ "$(uname -m)" != x86_64 ]; then
        echo "linux-x86_64 builds natively: run it on an x86_64 machine" >&2
        return 1
      fi
      X64_CC="$launcher$(_dena_tool gcc cc)" || return 1
      X64_CXX="$launcher$(_dena_tool g++ c++)" || return 1
      X64_AR="$(_dena_tool gcc-ar ar)" || return 1
      X64_STRIP="$(_dena_tool strip)" || return 1
      X64_OBJDUMP="$(_dena_tool readelf)" || return 1
      X64_EXT=so
      X64_PLATFORM=unix
      ;;
    *) echo "not a desktop target: $target" >&2; return 2 ;;
  esac
}

dena_check_lib() {
  local lib="$1" target="$2"
  dena_run "$X64_STRIP" --strip-unneeded "$lib"
  dena_dry && return 0
  if [ "$target" = win64 ]; then
    local bad
    bad="$("$X64_OBJDUMP" -p "$lib" | awk '/DLL Name:/ { print $3 }' |
      grep -iE '^(libgcc_s|libstdc\+\+|libwinpthread|libgomp)' || true)"
    if [ -n "$bad" ]; then
      echo "$(basename "$lib") needs MinGW runtime DLLs: $bad (link them statically)" >&2
      return 1
    fi
  else
    "$X64_OBJDUMP" -d "$lib" | awk '/NEEDED/ { gsub(/[][]/, "", $5); printf "  needs %s\n", $5 }'
  fi
}

dena_fresh_copy() {
  local src="$1" work="$2" stamp="$3"
  if [ -f "$work/.dena-commit" ] && [ "$(cat "$work/.dena-commit")" = "$stamp" ]; then
    return 0
  fi
  if dena_dry; then
    echo "+ copy the tracked files of $src to $work"
    return 0
  fi
  rm -rf "$work"
  mkdir -p "$work"
  git -C "$src" ls-files --recurse-submodules -z |
    (cd "$src" && tar --null -T - -cf -) | (cd "$work" && tar -xf -)
  echo "$stamp" > "$work/.dena-commit"
}
