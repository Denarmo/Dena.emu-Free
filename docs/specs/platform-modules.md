# Spec: Platform modules (Linux handhelds)

Status: draft (Milestone 4, package 2)

## What a module is

One **device profile** per SoC family, as a small `key = value` text file in
`shells/linux/profiles/<id>.conf`. The launcher embeds them all and picks the
first whose `match` strings appear in `/proc/device-tree/compatible` (or the
model string). A profile with the same `id` on the SD card
(`Dena/devices/<id>.conf`) replaces the built-in one, so a fix needs no new
build.

| Key | Meaning |
| --- | --- |
| `id`, `name` | Short id (`h700`, `a133p`, `rk3566`) and display name |
| `match` | Substring of the device-tree compatible list (repeatable, up to 8) |
| `display` | `WxH@Hz`, or `auto` for the DRM connector's preferred mode |
| `backlight`, `backlight_max`, `backlight_min` | sysfs brightness file (glob allowed), raw range |
| `battery` | power_supply directory (glob allowed): reads `capacity`, `status` |
| `audio` | ALSA card name, used when `audio_driver` finds no card |
| `audio_driver` | ALSA driver of the card to play on (`sun4i-codec`), whatever its number |
| `volume` | Simple mixer element the volume keys drive (`DAC`) |
| `mixer = <control> = <value>` | Set at launcher start (repeatable, up to 16): `on`, `off`, a raw number, `N%`, or an enum item |
| `verified` | `yes` once checked on the real device |
| `key.<code> = <action>` | evdev key code → action |
| `abs.<axis><+/-> = <action>` | hat axis direction → action |

Actions: RetroPad `b y select start up down left right a x l r l2 r2 l3 r3`,
and `menu`, `power`, `volume_up`, `volume_down`. Unknown keys are ignored
(newer profiles load in older builds); a malformed line fails with its line
number.

## Built-in profiles (all unverified)

`h700` (Anbernic RG35XX / RG40XX / RG CubeXX / RG34XX), `a133p` (TrimUI
Smart Pro, Brick), `rk3566` (Anbernic RG353, Miyoo Flip). Written from public
spec sheets and the standard Linux gamepad codes (`BTN_SOUTH` = B,
`BTN_EAST` = A, `BTN_DPAD_*`, `ABS_HAT0X/Y`, `KEY_POWER`, volume keys), with
display `auto` and globbed sysfs paths. Nothing comes from MinUI, SpruceOS
or vendor firmware. Each stays `verified = no` until `dena-keytest` has been
run on the device.

## Helpers

- `dena_parse_percent`, `dena_parse_charging`: battery sysfs text.
- `dena_backlight_raw`: user level 0–100 → raw value on a squared
  (perceptual) curve between `backlight_min` and `backlight_max`; 0 = off.
  A straight line instead when the kernel's table is already perceptual.
- `dena_backlight_adopt`: the power daemon reads `max_brightness` and
  `scale` next to the brightness file at start, so 100 % is the panel's real
  maximum whatever the profile says (`backlight_max`/`backlight_min` are only
  the fallback). A `non-linear` scale (pwm-backlight `brightness-levels`)
  makes every level from 1 usable and leaves the curve to the kernel. The H700
  boards get 101 CIE levels from patch 0920, so level n is n %.
- `dena-keytest` (Linux only): prints each key/hat event as `key.<code>` /
  `abs.<axis><dir>` with the action the profile gives it, which is exactly
  the line to put in a profile. Switches (lid, headphone jack) and dropped
  events are printed too. The power key quits.

## Acceptance tests (host, `tools/ci/local.sh linux`)

- Parsing: every key, CRLF lines, comments, unknown keys; errors return the
  line number (missing `=`, unknown action, bad hat, bad display, no `id`).
- Matching: the NUL-separated compatible lists of an RG35XX Plus, a TrimUI
  Brick and a Miyoo Flip pick h700, a133p and rk3566; a PC matches nothing.
- Built-ins: three profiles, all unverified, A on `BTN_EAST`, power on
  `KEY_POWER`.
- sysfs: percent clamping and garbage; charging states; backlight off at 0,
  min at 1, max at 100, monotonic, below linear at 50.
- On device (human checkpoint): `dena-keytest` on each handheld; fix and
  mark `verified = yes`.
