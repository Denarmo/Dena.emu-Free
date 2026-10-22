# Spec: single-card boot (H700)

Status: implemented for the H700 family (RG35XX SP / Plus / H / 2024);
QEMU boot test passes; first boot on a real device is a human checkpoint.
Requested by the user (2026-10-17): Dena.emu should boot from one SD card
with its own boot loader, kernel and system, instead of the two-card setup
where the stock firmware card boots and our card only carries the app
(sd-card.md).

## What the user gets

- `Dena-<version>-rg35xxsp.img`: flash it to one microSD card (Raspberry Pi
  Imager, balenaEtcher, `dd`), put it in the first slot (TF1) and power on.
  No stock firmware card, no vendor files.
- First boot creates the games partition `DENA` (exFAT) over the rest of the
  card and lays out `Roms/<system>`, `Bios`, `Saves`, `States`, `Carts`,
  `Dena/user` and `Dena-README.txt` (the same layout as sd-card.md). On a PC
  the card then shows `DENA` for games and the small `DENA-BOOT`.
- The launcher starts on its own; when it exits the handheld powers off
  (there is no stock system to go back to).

## Boot chain

| Stage | Where | What |
| --- | --- | --- |
| Boot ROM | SoC | Loads the SPL from the card at 8 KiB (eGON header and checksum) |
| U-Boot SPL | card, 8 KiB | DRAM init (LPDDR4 by default, `--dram lpddr3` for boards with LPDDR3), loads TF-A BL31 and U-Boot proper |
| TF-A BL31 | in the U-Boot FIT | Secure monitor, PSCI (`sun50i_h616` platform) |
| U-Boot | in the U-Boot FIT | Distro boot: `extlinux/extlinux.conf` on the bootable FAT partition |
| Linux | DENA-BOOT `Image` + `dtbs/allwinner/<model>.dtb` | Everything built in, no modules; panel init data built in as firmware |
| initramfs | DENA-BOOT `initramfs.cpio.gz` | busybox: finds `LABEL=DENA-BOOT`, loop-mounts `dena-system.squashfs`, tmpfs overlay, `switch_root` |
| busybox init | system image | `dena-sysinit` (mounts, first-boot partitioning), `dena-session` (boot hook + launcher, then power off), `dena-net` (Wi-Fi), `dena-shutdown` |

Every stage is built from source here (os/image/build.sh): no vendor boot0,
boot_package or kernel, and nothing of the stock firmware is read or copied.

## Card layout

```
0        MBR: partition 1 only; partition 2 is made on the first boot
8 KiB    u-boot-sunxi-with-spl.bin (must end before 16 MiB)
16 MiB   p1 FAT32 "DENA-BOOT", 512 MiB, bootable
           Image, initramfs.cpio.gz, dena-system.squashfs, VERSION
           dtbs/allwinner/*.dtb  (every H700 model)
           extlinux/extlinux.conf (FDT = the model the image was built for)
528 MiB  p2 exFAT "DENA" (type 7), to the end of the card, made on first boot
```

- The boot files take under 45% of DENA-BOOT, so a second system image fits
  during a future system update (written next to the old one, then renamed).
- One image per default model (`--device`), all device trees on every card:
  another H700 model only needs the `FDT` line changed. The RG35XX SP has
  two panel revisions; `rg35xxsp-v2` (or editing `FDT` to
  `sun50i-h700-anbernic-rg35xx-sp-v2-panel.dtb`) is for the newer panel.
- Kernel command line, release: `console=ttyS0,115200 quiet loglevel=3
  logo.nologo vt.global_cursor_default=0 consoleblank=0
  dena.boot=LABEL=DENA-BOOT`: the kernel and init talk only to the serial
  port, so the panel shows no text, no penguins and no cursor, only the
  Dena splash. `dena.debug` keeps the system up (and opens an initramfs
  shell on errors) for the serial console instead of powering off.

## Release and diagnostic mode

- Release (default): splash (below), no logs on the card except the boot
  hook's `Dena/user/boot.log` (replaced every boot).
- Diagnostic, on the card: an empty file `Dena/diagnostic` on the games
  partition. The splash stays; this boot's init log (with times from
  `/proc/uptime`) goes to `Dena/user/init.log`, and DRM connector states,
  `/dev/dri`, `/dev/fb*`, backlights and `dmesg` to `Dena/user/dmesg.log`,
  before the launcher and at shutdown (both replaced every boot).
- Diagnostic image: `build.sh --diagnostic` (file name `-diag.img`) uses
  `console=tty1 console=ttyS0,115200 loglevel=7 dena.diag dena.debug`:
  kernel messages on the panel, no splash, the logs above, and a shell on
  the serial port instead of power off. Adding `dena.diag` to `APPEND` in
  `extlinux.conf` does the same on a release card.

## Splash (`os/image/splash/dena-splash.c`)

- A static framebuffer tool (no libraries) built by `build.sh` with the
  cross compiler into `/usr/lib/dena/bin`. It draws the Dena logo from the
  geometry of `docs/branding/logo.svg` (light "D", Dena Gold dot) centred on
  Dark Anthracite (#202024), with an optional line of text (its own 5x7
  capitals) and a Dena Gold progress bar. 16, 24 and 32 bpp; scales with the
  panel (640x480, 720x720, ...).
- `dena-sysinit` starts it first as a daemon (`--daemon /run/dena/splash
  --wait 20`): it waits for `/dev/fb0` (the panel probes late) and shows
  whatever `/run/dena/splash` says (`logo`, `message TEXT`, `progress PCT
  TEXT`), redrawn when the file is replaced, so callers never block.
  `dena-session` writes `quit` just before the launcher takes the display;
  the splash stays on screen until the launcher's first frame.
- `dena-shutdown` draws "SHUTTING DOWN" once the launcher is gone.

## Boot time

- No kernel text on the serial port beyond warnings (`quiet loglevel=3`).
- The display wait polls every 0.1 s (up to 10 s), so a panel that is
  already up costs nothing; the splash waits on its own in parallel.
- The card layout is checked once per system version (stamp
  `Dena/user/.layout`), not on every boot; logs and `sync` only in
  diagnostic mode.
- Running after boot: busybox init, the launcher, `dena-powerd`, and the
  serial console shell (only on the serial port). Nothing else.

## Power off and sleep

- `dena-session` runs the boot hook with `DENA_POWEROFF=poweroff`, so a long
  press of the power key makes `dena-powerd` (after the launcher has saved)
  ask init to power off instead of cutting the power itself; a short press
  sleeps as in power-daemon.md.
- Every power off goes through `dena-shutdown`: stop the launcher and
  `dena-powerd` (TERM, then KILL after 3 s), shutdown screen, `sync`,
  unmount the games partition, so it is never left dirty.

## First boot (`dena-sysinit`)

- Partition 2 starts exactly where DENA-BOOT ends (never in the gap before
  it, where the boot loader lives) and takes the rest of the card. The boot
  partition is mounted, so the table can't be re-read whole: `sfdisk
  --append --no-tell-kernel` writes it and `partx --add --nr 2:2` tells the
  kernel (`addpart` is gone from util-linux in Debian 13, and sfdisk on its
  own only tries a full re-read, which fails while DENA-BOOT is mounted).
- Then `mkfs.exfat -L DENA`. A partition 2 that exists but has no boot
  sector (no 0x55AA: the first boot was cut off before formatting) is
  formatted on the next boot; anything else on partition 2 is never
  formatted, whatever it is.
- A progress screen ("PREPARING YOUR CARD", 5 → 30 → 70 %) shows while it
  partitions and formats.
- Mount: exFAT, or FAT32 if the user reformatted it on a PC. The layout is
  added where missing; nothing is overwritten.

## The app

- The app payload (`os/payload.py`: launcher, power daemon, cores, Flutter
  engine and bundle) goes into the system image at `/usr/lib/dena`, with the
  boot hook and updater from `os/scripts`.
- `dena-session` runs the same boot hook as the two-card setup with
  `DENA_CARD=/mnt/card DENA_APP=/usr/lib/dena`. An app installed on the card
  by a `Dena-update-*.zip` (`Dena/bin/dena-launcher`) wins over the one in
  the system image, so app updates by file still work.
- Before the launcher, `dena-session` waits up to 10 s for a DRM connector
  to report `connected` (the SPI panel probes late).

## Wi-Fi (`dena-net`)

- RTL8821CS on SDIO (mmc1), mainline `rtw88_8821cs`, powered up by
  `mmc-pwrseq-simple` (reset on PG18, 32 kHz clock fan-out on PG10).
  `CONFIG_RESET_GPIO` stays off: with it the pwrseq hands its `reset-gpios`
  to the reset framework, which only takes 2-cell GPIO specifiers, while the
  sunxi pin controller uses 3, so the probe failed with "reset control not
  ready" and the SDIO card never powered up.
- Firmware `rtw88/rtw8821c_fw.bin` from upstream linux-firmware, pinned by tag
  and sha256 in `os/image/linux/firmware.txt` (licence: redistributable, text
  in `os/image/linux/firmware-licences`, copied to
  `/usr/share/licenses/firmware`), and `regulatory.db` + `.p7s` from the
  `wireless-regdb` package (signed upstream, checked by the kernel's built-in
  keys). All three are built into the kernel (`CONFIG_EXTRA_FIRMWARE`)
  because the driver and cfg80211 ask for them before the root file system
  exists.
- `dena-net` (inittab `once`, next to the session) waits up to 20 s for
  `wlan0`, then starts `wpa_supplicant` (nl80211) with
  `Dena/user/wpa_supplicant.conf` on the games partition, created empty
  (`ctrl_interface=DIR=/run/wpa_supplicant`, `update_config=1`) on a new
  card. The launcher lists, adds and removes networks through the control
  socket (`wpa_cli -i wlan0`, or the socket protocol), and `save_config`
  writes them back to the card. Users can also edit the file on a PC.
- DHCP: busybox `udhcpc -b` with `dena-dhcp` (address, default route,
  `/etc/resolv.conf`). On the first lease the clock is set with
  busybox `ntpd -q -p pool.ntp.org` (or `rdate` where busybox has no ntpd,
  as on Ubuntu) and saved to the RTC: TLS for RomM and
  RetroAchievements needs the right time.
- Logs: `/run/dena/net.log`, summary lines in the init log (copied to
  `Dena/user/init.log` in diagnostic mode).
- Regulatory domain: the world domain (`00`) unless a network or the
  launcher sets `country=` in the file.

## USB storage mode (`dena-usb-storage`)

- Shows the games partition to a computer on the USB-C port as a removable
  drive (configfs gadget, Linux Foundation 1d6b:0104, mass storage function
  with the partition's block device as `lun.0/file`). The legacy
  `g_mass_storage` gadget is off: built in, it claimed the port at boot with
  no backing file and failed.
- The handheld must not use the partition while a computer writes to it, so
  it only runs between launcher runs: the launcher creates
  `/run/dena/usb-storage` and exits; `dena-session` sees the file, runs
  `dena-usb-storage` (unmount, serve, mount again) and then starts the
  launcher again. The mode never starts without that request: the session
  deletes any old request before each launcher run, and the helper does
  nothing (exit 2) without one and uses it up. If the launcher is still
  running 5 s after asking, the session stops it.
- dena-boot.sh waits for dena-powerd to end (it logs to the card), and the
  helper retries the unmount for 5 s before it calls the card busy (logged
  with the processes holding it).
- Ends when the computer ejects the drive (`lun.0/file` emptied), when the
  cable is pulled after the computer had the drive (UDC state `not
  attached`, or VBUS gone for 2 s on the PMIC's USB supply), on a press of
  the power key (`axp20x-pek`; dena-powerd is not running then), or after
  2 minutes with no computer. If the partition is busy or the gadget can't
  start, the partition is left (or mounted again) as it was and the
  launcher comes back.
- Screen (dena-splash, one line): `STARTING USB STORAGE`, then `CONNECT
  USB-C TO A COMPUTER` until the computer has configured the drive, then
  `USB DRIVE ON. EJECT IT TO RETURN`, then `RETURNING TO DENA.EMU`.
  Errors show for 4 s: `USB STORAGE NOT AVAILABLE` (no UDC), `CARD BUSY.
  TRY AGAIN`, `USB STORAGE COULD NOT START`, `GAMES CARD ERROR. RESTART`
  (cannot mount again).
- Gadget: serial number from the card's CID, SCSI inquiry `Dena.emu Games
  card`, read-write, removable. Kernel: MUSB dual role (`dr_mode = "otg"`,
  ID on PI4, VBUS from the AXP717 USB supply), `USB_CONFIGFS_MASS_STORAGE`.
- Tests: `os/tests/test_usb_storage.py` runs the helper against a fake
  sysfs/configfs.
- Launcher side: Settings > Files > USB storage (handheld-ui.md), shown only
  when `dena-usb-storage` is in the system image, writes the request file
  and exits.

## System image

- Base: Debian 13 arm64 packages (`os/image/rootfs/packages.txt`: busybox
  static, glibc, libstdc++, Mesa with Panfrost, libdrm, libgbm, EGL/GLES,
  alsa-lib, libudev, sfdisk/partx, exfatprogs, wpa_supplicant,
  wireless-regdb), extracted with
  `mmdebstrap --variant=extract` (no package scripts run, so no arm64
  emulation is needed). `/bin`, `/sbin`, `/lib` are linked into `/usr`;
  docs, man pages and translations are dropped.
- squashfs with zstd, fixed time stamps. About 65 MiB.

## Kernel

- Linux 7.1.2 (stable) with the H700 patch set in `os/image/linux/patches`:
  DE33 display engine, TCON TOP/LCD, H616 PWM, PWM backlight, the generic
  panel-mipi driver and its RG35XX panel nodes, GPU OPPs, USB OTG fixes,
  codec suspend, RTC on the Plus/SP. Upstream mainline (7.3) still lacks the
  H616 LCD pipeline in its device trees, hence the patches.
- Panel init sequences are kept as JSON (`os/image/linux/panels`) and turned
  into `panels/<compatible>.panel` firmware (the binary layout documented in
  `panel-mipi.c`) by `panelgen.py`; they are built into the kernel
  (`CONFIG_EXTRA_FIRMWARE`) because the panel probes before the root file
  system exists.
- Config: arm64 `defconfig` with other SoC families off, plus
  `os/image/linux/dena-h700.config` (everything the handheld needs built in,
  `CONFIG_MODULES` off).
- Input: mainline `gpio-keys` with the standard gamepad codes, which match
  the H700 device profile (`shells/linux/profiles/h700.conf`).

## Building (`os/image/build.sh`)

Linux host, or Docker on any PC (`os/image/Dockerfile`):

```
docker build -t dena-image os/image
docker run --rm -v "$PWD:/src" -w /src dena-image \
  os/image/build.sh --device rg35xxsp --payload os/build/payload --test
```

Sources are cloned at pinned tags and checked against pinned commits
(`os/image/sources.txt`); patches are applied once per patch set. Options:
`--device`, `--dram`, `--version`, `--payload`, `--test`, `--xz`. Output in
`os/image/out/`. A first build takes about 25 minutes on 4 cores (most of it
the kernel).

## Acceptance tests

- `os/tests/test_image.py` (any PC, part of `tools/ci/local.sh os`): panel
  firmware round trip and encoding rules, initramfs archive contents and
  reproducibility, the init scripts only use applets and tools that the
  images carry, `/usr` merge, SPL header and checksum checks, MBR layout,
  and (with dosfstools and mtools) a whole card image built from synthetic
  inputs, read back, and rebuilt byte for byte.
- `os/image/build.sh --test` (Linux/Docker): builds everything, then
  `qemu-test.sh` boots the card's own kernel, initramfs and system image
  twice on QEMU's arm64 virt machine with a stand-in launcher: DENA-BOOT
  found, system mounted, partition 2 created after DENA-BOOT up to the end
  of the card, layout made, launcher started with `DENA_HANDHELD=1` and the
  app from the system image, power off through `dena-shutdown`; second boot
  doesn't repartition. `test_image.py` also renders the splash screens into
  raw files with the host compiler and checks colours and the progress bar.
- On device (human checkpoint): flash, boot an RG35XX SP from TF1 alone,
  check the panel, buttons, sound, battery, power off; copy a game to
  `DENA/Roms` on a PC and play it.

## Not yet

- System updates by file (a new `dena-system.squashfs`/kernel on DENA-BOOT,
  checked and swapped at boot), like app updates.
- Bluetooth (RTL8821CS on uart1), HDMI, rumble, lid
  switch handling in the power daemon, charging-only boot.
- A133P and RK3566 single-card images.
- Publishing images: GPL source for every binary on the card must ship next
  to each public image (kernel, U-Boot, TF-A from the pinned trees; Debian
  source packages for the base). Public releases need the user (CLAUDE.md §7).

## Provenance

- Wi-Fi: mainline `rtw88` and the upstream device tree's pwrseq node; the
  firmware and regulatory database come unchanged from linux-firmware and
  wireless-regdb. The RESET_GPIO conflict was found by reading
  `pwrseq_simple.c` and `drivers/reset/core.c` in the pinned kernel.
- Boot ROM offset (8 KiB), eGON header and checksum: the public linux-sunxi
  wiki description of the boot ROM and the eGON header; checked against the
  U-Boot image this build produces.
- U-Boot `anbernic_rg35xx_h700_defconfig` and the TF-A `sun50i_h616`
  platform: upstream, unchanged. LPDDR3 timing values and the one-line DRAM
  fix: from ROCKNIX's public H700 build (GPL-2.0; the patch is by Philippe
  Simons).
- Kernel patches: taken unchanged from ROCKNIX's public H700 patch set
  (GPL-2.0, by the upstream authors named in each patch: Jernej Škrabec,
  Ryan Walklin, Chris Morgan, James Hilliard, Hironori Kikuchi, Philippe
  Simons, Jacob Cook, Kailash, tiopex). Left out: their own joypad driver,
  device-tree id and battery-name patches, and the ones built on them.
- Panel init sequences and timings: decoded from ROCKNIX's panel firmware
  files (hardware register data) into our JSON; the file format is from the
  kernel's `panel-mipi.c` header comment.
- Image layout, initramfs, init scripts, first-boot partitioning, build
  scripts: our own design and code. ROCKNIX served only as a reference for
  which versions and patches work on this hardware; none of its scripts are
  used. Nothing from MinUI, SpruceOS or the stock firmware.
