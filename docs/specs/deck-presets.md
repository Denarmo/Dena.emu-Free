# Steam Deck presets, suspend/resume and Gaming Mode

Windows and SteamOS (Steam Deck first). Feature 6 of the desktop features
proposal (`desktop/features-proposal.md`, "Steam Deck presets"), port plan
phase 5. Free. Builds on the internal resolution choice
([desktop-resolution.md](desktop-resolution.md)) and run-ahead
([run-ahead.md](run-ahead.md)) without changing either.

## 1. Presets

Settings > VIDEO.CFG > **Presets** opens `PRESETS.CFG`: one row per system
with its preset and what the preset picks. Each system (one desktop core
each) has its own preset:

| Preset | Internal resolution | Run-ahead | Refresh | TDP |
| --- | --- | --- | --- | --- |
| `OFF` | your own RES choice | your own run-ahead | — | — |
| `BATTERY` | Auto (native) | off | lowest even rate | low |
| `BALANCED` | largest factor that fits the screen height | 1 frame | lowest even rate | middle |
| `PERFORMANCE` | smallest factor that fills the screen height | 2 frames | highest even rate | high |

- **Defaults:** every system on `BALANCED` on a Steam Deck, `OFF` on any
  other PC (their RES and run-ahead settings stay exactly as before).
- An `ALL` row at the top sets every system at once. On a system row, A (or
  a click) steps the preset: OFF > BATTERY > BALANCED > PERFORMANCE > OFF.
- Saved in `desktop_presets.json` in the data folder:
  `{"systems": {"n64": "performance", "nes": "off"}}`. A system missing from
  the file has the default; a damaged file gives the defaults.

### Resolution

- Only systems with a resolution choice on the desktop (N64, PSX, PSP, DS,
  Dreamcast, PS2, GameCube, Wii; `upscaleFactors` in `shader_store.dart`)
  get a factor; the rest are native. On the Deck, Dreamcast, PS2, GameCube
  and Wii stay Auto on BALANCED (2x is 960, 896 and 1056 px, taller than the
  screen; Auto is 2x for all four, ps2.md, gamecube-wii.md).
- "Fits" and "fills" use the screen's height in physical pixels and the
  system's native height (N64 240, PSX 240, PSP 272, DS 384 for both
  screens, Dreamcast 480, PS2 448, GameCube and Wii 528). Steam Deck (800 px): BALANCED N64 3x, PSX 2x,
  PSP 2x, DS 2x;
  PERFORMANCE N64 4x, PSX 4x, PSP 3x, DS 3x. A 4K screen: PERFORMANCE 8x.
  When no factor fits, BALANCED is Auto; when none fills, PERFORMANCE takes
  the largest.
- A game's own RES choice (the shader sheet with Save: This game) wins over
  the preset; the preset wins over the system's saved RES. Widescreen is not
  part of a preset.

### Run-ahead

- Frames from the preset, the method from Settings > Run-ahead. Only the
  run-ahead systems use it (NES, SNES, GB/GBC/GBA, PICO-8, PSX; PSX at most
  2); others show `—`.
- Applied when a game starts (`dena_desktop_set_run_ahead`) and put back to
  the Settings choice when the game ends. `OFF` leaves the Settings choice in
  effect.

### Refresh rate

- Emulated systems output 60 frames a second (50 for PAL games). The preset
  suggests the refresh rate in the Deck's panel range that is a whole
  multiple of that, so every frame shows for the same time: lowest such rate
  for BATTERY and BALANCED, highest for PERFORMANCE. Steam Deck LCD
  (`Jupiter`): 40-60 Hz; Steam Deck OLED (`Galileo`): 45-90 Hz. Today that is
  60 Hz on both (PAL: 50 Hz); 40/45 Hz would only divide 20/22.5 fps output
  and 90 Hz only 45 or 90 fps, which come with frame generation later (the
  rule is generic: `evenRefresh(fps, min, max)`).
- The page shows the display's current refresh (Flutter's display) and a
  warning line when it is not a whole multiple of 60, for example "Display
  at 45 Hz: 60 fps games judder. Set 60 Hz." On other PCs the same warning
  covers 144 Hz and similar screens (VRR or 120 Hz plays smoother).
- The app does not change the refresh itself: in Gaming Mode Steam owns it.

### TDP

- A suggested TDP limit in watts per system and preset, Steam Deck only
  (other PCs show `—`): 2D systems 3-6 W, PSX and DS 5-10 W, N64 6-12 W, Saturn
  6-10 W, PSP and Dreamcast 7-13 W, PS2 9-15 W, GameCube and Wii 8-15 W (table `deckTdp` in `deck_presets.dart`). These are starting
  points to check on the hardware.
- The user sets it, with the refresh rate, in Steam's Quick Access menu >
  Performance with "Use per-game profile" on for Dena.emu; the page says so.

## 2. Suspend and resume

- When the system goes to sleep while a game is loaded, the host pauses it,
  which writes the battery save and the auto-save state the session already
  writes on pause (game-session.md, Pause). After waking, a game that was
  playing continues by itself; one that was paused (pause menu open) stays
  paused.
- Linux (SteamOS, any systemd distro): the GTK runner takes a logind
  **delay** inhibitor (`org.freedesktop.login1.Manager.Inhibit("sleep",
  "Dena.emu", "Saving the game before sleep", "delay")`) and listens to
  `PrepareForSleep`. On `true` it calls `dena_desktop_suspend()` and then
  closes the inhibitor so sleep goes on; on `false` it calls
  `dena_desktop_resume()` and takes a new inhibitor. No system bus or no
  logind: nothing happens (the game is simply frozen and continues, as
  before). The Flatpak gets `--system-talk-name=org.freedesktop.login1`.
- Windows: `WM_POWERBROADCAST` `PBT_APMSUSPEND` calls `dena_desktop_suspend()`
  (Windows allows about two seconds), `PBT_APMRESUMEAUTOMATIC` /
  `PBT_APMRESUMESUSPEND` call `dena_desktop_resume()`.
  `RegisterSuspendResumeNotification` makes Modern Standby PCs send them too.
- `dena_desktop_suspend()` returns 1 when a game was saved, 0 without one;
  `dena_desktop_resume()` resumes only a game the suspend paused, so a second
  resume message (Windows sends both) does nothing. Both run on the main
  thread, like every other session call.
- Steam Cloud is not used (a non-Steam game has none).

## 3. Gaming Mode

- Gaming Mode is detected by gamescope's environment: `GAMESCOPE_WAYLAND_DISPLAY`
  set, or `XDG_CURRENT_DESKTOP=gamescope`.
- Under gamescope the app always starts fullscreen in controller mode,
  whatever "Fullscreen at launch" says (gamescope shows one app fullscreen
  anyway), and does not restore a window position.
- Deck button glyphs: the Deck counts as a gamepad and its controls print the
  Deck's glyphs (already in controller-mode.md); unchanged.
- On-screen keyboard: under gamescope, A on a text field (sign-in forms,
  server addresses, search) asks Steam for its keyboard
  (`xdg-open steam://open/keyboard`, through the OpenURI portal in the
  Flatpak), which types into the focused field. When that fails, the app's
  own D-pad keyboard opens as before. Places that open the app's keyboard
  directly (Rename, Wi-Fi password) keep it. Outside gamescope nothing
  changes.

## Interface

- Host (`desktop.h`): `int32_t dena_desktop_suspend(void)`,
  `void dena_desktop_resume(void)`; optional in `desktop_loader.h` (an older
  library without them still loads).
- Dart: `app/lib/src/desktop/deck_presets.dart` (`DeckPreset`,
  `DeckModel`, `PresetPlan`, `planPreset`, `evenRefresh`,
  `DeckPresetSettings`, `DeckPresetsScope`, `PresetsTile`, `PresetsPage`);
  `app/lib/src/desktop/gaming_mode.dart` (`detectGamescope`,
  `SteamKeyboard`). `DesktopShell` loads the presets and the session asks
  them for the factor and run-ahead at start.

## Acceptance tests

- Dart: plans per system and preset for the Deck LCD, OLED and a 4K PC;
  `evenRefresh`; settings defaults (Deck: balanced, PC: off), save/load,
  damaged file; the session sends the preset's factor unless the game has
  its own, and the run-ahead frames at start and the Settings choice after;
  the page steps a preset with A and sets all with the ALL row; refresh
  warning; goldens at 1280x720 and in the TV layout (1920x1080).
- Gaming Mode: gamescope detection; the launch rule forces fullscreen under
  gamescope without placing the window; A on a text field asks Steam's
  keyboard once, falls back to the app keyboard when Steam fails, and never
  asks Steam outside gamescope.
- Host (desktop_host_tests): suspend without a game returns 0; with the
  test core playing, suspend writes the auto-save state and pauses, resume
  continues once, and suspend while paused leaves it paused after resume.
- Desktop pass / Steam Deck (owner hardware): see
  `desktop/deck-presets-verify.md` in the project files.
