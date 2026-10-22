# Spec: Power daemon (Linux handhelds)

Status: draft (Milestone 4, package 3). Policy tested on the host; the daemon
compiles against Linux headers but has not run on a device.

## Policy (`shells/linux/src/power.c`, pure)

| Event | When | Then |
| --- | --- | --- |
| Short power press (< 2 s) | awake | ask the launcher to save → on "saved" (or after 5 s) backlight off, suspend |
| Wake (resume event, or a power press while asleep) | asleep | backlight on, tell the launcher "resumed" (the game stays paused) |
| Power key held 2 s | any | ask the launcher to save → backlight off, power off (no need to release first) |
| Lid closed (`SW_LID`, RG35XX SP) | awake | sleep as for a short press |
| Lid opened | asleep | wake as for a resume event (once, whichever comes first) |
| No input for the idle time | awake, idle > 0 | sleep as for a short press (default: off; Settings later) |
| Battery ≤ 10 %, unplugged | awake | warn once; plugging in re-arms the warning |
| Battery ≤ 3 %, unplugged | any | (screen on if asleep) save → power off |
| Power events < 1 s after waking | — | ignored (the wake press arrives late on some kernels) |
| A key release with no press | — | ignored |

Unreadable battery values do nothing. After power off the machine ignores
everything.

## Daemon (`dena-powerd`, Linux only)

- Loads the device profile (platform-modules.md); `--profile` overrides it.
- Reads every `/dev/input/event*`: the profile's `power` key drives the
  policy, `SW_LID` closes and opens the lid; any other key or axis counts
  as activity.
- Polls `<battery>/capacity` and `status` every 30 s.
- Backlight: the user's level (0–100, default 70, set by the launcher) goes
  through the profile's perceptual curve; "off" writes 0.
- Suspend: `sync`, then `mem` to `/sys/power/state`; returns at wake-up.
- Power off: tell the launcher, `sync`, then run `$DENA_POWEROFF` if set (the
  single-card system sets `poweroff`, so init runs `dena-shutdown` and the
  card is unmounted) and wait to be stopped; without it, or if it fails,
  `reboot(RB_POWER_OFF)`.
- `--idle <seconds>` sets idle sleep (0 = never).

### Launcher protocol

Unix stream socket, default `/tmp/dena-power.sock`, one client, lines of
text:

| Direction | Line | Meaning |
| --- | --- | --- |
| daemon → launcher | `save` | pause the game and flush battery saves and the auto-save state, then answer `saved` |
| daemon → launcher | `resumed` | woke up; show the pause menu |
| daemon → launcher | `battery-low` | show the low-battery warning |
| daemon → launcher | `poweroff` | powering off now |
| launcher → daemon | `saved` | saves are on the card |
| launcher → daemon | `activity` | the user did something (idle timer) |
| launcher → daemon | `brightness <n>` | new backlight level 0–100 (the daemon starts at 100 until one arrives) |

The launcher side is `PowerLink` (`app/lib/src/shell/power_link.dart`): it
answers every `save` with `saved`, even when saving fails or no game runs,
reports `activity` at most every 10 s, and clamps `brightness` to 1-100. It
connects only on Linux when the socket exists. `main.dart` connects in
handheld mode and provides it through `PowerScope`:

- The session answers `save` by pausing and writing the battery save and
  auto-save state (`saveNow`); in the library there is nothing to save.
- `resumed` opens the pause sheet over the paused game.
- `battery-low` shows a snackbar; every button press reports `activity`.

## Acceptance tests

- Host (`power_tests`): short press → save → suspend → resume; wake by key
  without a resume event; late wake press ignored, later presses work; lone
  release ignored; long press shuts down while held and its release doesn't
  sleep; the launcher not answering still sleeps after 5 s; idle sleep and
  "never"; battery warning once, re-armed by charging, never shut down while
  charging, shutdown at 3 % (waking the screen if asleep), unreadable values
  ignored.
- App (`power_link_test`): save waits for the flush then answers; no game
  or a failed save still answers; resumed and battery-low reach the UI,
  unknown lines are ignored; activity throttled; brightness clamped; the
  app shows the battery warning and reports presses; the session saves
  before sleep and opens the pause sheet on waking.
- Compile check: `dena-powerd` and `dena-keytest` against the NDK's Linux
  headers in `tools/ci/local.sh linux`.
- On device (human checkpoint): sleep/wake by power key, long-press power
  off with saves written, low-battery shutdown on an unplugged device.
