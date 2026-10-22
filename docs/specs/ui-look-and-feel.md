# UI look and feel

> **Retired (2026-10-18).** The app uses the Brutalist look:
> [brutalist-ui.md](brutalist-ui.md) and [theming.md](theming.md). The moulded look
> this file used to describe (Nunito, plastic grain, key caps, `BevelBorder`, gold
> section bars, the XMB media players) was deleted in the Brutalist cleanup PR;
> `git log -- docs/specs/ui-look-and-feel.md` has the old text.

## What is still in use

- **Dena Icons** (`tools/icons/build_icons.py` → `app/lib/src/ui/dena_icons.dart`):
  our own icon font, now drawn in the 9x9 pixel style (brutalist-ui.md 2.5);
  `--style moulded` still rebuilds the old drawings. Codepoints run from U+E000 in
  definition order and never move. No `Icons.*` outside the touch-skin menu glyph.
- **System accents** (`app/lib/src/ui/system_palette.dart`): a generic seed hue per
  system (no console logos or trade dress), harmonised towards the app's primary
  colour. Used only for the small SYS marker in the library table and the box
  placeholder tint (brutalist-ui.md 2.1); never to tint panels.
