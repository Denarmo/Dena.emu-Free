# Turbo fire

Held buttons marked as turbo repeat automatically, on touch skins and on
physical controllers alike.

## Behaviour

- Turbo-capable buttons: A, B, X, Y, L, R (libretro joypad bits).
- Rates: 30, 15 (default), 10 and 7 presses per second, i.e. the button reads
  pressed for 1, 2, 3 or 4 emulated frames and released for the same count.
- The cycle starts on a pressed frame and restarts whenever no turbo button is
  held, so a quick tap always registers.
- Turbo applies to every port and to the touch mask. It is counted in emulated
  frames, so fast-forward keeps the in-game rate.
- Settings > Controls > Turbo fire sets the global setup.
- The pause menu's Turbo section edits the running game; any change there saves
  a per-game override that replaces the global setup for that game.

## Storage

`<dataDir>/turbo.json`:
`{"global": {"mask": 0, "rate": 15}, "games": {"<sha1>": {"mask": 256, "rate": 30}}}`.
Unknown bits are dropped, an unknown rate falls back to 15, and a damaged file
counts as no turbo.

## Native

`Runner::set_turbo(mask, half_frames)` (host/runner), applied in
`run_one_frame`. Android exposes it over dart:ffi as `dena_set_turbo`. The
Linux launcher does not wire it yet.

## Tests

- `app/test/turbo/turbo_store_test.dart`: resolve, override, clear, damaged file.
