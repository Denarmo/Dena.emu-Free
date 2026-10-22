# Spec: Game boxes

Status: in progress (owner request 2026-10-17)

The library shows each game as its console's real box instead of a flat
card: a printed carton, a plastic keep case, a CD jewel case or (PICO-8) the
cart itself, with the cover art in the box's label window and the box's side
and top showing so it reads as an object on a shelf.

## Box model (`app/lib/src/library/game_box_model.dart`)

Pure data, shared by the grid, the stash, the long-press zoom and the open-box
launch animation. `boxSpecFor(system)` returns a `BoxSpec`:

| Field | Meaning |
| --- | --- |
| `widthMm`, `heightMm`, `depthMm` | Real front-face size and thickness (approx. North American retail) |
| `material` | `cardboard`, `plastic`, `jewel` or `cart`: corners, gloss, sides |
| `label` | Cover window as fractions of the front face |
| `cornerMm`, `shellColor` | Moulding radius and plastic/tray/cart colour |
| `media`, `mediaWidthMm`, `mediaHeightMm`, `mediaRect` | What is inside and where it rests when open |
| `hinge` | `left` (cases open like a book), `top` (carton flap), `none` |
| `rotatable` | Regional orientation differs (SNES, N64, Saturn) |

| System | Box | Size (mm) | Media |
| --- | --- | --- | --- |
| NES | carton, portrait | 127 x 178 x 25 | cartridge |
| SNES | carton, landscape (portrait for PAL/JP covers) | 190 x 138 x 32 | cartridge |
| N64 | carton, landscape (turns for portrait covers) | 186 x 134 x 38 | cartridge |
| GB, GBC | small carton | 114 x 127 x 25 | cartridge |
| GBA | small carton | 125 x 125 x 25 | cartridge |
| DS / 3DS | plastic case, rounded | 125 x 137 x 14 / 11 | game card |
| PS1, Dreamcast | jewel case, left hinge strip | 142 x 125 x 10 | disc |
| PS2 | plastic keep case | 135 x 190 x 14 | disc |
| GameCube, Wii | plastic keep case (black / white) | 135 x 190 x 14 | disc (80 / 120 mm) |
| PSP | UMD case | 105 x 180 x 14 | UMD |
| Genesis | plastic clamshell | 133 x 187 x 23 | cartridge |
| Saturn | long case | 140 x 195 x 14 | disc |
| PICO-8 | the cart itself | 86 x 98 x 12 | none |
| anything else | generic keep case | 135 x 190 x 14 | disc |

Sizes: every grid cell is a stage of `boxStageMm` (216 mm square, the largest
box plus its visible side), so boxes keep their real relative size: a Game Boy
box is visibly smaller than an N64 box. `boxFootprintOn(spec, stage)` gives the
drawn size (front plus side and top) for other views such as the stash.

Orientation: a `rotatable` box turns when the cover image is clearly the other
way round (aspect < 0.92 or > 1.08), so a PAL SNES cover gets an upright box
instead of being cropped. Near-square covers keep the default.

## Drawing (`game_box.dart`)

- Oblique view: the right side and the top show at `boxDepthSlant` x depth,
  with a contact shadow on the shelf.
- Carton: square corners, sides printed in the system colour, faint matte
  sheen, flap fold on top.
- Plastic case: moulded frame around a clear sleeve, diagonal gloss band,
  hinge line on the spine side.
- Jewel case: dark hinge strip with two ridges left of the insert, stronger
  gloss.
- Cart: body colour, recessed label well, grip ridges below the label.
- The cover (custom art or box art, else the system placeholder) fills the
  label window (`BoxFit.cover`), with the foil sheen on top.
- D-pad focus: the box grows 6 % from its base and gets a primary-colour ring
  with a soft glow. No ring in touch mode.

## Inspection view (`game_box_menu.dart`, brutalist-ui.md 4.3)

- Long-press a box (touch), or Y / Menu with the D-pad, in the grid, the
  carts tab or the stash. It opens at once (no fly-in, no bob, no blur).
- **Viewport** (`InspectViewport`): primary-blue blueprint panel with an 8 px
  white grid and dashed crosshairs; the box sits rotated -6° with a hard
  offset shadow and the foil stripe on its front face. Labels: an
  `INSPECT // <SYS>` header tag and white callouts `foil layer ->`,
  `<- spine <depth>mm` and `<-- ratio 1:<aspect> -->`.
- **Details:** the file name as title, a key-value strip (SYS, YEAR, PLAYED,
  FILE), a big primary **PLAY ->** key (autofocused), then the options:
  Favourite / Unfavourite [F], Rename [R], Home screen [H] (when the platform
  has shortcuts), Achievements [A] (signed in and the system is supported),
  Choose cover [C] (with box art), Game info [I]. The letter keys work on a
  keyboard.
- **Delete** is a full-width hazard `HOLD TO DELETE` button: a 1 s hold (touch,
  A or Enter) deletes the game and closes; letting go early does nothing. No
  confirm dialog.
- **Layouts:**
  - Phone: a full screen over grid paper: `<- BACK` and the path
    `/games/<file>`, the viewport, details, PLAY, options two per row, delete.
  - Handheld (640x480, 720x720): the library stays behind a scrim; the
    viewport top-left and a 300 px INSPECT panel on the right with the
    options in one column, letters on the right.
  - Desktop: the INSPECT panel (440 px) on the right with the viewport at its
    top.
- B, Escape, Back, `<- BACK` or a tap outside the panel closes.
- Game info is a brutalist dialog listing system, file, size, added, last
  played, play time, CRC-32 and SHA-1.

### Handhelds

Nothing in the view animates, so it costs the Mali-G31 nothing. Home screen is
not offered (no home screen); Rename types on the on-screen keyboard.

## Home-screen shortcut icon

Add to home screen pins a shortcut (shortcuts.md) whose icon is the cover drawn
as an adaptive icon (`CoverIcon` in `GameShortcuts.kt`): the whole cover fitted
into the 66 dp safe zone with a shadow, over a blurred, dimmed copy of itself
that fills the bleed, so every launcher mask shows the full box art. No cover:
the app icon.

## Acceptance tests

- Unit: every `GameSystem` has its own spec; shapes, materials, media and
  hinges as in the table; GB box smaller than N64 on the same stage; every box
  (both orientations) fits its stage with its side; label and media rects lie
  in the front face; rotatable boxes turn for portrait covers and fixed ones
  never do.
- Golden: `box_shelf` (phone and 640x480, touch and focus) with one game per
  box shape, some with covers and some with placeholders.
- Widget + golden: `box_menu` (phone, 640x480, 720x720): long-press opens the
  inspection view with every option, Game info shows the file name, Home
  screen pins and closes; a short press on HOLD TO DELETE keeps the game and
  a 1 s hold deletes it. D-pad: Y opens with PLAY focused, the arrows reach
  Rename and HOLD TO DELETE, a short A keeps the game, B closes
  (handheld_navigation_test).
- On device: boxes look like objects at phone size and on the handheld; the
  grid scrolls smoothly with a full library.
