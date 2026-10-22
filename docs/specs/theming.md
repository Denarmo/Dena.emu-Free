# Theming

The app uses the Brutalist look (brutalist-ui.md): Paper (light graph paper, black ink)
by default, Ink (dark) on request, with hazard yellow `#FFE600` as the focus and
highlight colour. Material You and the console palettes are gone (owner decision,
2026-10-18).

## Choices (Settings > Theme)

- **Mode**: Paper (default) / Ink / System, a segmented button (D-pad operable).
- **Accent**: Hazard (`#FFE600`, default) / Gold (`#F1C40F`, Dena gold). It sets the
  focus and highlight fill; text on it is always black.
- **Library view**: table (default) / grid / stash. The table arrives with the library
  area PR; until then `table` shows the grid as before.
- Saved to `<dataDir>/theme.json` as
  `{"mode": "paper"|"ink"|"system", "accent": "hazard"|"gold", "library": "table"|"grid"|"stash", "audioLatencyMs": n}`.
  A missing or damaged file gives the defaults.

### Migration

Files written before the redesign load as follows: `"mode": "dark"` is Ink,
`"light"` is Paper, `"system"` stays; `palette` is ignored; `stash: true` is kept as
the stash library view; the audio latency carries over. The next change rewrites the
file in the new form.

## Tokens (app/lib/src/ui/brutal/tokens.dart)

`BrutalTokens` is a `ThemeExtension` registered by `denaTheme()`; widgets read it with
`BrutalTokens.of(context)`, which also adapts sizes to the device (phone, handheld,
desktop). `brutalScheme()` maps the tokens onto a `ColorScheme` so stock Material
widgets on screens not yet converted read black-on-paper (or white-on-ink) with the
accent as their highlight. Colour values are in brutalist-ui.md section 2.1.

The handheld launcher reports `platformBrightness: dark`, so System is Ink there. The
game backdrop is always black.

## Fonts

- IBM Plex Mono (OFL-1.1, `app/assets/fonts/ibm_plex_mono/`, weights 500/600/700):
  all UI text.
- Archivo Black (OFL-1.1, `app/assets/fonts/archivo_black/`): headlines, stickers,
  the wordmark.
- Roboto (OFL-1.1) stays bundled as the fallback: Linux handhelds have no system fonts.
- Nunito, the pre-Brutalist face, is gone from the app (files deleted in the cleanup PR).
- Dena Icons (`app/assets/fonts/dena_icons/DenaIcons.otf`): our own icon font, drawn
  in the 9x9 pixel style (brutalist-ui.md section 2.5).

## Acceptance

- Every token text pair in Paper and Ink with both accents meets 4.5:1
  (`test/ui/app_theme_test.dart`, `test/ui/brutal_kit_test.dart`).
- Fresh install starts on Paper with the hazard accent; choosing Ink and Gold restyles
  the app at once and survives a restart.
- An old theme.json migrates as above.
- Goldens regenerated; `tool/screenshots_test.dart` renders the library in Paper and
  Ink and in both accents.
