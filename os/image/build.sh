#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the Dena.emu single-card SD image for the Allwinner H700 handhelds
# (RG35XX SP / Plus / H / 2024): mainline U-Boot + TF-A, Linux with the H700
# display patches, an initramfs and the read-only system image, so the
# handheld boots from one card with no stock firmware card.
# Spec: docs/specs/single-card.md
#
# Usage: os/image/build.sh [options]
#   --device NAME   rg35xxsp (default), rg35xxsp-v2, rg35xxplus, rg35xxh, rg35xx2024
#   --dram TYPE     lpddr4 (default) or lpddr3, the board's memory type
#   --version V     image version (default: git describe)
#   --payload DIR   app payload from os/payload.py (bin/, lib/, data/)
#   --test          also build an image with a stand-in launcher and boot it
#                   in QEMU (os/image/qemu-test.sh)
#   --xz            also write <image>.xz
#   --diagnostic    kernel messages on the panel instead of the splash, logs
#                   on the card, a shell instead of power off (name: -diag)
# Environment: DENA_IMAGE_WORK (sources and build trees, default
# os/image/work), DENA_IMAGE_OUT (default os/image/out), CROSS_COMPILE
# (default aarch64-linux-gnu-), DENA_SUITE / DENA_MIRROR / DENA_COMPONENTS
# (base packages, default Debian trixie), JOBS.
# Needs a Linux host (or os/image/Dockerfile): see the spec for the tools.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="${DENA_IMAGE_WORK:-$here/work}"
out="${DENA_IMAGE_OUT:-$here/out}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
jobs="${JOBS:-$(nproc)}"
suite="${DENA_SUITE:-trixie}"
mirror="${DENA_MIRROR:-http://deb.debian.org/debian}"
components="${DENA_COMPONENTS:-main}"

device=rg35xxsp
dram=lpddr4
version=""
payload=""
test_boot=""
xz=""
diagnostic=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --dram) dram="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --payload) payload="$(cd "$2" && pwd)"; shift 2 ;;
    --test) test_boot=1; shift ;;
    --xz) xz=1; shift ;;
    --diagnostic) diagnostic=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

# Device -> default device tree. Every H700 tree goes on the card, so another
# model needs only the FDT line in extlinux.conf changed.
case "$device" in
  rg35xxsp) fdt=sun50i-h700-anbernic-rg35xx-sp.dtb ;;
  rg35xxsp-v2) fdt=sun50i-h700-anbernic-rg35xx-sp-v2-panel.dtb ;;
  rg35xxplus) fdt=sun50i-h700-anbernic-rg35xx-plus.dtb ;;
  rg35xxh) fdt=sun50i-h700-anbernic-rg35xx-h.dtb ;;
  rg35xx2024) fdt=sun50i-h700-anbernic-rg35xx-2024.dtb ;;
  *) echo "build.sh: unknown device $device" >&2; exit 2 ;;
esac
dtbs=(sun50i-h700-anbernic-rg35xx-sp.dtb sun50i-h700-anbernic-rg35xx-sp-v2-panel.dtb
      sun50i-h700-anbernic-rg35xx-plus.dtb sun50i-h700-anbernic-rg35xx-h.dtb
      sun50i-h700-anbernic-rg35xx-2024.dtb)
case "$dram" in lpddr4|lpddr3) ;; *) echo "build.sh: --dram lpddr4|lpddr3" >&2; exit 2 ;; esac
[ -n "$version" ] || version="$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)"

src="$work/src"
bld="$work/build"
mkdir -p "$src" "$bld" "$out"
step() { echo "=== $*"; }

# --- Sources: pinned tag and commit (sources.txt) -----------------------------
fetch() {
  local name="$1" url="$2" tag="$3" commit="$4" dir="$src/$1"
  if [ ! -d "$dir/.git" ]; then
    step "fetch $name $tag"
    git clone -q --depth 1 --branch "$tag" "$url" "$dir"
  fi
  local head
  head="$(git -C "$dir" rev-parse HEAD)"
  if [ "$head" != "$commit" ]; then
    echo "build.sh: $name is at $head, expected $commit ($tag)" >&2
    exit 1
  fi
}
while read -r name url tag commit; do
  case "$name" in ''|'#'*) continue ;; esac
  fetch "$name" "$url" "$tag" "$commit"
done < "$here/sources.txt"

# Applies a patch set to a pristine tree once; a stamp records which set
# (and which of our own files are copied into the tree).
patch_tree() {
  local dir="$1"; shift
  local stamp="$dir/.dena-patches" sum
  sum="$(cat "$@" /dev/null | sha256sum | cut -d' ' -f1)"
  [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sum" ] && return 0
  git -C "$dir" reset -q --hard
  git -C "$dir" clean -q -fdx
  local p
  for p in "$@"; do
    # GNU patch, not git apply: some files are several mails concatenated.
    # Other files (device trees) only count towards the stamp.
    case "$p" in *.patch) patch -d "$dir" -p1 -N -s --no-backup-if-mismatch < "$p" ;; esac
  done
  echo "$sum" > "$stamp"
}

# --- TF-A (BL31) ---------------------------------------------------------------
step "TF-A"
make -s -C "$src/tf-a" PLAT=sun50i_h616 DEBUG=0 BUILD_BASE="$bld/tf-a" -j"$jobs" bl31
bl31="$bld/tf-a/sun50i_h616/release/bl31.bin"

# --- U-Boot ----------------------------------------------------------------------
step "U-Boot ($dram)"
patch_tree "$src/u-boot" "$here"/u-boot/patches/*.patch
ub="$bld/u-boot-$dram"
make -s -C "$src/u-boot" O="$ub" anbernic_rg35xx_h700_defconfig
frags=("$here/u-boot/dena-h700.config")
[ "$dram" = lpddr3 ] && frags+=("$here/u-boot/lpddr3.config")
(cd "$src/u-boot" && scripts/kconfig/merge_config.sh -m -O "$ub" "$ub/.config" "${frags[@]}" > /dev/null)
make -s -C "$src/u-boot" O="$ub" olddefconfig
make -s -C "$src/u-boot" O="$ub" -j"$jobs" BL31="$bl31"
uboot="$ub/u-boot-sunxi-with-spl.bin"

# --- Panel firmware ------------------------------------------------------------
step "panel firmware"
rm -rf "$bld/firmware"
python3 "$here/linux/panels/panelgen.py" build "$here"/linux/panels/*.json --out "$bld/firmware"

# --- Base packages -------------------------------------------------------------
pkgs="$(grep -vE '^#|^$' "$here/rootfs/packages.txt" | paste -sd, -)"
base="$bld/base-$suite.tar"
base_key="$(printf '%s %s %s %s' "$suite" "$mirror" "$components" "$pkgs" | sha256sum | cut -d' ' -f1)"
if [ ! -f "$base" ] || [ "$(cat "$base.key" 2>/dev/null)" != "$base_key" ]; then
  step "base packages ($suite)"
  mmdebstrap --quiet --variant=extract --architectures=arm64 --components="$components" \
    --include="$pkgs" "$suite" "$base" "$mirror"
  echo "$base_key" > "$base.key"
fi

# --- Kernel firmware -----------------------------------------------------------
# Built into the kernel (CONFIG_EXTRA_FIRMWARE): Wi-Fi firmware pinned in
# linux/firmware.txt, and the regulatory database from wireless-regdb.
step "kernel firmware"
while read -r path url sum; do
  case "$path" in ''|'#'*) continue ;; esac
  cache="$src/firmware/$path"
  if [ ! -f "$cache" ] || [ "$(sha256sum < "$cache" | cut -d' ' -f1)" != "$sum" ]; then
    mkdir -p "$(dirname "$cache")"
    curl -fsSL -o "$cache.part" "$url"
    if [ "$(sha256sum < "$cache.part" | cut -d' ' -f1)" != "$sum" ]; then
      echo "build.sh: $path from $url does not match its sha256" >&2
      exit 1
    fi
    mv "$cache.part" "$cache"
  fi
  mkdir -p "$bld/firmware/$(dirname "$path")"
  cp "$cache" "$bld/firmware/$path"
done < "$here/linux/firmware.txt"
# Debian installs regulatory.db through alternatives (not run by the extract
# variant), Ubuntu installs it directly: take the upstream-signed files.
rm -rf "$bld/regdb"
mkdir -p "$bld/regdb"
tar -xf "$base" -C "$bld/regdb" --wildcards './lib/firmware/regulatory.db*' './usr/lib/firmware/regulatory.db*' 2>/dev/null || true
for f in regulatory.db regulatory.db.p7s; do
  found=""
  for c in "$bld"/regdb/{,usr/}lib/firmware/{"$f","$f-upstream"}; do
    [ -f "$c" ] && { found="$c"; break; }
  done
  [ -n "$found" ] || { echo "build.sh: wireless-regdb has no $f" >&2; exit 1; }
  cp "$found" "$bld/firmware/$f"
done

# --- Linux -----------------------------------------------------------------------
step "Linux"
patch_tree "$src/linux" "$here"/linux/patches/*.patch "$here"/linux/dts/*.dts
dts_dir="$src/linux/arch/arm64/boot/dts/allwinner"
for d in "$here"/linux/dts/*.dts; do
  cp "$d" "$dts_dir/"
  b="$(basename "$d" .dts)"
  grep -q "$b.dtb" "$dts_dir/Makefile" || echo "dtb-\$(CONFIG_ARCH_SUNXI) += $b.dtb" >> "$dts_dir/Makefile"
done
kb="$bld/linux"
mkdir -p "$kb"
sed "s|@PANEL_FIRMWARE_DIR@|$bld/firmware|" "$here/linux/dena-h700.config" > "$kb/dena.config"
make -s -C "$src/linux" O="$kb" ARCH=arm64 defconfig
(cd "$src/linux" && ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "$kb" "$kb/.config" "$kb/dena.config" > /dev/null)
make -s -C "$src/linux" O="$kb" ARCH=arm64 olddefconfig
make -s -C "$src/linux" O="$kb" ARCH=arm64 -j"$jobs" Image "${dtbs[@]/#/allwinner/}"
kernel="$kb/arch/arm64/boot/Image"
dtb_args=()
for d in "${dtbs[@]}"; do dtb_args+=(--dtb "$kb/arch/arm64/boot/dts/allwinner/$d"); done

# --- Splash (static: it starts before anything else) ----------------------------
step "splash"
"${CROSS_COMPILE}gcc" -static -Os -s -Wall -o "$bld/dena-splash" "$here/splash/dena-splash.c" -lm

# --- initramfs, system image, card image ---------------------------------------
step "initramfs"
rm -rf "$bld/busybox"
mkdir -p "$bld/busybox"
tar -xf "$base" -C "$bld/busybox" ./usr/bin/busybox
python3 "$here/initramfs.py" --busybox "$bld/busybox/usr/bin/busybox" --out "$bld/initramfs.cpio.gz"

image() { # <system payload or ""> <image path>
  local sys="$bld/dena-system.squashfs" args=()
  [ -n "$1" ] && args=(--payload "$1")
  step "system image ${1:+(payload $1)}"
  python3 "$here/system.py" --rootfs-tar "$base" --version "$version" --out "$sys" \
    --splash "$bld/dena-splash" "${args[@]}"
  step "card image $2"
  python3 "$here/assemble.py" --uboot "$uboot" --kernel "$kernel" \
    --initramfs "$bld/initramfs.cpio.gz" --system "$sys" "${dtb_args[@]}" --fdt "$fdt" \
    --version "$version" ${diagnostic:+--diagnostic} --out "$2"
}

img="$out/Dena-$version-$device.img"
[ "$dram" = lpddr3 ] && img="${img%.img}-lpddr3.img"
[ -n "$diagnostic" ] && img="${img%.img}-diag.img"
image "$payload" "$img"
[ -n "$xz" ] && xz -T0 -9 -k -f "$img"

if [ -n "$test_boot" ]; then
  test_img="$bld/qemu-test.img"
  image "$here/qemu/fake-payload" "$test_img"
  step "QEMU boot test"
  "$here/qemu-test.sh" "$test_img" "$kernel" "$bld/initramfs.cpio.gz"
fi
echo "done: $img"
