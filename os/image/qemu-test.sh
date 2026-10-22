#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Boot smoke test for the single-card image (docs/specs/single-card.md):
# boots the card's own kernel, initramfs and system image on QEMU's arm64
# "virt" machine with the card image as the disk, twice, and checks the boot
# log. The H700 hardware (display, buttons, U-Boot itself) is not exercised;
# everything from the initramfs on is the same code that runs on the device.
#
# Usage: os/image/qemu-test.sh <card.img> <Image> <initramfs.cpio.gz>
# The card image should carry the stand-in launcher (build.sh --test).
set -euo pipefail

img="$1" kernel="$2" initrd="$3"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
disk="$tmp/card.img"
cp "$img" "$disk"
# A 1 GiB "SD card": room for the games partition made on the first boot.
truncate -s 1G "$disk"

boot() { # <log>
  timeout 300 qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2 -m 1024 \
    -nographic -no-reboot -kernel "$kernel" -initrd "$initrd" \
    -append "console=ttyAMA0 dena.boot=LABEL=DENA-BOOT" \
    -drive "file=$disk,format=raw,if=virtio" < /dev/null > "$1" 2>&1 || true
  tr -d '\r' < "$1" > "$1.txt"
}

failed=0
expect() { # <log> <pattern> <what>
  if grep -qE "$2" "$1.txt"; then
    echo "ok: $3"
  else
    echo "FAIL: $3 (no /$2/ in the boot log)"
    failed=1
  fi
}
reject() {
  if grep -qE "$2" "$1.txt"; then
    echo "FAIL: $3"
    failed=1
  else
    echo "ok: $3"
  fi
}

echo "--- first boot"
boot "$tmp/boot1.log"
l="$tmp/boot1.log"
expect "$l" 'dena-initramfs: boot partition /dev/vda1' "initramfs found DENA-BOOT"
expect "$l" 'dena-initramfs: system dena-system.squashfs mounted' "system image mounted"
expect "$l" 'dena-init: first boot: card expanded \(/dev/vda2\)' "games partition created"
expect "$l" 'dena-init: card ready \(/dev/vda2\)' "games partition mounted"
expect "$l" 'fake-launcher: ran handheld=1 card=/mnt/card app=/usr/lib/dena/data/app' "launcher started by the boot hook"
expect "$l" 'fake-launcher: roms: gb gba gbc n64 nds nes pico8 psp psx snes $' "card laid out (Roms/<system>)"
expect "$l" 'dena-init: session end: .*launcher exit 0' "launcher exit logged"
expect "$l" 'dena-init: powering off' "powers off after the session"
expect "$l" 'dena-init: shutdown' "shutdown script ran (card unmounted)"

echo "--- second boot"
boot "$tmp/boot2.log"
l="$tmp/boot2.log"
reject "$l" 'first boot' "no repartitioning on the second boot"
expect "$l" 'dena-init: card ready \(/dev/vda2\)' "games partition mounted again"
expect "$l" 'fake-launcher: ran' "launcher started again"

# The partition table as the device leaves it: DENA-BOOT at 16 MiB and the
# exFAT games partition right after it, up to the end of the card.
table="$(sfdisk -d "$disk" 2>/dev/null || true)"
p1="$(echo "$table" | sed -n 's|.*1 : start= *\([0-9]*\), size= *\([0-9]*\), type=c.*|\1 \2|p')"
p2="$(echo "$table" | sed -n 's|.*2 : start= *\([0-9]*\), size= *\([0-9]*\), type=7.*|\1 \2|p')"
set -- $p1 $p2
if [ $# = 4 ] && [ "$1" = 32768 ] && [ "$3" = $(($1 + $2)) ] && [ $(($3 + $4)) = $((1 << 21)) ]; then
  echo "ok: partition table (DENA-BOOT at 16 MiB, games partition after it to the end)"
else
  echo "FAIL: partition table"; echo "$table"; failed=1
fi

if [ "$failed" != 0 ]; then
  echo "--- first boot log"; cat "$tmp/boot1.log.txt"
  echo "--- second boot log"; cat "$tmp/boot2.log.txt"
  exit 1
fi
echo "qemu-test: all checks passed"
