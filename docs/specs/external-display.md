# Spec: External display

Status: draft (Milestone 3, package 8)

## Behaviour

- While a game is running and Android reports a presentation display (HDMI,
  USB-C DisplayPort, or a wireless display the system mirrors as one), the
  game picture moves to that display through Android's `Presentation` API.
  The picture is centred at the system's aspect on black and fills the
  display's height or width.
- The phone keeps the session screen: the touch skin (or the gamepad hint
  layout) stays, and the game area shows "Playing on <display name>" instead
  of the picture. Touch, gamepads, the pause menu and rewind work as usual.
- When the display goes away mid-game the picture comes back to the phone and
  the game keeps running (unlike a controller disconnect, nothing is lost).
- Only one external display is used: the first presentation display.
- Casting (Google Cast) for watching only is a later package.

## Shell

- `SurfaceRouter` holds the phone surface (SurfaceView or texture path) and the
  external surface; the runner always draws to the external one when it
  exists, else the phone one. Pure Kotlin, unit-tested with a fake sink.
- `ExternalDisplay` listens to `DisplayManager` between session start and
  stop, shows a `Presentation` holding an aspect-fitted `SurfaceView`, and
  reports the display's name (or null) to Dart through
  `GameEventsApi.onExternalDisplayChanged`.
- Dart passes the picture aspect with `GameHostApi.setDisplayAspect` when the
  session starts.

## Acceptance tests

- Kotlin: the router prefers the external surface, falls back to the phone
  surface when the external one goes, and doesn't re-send an unchanged surface.
- Kotlin: aspect fitting centres the picture (letterbox and pillarbox).
- Dart: the session sends the system's aspect at start; after
  `onExternalDisplayChanged("TV")` it shows "Playing on TV" and the skin stays;
  after `onExternalDisplayChanged(null)` the message goes.
- On device (human checkpoint): a USB-C/HDMI display shows the game while the
  phone shows the skin; unplugging returns the picture to the phone.
