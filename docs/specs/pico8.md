# Spec: PICO-8

Status: draft (Milestone 3, package 10)

## Runtime

- CLAUDE.md allows "our own clean-room compatible runtime (or a permissive one
  after license check)". We use **fake-08** (MIT), a PICO-8 compatible
  runtime with a libretro core, built from a pinned commit by
  `cores/fake08/build.sh` for arm64-v8a, x86_64 and the host. Not Lexaloffle
  code and no official PICO-8 binaries.
- License check (docs/licenses.md): fake-08 MIT; z8lua MIT; zepto8-derived
  parts WTFPL-2; PicoLove zlib; LodePNG zlib-style; miniz, simpleini, tac08
  MIT. The bitmap font is the PICO-8 font Lexaloffle released as CC0.
  One function pair, `oval()`/`ovalfill()`, came from a CC BY-SA 3.0 snippet,
  which a GPL-3.0 app can't take; the build removes it and appends our own
  implementation (`cores/fake08/dena_oval.inc`, written from the ellipse
  definition).
- Picture 128×128 at 30 or 60 fps; mono audio from the runtime's synth.
- **Save states:** fake-08 saves PICO-8 memory but not the Lua program, so a
  loaded state doesn't resume faithfully (the round-trip test fails). PICO-8
  games therefore run without states: no Save/Load/Rewind tiles, no rewind
  capture, no auto-resume (a cart restarts from its title). Carts that use
  `cartdata` keep their own saves through the runtime.

## Library and Carts tab

- `.p8` (text) and `.p8.png` (PNG) carts import as system `pico8`
  ("PICO-8"), through the usual import paths. A plain `.png` is not a cart.
- The **Carts** tab lists PICO-8 carts with an "Add carts" button and a
  "Browse the BBS" card (pico8-cart-browser.md; `pico8BrowserEnabled`, on
  since 2026-10-17; with it off the card says the browser comes later). No
  carts are rehosted or bundled.
- Above that, a **Dena Explore** card starts our own launcher cart, which
  lists and launches library carts from inside PICO-8 and browses and
  downloads BBS carts (pico8-launcher-cart.md).
- Carts also appear in the Games tab (filter chip "PICO-8").
- Box art: none (placeholder); `.p8.png` label art is a later package.

## Controls

- RetroPad mapping used by fake-08: D-pad, O = B, X = A, Pause = Start.
- Built-in skin: D-pad, O and X, Pause, menu (no Select).
- Bundled skin "Pixel Cart" (`pico8.deltaskin`, default for PICO-8): pixel-art
  shell in the 16-colour palette, chunky D-pad, red O and blue X, Pause pill,
  drawn by `tools/skins/build_skins.py` at 3 points per art pixel.
- Camera cutouts: the PICO-8 game area (picture and skin) is inset by the
  display cutout (`DisplayFeatureType.cutout`, else the reported view
  padding), so a punch-hole or notch never covers the picture.

## Acceptance tests

- Host golden frames (our own cart `host/tests/roms/pico8/test.p8`, which
  draws every primitive including ovals and a sprite): idle at 90 frames, and
  holding O from frame 30 turns the background dark blue.
- Import rules: `.p8` and `.p8.png` (any case) detect as PICO-8; `.png` doesn't.
- Session: a PICO-8 game starts without a state path, with rewind off, and the
  pause sheet has no Save/Load/Rewind.
- Golden: built-in PICO-8 skin at phone, 640×480 and 720×720.
- On device (human checkpoint): a downloaded cart plays with touch and gamepad.
