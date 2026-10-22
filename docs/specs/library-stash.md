# Library stash view

An optional, playful alternative to the Games grid: the filtered games lie on
the screen as a pile of cover boxes that can be flung around until the wanted
one turns up, then tapped to play.

## Switching

- A toggle button in the Games tab header (next to Sort) switches between
  **Grid** (default) and **Stash**. Tooltip: "Stash view" / "Grid view".
- The choice is saved in `<dataDir>/theme.json` as `"library": "stash"`
  (absent means grid) and restored on the next start.
- Search, system chips and sort apply to the stash exactly as to the grid. The
  Continue card is not shown in stash mode; the stash fills the rest of the tab.

## Physics (own code, no dependency)

- Top-down table: no sideways gravity. Each box is a cover (aspect 0.72, width
  88 px on ≤ 480 px tall screens, else 104 px) simulated as a circle of radius
  0.5 × the box widget's width for collisions (taken from the box size, so
  per-console box shapes collide at their own size), drawn as a rotated
  rounded rectangle.
- **Drop-in**: switching to the stash (or opening the app in it) drops every
  box onto the table. Each box starts 480–1140 px above the table (staggered
  in draw order, bottom of the pile lands first) with a little sideways drift
  and tumble, falls with gravity 2600 px/s², bounces off the table with
  restitution 0.32 (stops under 140 px/s) and gets a small knock and spin on
  each landing. Two boxes collide only when their heights are within 22 px,
  so a falling box passes over the pile until it lands, then shoves the boxes
  it lands on. Height is drawn as the box rising 0.8 px per px and growing
  1/1600 per px, with an unblurred shadow left on the table. Games that
  appear later (filter changes) drop in the same way. Grabbing a falling box
  puts it on the table. With the platform's reduced-motion setting
  (`MediaQuery.disableAnimations`) there is no drop: boxes start at rest.
- Fixed 1/120 s substeps. Velocity decays with friction (`v *= e^(-2.2 dt)`),
  spin with `e^(-3 dt)`. Speeds under 4 px/s snap to zero.
- Walls: the stash area edges; a box hitting one is pushed back inside and its
  normal velocity reversed with restitution 0.55; tangential speed adds spin.
- Box–box: overlapping circles are separated along the centre line and get an
  impulse with restitution 0.6; a held box has infinite mass.
- The ticker runs only while something moves or is held, then stops.
- Initial layout is deterministic (seeded) so goldens are stable: boxes are
  scattered over the area with small random rotations.

## Input

- **Touch**: drag a box to move it (it follows the finger and pushes others);
  release flings it with the gesture velocity (clamped to 2500 px/s). Tap plays
  the game. Long-press opens the game sheet.
- **Shake** button (FAB-row icon button, and gamepad X / key `S`): gives every
  box a random velocity and spin.
- **D-pad**: every box is focusable; arrows move focus by geometry, the focused
  box shows the primary ring and is drawn on top. A plays, Y opens the sheet,
  X shakes.

## Handhelds

The Linux handheld puts at most 40 boxes on the table (the first 40 of the
current filter): every box collides with every other and the pile rebuilds each
frame, which the H700's cores can't hold at 60 fps for a large library, and
640x480 fits fewer anyway. A note at the bottom right says "40 of N games:
filter to find more". The Shake button reads "Shake (X)" since X shakes.

## Edge cases

- Zero games after filtering: show "No games match" centred.
- Resizing (rotation, fold) clamps all boxes inside the new area.
- Games added/removed while open: new boxes appear at random places, removed
  boxes disappear; others keep their positions.
- Accelerometer tilt is out of scope until a sensors dependency exists.

## Acceptance tests

- Physics unit tests: dropped boxes fall, bounce and settle apart inside the
  area; a high box passes over a low one; a flung box slows to rest; boxes never leave the area;
  two overlapping boxes separate; a shake moves every box.
- Widget: the toggle switches to the stash, persists, tapping a box plays it,
  A on the focused box plays it, Shake moves boxes, switching to the stash
  drops the boxes in and they stay draggable, reduced motion skips the drop.
- Goldens: stash at phone and 640×480, touch and focus modes, plus one
  mid-fling frame and one mid-drop frame.
