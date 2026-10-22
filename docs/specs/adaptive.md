# Spec: Adaptive layouts (tablets and foldables)

Status: draft (Milestone 3, package 9)

## App shell

- Under 600 logical px wide: `NavigationBar` at the bottom. From 600 px
  (tablets, unfolded foldables, landscape phones): `NavigationRail` on the
  left. Already in place since M2 (app_shell.dart); L1/R1 switch tabs in both.

## Game screen

- **Tabletop posture.** When a foldable is half open with the fold running
  across the screen (`DisplayFeatureType.fold` in `postureHalfOpened`), or the
  device has a horizontal physical hinge, the built-in skin puts the game
  picture in the upper half (centred, as large as fits above the fold) and
  the controls in the lower half, below the fold. The skin is opaque in this
  layout. With a gamepad (skin hidden) the picture stays in the upper half.
- Book posture (vertical fold) and flat: the normal portrait/landscape layout.
- Imported `.deltaskin` skins keep their own layout (they choose per device
  type, not per posture).
- **Large screens.** The D-pad, stick and face-button cluster are capped at
  220 logical px (about 3.5 cm), so tablets don't get palm-sized controls;
  everything else scales as before.

## Acceptance tests

- Tabletop: for GBA, PS1 and N64 skins the picture ends above the fold, every
  control starts below it, and the skin is opaque.
- A 1280×800 tablet caps the D-pad at 220 px.
- Fold detection: a half-open horizontal fold and a horizontal hinge count; a
  flat fold, a vertical fold or no feature don't.
- Existing skin goldens at phone, 640×480 and 720×720 are unchanged.
- On device (human checkpoint): a Pixel Fold / Galaxy Z Fold in tabletop
  posture shows the picture on the upright half.
