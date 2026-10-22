# Spec: Pause menu

Status: draft (Milestone 2, package 6)

## Layout (Brutalist, brutalist-ui.md 4.5)

The menu covers the screen with the live game showing through, a PAUSED
sticker on it; a tap on the game resumes. Actions are one numbered stack of
key-cap buttons, Resume (primary, focused first) on top:
**Resume**, **Save state**, **Load state** `[N FILES]`, **Rewind**
(rewind.md), **Cheats** `[on/all ON]`, **Shader** `[NAME]` (shaders.md),
**Screenshot**, **Speed** `[1X] 2X 4X`, **Controllers** `[n]` (opens a
CONTROLLERS table, gamepads.md), **Link cable**, **Achievements**
`[u/t]`, **Settings** (GAME.CFG), **Quit game** (dark).

- Phone (or any window under 600 wide): the game on top with a
  `SESSION // FILE_NAME` caption, the stack on grid paper under it, the slot
  strip (slots 1–4) under Save state and a log of this session's actions last.
- Handheld and desktop: game, FILE / SESSION / CORE strip and slot strip on
  the left, the stack on the right. When the stack doesn't fit, Rewind,
  Shader, Controllers and Link cable fold into Settings > GAME.CFG, so it
  never scrolls. GAME.CFG also holds the game's turbo setup.
- The slot strip picks the slot Save state and Load state focus first; L1/R1
  move it on a pad (the strip takes no D-pad focus).
- Sub-sheets (SAVE.STATE, LOAD.STATE, CHEATS, CHEATS.DB, SHADER.CFG,
  LINK.CABLE, ACHIEVEMENTS, CONTROLLERS, GAME.CFG) open at the bottom on
  phones and as a right side panel elsewhere, with an `[A] OK [B] BACK` bar
  on pad devices; SHADER.CFG leaves the game undimmed for the preview. A
  stored cheat is deleted by holding DEL for 1 s.

Every control is reachable with the D-pad; B closes a sheet, and on the menu
resumes.

## Capture

Writes the last game frame (core resolution, no skin) as a PNG to the shared
Pictures collection, folder `Pictures/Dena.emu`, named
`<title> <yyyy-MM-dd HH.mm.ss>.png`, through MediaStore (no storage
permission needed on Android 10+). On Android 8–9 it writes to the same folder and
needs the storage permission (`maxSdkVersion 28`); until a permission prompt
lands with the settings screens, it reports "The screenshot could not be saved"
there. The sheet stays open and a snackbar says "Screenshot saved".

## Native API

- Runner: `screenshot(path)` writes the current frame with
  `dena_frame_write_png` on the emulator thread.
- `GameHostApi.captureScreenshot(name)` → error message or null.

## Acceptance tests

- Dart: pause sheet goldens at the matrix sizes (touch and focus); D-pad order
  Resume → Save state → Load state → Rewind → Cheats → Shader → Screenshot →
  speed → Controllers → Settings/Quit; at 640×480 the folded actions open
  from Settings; Capture calls the API
  with the title and time and shows the snackbar without closing the sheet.
