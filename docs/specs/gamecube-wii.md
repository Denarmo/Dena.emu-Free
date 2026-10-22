# GameCube and Wii (desktop)

Windows and SteamOS only. Desktop wave 2 of the port plan
(`desktop/port-plan.md`, section 5): GameCube and Wii on the Dolphin libretro
fork become app systems, following dreamcast-saturn.md. The core is built by
`cores/dolphin/build.sh` (Linux) and `cores/dolphin/build-msvc.ps1`
(Windows, MSVC); docs/dev/desktop-cores.md has the steps and
docs/licenses.md the licence row. Android, the Linux handheld and iOS don't
ship the core, so the systems stay off there. Emulation is free.

## Systems

| Id | Name | Core | Files |
| --- | --- | --- | --- |
| `gamecube` | GameCube | `dolphin_libretro` | `.iso`, `.gcm`, `.rvz`, `.wia`, `.gcz`, `.ciso`, `.dol`, `.elf` |
| `wii` | Wii | `dolphin_libretro` (same core) | `.iso`, `.rvz`, `.wia`, `.gcz`, `.ciso`, `.wbfs`, `.dol`, `.elf` |

- `GameSystem.desktopOnly` is true for both. The importer refuses them off
  the desktop with "GameCube games play on the Windows and SteamOS
  versions" (same for Wii).
- No BIOS is needed: Dolphin boots discs with its high-level IPL
  (`dolphin_skip_gc_bios = enabled`, the core default) and makes its own Wii
  NAND. A real IPL is never asked for or bundled.
- Picture aspect 4:3 (16:9 with widescreen on).

## Library

- `.iso` is shared with the PSP: the importer reads the header. The magic
  word `C2 33 9F 3D` at 0x1C makes it GameCube, `5D 1C 9E A3` at 0x18 Wii,
  anything else stays PSP (and then needs PSP's `CD001`).
- `.gcm` reads the same header; `.ciso` the same after its 0x8000-byte block
  map (header `CISO`); `.gcz` (magic `01 C0 0B B1`) by its little-endian
  sub-type at byte 4 (0 GameCube, 1 Wii); `.wia` / `.rvz` (`WIA\x01` /
  `RVZ\x01`) by the big-endian disc type at 0x48 (1 GameCube, 2 Wii);
  `.wbfs` (`WBFS`) is always Wii. A file whose bytes say neither, or say the
  other system than the name, is "Not a supported game file".
- `.dol` and `.elf` (homebrew) carry no system: a `Wii` folder among the
  three nearest parents makes them Wii, otherwise GameCube. A `.dol` must be
  at least 0x100 bytes and not text; an `.elf` must be 32-bit big-endian
  PowerPC (e_machine 20).
- Folder names: `GameCube`, `Nintendo GameCube`, `gc`, `gcn`, `ngc` / `Wii`,
  `Nintendo Wii`. They only decide `.dol` / `.elf`; a `GameCube` folder never
  makes a `.chd` or `.cue` GameCube (Dolphin can't read those).
- Disc images are streamed (hashed while copied) like other discs. All of
  them join the import extensions and the desktop pickers.
- Box art: libretro-thumbnails `Nintendo - GameCube` and `Nintendo - Wii`
  (Redump DATs in the offline index, `tools/boxart/build_index.py`). The
  boxes are keep cases (135 x 190 x 14 mm) holding an 80 mm (GameCube) or
  120 mm (Wii) disc.
- ROM manager: Redump DATs `Nintendo - GameCube` and `Nintendo - Wii`.
  `.rvz`, `.wia`, `.gcz`, `.wbfs` and `.ciso` are compressed, so the hash
  check reports them as UNCHECKED; DolphinTool's RVZ conversion
  (rom-manager.md) is unchanged.
- RetroAchievements console ids: GameCube 16, Wii 19. The hash is of the
  file as stored, so only plain `.iso` / `.gcm` match today.

## Core

- `<system>/dolphin-emu/Sys` holds Dolphin's data (game settings, shaders,
  fonts, Wii resources). The build copies `Data/Sys` of the pinned commit to
  `cores/build/<target>/dolphin-emu/Sys` with a `dena-assets.txt` stamp; the
  package ships it as `cores/dolphin-emu` beside the core, and the host
  copies it to the system folder before the core starts unless the same
  stamp is there (like PPSSPP's assets).
- Saves: for Dolphin only, the host answers `GET_SAVE_DIRECTORY` with the
  app's save folder (`<data>/saves`), so Dolphin's user folder is
  `<data>/saves/User`: GameCube memory cards under `User/GC`, the Wii NAND
  (game saves, Mii data) under `User/Wii`. Other cores keep the system
  folder as before.

### Core options (defaults set by the host)

- `dolphin_efb_scale = 2`: Auto is 2x on the desktop (1280x1056 internal).
  The RES row offers Auto, 2x, 3x, 4x, 6x, 8x (desktop-resolution.md).
- `dolphin_widescreen = disabled`, `dolphin_widescreen_hack = disabled`:
  widescreen is off by default. WIDE 16:9 turns both on (the Wii's own
  16:9 setting for Wii games, the hack for GameCube games).
- `dolphin_ir_mode`: `1` (the right stick aims the Wii Remote, absolute),
  or `2` (the pointer) when player 1's controller profile has gyro in
  pointer mode (below).
- Run-ahead stays off (run-ahead.md: a heavy core).

## Pads

The desktop pad sends the RetroPad positionally (controller-mode.md).

GameCube (the core's "GameCube Controller"):

| RetroPad | GameCube |
| --- | --- |
| B (bottom) | B |
| A (right) | A |
| Y (left) | Y |
| X (top) | X |
| R1 | Z |
| L2 / R2 | L / R (digital) |
| Left / right stick | control stick / C stick |
| Start | Start |

Wii: the host picks the core's "WiiMote + Nunchuk" device on every port
(the first controller type whose name has "nunchuk" and not "motionplus";
SET_CONTROLLER_INFO), so the left stick is the Nunchuk stick:

| RetroPad | Wii Remote + Nunchuk |
| --- | --- |
| B / A | B / A |
| X / Y | C / Z |
| L1 / R1 | − / + |
| Start / Select | 1 / 2 |
| R2 / L2 | shake Remote / shake Nunchuk |
| R3 | Home |
| Left stick | Nunchuk stick |
| Right stick | pointer (`dolphin_ir_mode = 1`) |

- Gyro (controller-profiles.md): in RIGHT STICK mode the gyro adds to the
  right stick, so it aims the pointer too; in POINTER mode the host sets
  `dolphin_ir_mode = 2` and the gyro drives the touch pointer, which
  Dolphin reads as the Wii Remote's aim. R3 then taps the pointer, so Home
  is not on the pad in that mode. The mode is read from player 1's profile
  when the game starts; a change applies on the next start.
- Both systems are in `systemsWithL2` (L2 isn't hold-to-rewind) and are
  analog systems.
- Built-in touch skins (desktop touchscreens): GameCube draws A (large),
  B, X, Y, L, Z, R and a stick; Wii draws A, B, C, Z, −, + and a stick.

## Deck presets

Both systems are on the presets page (deck-presets.md). Native height
528 (the EFB), so on a Deck BALANCED stays Auto (2x) and PERFORMANCE takes
2x; suggested TDP 8 / 11 / 15 W.

## Known gaps

- No netplay: GameCube and Wii are not in netplay.md's systems (like PS2).
- No motion (MotionPlus, tilt), Classic Controller or sideways Wii Remote
  modes from the app's pads; no GameCube analog triggers.
- Only player 1 can aim with the pointer; players 2–4 aim with the right
  stick.
- RetroAchievements hashes match plain `.iso` / `.gcm` only.
- The Windows DLL is built with MSVC, not the MinGW cross build of the
  other cores.

## Acceptance tests

- `app/test/library/gamecube_wii_test.dart`: registry, desktop-only
  gating, every header format, `.iso` PSP fallback, folder rules for
  `.dol` / `.elf`, content checks, in-place imports, phone refusal, skins,
  resolution and the presets list.
- `host/runner/runner_tests.cpp`: Dolphin's resolution and widescreen
  options, defaults, the pointer aim option and the save folder.
- `host/tests/unit_tests.c`: the Nunchuk device pick.
- `host/desktop/tests`: player 1's gyro pointer from the profiles, and the
  `dolphin-emu` asset copy.
- `tools/toolchain/test_desktop_cores.py`: the build scripts' dry runs
  (Linux and MSVC).
- On DENA-PC: /mnt/project-files/desktop/gc-wii-verify.md.
