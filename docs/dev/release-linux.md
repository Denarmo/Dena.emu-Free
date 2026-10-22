# Linux and SteamOS release (Flatpak and portable tar.gz)

How the Linux x86_64 release of Dena.emu is packaged for the Steam Deck and
desktop distros. The Windows packages have their own page (Windows packaging
thread); the port plan is section 4 of the desktop port plan.

One command, from WSL2 Debian on DENA-PC, in the repo's own worktree on the
Linux file system (not under /mnt/c):

    tools/release/build-linux.sh

It writes to `build/release-linux/out/`:

| File | What |
| --- | --- |
| `dena-emu-X.Y.Z-linux-x64.flatpak` | Single-file Flatpak bundle, app id `io.github.denarmo.DenaEmu`, runtime from Flathub |
| `dena-emu-X.Y.Z-linux-x64-portable.tar.gz` | A `dena-emu/` folder with `portable.txt`, started by `dena-emu/dena-emu` |
| `release-notes-linux.md` | The release-notes stub with the Steam Deck steps (also printed) |

`X.Y.Z` is the `version:` of `app/pubspec.yaml` without the build number.

## Setup (once)

    sudo apt install flatpak flatpak-builder clang cmake ninja-build pkg-config \
      libgtk-3-dev ccache git appstream-compose librsvg2-common
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --user flathub org.freedesktop.Sdk/x86_64/26.08 org.freedesktop.Platform/x86_64/26.08
    # the older SDK and its clang, for the portable tar.gz
    flatpak install --user flathub org.freedesktop.Sdk/x86_64/22.08 org.freedesktop.Sdk.Extension.llvm16/x86_64/22.08
    sudo apt install rsync binutils python3

Plus a Linux Flutter SDK on `PATH` inside WSL (the stable tarball from
flutter.dev unpacked to `~/flutter`, then `export PATH=$HOME/flutter/bin:$PATH`),
and the core build setup from [desktop-cores.md](desktop-cores.md).
The runtime version is pinned in `cores/desktop-runtime.txt`; the script stops
if the manifest's `runtime-version` disagrees. The portable SDK and the glibc
floor are pinned in the same file (`portable_*` lines).

## Oldest supported system (portable tar.gz)

The portable tar.gz runs on **glibc 2.35 or newer with libstdc++ from GCC 12
or newer** (`GLIBCXX_3.4.30`): Debian 12, Ubuntu 22.04, Fedora 36, current SteamOS
and anything newer. The Flatpak brings its own runtime and is not limited.

Before 0.1.0-test2 the tar.gz was built in the 26.08 SDK, needed glibc 2.43
and did not load its host library on Debian 13 (the desktop test pass, 10-18).
Now its cores, `libdena_host.so` and Flutter runner are all built inside
`org.freedesktop.Sdk//22.08` (glibc 2.35, GCC 12; end-of-life but still on
Flathub, and only used as a build environment). Clang for the Flutter runner
comes from its `llvm16` extension.

The script checks this: after staging the tar.gz it runs
`tools/release/linux/check_glibc_floor.py` on every ELF file in it, prints the
floor and the highest `GLIBC_`/`GLIBCXX_` version found, and **stops the build
if any file needs more than the floor**. To raise the floor, change
`portable_sdk`, `portable_glibc` and `portable_glibcxx` together, then this
section. The check works on any folder:

    python3 tools/release/linux/check_glibc_floor.py --glibc 2.35 --glibcxx 3.4.30 <folder>

## What the script does

Steps 1 to 5 and 7 make the Flatpak, step 6 the portable tar.gz.

1. Builds the 11 linux-x86_64 cores (Dolphin included: GameCube and Wii) inside the Flatpak SDK
   (`cores/build-desktop.sh linux-x86_64`; skip with `--skip-cores`).
2. Builds `libdena_host.so` inside the same SDK into `build/desktop-linux-sdk`
   and runs its tests, so it links against the runtime's SDL dependencies
   (PipeWire, PulseAudio, ALSA, udev).
3. `flutter build linux --release` in `app/`. Arguments after `--` go to it,
   for example `-- --dart-define=DENA_SCREENSCRAPER_DEVID=<id>`.
4. Stages the bundle in `build/release-linux/bundle`, swaps in the SDK-built
   host library and checks that 12 cores are in `lib/cores`
   (`--allow-missing-cores` packages fewer, with a warning).
5. Runs `ldd` on every binary inside `org.freedesktop.Platform` and stops on
   any `not found`. The Flutter runner is built on Debian, so this is the
   check that it runs on the runtime (GTK 3 is part of the freedesktop
   Platform).
6. For the portable tar.gz: copies the repo to
   `build/release-linux/portable-src` (rsync, without `.git` and build
   output; the copy keeps its own core and build folders between runs), then
   runs `tools/release/linux/portable-build.sh` inside the 22.08 SDK, which
   builds the 12 cores, `libdena_host.so` (with its tests) and
   `flutter build linux --release` there. It stages the result, checks the
   core count and the glibc floor (above) and packs the tar.gz. With
   `--skip-cores` the tar.gz reuses the cores of its previous portable build;
   the first portable build always needs the cores.
7. Builds the Flatpak with
   `tools/release/linux/io.github.denarmo.DenaEmu.yml` (`--disable-rofiles-fuse`
   for WSL2) and exports the single-file bundle with Flathub as its runtime
   repo.
8. Writes the release-notes stub.

`--no-flatpak` or `--no-portable` builds one package only (the other one's
steps are skipped, SDKs included).

## Files

`tools/release/linux/`:
- `io.github.denarmo.DenaEmu.yml`: the Flatpak manifest. It packages the
  staged bundle as `/app/lib/dena-emu`, starts it through `/app/bin/dena-emu`.
- `io.github.denarmo.DenaEmu.desktop`: desktop entry (Game;Emulator). It
  takes a file (`Exec=dena-emu %f`) and lists the game MIME types, so file
  managers offer Dena.emu under "Open with"; the game then starts at once
  ([open-with.md](../specs/open-with.md)).
- `io.github.denarmo.DenaEmu.metainfo.xml`: AppStream metadata. **Every
  release needs a `<release version="X.Y.Z" date="...">` entry**; the script
  stops without one.
- `dena-emu`: the portable launcher script.

Icons come from `docs/branding/logo.svg` (scalable) and `icon-512.png`.
The GTK application id in `app/linux/CMakeLists.txt` is the same
`io.github.denarmo.DenaEmu`, so the window matches the desktop entry and gets
its icon on Wayland and X11.

## Sandbox permissions (defaults)

| Permission | Why |
| --- | --- |
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc` | Window on Wayland (Deck desktop, gamescope) or X11 |
| `--device=all` | GPU, `/dev/input` and `/dev/hidraw` for SDL3 controllers (rumble, gyro, DualSense/Switch Pro over HIDAPI). `--device=input` misses hidraw |
| `--socket=pulseaudio` | Audio; on SteamOS PipeWire serves this socket (pipewire-pulse) |
| `--share=network` | RomM, RetroAchievements, PICO-8 BBS, link cable |
| no `--filesystem` | Game folders and files come from the file chooser portal; data is in `~/.var/app/io.github.denarmo.DenaEmu/data` |

GL and Vulkan drivers come from `org.freedesktop.Platform.GL.default`, which
Flatpak installs with the runtime; the manifest declares nothing for them.

Folders picked through the portal are reached through the document portal
(`/run/user/<uid>/doc/...`). Games load and the start-up rescan works, but
live folder watching (inotify) may not see changes there. Users who want live
watching of an SD card or another drive can grant it directly, after which
the folder dialog returns the real path:

    flatpak override --user --filesystem=/run/media io.github.denarmo.DenaEmu

## Install and run

    flatpak install --user build/release-linux/out/dena-emu-X.Y.Z-linux-x64.flatpak
    flatpak run io.github.denarmo.DenaEmu

Portable: `tar xzf dena-emu-X.Y.Z-linux-x64-portable.tar.gz && dena-emu/dena-emu`.
Data stays in `dena-emu/Dena`; ROMs dropped in `dena-emu/Dena/Roms/<system>`
show up at launch. The portable folder needs GTK 3 on the host (SteamOS and
common desktop distros have it) and glibc 2.35 or newer (see Oldest supported
system).

## Steam Deck

The script prints these as release notes: Desktop Mode, install the Flatpak,
Steam › Add a Non-Steam Game › Dena.emu (no launch options; for the portable
folder point at `dena-emu/dena-emu` and keep `%command%`), controller layout
"Gamepad", and turn Steam Input off for the shortcut if gyro should come
straight from SDL.

## Flathub later

The manifest's bundle source is a local `type: dir`. For Flathub it becomes
the release's portable tar.gz as `type: archive` with its sha256 (Flathub
builds offline). Flathub also wants screenshots in the metainfo and the
`io.github.denarmo` id verified through the GitHub account.
