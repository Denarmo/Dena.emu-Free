# Launch animation

Playing a game (tap a box, Play in the hold menu, or A on a focused box on the
handheld) opens the game's box and loads its media: the core starts underneath
while the animation runs, so the load time hides behind it.

## Behaviour

- **One entry point.** `playGame` pushes a `LaunchRoute` (`app/lib/src/library/launch_animation.dart`).
  Every play path (grid, stash, Continue card, hold menu, PICO-8 launcher, shortcuts)
  goes through it. The Dena Explore launcher cart itself does not animate.
- **Session starts on frame one.** The route builds `SessionScreen` immediately; it stays
  unpainted until the backdrop covers the library (`LaunchTimeline.sessionShownAt`), then
  the box animation plays over it.
- **Timeline** (560 ms of hard steps, `LaunchTimeline`, brutalist-ui.md 4.4): no
  easing, no fades, no glow; every change lands on a 40 ms grid.
  1. *Invert* (0–80 ms): the tapped box's rectangle (`LaunchOrigin`; the focused
     box with a D-pad) goes black with the file name in the focus colour.
  2. *Centre* (80 ms): the screen cuts to black with the box centred, a hard
     offset shadow under it. The session is visible from here.
  3. *Open* (240 and 320 ms): cardboard boxes lift the top flap in two steps;
     plastic cases open the front in two steps (half, then folded left of the
     spine), showing the tray. PICO-8 never opens.
  4. *Media* (280 and 360 ms): the media rises out of the box in two steps and
     sits in front of it on the second.
  5. *Log* (400 ms): `> boot <file name> ... ok` prints under the box.
  6. *Cut* (560 ms): the overlay is gone; the game shows.
- **Skip:** a tap anywhere or any key / button jumps to the end. Keys use a global
  `HardwareKeyboard` handler so the session keeps its own focus.
- **Reduced motion** (`MediaQuery.disableAnimations`): one still frame (box open,
  media out, boot line) for 360 ms, then a cut.
- **Exit** (popping the session): an instant cut, never the launch in reverse.

## Media

| Kind | Systems | Drawing |
| --- | --- | --- |
| Cartridge | NES, SNES, N64, GB, GBC, GBA, DS, 3DS, Genesis | `CartShape` per system: real outside proportions, plastic colour, label well, grip ridges, top notch (GBA/DS), stepped shoulders (N64) |
| Disc | PS1, PS2, Saturn, Dreamcast, GameCube, Wii | Silver disc with clear hub and centre hole |
| UMD | PSP | Dark shell, label across the top, disc window below |
| PICO-8 cart | PICO-8 | The `.p8.png` itself (it is a picture of a cart) |

All drawings are our own: plain shapes, no logos or trademarks.

## Media art

`MediaArtCache` (`media_art.dart`), cached under `<dataDir>/art/<sha1>.media.png` next to
the covers, so `BoxArtCache.forget` deletes both.

1. The player's custom media art (`<sha1>.media.custom.png`).
2. The cached download.
3. **ScreenScraper** (`ScreenScraperSource`), when the build has developer credentials
   (`--dart-define=DENA_SCREENSCRAPER_DEVID=… --dart-define=DENA_SCREENSCRAPER_DEVPASSWORD=…`).
   Looked up by CRC, SHA-1 and file name; cartridges take `support-texture` (the flat label),
   discs and UMDs `support-2D` (the face scan). Region: the file's own tags, then USA, World,
   Europe, Japan. One request at a time.
4. **Fallback:** the game's cover, cropped onto the console's label frame (the printed
   band around the label, e.g. black on NES, light on SNES) or onto the disc's print area.

A miss writes `<sha1>.media.none` and is retried after 7 days; a failed lookup (offline,
quota) records nothing and is retried after a restart. Media art is prefetched on import and
at each launch; the launch waits at most 350 ms for the cover and media art, so a slow
network only means the fallback shows this time.

The libretro thumbnail server has covers, snaps and title screens but no label or disc
scans, which is why genuine media art needs ScreenScraper.

## Box shape

The box comes from the library's box model (`game_box_model.dart`, game-boxes.md):
`aspect` and `depthMm` size it, `hinge` picks the opening (left: case, top: carton,
none: PICO-8, which only lifts), and `mediaRect` seats the media at its real size in the
open box.

## Handhelds and desktop

The same 560 ms timeline everywhere: there is no motion to thin out, so the
handheld needs no shorter version. Any button still skips.

## Tests

`test/library/media_art_test.dart`: media kinds, ScreenScraper reply picking and request
queueing, cache hits, misses, failures and custom art.
`test/library/launch_animation_test.dart`: session starts on the first frame, tap and key
skip, reduced motion still frame, the 560 ms hard-step timeline, the boot line at 400 ms,
every frame draws for each media kind, `LaunchOrigin` rects.
