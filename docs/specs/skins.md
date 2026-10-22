# Spec: Skins and touch controls

Status: draft (Milestone 2, package 8). Delivered in two parts:
**8a** built-in touch controls, touch input path, last-input-wins;
**8b** `.deltaskin` import, rendering and the Skins tab.

## 8a: Built-in touch controls

- Every system has a built-in skin drawn by Flutter (Material shapes, no
  image assets): D-pad, face buttons (NES/GB/GBC: B A; GBA: B A + L R;
  SNES: Y X B A + L R), Start, Select and a menu button. Portrait: game on
  top, controls below. Landscape: game centred, controls at the sides over a
  translucent scrim.
- The skin layout uses the same model as imported skins (8b): a mapping size
  and items with frames, inputs and extended edges, so hit-testing and
  rendering are shared.
- **Touch input:** multi-touch; each pointer presses the item under it
  (frame + extended edges); the D-pad item splits into 8 directions by angle
  from its centre (dead zone 15 % of its size). Sliding a finger moves the
  press. The combined mask goes to the core's port 1 (libretro port 0).
  Haptic tick on each new press.
- **Hot path:** touch masks reach native through `dart:ffi`
  (`dena_touch_buttons(mask)` exported by `libdena_android.so`), never a
  method channel. Native ORs the touch mask with port 0's gamepad mask.
- **Last input wins:** a mapped gamepad or keyboard press hides the skin (the
  game view takes the full screen); a touch anywhere on the game screen shows
  it again; a gamepad disconnect shows it. The menu item opens the pause
  sheet. Shown/hidden is per session, not saved.

## 8b: `.deltaskin` files

The format is public (a zip holding `info.json` plus PDF or PNG artwork;
documented on the Delta docs site and in community guides; see
docs/provenance.md). We implement it from that description only.

- `info.json`: `name`, `identifier`, `gameTypeIdentifier`
  (`com.rileytestut.delta.game.{nes,snes,gbc,gba,ds,n64,genesis}`), `debug`,
  `representations` → device (`iphone`, `ipad`) → display type (`standard`,
  `edgeToEdge`, `splitView`) → orientation (`portrait`, `landscape`) with
  `assets` (`resizable` PDF or `small`/`medium`/`large` PNG), `items`,
  `screens`, `mappingSize`, `extendedEdges`, `translucent`.
- Items: `inputs` is a list of input names (several = combo) or, for `dpad` /
  `thumbstick`, a map of `up`/`down`/`left`/`right`; `frame`, optional
  `extendedEdges`. Names: `up down left right a b x y l r start select menu`,
  plus `quickSave quickLoad fastForward toggleFastForward`.
- Screens: `outputFrame` (points in mapping space), optional `inputFrame`
  (core pixels). Filters are ignored.
- Selection: phones use `iphone` (prefer `edgeToEdge` when the screen is
  taller than 2:1, else `standard`), tablets and handhelds use `ipad` then
  `iphone`; the current orientation, falling back to the other one.
- Artwork: PDFs are rasterised on Android with `PdfRenderer` at the target
  size and cached; PNGs are used as they are.
- **Pressed feedback:** input goes out on touch-down; the keys' travel only
  follows it on screen. Keys ease down (about 12 ms, the first frame already
  half way) and spring back up (about 35 ms) instead of jumping, driven by one
  ticker that stops at rest; only moving keys rebuild, and painted skins only
  repaint. The D-pad is one moulded cross that rocks about its centre in
  perspective (about 10°) towards the held direction: the held arm goes
  down into shade, the opposite one comes up into the light, its soft shadow
  shifts, and diagonals rock towards the corner. A haptic tick on each new
  press and on every D-pad direction change.
  - Skins that bring their own artwork (imported and bundled, debug off):
    a held button's piece of the art (a circle for square frames, else a
    stadium) is redrawn smaller (92 %), a little lower and darker, shaded
    from the rim above, over a dark gap where it sat. The D-pad's cross is
    redrawn rocked over its dark socket, and a held stick's knob follows the
    thumb.
  - Built-in skins: buttons are moulded caps on a lip in shade; pressed, the
    cap travels down over its lip, falls into shadow and takes a hint of the
    accent. The D-pad has a centre dimple and engraved arrows.
- **Filling the screen:** the skin is scaled to fit and aligned to the
  bottom. When that leaves bars of at most 15 % (a phone a little wider or
  taller than the mapping size), a stretched copy of the artwork is drawn
  behind it so the shell reaches the screen's edges; larger bars stay black.
- **System bars:** the game screen hides the status and navigation bars
  (immersive sticky) in portrait and landscape, for every system including
  PICO-8. Leaving the game shows them again.
- Skins tab lists built-in and imported skins per system; import via SAF or
  share sheet; one skin per system and orientation is active.

## 8c: Bundled console-style skins

- `app/assets/skins/<id>.deltaskin` ships one skin per supported system:
  NES, SNES, GB, GBC, GBA, N64, DS, PSX, PSP (Genesis is hidden for now).
  They are ordinary `.deltaskin` files (PNG artwork, `iphone` → `standard`
  and `edgeToEdge` → portrait and landscape), so the import path renders
  them; identifiers are `com.denaemu.skins.<id>`.
- **Artwork is our own**, drawn from plain shapes by
  `tools/skins/build_skins.py` (Pillow). Each skin evokes its console through
  colour palette, button layout and button shapes only: no logos, brand
  names, trademarks or traced official art. Labels are generic (A, B, X, Y,
  L, R, START, SELECT; PlayStation-style face buttons are plain geometric
  outlines). Skin names are our own.
- Parts are shaded from height maps (bevel profiles, a key light from the
  top left, a fill light, specular gloss, contact shadows and occlusion in
  sockets) so keys read as moulded plastic: domed face buttons, a rocking
  D-pad with a centre dimple and engraved arrows, rubber Start/Select keys,
  dished wells and recessed speaker slots.
- **Shell fills the screen:** wherever the shell meets the screen's edges
  it runs past the canvas, so there are no rounded corners there: handheld
  and landscape skins fill the whole canvas; home-console portrait pads have
  a flat top under the picture and fill the sides and bottom. Bumpers sit
  flush with the screen's edges. The PSP nub sits about one D-pad height
  below the D-pad so the two aren't caught together.
- Plastics: rough spark-eroded shells (Game Boy family), see-through shells
  with faint internals (clear editions), clear keys and bumpers (PSP),
  metal-flake gloss (metallic editions) and a cross-hatched grip on the PSP
  nub. Artwork is WebP (lossy, alpha kept) to keep textures small; the app
  decodes it like PNG. Bundled skins are for this app, so Delta's PNG/PDF
  rule doesn't bind them.
- **Alternate editions:** each console also ships other colourways modelled
  on real editions' colours and materials (our own palettes and names, never
  an edition's name, logo or wordmark), e.g. a vibrant metallic blue PSP with
  clear blue keys, a clear Game Boy, translucent N64s. They are listed under
  their system in the Skins tab and are never made active automatically.
- The script validates every layout (items inside the mapping, no overlaps,
  nothing on the game picture, picture aspect matching the system) and
  exits non-zero on a problem. Re-run it after changing the art and commit
  the outputs; bump `bundledSkinsVersion` so installs refresh their files.
- `psx` and `psp` are accepted as `gameTypeIdentifier` suffixes (Delta has
  no such systems; our skins use `com.denaemu.game.<id>`).
- **Install:** on start the app installs the bundled skins when the stored
  `bundled` version in `skins/index.json` differs from
  `bundledSkinsVersion`. The first time, each becomes the active skin for its
  systems unless the user already chose one; later versions refresh the files
  without changing choices. Choosing "Built-in" sticks.
- Bundled skins show "Console style" in the Skins tab and can't be deleted
  (switch to Built-in instead).

## Acceptance tests

- Dart: hit-testing (frames, extended edges, overlap order, D-pad angles and
  dead zone, multi-touch combine and release); last-input-wins state machine;
  built-in skin goldens per system at the matrix sizes (portrait and
  landscape); `info.json` parsing of a fixture we write ourselves (no
  third-party skins in the repo) and representation selection.
- Dart (8c): every bundled skin parses, has all four representations with
  artwork, the system's inputs, one menu item, picture aspect within 1 %, no
  item on the picture, and a phone pick in both orientations; the first
  install sets defaults, keeps a user's choice, and a later "Built-in" choice
  survives a restart.
- On device (emulator CI): the touch path reaches the core (covered when the
  integration test drives the session screen).
