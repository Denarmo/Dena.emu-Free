# Spec: Handheld input (Linux launcher)

Status: draft (Milestone 4). Host-tested with fake input nodes
(`input_tests`); not yet checked on a device.

How the launcher turns the evdev events of a Linux handheld into game
buttons and Flutter keys. The mapping itself (key code → action) is the
device profile (platform-modules.md).

## Input nodes

- Every `/dev/input/event*` is opened at start (up to 16). An inotify watch
  on `/dev/input` opens nodes that appear later (USB pads) and closes nodes
  that go away; a read error (`ENODEV`) closes the node too. Closing a node
  releases everything it held.
- After `SYN_DROPPED` the node's events up to the next `SYN_REPORT` are
  skipped and its real state is read back (`EVIOCGKEY`, `EVIOCGABS` for the
  hats): what is no longer held is released, what is held is pressed.

## Router (`dena/input.h`, pure)

- Each node tracks its held sources (key codes and hat directions). An
  action goes down when its first source goes down and up when its last is
  released, so the same button on two nodes, or a D-pad key and a hat on one
  node (stock firmware), never doubles.
- A second down without an up and an up without a down are dropped.
- A hat axis is two buttons: moving straight from left to right releases
  left, then presses right.
- Kernel auto-repeat (value 2) only steps the volume; the gpio-keys volume
  node on the H700 has it.
- D-pad repeat for menus: the newest held direction repeats after 400 ms,
  then every 80 ms, then every 40 ms once held 2 s. One repeat per tick, so
  a late tick never bursts. Other buttons never repeat.

## Routing (`launcher.c`, `dena_game_input`)

- Volume keys step the mixer (handheld-session.md); power belongs to
  `dena-powerd`.
- While a game runs and is not paused, RetroPad buttons go to the core
  (`set_buttons`). Menu, or Start + Select, releases every button in the
  core and sends `onMenuRequested`.
- A release goes where its press went: a press the game took sends its
  release to the game even after the pause menu opened, and a press the UI
  took sends its release to the UI even after a game started. A release
  whose press went elsewhere is not sent, so Flutter never sees a key up
  without its key down.
- D-pad repeats go to Flutter as `kFlutterKeyEventTypeRepeat` (and a raw
  keydown) only for a press the UI took and only while no game is playing.

## Buttons on the RG35XX SP (mainline device tree, profile `h700`)

| Button | evdev | Action | UI | In game |
| --- | --- | --- | --- | --- |
| D-pad | `BTN_DPAD_*` (544-547) | up/down/left/right | move focus (repeats) | D-pad |
| A / B | `BTN_EAST` / `BTN_SOUTH` | a / b | activate / back | A / B |
| X / Y | `BTN_NORTH` / `BTN_WEST` | x / y | screen actions (Y details) | X / Y |
| L1 / R1 | `BTN_TL` / `BTN_TR` | l / r | switch tabs | L / R |
| L2 / R2 | `BTN_TL2` / `BTN_TR2` | l2 / r2 | — | L2 / R2 |
| Select / Start | `BTN_SELECT` / `BTN_START` | select / start | — | Select / Start; both: pause menu |
| Menu | `BTN_MODE` | menu | — | pause menu |
| Volume | `KEY_VOLUMEUP/DOWN` | volume | volume step (repeats) | same |
| Power | `KEY_POWER` (axp20x-pek) | power | short: sleep, hold 2 s: power off | same |
| Lid | `SW_LID` | — | close: sleep, open: wake (dena-powerd) | same |

## Acceptance tests

Host (`input_tests`, `power_tests`):

- Every SP button maps through the built-in `h700` profile.
- Doubled downs, orphan ups, kernel repeats of face buttons dropped;
  unmapped keys and bad node numbers ignored.
- Same button on two nodes and key + hat on one node: one press, one release.
- Hats: direction changes release then press.
- Resync after dropped events releases and presses the difference, and is
  idempotent; unplugging releases only what that node held.
- Repeat timing: delay, interval, faster after 2 s, no burst, newest
  direction wins, release stops it, non-D-pad never repeats.
- Game routing: Menu and Start + Select open the menu with every button
  released; releases follow their presses across pause and resume.
- Lid: close sleeps after saving, open wakes once (with or without the
  resume event), long power press still powers off with the lid shut.

On a device (human checkpoint): every button in `dena-keytest`; holding the
D-pad scrolls the library; Menu opens the pause menu in a game; no button
stays stuck after opening and closing the pause menu while holding it.
