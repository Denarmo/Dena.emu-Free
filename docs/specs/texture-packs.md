# HD texture packs (desktop)

A desktop-only feature from desktop wave 2 (port-plan.md §5, features
proposal "Texture packs"). Windows and SteamOS only; the phone and handheld
builds don't have it. Texture packs are free.

## 1. HD texture packs

### Systems and cores

| System | Core | Core option(s) set when packs are on | Where the core reads packs |
| --- | --- | --- | --- |
| N64 | Mupen64Plus-Next (GLideN64) | `mupen64plus-txHiresEnable=True`, `mupen64plus-txHiresFullAlphaChannel=True` | `<system>/Mupen64plus/hires_texture/` (Rice-format folders or `.hts`/`.htc` packs named after the ROM's internal name) |
| PS1 | Beetle PSX HW | `beetle_psx_hw_track_textures=enabled`, `beetle_psx_hw_replace_textures=enabled`, `beetle_psx_hw_texture_directory=system` | `<system>/<disc file name without extension>-texture-replacements/` |
| PSP | PPSSPP | `ppsspp_texture_replacement=enabled` | `<memory stick>/PSP/TEXTURES/<GAME ID>/`; the memory stick is the system folder |
| Dreamcast | Flycast | `reicast_custom_textures=enabled` | `<system>/dc/textures/<game ID>/` |

`<system>` is the folder the host hands every core as its system and save
directory: `<storage root>/Bios` on the desktop (desktop-shell.md, Storage).
DuckStation (the usual PS1 pack target) is banned (CLAUDE.md §3), so PS1
uses Beetle PSX HW's own replacement, which needs texture tracking; Beetle
marks that as experimental and it can crash some games, so the app says so.
Saturn, NES, SNES, GB/GBC/GBA and DS have no texture replacement in our
cores; their games never show the option.

### Folders

- The player's folder is `<storage root>/Textures/<system>` with
  `<system>` one of `n64`, `psx`, `psp`, `dreamcast` (on Windows
  `%APPDATA%\Dena.emu\Textures\psp`, in the portable build next to the
  exe; on SteamOS `~/.local/share/Dena.emu/Textures/psp` or the Flatpak's
  data folder). The app creates the four folders at start.
- Packs go in exactly as they ship: N64 packs (a folder or `.hts` file named
  after the game) in `n64`; PSP packs (a folder named after the game ID,
  for example `ULUS10041`) in `psp`; Dreamcast packs (a folder named after
  the game ID) in `dreamcast`; PS1 packs in `psx`, in a folder named after
  the disc file without its extension (`Crash (USA)` or
  `Crash (USA)-texture-replacements`).
- Before a game starts, the app makes the core's own pack folder (table
  above) a link to the player's folder: an NTFS junction on Windows (no
  admin rights needed), a symlink on Linux. N64, PSP and Dreamcast link the
  whole system folder; PS1 links the one disc's folder.
- A link pointing elsewhere is replaced. An empty real folder at the core's
  path is replaced by the link. A real folder with files in it (packs the
  player put there by hand) is left alone and used as it is. A file in the
  way means packs stay off for that start (logged).

### When packs are on

- Off until the game's folder has at least one file (any depth): for N64,
  PSP and Dreamcast the system folder, for PS1 the disc's folder. Once it
  has files, packs are on for every game of that system by default; cores
  load a pack only for the game it belongs to, so an unrelated game is
  unaffected.
- **Per-game switch:** the game menu (long-press or Y on a box) shows
  `Textures: on` / `Textures: off` (key T) for N64, PS1, PSP and Dreamcast
  games. The choice is saved per game (by SHA-1) in
  `<data folder>/texture_packs.json` (`{"games": {"<sha1>": true|false}}`)
  and wins over the default. Turning it on while the folder is empty says
  where to drop the pack and opens that folder.
- The choice applies from the next start: the host sets the core options
  before the core loads (`dena_desktop_set_texture_packs`, a dart:ffi call
  made just before the session starts; reset to off when the session
  closes). No Pigeon change, so Android and the handheld are untouched.

### Settings

Settings > VIDEO.CFG > **Texture packs** (desktop only) shows the number of
entries across the four folders, or `none`. It opens TEXTURES.CFG: one row
per system with its entry count (`EMPTY`, `1 PACK`, `N PACKS`) and an
**OPEN FOLDER** button (Explorer on Windows, `xdg-open`/the portal on
Linux), the folder path, how to name packs, and the PS1 warning. Every
control is reachable by D-pad; the first OPEN FOLDER has focus.

### Edge cases

- Huge packs (tens of thousands of files): the check stops at the first
  file; counts list only the top level.
- A damaged `texture_packs.json` means no per-game choices; the next change
  rewrites it.
- Without a storage root (tests) there is no Textures folder and no option.
- Packs on a network drive or another disk work on Windows (junctions can
  point to any local volume; not to network shares, which then stay off and
  are logged).

## Acceptance tests

Automated (cloud):

1. Host runner: each core gets exactly the options above when packs are on,
   none when off, and mGBA/melonDS get none (`host/runner/runner_tests.cpp`).
2. Dart (`app/test/desktop/texture_packs_test.dart`): only the four systems
   take packs; folders are created; off until a file exists at any depth;
   the per-game choice saves, loads and wins; damaged file; core folders
   per system; PS1 per disc under both names; `prepare` links and tells the
   host; link replace/empty-folder/real-folder/file-in-the-way cases; the
   Settings row and page by D-pad; goldens at 640x480, 1280x720 and TV.

On a real PC (desktop pass, desktop/texture-packs-verify.md):

3. A PSP pack in `Textures/psp/<ID>` loads in that game (D:\ROMS has PSP
   games); turning it off in the game menu shows the original textures.
4. N64, PS1 and Dreamcast packs, with games the owner supplies.
