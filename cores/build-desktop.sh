#!/usr/bin/env bash
# Builds every desktop core for one target (docs/dev/desktop-cores.md).
# Usage: cores/build-desktop.sh [--dry-run] [--native] <win64|linux-x86_64> [core...]
#   core      a directory under cores/ (default: all of DESKTOP_CORES below)
#   --native  linux-x86_64 only: build with the host's gcc instead of inside
#             the Flatpak SDK (quick checks; release builds use the SDK)
#   --dry-run print every command, change nothing
# Output: cores/build/<target>/*_libretro.{dll,so}. Keeps going after a core
# fails and exits 1 at the end if any did.
set -euo pipefail

# The desktop cores, in build order (small to big). PCSX ReARMed is ARM only;
# Beetle PSX HW is the x86_64 PlayStation core. LRPS2 (PS2) builds here for
# linux-x86_64 only; its win64 DLL comes from MSVC (cores/lrps2/build-msvc.ps1).
DESKTOP_CORES=(fceumm mgba fake08 bsnes beetle_psx beetle_saturn melonds
  mupen64plus flycast ppsspp lrps2 dolphin)
# Built with MSVC on Windows for win64 (their build-msvc.ps1), so skipped here
# for that target. (LRPS2's own script skips win64 itself.)
MSVC_CORES=(dolphin)

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=cores/desktop.sh
source "$root/cores/desktop.sh"
native=0
args=()
for a in "$@"; do
  case "$a" in
    --native) native=1 ;;
    *) args+=("$a") ;;
  esac
done
dena_parse_args "${args[@]}"
set -- "${dena_args[@]}"
target="${1:?usage: build-desktop.sh [--dry-run] [--native] <win64|linux-x86_64> [core...]}"
shift
dena_is_desktop "$target" || { echo "not a desktop target: $target ($DENA_DESKTOP_TARGETS)" >&2; exit 2; }
cores=("$@")
[ ${#cores[@]} -gt 0 ] || cores=("${DESKTOP_CORES[@]}")

# Linux release builds run inside the freedesktop SDK the Flatpak uses, so
# the cores link against the runtime's glibc and libraries.
sdk="$(sed -n 's/^sdk=//p' "$root/cores/desktop-runtime.txt")"
if [ "$target" = linux-x86_64 ] && [ "$native" = 0 ] && [ -z "${FLATPAK_ID:-}" ]; then
  ccache_dir="${CCACHE_DIR:-$HOME/.cache/ccache}"
  inner=(bash "$root/cores/build-desktop.sh" --native)
  dena_dry && inner+=(--dry-run)
  inner+=("$target" "${cores[@]}")
  if ! dena_dry; then
    command -v flatpak >/dev/null || { echo "no flatpak: see docs/dev/desktop-cores.md, Setup (or pass --native)" >&2; exit 1; }
    flatpak info "$sdk" >/dev/null 2>&1 || { echo "missing $sdk: flatpak install --user flathub $sdk" >&2; exit 1; }
    mkdir -p "$ccache_dir"
  fi
  dena_run flatpak run --filesystem="$root" --filesystem="$ccache_dir" \
    --env=CCACHE_DIR="$ccache_dir" --share=network --command=bash "$sdk" -c \
    "cd \"\$1\" && shift && exec \"\$@\"" _ "$root" "${inner[@]}"
  # In dry-run mode, also show what runs inside the SDK.
  dena_dry && exec "${inner[@]}"
  exit 0
fi

failed=()
for core in "${cores[@]}"; do
  if [ "$target" = win64 ] && printf '%s\n' "${MSVC_CORES[@]}" | grep -qxF "$core"; then
    echo "=== $core ($target): built with MSVC on Windows, cores\\$core\\build-msvc.ps1"
    continue
  fi
  script="$root/cores/$core/build.sh"
  [ -f "$script" ] || { echo "no such core: $core" >&2; failed+=("$core"); continue; }
  echo "=== $core ($target)"
  set +e
  bash "$script" "$target"
  rc=$?
  set -e
  [ $rc -eq 0 ] || failed+=("$core")
done
if [ ${#failed[@]} -gt 0 ]; then
  echo "failed: ${failed[*]}" >&2
  exit 1
fi
if dena_dry; then echo "dry run: ${#cores[@]} cores for $target"; else echo "all ${#cores[@]} cores built for $target"; fi
