#!/usr/bin/env bash
# Builds the Linux x86_64 release of Dena.emu (docs/dev/release-linux.md):
#   dena-emu-X.Y.Z-linux-x64.flatpak            single-file Flatpak bundle
#   dena-emu-X.Y.Z-linux-x64-portable.tar.gz    folder with portable.txt
# and prints the release-notes stub with the Steam Deck setup steps.
# Runs in WSL2 Debian on DENA-PC (never in the cloud: it builds the cores).
# The Flatpak is built in the 26.08 SDK; the portable tar.gz is built in an
# older SDK (portable_sdk=) so it runs on glibc down to portable_glibc= (both
# in cores/desktop-runtime.txt), and the build fails if it needs more.
#
# Usage: tools/release/build-linux.sh [options] [-- <flutter build args>]
#   --skip-cores     no core rebuild: the Flatpak uses cores/build/linux-x86_64,
#                    the tar.gz the cores of its previous portable build
#   --no-flatpak     only the portable tar.gz
#   --no-portable    only the Flatpak
#   --allow-missing-cores
#                    package even when fewer than the 12 desktop cores exist
# Anything after -- goes to `flutter build linux --release`, for example
#   -- --dart-define=KEY=value
# Output: build/release-linux/out/
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ID=io.github.denarmo.DenaEmu
EXPECTED_CORES=12
manifest="$root/tools/release/linux/$APP_ID.yml"
metainfo="$root/tools/release/linux/$APP_ID.metainfo.xml"
work="$root/build/release-linux"
out="$work/out"
bundle="$work/bundle"   # the manifest's `type: dir` source

skip_cores=0 flatpak=1 portable=1 allow_missing=0 flutter_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-cores) skip_cores=1 ;;
    --no-flatpak) flatpak=0 ;;
    --no-portable) portable=0 ;;
    --allow-missing-cores) allow_missing=1 ;;
    --) shift; flutter_args=("$@"); break ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "build-linux: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }

# Version from pubspec.yaml: "version: 0.0.9+9" -> 0.0.9
version="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$root/app/pubspec.yaml" | head -n1)"
[ -n "$version" ] || die "no version in app/pubspec.yaml"
name="dena-emu-$version-linux-x64"
grep -q "<release version=\"$version\"" "$metainfo" ||
  die "add <release version=\"$version\" date=\"YYYY-MM-DD\"> to $metainfo"

sdk="$(sed -n 's/^sdk=//p' "$root/cores/desktop-runtime.txt")"
runtime="$(sed -n 's/^runtime=//p' "$root/cores/desktop-runtime.txt")"
portable_sdk="$(sed -n 's/^portable_sdk=//p' "$root/cores/desktop-runtime.txt")"
portable_llvm="$(sed -n 's/^portable_llvm=//p' "$root/cores/desktop-runtime.txt")"
portable_glibc="$(sed -n 's/^portable_glibc=//p' "$root/cores/desktop-runtime.txt")"
portable_glibcxx="$(sed -n 's/^portable_glibcxx=//p' "$root/cores/desktop-runtime.txt")"
[ -n "$portable_sdk" ] && [ -n "$portable_llvm" ] && [ -n "$portable_glibc" ] && [ -n "$portable_glibcxx" ] ||
  die "cores/desktop-runtime.txt needs portable_sdk, portable_llvm, portable_glibc and portable_glibcxx"
grep -q "^runtime-version: '${runtime##*/}'" "$manifest" ||
  die "$manifest runtime-version does not match $runtime (cores/desktop-runtime.txt)"

step "Checking tools"
for tool in flutter flatpak; do
  command -v "$tool" >/dev/null || die "missing $tool: see docs/dev/release-linux.md, Setup"
done
if [ "$flatpak" = 1 ]; then
  command -v flatpak-builder >/dev/null || die "missing flatpak-builder: sudo apt install flatpak-builder"
fi
refs=()
[ "$flatpak" = 1 ] && refs+=("$sdk" "$runtime")
if [ "$portable" = 1 ]; then
  refs+=("$portable_sdk" "$portable_llvm")
  for tool in rsync readelf python3; do
    command -v "$tool" >/dev/null || die "missing $tool: see docs/dev/release-linux.md, Setup"
  done
fi
for ref in "${refs[@]}"; do
  flatpak info "$ref" >/dev/null 2>&1 || die "missing $ref: flatpak install --user flathub $ref"
done
echo "Dena.emu $version"
mkdir -p "$work" "$out"
[ "$flatpak" = 1 ] && echo "Flatpak: $sdk"
[ "$portable" = 1 ] && echo "portable tar.gz: $portable_sdk, glibc floor $portable_glibc (GLIBCXX $portable_glibcxx)"

# 1. Cores, inside the Flatpak SDK (cores/build-desktop.sh does that).
if [ "$flatpak" = 1 ] && [ "$skip_cores" = 0 ]; then
  step "Building the linux-x86_64 cores"
  bash "$root/cores/build-desktop.sh" linux-x86_64 || die "core build failed (see the summary above)"
fi

if [ "$flatpak" = 1 ]; then
# 2. The host library, inside the same SDK so it links against the runtime.
step "Building libdena_host.so in $sdk"
host_build="$root/build/desktop-linux-sdk"
flatpak run --filesystem="$root" --share=network --command=bash "$sdk" -c '
  set -e
  cmake -S "$1/host/desktop" -B "$2" -G Ninja -DCMAKE_BUILD_TYPE=Release
  ninja -C "$2"
  ctest --test-dir "$2" --output-on-failure
' _ "$root" "$host_build"
[ -f "$host_build/libdena_host.so" ] || die "no $host_build/libdena_host.so"

# 3. The Flutter release bundle. It copies cores/build/linux-x86_64 into
# lib/cores; the SDK-built host library replaces any other copy below.
step "Running flutter build linux --release"
(cd "$root/app" && flutter build linux --release "${flutter_args[@]}")
flutter_bundle="$root/app/build/linux/x64/release/bundle"
[ -x "$flutter_bundle/dena_emu" ] || die "no $flutter_bundle/dena_emu"

step "Staging the bundle in $bundle"
rm -rf "$bundle"
cp -a "$flutter_bundle" "$bundle"
cp "$host_build/libdena_host.so" "$bundle/lib/libdena_host.so"
mkdir -p "$bundle/lib/cores"
cores=$(find "$bundle/lib/cores" -name '*_libretro.so' | wc -l)
echo "$cores cores in lib/cores"
if [ "$cores" -lt "$EXPECTED_CORES" ]; then
  [ "$allow_missing" = 1 ] || die "only $cores of $EXPECTED_CORES cores (run without --skip-cores, or pass --allow-missing-cores)"
  echo "warning: packaging $cores of $EXPECTED_CORES cores" >&2
fi

# 4. Every library must resolve inside the runtime the Flatpak runs on.
step "Checking libraries against $runtime"
missing="$(flatpak run --filesystem="$bundle:ro" --command=sh "$runtime" -c '
  cd "$1"
  command -v ldd >/dev/null || { echo "SKIP"; exit 0; }
  for f in dena_emu lib/*.so lib/cores/*.so; do
    [ -f "$f" ] || continue
    LD_LIBRARY_PATH="$1/lib" ldd "$f" 2>&1 | sed -n "s|^[[:space:]]*\(.*\) => not found|$f: \1|p"
  done
' _ "$bundle")"
if [ "$missing" = SKIP ]; then
  echo "warning: no ldd in $runtime, library check skipped" >&2
elif [ -n "$missing" ]; then
  echo "$missing" >&2
  die "libraries missing from $runtime (see above)"
else
  echo "all libraries resolve"
fi
fi

# 5. Portable tar.gz, built from its own copy of the repo inside the older
# portable SDK (tools/release/linux/portable-build.sh), so its cores, host
# library and Flutter runner need no newer glibc than portable_glibc.
if [ "$portable" = 1 ]; then
  psrc="$work/portable-src"
  step "Copying the repo to $psrc"
  mkdir -p "$psrc"
  # Build output and core sources stay out; the copy keeps its own between runs.
  rsync -a --delete --exclude=/.git/ --exclude=/build/ --exclude=/cores/build/ \
    --exclude=/app/build/ --exclude=/app/.dart_tool/ --exclude=/app/linux/flutter/ephemeral/ \
    "$root/" "$psrc/"

  step "Building the portable binaries in $portable_sdk"
  flutter_root="$(cd "$(dirname "$(readlink -f "$(command -v flutter)")")/.." && pwd)"
  llvm_bin="/usr/lib/sdk/$(echo "$portable_llvm" | sed 's|^org\.freedesktop\.Sdk\.Extension\.||; s|/.*||')/bin"
  ccache_dir="${CCACHE_DIR:-$HOME/.cache/ccache}"
  mkdir -p "$ccache_dir"
  flatpak run --filesystem=home --filesystem="$psrc" --filesystem="$flutter_root" \
    --filesystem="$ccache_dir" --env=CCACHE_DIR="$ccache_dir" \
    --env=DENA_FLUTTER_ROOT="$flutter_root" --env=DENA_LLVM_BIN="$llvm_bin" \
    --share=network --command=bash "$portable_sdk" \
    "$psrc/tools/release/linux/portable-build.sh" "$psrc" "$skip_cores" "${flutter_args[@]}" ||
    die "portable build failed in $portable_sdk (see above)"
  pbundle="$psrc/app/build/linux/x64/release/bundle"
  [ -x "$pbundle/dena_emu" ] || die "no $pbundle/dena_emu"

  step "Packing $name-portable.tar.gz"
  stage="$work/portable/dena-emu"
  rm -rf "$work/portable"
  mkdir -p "$stage"
  cp -a "$pbundle/." "$stage/"
  cp "$psrc/build/desktop-linux/libdena_host.so" "$stage/lib/libdena_host.so"
  pcores=$(find "$stage/lib/cores" -name '*_libretro.so' 2>/dev/null | wc -l)
  echo "$pcores cores in lib/cores"
  if [ "$pcores" -lt "$EXPECTED_CORES" ]; then
    [ "$allow_missing" = 1 ] || die "only $pcores of $EXPECTED_CORES portable cores (run without --skip-cores, or pass --allow-missing-cores)"
    echo "warning: packaging $pcores of $EXPECTED_CORES cores" >&2
  fi

  step "Checking the portable binaries against the glibc floor"
  python3 "$root/tools/release/linux/check_glibc_floor.py" \
    --glibc "$portable_glibc" --glibcxx "$portable_glibcxx" "$stage" ||
    die "the portable build needs a newer glibc than $portable_glibc (see above)"

  install -m755 "$root/tools/release/linux/dena-emu" "$stage/dena-emu"
  printf 'Dena.emu portable mode: all data stays in the Dena folder beside this file.\n' >"$stage/portable.txt"
  mkdir -p "$stage/Dena/Roms"
  tar -C "$work/portable" -czf "$out/$name-portable.tar.gz" --owner=0 --group=0 dena-emu
  echo "$out/$name-portable.tar.gz"
fi

# 6. Flatpak: build into a local repo, then export the single-file bundle.
if [ "$flatpak" = 1 ]; then
  step "Building the Flatpak $APP_ID"
  # rofiles-fuse is often unavailable in WSL2.
  flatpak-builder --user --force-clean --disable-rofiles-fuse \
    --state-dir="$work/flatpak-state" --repo="$work/flatpak-repo" \
    "$work/flatpak-build" "$manifest"
  flatpak build-bundle "$work/flatpak-repo" "$out/$name.flatpak" "$APP_ID" \
    --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo
  echo "$out/$name.flatpak"
fi

# 7. Release notes stub (also saved beside the packages).
notes="$out/release-notes-linux.md"
cat >"$notes" <<NOTES
## Linux and Steam Deck (x86_64)

- \`$name.flatpak\`: Flatpak for SteamOS and any distro (runtime $runtime from Flathub).
- \`$name-portable.tar.gz\`: portable folder; everything stays inside it.

### Install on the Steam Deck
1. Press the Steam button › Power › **Switch to Desktop**.
2. Download \`$name.flatpak\`, then open Konsole and run
   \`flatpak install --user ~/Downloads/$name.flatpak\`
   (Discover can also open the file). The runtime comes from Flathub on its own.
3. Open Steam › Games › **Add a Non-Steam Game to My Library** › tick **Dena.emu** › Add Selected Programs.
   No launch options are needed for the Flatpak entry.
   For the portable folder instead: unpack it, Browse… to \`dena-emu/dena-emu\`, and leave the launch options as \`%command%\`.
4. Back in Gaming Mode, open Dena.emu's controller settings in Steam and pick the **Gamepad** layout (not "Keyboard and Mouse"), so Steam Input passes a controller through.
5. Steam Input note: to get gyro and the original controller straight from SDL, turn Steam Input off for the Dena.emu shortcut (Properties › Controller › Disable Steam Input).

Dena.emu starts fullscreen in controller mode when a controller is present, so the Deck always opens fullscreen.
Add your game folders in Games › Add a folder; the Flatpak sees only folders you pick there. For SD-card folder watching, see docs/dev/release-linux.md.
NOTES
step "Release notes ($notes)"
cat "$notes"
