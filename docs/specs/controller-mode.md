# Spec: Controller mode, fullscreen at launch and the TV layout (Windows, SteamOS)

Status: implemented in code (thread "Controller fullscreen and TV layout");
first run on DENA-PC in the combined desktop test pass. Builds on the
desktop shell ([desktop-shell.md](desktop-shell.md)) and the handheld's
button navigation ([handheld-ui.md](handheld-ui.md)). No new visuals: the
UI redesign swaps the look later without touching this logic.

## Launch rule

- At start (`DesktopShell.start`, `app/lib/src/desktop`), after SDL has
  enumerated devices the app waits up to **500 ms** for slow USB or
  Bluetooth pads (`dena_desktop_gamepads` polled every 20 ms; a pad already
  there returns at once).
- **Any gamepad → borderless fullscreen + controller mode. None →
  windowed + mouse/keyboard mode.** On a Steam Deck (`SteamDeck=1`, or DMI
  board vendor Valve, board Jupiter or Galileo) the built-in controls count
  as a gamepad, so the Deck always starts in controller mode.
- Settings › Display › **Fullscreen at launch: Auto (default) / Always /
  Never**, in `desktop_display.json` in the data folder. Always and Never
  set only the window; controller mode still follows the pads.
- Before going fullscreen the window moves back to where it was last
  (`window.txt` in the data folder, saved when the window closes), so
  fullscreen opens on the monitor the window was last on. A saved place on
  a monitor that is gone is ignored.

## Window (`dena/window` channel, both runners)

- `setFullscreen(bool)`: borderless fullscreen covering the monitor the
  window is on (no display mode switch); off restores the window as it was.
- `isFullscreen()`, `restorePlacement(path)`.
- **F11 and Alt+Enter** toggle fullscreen at any time, also during a game:
  the runners catch them before the game and Flutter see the key.
- Linux: positions are ignored where the compositor places windows itself
  (Wayland, gamescope); gamescope in Gaming Mode is fullscreen anyway.

## Controller mode

- On at launch per the rule above; also turned on by any pad press or stick
  move, or by a pad plugged in later (counted once a second). The window is
  never changed by that.
- A mouse click turns it off only when no gamepad is connected (and never
  on a Deck), so a mouse next to a pad, or the Deck's touch screen, does
  not flip the layout back and forth. The routes keep their state either
  way.
- In controller mode the app behaves as on a handheld for input
  (`usesButtons`): hint bars, the D-pad leaving text fields, A on a text
  field opening the on-screen keyboard (under gamescope Steam's keyboard
  first, [deck-presets.md](deck-presets.md)), Rename on the on-screen keyboard. Nothing is hidden: the
  handheld-only cuts (Apps tab, Skins, Audio latency) do not apply.

## Buttons

- While no game is playing (library, pause menu, settings), the host
  library reports each pad change to Dart (`dena_desktop_set_ui_input`,
  a `NativeCallable.listener` on SDL's thread). While a game plays, pads go
  to the game only; Start + Select or Guide opens the pause menu as before.
- Dart turns them into the same Flutter keys the handheld embedder sends
  (`embedder_core.h`): D-pad and left stick = arrows, A/B/X/Y, L1/R1,
  L2/R2, L3/R3, Start/Select = game buttons, Guide = gameButtonMode. Held
  directions repeat after 400 ms, then every 80 ms. A release whose press
  went to the game is dropped; a press whose release went to the game lets
  go first.
- **Confirm follows the labels in menus:** on pads whose bottom button is
  printed A or Cross (Xbox, PlayStation, Deck, most generic pads) that
  button is A (select) and the right one is B (back), with X/Y swapped to
  match the print. Nintendo-layout pads (Switch Pro, Joy-Cons) keep right =
  A. Games stay positional as before (desktop-shell.md, Controllers).
- The left stick moves like the D-pad past half travel, released under a
  third.

## Glyphs

The hint bar prints the pad's own labels (family of the pad used last,
from SDL's gamepad type and USB ids):

| Hint | Generic | Xbox | PlayStation | Nintendo | Steam Deck |
| --- | --- | --- | --- | --- | --- |
| Confirm / back | A / B | A / B | ✕ / ○ | A / B | A / B |
| X / Y | X / Y | X / Y | □ / △ | X / Y | X / Y |
| Tabs | L1 / R1 | LB / RB | L1 / R1 | L / R | L1 / R1 |
| Start | START | MENU | OPTIONS | + | MENU |

Under Steam Input the Deck's controls look like an Xbox pad; on a Deck
those get the Deck column.

## TV layout

- In controller mode the whole UI (library, game boxes, box zoom, launch
  animation, pause menu, settings, dialogs) is laid out at no less than
  1280×720 logical pixels and scaled up to fill the window: 1.5x at 1080p,
  3x at 4K (100 %), 1x on the Deck's 1280×800. `TvScale` in the app's
  builder gives the child the smaller MediaQuery and paints it larger, so
  text and vector art stay sharp; pointer input is mapped through it.
- Mouse/keyboard mode is the normal desktop layout (scale 1).

## Acceptance tests (`app/test/desktop`, `host/desktop/tests`)

- Launch rule matrix (Auto/Always/Never × pads × Deck), the 500 ms wait,
  Deck detection.
- Start-up: a pad means restorePlacement then setFullscreen(true); no pad
  stays windowed; Always goes fullscreen without controller mode.
- Synthesized keys: the action table, physical ids as the handheld's,
  repeats at 400/80 ms, stray releases, re-presses.
- Navigation through the framework at 1920×1080: TV layout lays out at
  1280×720, Xbox and PlayStation glyphs, D-pad moves focus, held repeats,
  A plays; a click keeps controller mode while a pad is there and leaves it
  after unplugging.
- Settings shows Fullscreen at launch; the page picks by D-pad and A and
  the choice survives a restart.
- Host: pad families, label-based confirm swap, stick hysteresis, UI
  action diffs (`desktop_map_tests`).
