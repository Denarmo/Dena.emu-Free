# Spec: Gamepads

Status: draft (Milestone 2, package 7)

## Purpose

Play with up to four controllers at once, pause safely when one disconnects,
and open the pause menu from any controller. Builds on the Milestone 1 input
path: Android key and motion events are read in the Activity before Flutter
and sent to native as RetroPad masks (latency-spike.md, Input).

## Player slots

- Ports 1–4 map to libretro ports 0–3. Each Android input device (by
  `InputDevice.getId()`; the built-in keyboard and any keyboard count as one
  device each) gets its own pad state.
- **Assignment:** the first device that presses a mapped button takes the
  lowest free port. A device keeps its port until it disconnects or the
  session ends. A fifth device is ignored.
- Ports are shown in the pause sheet's controller row ("P1 Xbox Wireless
  Controller", "P2 —"). Moving a device to another port from that row comes
  with the full pause menu (pause-menu.md).

## Disconnect

- When a device holding a port disconnects during a session, its buttons are
  released, the port is freed, and the game pauses with the pause sheet open
  and a snackbar "Controller 2 disconnected". Touch controls (skins) reappear
  once skins land (skins.md).
- A device that reconnects is treated as new (first press takes a port).

## Menu chord

- Start + Select held together on any assigned device opens the pause sheet
  (Back still works). The chord's buttons are released in the core first, so
  the game does not see a lingering press.

## Not in this package

Per-game and per-controller remapping on Android, button glyphs and rumble
follow in a second gamepads package with the settings screens; the
positional mapping (PadMapper) stays the default. The desktop has profiles
already (below).

## Desktop: eight players

Windows and SteamOS (desktop-shell.md) take up to **eight** controllers.

- SDL pads get ports 1–8 (libretro 0–7) in connection order; a ninth pad
  waits and takes the first port that frees up. The host keeps
  `DENA_MAX_PORTS` = 8 and input replays accept ports 0–7.
- **Multitap:** when more than two ports hold a controller, the host looks
  in the core's `SET_CONTROLLER_INFO` for a device whose description says
  "multitap" (or "multi-tap") and selects it on that port with
  `retro_set_controller_port_device` (bsnes: SNES Multitap on port 2). Back
  to two or fewer pads, the port returns to the RetroPad. Cores with four
  native ports (N64, GameCube) need nothing. A change invalidates run-ahead.
- `onPlayersChanged` sends eight names on the desktop.

## Desktop: profiles and gyro

A **profile** remaps a controller's buttons and sets its gyro. It is for a
controller model (SDL GUID) or any controller, and for one game (SHA-1) or
any game. Profiles live in `controller_profiles.sqlite` in the desktop data
folder (Drift, apart from the library database).

- **Precedence**, whole profile, no field merging: this controller in this
  game, then any controller in this game, then this controller in any game,
  then any controller in any game; none means the pad plays as is. So a
  game's profile beats a controller's.
- **Defaults:** buttons send themselves; gyro **off**; sensitivity x1 (a
  stick tilts fully at 120°/s; the pointer crosses the screen per 60° of
  turn); dead zone 1.5°/s, taken off softly (subtracted, so motion just past
  it stays fine); invert Y off. Choices: sensitivity x0.5, 1, 1.5, 2, 3; dead
  zone 0, 1, 1.5, 3, 5°/s.
- **Gyro modes:** L-stick (N64 aiming, GameCube main stick), R-stick
  (camera, N64 C-buttons), Pointer (DS touch screen, PSP pointer). The gyro
  adds to the physical stick, clamped. Turning left pushes left and tilting
  the top up pushes up. As the pointer it moves relative to the turn and
  stops at the edges; R3 touches and the game doesn't see R3. On a DS the
  pointer stays on the bottom screen; elsewhere it covers the frame. The
  gyro sensor is only enabled while a profile uses it.
- **Hardware:** any pad SDL3 reports a gyro for (Steam Deck, DualSense,
  DualShock 4, Switch Pro). Steam Input works on top of everything here; it
  hides the real gyro, so for gyro straight from SDL turn Steam Input off for
  the Dena.emu shortcut (release notes, release-linux.md).
- The menu chord and Guide are read from the raw buttons, so a remap never
  loses the pause menu.
- **Settings:** Settings > INPUT.CFG > Profiles: connected pads (port, name,
  gyro), saved profiles, New profile; the editor has Controller and Game
  choices, GYRO.CFG (mode, sensitivity, dead zone, invert Y), BUTTONS.CFG
  (each button sends another or nothing) and hold to delete. Every change is
  saved at once and sent to the host; starting and leaving a game re-sends
  the profiles for that game.
- **Host API** (desktop.h): `dena_desktop_set_profiles(text)`, one line per
  controller GUID plus `*` for every other pad:
  `<guid|*> map=<16 targets, -1 unbound> gyro=<0 off|1 L|2 R|3 pointer>
  sens=<x100> dz=<x100> inv=<0|1> area=<1 bottom|0 frame>`; unknown keys are
  ignored, bad lines skipped. `dena_desktop_pads_info()` returns
  `port\tguid\tgyro\tname` lines (port -1 while waiting).
- **Tests:** host `pad_profile_tests` (remap, parsing, dead zone, gyro stick
  and pointer, multitap rule), `host_unit_tests` (multitap device lookup,
  port 8 rejected); Dart `controller_profiles_test.dart` (precedence, host
  text, database, store, D-pad and tap editing, goldens at 1280x720 and the
  TV layout).

## Native and platform API

- `nativeSetButtons(port, mask, eventTime)` is unchanged; Kotlin now calls it
  for ports 0–3.
- Pigeon `GameEventsApi` (FlutterApi, Kotlin → Dart):
  `onMenuRequested()`, `onControllerDisconnected(port, name)`,
  `onPlayersChanged(names)` (four entries, empty for a free port).

## Acceptance tests

- JVM (Kotlin): `PlayerSlots` assigns ports in order of first press, ignores a
  fifth device, frees a port on disconnect and reports it, and reuses the
  lowest free port; the chord is detected from any assigned device and clears
  its buttons.
- Dart: a disconnect event opens the pause sheet and shows the snackbar; the
  menu event opens it; the controller row lists the players (goldens at the
  matrix sizes).
