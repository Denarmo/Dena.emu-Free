# Spec: SD-card layout, boot hook and updates

Status: draft (Milestone 4, package 4). Builder and scripts tested on this
PC; per-device boot integration waits for hardware (see "Boot hook").
This is the two-card setup (stock firmware card + ours). The H700 handhelds
also get a single-card image with its own boot loader and kernel that uses
the same layout and boot hook: single-card.md.

## Layout (fixed)

```
<card>/
  Roms/<system>/   nes snes gb gbc gba nds n64 psx psp pico8 (the app's ids)
  Bios/            BIOS files the user dumped themselves
  Saves/           battery saves (written by Dena.emu)
  States/          save states (written by Dena.emu)
  Carts/           PICO-8 carts
  Dena/
    bin/           dena-boot.sh, dena-update.sh, dena-launcher, dena-powerd
    lib/           libretro cores and runtime libraries
    data/          Flutter assets
    devices/       built-in device profiles (platform-modules.md)
    user/          settings, devices/ overrides, boot.log: survives updates
    version.txt
  Dena-README.txt
```

## Card library

On a handheld the library is the card: at every start the launcher scans
`Roms/` (recursively, in the background) and adds each supported game it
does not already have by path, in place (hashed, never copied; zips are
extracted into the app's games folder as on Android). Hidden files (`.x`,
macOS `._x`) are skipped; a file whose hash is already in the library is a
duplicate. Deleting a game in the app deletes its file on the card.

The vendor's own files stay untouched; nothing of the vendor firmware, no
games and no BIOS files are ever in our zips (CLAUDE.md §4).

## Builder (`os/build_sd.py`)

`python os/build_sd.py --version <v> --out <dir> [--payload <dir>]` writes:

- `Dena-<v>.zip`: the whole tree above, to unpack onto a card that has the
  stock firmware. Empty folders carry a `.keep`. Files in `bin/` keep the
  execute bit; scripts are LF-only (busybox sh).
- `Dena-update-<v>.zip`: `Dena/` without `user/`, plus `manifest.sha256`
  (sha256sum format) over every file.

`--payload` brings the cross-built `bin/`, `lib/` and `data/` (packages 5, 6);
without it the zips hold scripts, profiles and layout.

`python os/payload.py --out <dir>` assembles that payload from the cross
builds: `bin/` gets dena-launcher, dena-powerd and dena-keytest, `lib/` every
`cores/build/linux-aarch64/*_libretro.so`. Each file must pass
`tools/toolchain/elfcheck.py` first; then it is stripped with `llvm-strip
--strip-unneeded` (`--strip`, `LLVM_STRIP`, PATH, or the newest Android
NDK's). Missing files fail the run unless `--allow-missing`. Today's
payload is about 84 MB stripped. When present it also takes the Flutter
engine, the app's native libraries (`lib/libsqlite3.so` from the bundle's
native assets) and the app bundle. Release, what cards ship: the AOT app
from `os/app_aot.py` (`data/app/lib/libapp.so`, not stripped), its
`flutter_assets` without the JIT files, the release engine and
`icudtl.dat` from `tools/toolchain/flutter_engine.py` (embedder.md); an AOT
app without the release engine fails the run unless `--allow-missing`.
Debug, development only: a `flutter build bundle --debug` bundle
(`kernel_blob.bin`) with the debug engine, with a warning. The boot hook starts `dena-launcher Dena/data/app [user
profile]`.

## Updates (`dena-update.sh`, at boot)

- Takes the lexically last `Dena-update-*.zip` on the card root.
- Unzips into `.dena-update-tmp/` (non-interactive), requires `Dena/` and
  `manifest.sha256`, verifies every checksum.
- Swaps: moves `Dena/user/` into the new tree, `Dena/` → `Dena.old/`, new →
  `Dena/`, deletes `Dena.old/`, renames the zip `*.applied`.
- Any failure (not a zip, not an update, a checksum mismatch, a move that
  fails) leaves the old `Dena/` and `user/` in place and renames the zip
  `*.failed`. The boot hook runs the updater from a copy in `/tmp`, because
  it replaces its own folder.

## Boot hook (`dena-boot.sh`)

- Applies a pending update, then sets `DENA_HANDHELD=1`, `DENA_CARD`,
  `LD_LIBRARY_PATH=Dena/lib`, starts `dena-powerd` (with the first
  `user/devices/*.conf` override, if any) and runs `dena-launcher` in the
  foreground. When the launcher exits it stops the daemon, syncs and returns
  to the stock system. Without `Dena/` or a launcher it exits at once.
- Logs to `Dena/user/boot.log`.
- **Per-device integration** (which stock startup file calls the hook, per
  firmware version) depends on each device's stock firmware, an open
  question for the user (CLAUDE.md §9). It's written and checked on the rig
  per device, from the vendor's own startup scripts as found on the device,
  and never from MinUI or SpruceOS.

## Acceptance tests (`tools/ci/local.sh os`)

- Layout: every folder, version, the three profiles, LF scripts.
- Payload and zips: payload copied, `.keep` folders, execute bits, update
  manifest covers payload files and leaves out `user/`.
- Update: replaces `Dena/`, keeps `user/`, marks the zip applied, cleans up,
  second run is a no-op; a tampered zip or a non-update zip changes nothing
  and is marked failed.
- Boot: without a launcher it returns to stock after trying the update;
  with one it runs it with `DENA_HANDHELD=1`.
- On device (human checkpoint): unzip onto a stock card, boot, update by
  copying a zip.
