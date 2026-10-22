# Milestone 2 plan: Android MVP

Status: done (on main 2026-10-16; Genesis deferred). Checkpoint pending with the user.
Goal (CLAUDE.md §6): NES, SNES, GB/GBC, GBA, Genesis on Android with library, box art,
save states, auto-save, fast-forward, cheats, gamepads, skins and the Material 3 UI.
Checkpoint: design sign-off by the user, then the Play internal track (the upload itself
needs the user's account and signing key).

## Work packages (one spec and one PR each, in this order)

| # | Package | Spec | Depends on |
| --- | --- | --- | --- |
| 1 | Cores: FCEUmm (NES), bsnes (SNES), mGBA (GB/GBC/GBA), Genesis core | [cores-m2.md](cores-m2.md) | — |
| 2 | Game session: runner generalised to any core, pause/resume, auto-save, battery saves, fast-forward | [game-session.md](game-session.md) | 1 |
| 3 | Library: Drift database, import (SAF, share sheet, folder), system detection, grid, search, filter chips, recently played | [library.md](library.md) | — |
| 4 | Box art: bundled OpenVGDB lookup, on-demand image fetch and cache, custom art | [box-art.md](box-art.md) | 3 |
| 5 | Save states: slots with thumbnails, quick save/load, pause-menu sheet | [save-states.md](save-states.md) | 2 |
| 6 | Pause menu and game screen chrome (M3 bottom sheet, controller row) | [pause-menu.md](pause-menu.md) | 2, 5 |
| 7 | Gamepads: multi-controller slots, disconnect → pause, glyphs, remapping | [gamepads.md](gamepads.md) | 2 |
| 8 | Skins: `.deltaskin` import and rendering, touch input, last-input-wins | [skins.md](skins.md) | 2 |
| 9 | Cheats: Game Genie / Action Replay / GameShark / raw codes | [cheats.md](cheats.md) | 2 |
| 10 | App shell: NavigationBar/Rail (Games / Carts / Skins / Settings), D-pad navigation, settings | [app-shell.md](app-shell.md) | 3 |

Packages 3, 4 and 10 are Dart-only and can run alongside 1, 2 and 5–9, which touch the
native runner and the Kotlin shell.

## Defaults chosen (tell the user; easy to change)

- **Genesis core:** skipped for now (user, 2026-10-16). BlastEm is x86-only and
  ClownMDEmu is AGPL-3.0; Genesis Plus GX and PicoDrive stay banned. Genesis is
  hidden from import and the Skins tab until a core is chosen.
- **NES core:** FCEUmm (GPL-2.0) first. It is lighter than Mesen, which suits the 1 GB
  handhelds later.
- **SNES core:** bsnes in its performance profile (GPL-3.0).
- **Test content:** only homebrew or public-domain ROMs, or ROMs we generate ourselves
  like the GBA latency ROM.
