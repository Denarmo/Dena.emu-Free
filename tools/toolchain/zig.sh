#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Finds (or, with "install", downloads) the pinned Zig into the user's folder.
# Usage: tools/toolchain/zig.sh [path|install]   Spec: docs/specs/toolchain-linux.md
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^version=//p' "$here/zig.txt")"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) host=x86_64-windows exe=zig.exe base="${LOCALAPPDATA:-$HOME}/dena-tools" ;;
  Linux) host="$(uname -m)-linux" exe=zig base="$HOME/.local/share/dena-tools" ;;
  Darwin) host="$(uname -m | sed 's/arm64/aarch64/')-macos" exe=zig base="$HOME/Library/dena-tools" ;;
  *) echo "unsupported host" >&2; exit 2 ;;
esac
dir="$base/zig-$host-$version"

find_zig() {
  if [ -n "${DENA_ZIG:-}" ] && [ -x "$DENA_ZIG" ]; then echo "$DENA_ZIG"; return 0; fi
  if [ -x "$dir/$exe" ]; then echo "$dir/$exe"; return 0; fi
  return 1
}

case "${1:-path}" in
  path) find_zig ;;
  install)
    if find_zig >/dev/null; then find_zig; exit 0; fi
    line="$(sed -n "s/^$host=//p" "$here/zig.txt")"
    [ -n "$line" ] || { echo "no Zig pinned for $host" >&2; exit 2; }
    url="${line% *}" sum="${line#* }"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -sSfL -o "$tmp/zig.archive" "$url"
    echo "$sum  $tmp/zig.archive" | sha256sum -c - >/dev/null
    mkdir -p "$base"
    case "$url" in
      *.zip) unzip -q "$tmp/zig.archive" -d "$base" ;;
      *) tar -xJf "$tmp/zig.archive" -C "$base" ;;
    esac
    find_zig ;;
  *) echo "usage: $0 [path|install]" >&2; exit 2 ;;
esac
