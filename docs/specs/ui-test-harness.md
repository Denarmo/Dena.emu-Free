# Spec: UI test harness

Status: implemented (Milestone 0)

## Purpose

Every screen is tested at the sizes we design for and in both input modes
(CLAUDE.md §5, §7), so layout overflow or a missing focus path fails CI.

## Matrix

| Name | Logical size | Pixel ratio |
| --- | --- | --- |
| `640x480` | 640×480 | 1.0 |
| `720x720` | 720×720 | 1.0 |
| `phone` | 412×915 | 2.625 |

Input modes: `touch` (`FocusHighlightStrategy.alwaysTouch`, no focus ring) and
`focus` (`alwaysTraditional`, D-pad/gamepad/keyboard, focus ring visible).

## API (`app/test/support/screen_matrix.dart`)

- `testScreens(description, body, {sizes, modes, tags})` declares one test per
  (size, mode), named `description [size, mode]`, and resets the view after.
- `goldenName(screen, size, mode)` → `goldens/<screen>_<size>_<mode>.png`.
- `dpad(tester, key)` sends one key and settles, to walk focus like a D-pad.

## Goldens

Recorded with `flutter test --update-goldens` and committed. Text renders in
the test font (boxes), so goldens check layout, colour and focus, not glyphs.
`test/flutter_test_config.dart` accepts up to 2 % differing pixels (glyph edges differ between OSes; dense 640×480 screens reach 1.5 % on Windows) so goldens
recorded on one OS pass on the Linux CI runner. On failure CI uploads
`test/failures/` as an artifact.

## Rules for new screens

Each screen test must cover: renders without exceptions at every size; a golden
per (size, mode); every interactive element is reachable with arrow keys and
activates with Enter / gamepad A; Escape / gamepad B goes back.

## Known gap

The M3 default focus indicator on filled buttons is a subtle overlay, not a
ring. Designing a clearly visible focus ring is a Milestone 2 design task.
