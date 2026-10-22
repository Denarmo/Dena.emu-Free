# Dreamcast and Saturn (desktop)

Windows and SteamOS only. First half of feature 10 of the desktop features
proposal (`desktop/features-proposal.md`): Dreamcast on Flycast and Saturn
on Beetle Saturn become app systems. The cores are built by
`cores/build-desktop.sh` (docs/dev/desktop-cores.md); licences are in
docs/licenses.md. Android and the Linux handheld don't ship these cores, so
the systems stay off there. PS2 and GameCube/Wii are later threads.

## Systems

| Id | Name | Core | Files |
| --- | --- | --- | --- |
| `saturn` | Saturn | `mednafen_saturn_libretro` (Beetle Saturn) | `.cue` + tracks, `.chd` (not `.iso`: the core can't read it) |
| `dreamcast` | Dreamcast | `flycast_libretro` | `.gdi` + tracks, `.cdi`, `.chd`, `.cue` |

- `GameSystem.desktopOnly` is true for both; `playableOn(desktop:)` is the
  check. The importer refuses them off the desktop with "Saturn games play
  on the Windows and SteamOS versions" (same for Dreamcast). Settings >
  Shaders and the Skins tab leave them out off the desktop.
- Picture aspect 4:3 for both (16:9 with Dreamcast widescreen on).

## Library

Desktop folders are imported in place (desktop-library.md), so a sheet's
tracks stay beside it and the importer can look inside:

- `.cdi`, `.gdi`: Dreamcast.
- `.cue`: the first track the sheet names (its `FILE` line) is read: the
  ASCII `SEGA SEGASATURN` or `SEGA SEGAKATANA` at offset 0 (2048-byte
  sectors) or 0x10 (raw 2352-byte sectors) makes it Saturn or Dreamcast.
  Otherwise the folder name decides, then PlayStation. A cue whose track
  file is missing is refused as unknown. Copy imports (Android) copy the
  sheet with every track it names and sniff it the same way (psx.md); a
  Saturn or Dreamcast cue is then refused there as a desktop-only system.
- `.chd`: a GD-ROM (metadata tag `CHGD`, or the older `CHGT`, in CHD v3 to
  v5) is Dreamcast. A CD `.chd` doesn't say whether it is PlayStation or
  Saturn without decompressing it, so the folder name decides: `Saturn`,
  `Sega Saturn`, `ss` / `Dreamcast`, `dc` / `PS1`, `PSX`, `PlayStation`
  (case, spaces, `_` and `-` don't matter; the nearest of the three
  parent folders wins). Otherwise PlayStation, as before.
- A `.bin` carrying a Saturn or Dreamcast disc ID is a track, not a Genesis
  ROM, and is skipped (it joins through its sheet).
- `.cue` and `.gdi` hash the sheet and the first track together for the
  library's identity (SHA-1), and the first track alone for the CRC, so
  Redump-based box art and achievements match.
- Box art: libretro-thumbnails `Sega - Saturn` and `Sega - Dreamcast`, in
  the offline index (`tools/boxart/build_index.py`, Redump DATs).
- RetroAchievements console ids: Saturn 39, Dreamcast 40.
- Pickers: `.cue`, `.cdi`, `.gdi` join the import extensions (`.chd` was
  already there). The Windows installer's Open-with list and the Flatpak
  keywords already had them.

## BIOS

BIOS files are never bundled. The player dumps them from their own console
into the desktop Bios folder (`%APPDATA%\Dena.emu\Bios` on Windows,
`~/.var/app/io.github.denarmo.DenaEmu/data/Bios` in the Flatpak, `Bios`
beside the app in portable mode).

- Saturn needs the BIOS of the disc's region: `mpr-17933.bin` (US and
  Europe) or `sega_101.bin` (Japan). With neither, the game doesn't start
  and the screen says: "Saturn games need the BIOS of their region, dumped
  from your own console: mpr-17933.bin (US and Europe) or sega_101.bin
  (Japan), in <Bios folder>". With only the other region's file the core
  fails to load and the same sentence follows its error.
- Dreamcast reads `Bios/dc/dc_boot.bin` (and `dc_flash.bin`). Without it
  Flycast boots its built-in replacement BIOS; the game starts and a
  snackbar says "No Dreamcast BIOS: playing on the built-in one. If a game
  fails, put dc_boot.bin from your own console in <Bios>/dc".

## Core options (defaults set by the host)

- Flycast: `reicast_internal_resolution = 1280x960` (Auto is 2x on the
  desktop), `reicast_per_content_vmus = VMU A1` (one memory card per game,
  so a full card never blocks a new game).
- Beetle Saturn: `beetle_saturn_save_method = libretro` (battery saves go
  through the frontend's save RAM like every other system).
- Resolution and widescreen: desktop-resolution.md (Dreamcast `RES` 2x-8x
  and `WIDE`; Saturn has neither).
- Run-ahead stays off for both (run-ahead.md).

## Pads

The desktop pad sends the RetroPad positionally (controller-mode.md), so
the cores' own RetroPad mappings apply:

| RetroPad | Saturn | Dreamcast |
| --- | --- | --- |
| B (bottom) | A | A |
| A (right) | B | B |
| R1 | C | |
| Y (left) | X | X |
| X (top) | Y | Y |
| L1 | Z | |
| L2 / R2 | L / R | LT / RT (digital) |
| Left stick | | analog stick |
| Start | Start | Start |

- Both are in `systemsWithL2`, so L2 doesn't double as hold-to-rewind.
  Dreamcast is an analog system.
- Built-in touch skins (desktop touchscreens): Saturn draws six face
  buttons (X Y Z over A B C) and L/R; Dreamcast draws the four face
  buttons, LT/RT and a thumbstick.
- Triggers are digital: the host reports 0 for analog button reads, so
  Flycast sees LT/RT fully pressed or released. Analog triggers are a
  follow-up in host/desktop.

## Renderer notes

The app's desktop renderer is unchanged here. Flycast asks for OpenGL
through `GET_PREFERRED_HW_RENDER` and draws into the host's GL
framebuffer like Mupen64Plus and Beetle PSX HW; Beetle Saturn is software.
Anything the first boot shows (black screen, wrong size after a `RES`
change, a Vulkan request) is recorded in the verify doc for the renderer
owner.

## Known gaps

- VMU files land in the Bios folder (Flycast writes them there).
- Saturn CHDs need a Saturn folder; a Saturn `.cue` doesn't.
- Saturn `.iso` and `.ccd` aren't offered.

## Acceptance tests

- `app/test/library/dreamcast_saturn_test.dart`: registry entries,
  desktop-only gating, extension mapping, disc headers, folder hints, sheet
  parsing, GD-ROM CHD detection, in-place import with the track CRC, phone
  refusal, and every BIOS case.
- `host/runner/runner_tests.cpp`: Flycast's resolution table and the
  default options of both cores.
- On DENA-PC: /mnt/project-files/desktop/dreamcast-saturn-verify.md.
