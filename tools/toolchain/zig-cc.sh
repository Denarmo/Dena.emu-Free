#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# `zig cc` / `zig c++` for aarch64 Linux handhelds, for Makefiles that pass
# GNU-ld spellings zig's linker front end doesn't take.
# Usage: zig-cc.sh cc|c++ <args>...   (needs DENA_ZIG; adds DENA_CFLAGS;
# -lfoo becomes DENA_LIBDIR/libfoo.so when that file exists)
set -euo pipefail
tool="$1"
shift
args=()
# As the C++ compiler for C sources (LINUX_CC=c++), compile them as C++.
if [ "$tool" = c++ ]; then
  for a in "$@"; do [ "$a" = -c ] && args=(-x c++) && break; done
fi
for a in "$@"; do
  case "$a" in
    -Wl,-no-undefined) args+=(-Wl,--no-undefined) ;;
    -mcpu=*) args+=("-mcpu=$(echo "${a#-mcpu=}" | tr - _)") ;;  # zig: cortex_a53
    -mtune=*) ;;
    # zig hands sysroot libraries to lld as -l:<path>, which lld rejects on
    # Windows; name the file instead.
    -l*) if [ -n "${DENA_LIBDIR:-}" ] && [ -f "$DENA_LIBDIR/lib${a#-l}.so" ]; then
           args+=("$DENA_LIBDIR/lib${a#-l}.so")
         else
           args+=("$a")
         fi ;;
    *) args+=("$a") ;;
  esac
done
# shellcheck disable=SC2086
exec "${DENA_ZIG:?set DENA_ZIG}" "$tool" -target aarch64-linux-gnu.2.28 ${DENA_CFLAGS:-} "${args[@]}"
