# Foil covers

Library covers carry a flat holo stripe (brutalist-ui.md 4.3): two 6 px bands,
cyan and magenta at 40 %, running diagonally (-45°) through the middle of the
cover. No glint, sheen, grain, glow or dimming, and no time-based sweep.

- **Tilt (phones only):** one shared `FoilTilt` (Dart) fed by `TiltSensor`
  (Kotlin, EventChannel `app.dena/tilt`): game rotation vector, falling back to
  the accelerometer, low-pass filtered and emitted at about 30 Hz as `[x, y]`
  in -1..1. `foilShiftFor` turns it into a sideways shift of at most 8 px, in
  whole 2 px steps, so the stripe jumps rather than glides, and a tilt inside
  one step repaints nothing.
- **No sensor, non-Android, or a handheld:** the stripe is static and never
  repaints.
- **Lifecycle:** the sensor runs only while at least one cover listens, the
  cover's tab is visible (`TickerMode`), and the app is resumed.
- **Rendering:** `FoilStripePainter` (plain `CustomPainter`, two rects) inside
  each cover's own `RepaintBoundary`. The old `shaders/foil.frag` is unused and
  goes in the redesign cleanup PR.
- Only covers with art get foil; placeholders do not. The inspection view
  (game-boxes.md) shows the same stripe on the front face with a
  `foil layer ->` callout.
- **Tests:** `test/foil_test.dart` (max shift, 2 px steps, no repaint within a
  step); `FoilTilt.animate = false` in `flutter_test_config.dart`; the
  `box_shelf` and `box_menu` goldens show the stripe.
