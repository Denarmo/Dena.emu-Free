# PlayStation 2 (desktop)

Windows and SteamOS only. First item of desktop wave 2
(`desktop/port-plan.md`): PS2 on LRPS2, the libretro fork of PCSX2
(GPL-3.0-or-later, docs/licenses.md), with the player's own BIOS. Android
and the Linux handheld don't ship the core, so the system stays off there.

## System

| Id | Name | Core | Files |
| --- | --- | --- | --- |
| `ps2` | PS2 | `pcsx2_libretro` (LRPS2) | `.iso`, `.chd`, `.cso`, `.cue` + `.bin` |

- `GameSystem.ps2.desktopOnly` is true. The importer refuses PS2 games off
  the desktop with "PS2 games play on the Windows and SteamOS versions".
  Settings > Shaders and the Skins tab leave it out off the desktop.
- Picture aspect 4:3 (16:9 with widescreen on).
- Core file: `pcsx2_libretro.dll` on Windows, `pcsx2_libretro.so` on Linux
  (the app's name `libpcsx2_libretro.so` maps to it like every core,
  desktop-shell.md).

## Library

`.iso` and `.cso` are also PSP files, so the importer looks inside before
it decides (desktop folders are imported in place, desktop-library.md):

- `.iso`: the ISO 9660 volume descriptor at sector 16 and the root
  directory's `SYSTEM.CNF`. `BOOT2 =` is a PS2 disc. A system identifier of
  `PSP GAME`, or anything else, keeps the old answer: PSP.
- `.cso`: the same, read through the CSO block index (`CISO` header,
  uncompressed size, block size, index shift, one u32 offset per block,
  top bit = stored; other blocks are raw deflate).
- `.chd`: a DVD CHD (`chdman createdvd`, metadata tag `DVD `) is PS2,
  unless it lies in a `PSP` folder. A CD CHD needs a `PS2` folder
  (`PS2`, `PlayStation 2`, `Sony PlayStation 2`), else it stays PS1, as
  before.
- `.cue`: after the Saturn/Dreamcast header check, the first track is read
  as an ISO 9660 volume (2048-byte sectors, or raw 2352-byte ones with the
  data after 16 bytes in Mode 1 and 24 in Mode 2). `BOOT2 =` is PS2;
  otherwise the folder name, then PS1.
- Content check: `.chd` `MComprHD`, `.cso` `CISO`, `.iso` `CD001` at
  0x8001.
- Box art: libretro-thumbnails `Sony - PlayStation 2`, in the offline index
  (`tools/boxart/build_index.py`, Redump DAT). ROM manager hash check:
  Redump `Sony - PlayStation 2`. RetroAchievements console id 21.

## BIOS

Never bundled. The player dumps it from their own console into
`<Bios folder>/pcsx2/bios/`: `%APPDATA%\Dena.emu\Bios\pcsx2\bios` on
Windows, `~/.var/app/io.github.denarmo.DenaEmu/data/Bios/pcsx2/bios` in the
Flatpak, `Bios\pcsx2\bios` in the portable folder (beside `user\`). That is where
LRPS2 looks; it takes any PS2 BIOS file of 4 to 8 MB whatever its name and
picks the first valid one (`pcsx2_bios` core option).

- With no file of 4 to 8 MB there, the game doesn't start and the screen
  says: "PS2 games need a BIOS dumped from your own console, such as
  SCPH-70012.bin (US), SCPH-70004.bin (Europe) or SCPH-70000.bin (Japan),
  in <Bios folder>/pcsx2/bios".
- When the core still fails to load (a file of the right size that isn't a
  BIOS), the same sentence follows its error.

## Core options (defaults set by the host)

- `pcsx2_upscale_multiplier = 2x`: Auto is 2x on the desktop; `RES` 2x, 4x,
  8x (desktop-resolution.md).
- `pcsx2_renderer = OpenGL`: the host's GL context, like Mupen64Plus,
  Beetle PSX HW and Flycast.
- `pcsx2_shared_memory_cards = disabled`: one memory card per game,
  `<game name>.ps2`, in the app's save folder under `ps2/`
  (`<data>/saves/ps2/`). The runner passes that folder as the libretro
  save directory for LRPS2 only (`DENA_SAVE_DIR`, host.c); every other core
  keeps the system folder as before.
- Widescreen: `pcsx2_widescreen_hint = enabled (16:9)` with `WIDE` on, off
  by default.
- Run-ahead stays off (run-ahead.md); Deck presets: Auto on the Deck,
  TDP 9-15 W (deck-presets.md).

## Pads

The RetroPad is the DualShock 2: B ✕, A ○, Y □, X △, L1/R1, L2/R2, L3/R3,
both sticks, Start, Select. PS2 is in `systemsWithL2` and `analogSystems`.
The built-in touch skin (desktop touchscreens) draws the PlayStation face
buttons, L1/L2/R1/R2 and a left stick.

## Builds

- Linux (Flatpak and tar.gz): `cores/lrps2/build.sh linux-x86_64` from
  `cores/build-desktop.sh`, CMake, everything vendored; the freedesktop SDK
  22.08 floor applies (cores/desktop-runtime.txt).
- Windows: libretro builds LRPS2 with MSVC only, so the MinGW cross build
  skips it and `tools/release/build-windows.ps1` runs
  `cores/lrps2/build-msvc.ps1` (Visual Studio 2022 Build Tools) on the PC.
  A failed MSVC build leaves the other cores packaged and warns.

## Known gaps

- A PS2 CD in a `.chd` outside a `PS2` folder imports as PS1.
- No `.elf`, `.gz`, `.zso` or `.m3u` import yet.

## Acceptance tests

- `app/test/library/ps2_test.dart`: registry, desktop-only gating, ISO,
  CSO, raw cue track and DVD CHD detection, PSP stays PSP, content check,
  in-place import and phone refusal, BIOS check, Deck presets, skin.
- `host/runner/runner_tests.cpp`: LRPS2's resolution and widescreen
  tables, default options and the memory card folder.
- On DENA-PC: /mnt/project-files/desktop/ps2-verify.md.
