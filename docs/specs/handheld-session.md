# Spec: Games in the handheld launcher

Status: draft (Milestone 4, package 7). Builds on shared-runner.md and
embedder.md; nothing here has run on a device yet.

## What it does

`dena-launcher` plays games with the same Dart session screen as Android.
The shared `dena::Runner` runs the core; the launcher supplies a Linux
`RunnerPlatform` and answers the session's Pigeon calls itself, so the Dart
code does not change apart from the game view.

## Pieces

### Game bridge (`shells/linux/src/launcher/game_bridge.{h,cpp}`)

Answers `dev.flutter.pigeon.dena_android.GameHostApi.<method>` messages
(game_api.dart is the contract) with the StandardMessageCodec in `std_codec`.

- Input: a list of arguments. Ints may arrive as tag 3 or 4. Output: the
  Pigeon envelope, `[result]` on success, `[code, message, details]` on
  error. Void methods reply `[null]`.
- `start(core, rom, srm, state)` → `StartResult` (custom tag 130 wrapping
  `[outcome, error]`; outcome is custom tag 129 wrapping the enum index:
  fresh 0, resumed 1, badState 2). A failed start replies
  `[StartResult(null, message)]`, not an error. The BIOS directory is
  `$DENA_CARD/Bios` (sd-card.md).
- The core name is Android's library name (`libmgba_libretro.so`). A bare
  name resolves to `$DENA_CARD/Dena/lib/<name>`, else the same without the
  `lib` prefix (how the cores are built), else it is left to the library
  search path; a path with `/` is used as given.
- `pause`, `resume`, `setSpeed`, `configureRewind`, `setRewinding`,
  `saveNow`, `setCheats`, `stop`: forwarded to the runner.
- `saveState`, `loadState`: `null` on success, else a message.
- `captureScreenshot(name)`: writes `$DENA_CARD/Screenshots/<name>.png`
  (folder created when missing); `null` or a message. Names with `/` or
  `..` are refused.
- `setShader(id)`: `""` turns the shader off. Otherwise `id` must be a
  plain folder name (`a-z 0-9 - _`) with
  `$DENA_CARD/Dena/data/shaders/<id>/<id>.glslp` on the card (the payload
  copies `host/shaders` there), else "Unknown shader". The platform's error
  message, if any, is the result.
- `setDisplayAspect`, `setAnalogMode`, `setTouchMode`, `setAudioLatency`,
  `setUpscale`: accepted, no effect (no external display or touch skin on
  handhelds; sticks follow the profile; ALSA keeps fixed periods; native
  resolution only). The session sends the last two before every start, so
  an error here would fail every game.
- Turbo: the launcher exports `dena_set_turbo` (as `libdena_android.so`
  does) for dart:ffi; Achievements: rcheevos and `host/achievements` are
  linked in, the runner's frame hook feeds `dena_ra_frame`, and the
  `dena_ra_*` entry points are exported from the process (achievements.md).
- Unknown method or malformed arguments: error envelope
  `["bad-args", <message>, null]`; the launcher replies to unknown
  channels with an empty response (Flutter's "not implemented").

The bridge talks to an abstract `GameHost` (start, pause, ..., screenshot)
so it is host-tested with a fake; the launcher's `GameHost` is the runner.

### Events to Dart

`dev.flutter.pigeon.dena_android.GameEventsApi.onMenuRequested` and
`onControllerDisconnected` are sent by the launcher as Pigeon messages
(argument list encoded with `std_codec`).

### Linux platform (`linux_platform.{h,cpp}`)

- Vsync: while frames are wanted the emulator thread waits for the next
  vblank with `drmWaitVBlank` (relative 1) and calls `on_vsync` with its
  time. With no vblank support it sleeps to the next period of the
  profile's refresh rate. `wake()` writes an eventfd that ends the idle
  wait; during a vblank wait, commands wait at most one frame.
- Software frames: `draw_software` converts 0x00RRGGBB to RGBA bytes into
  a triple-buffered `FrameMailbox` and tells the engine a new frame is
  ready (`MarkExternalTextureFrameAvailable`). The raster thread takes the
  newest frame in the engine's external-texture callback and uploads it to
  a GL texture. The emulator thread never touches GL.
- GPU cores (N64, PSP; hw-render.md): `start_gpu` creates a GLES 3
  context on the emulator thread, shared with the engine's resource context
  (surfaceless, else a 1x1 pbuffer), and a framebuffer of the core's
  maximum size. Each presented frame is blitted (flipped for a bottom-left
  origin, so row 0 is the top as for software frames) into one of three
  textures sized to the frame, `glFinish`ed and published through a
  `SlotMailbox`; the engine's texture callback returns the newest one's
  name. The writer never touches the texture the reader holds. Screenshots
  and save-state thumbnails read the framebuffer back. To check on a
  device: sharing between the engine's GLES 2 contexts and the GLES 3
  context (expected on Mesa Panfrost; unknown on the A133P's PowerVR).
- Shaders (shaders.md): the same `ShaderChain` as Android, in the GL
  context above. GPU frames are copied into the chain's source texture
  (top row first); software frames are uploaded to it (swizzled from
  0x00RRGGBB) only while a shader is on, otherwise they keep using the
  mailbox. The chain draws into the next slot texture at the largest
  integer scale that fits the screen (`shader_scale`), and the engine shows
  that texture. A shader chosen before the start applies from the first
  frame; turning it off for a software core destroys the context and goes
  back to the mailbox. A broken preset keeps the current shader.
- Audio: at launcher start `dena_audio_setup` picks the card: the one whose
  ALSA driver is the profile's `audio_driver` (`plughw:N,0`), else the
  profile's `audio` name (default "default"). It then writes the profile's
  `mixer` settings (the route out of reset, e.g. DAC → mixer → line out on
  the H700 codec) and the saved volume. Games play S16LE stereo at 48 kHz in
  256-frame periods (5.3 ms); the hardware buffer is about half the audio
  latency setting, 3 to 8 periods (`dena_audio_periods`: 4 at 40 ms, 3 at
  30 and 20 ms), and starts once full. The runner's ring keeps the full
  setting as its target. A thread at real-time priority (SCHED_FIFO 50, else
  nice -10) fills each period from `read_audio`; an underrun (`-EPIPE`)
  counts an xrun and re-prepares. Pause drops the stream and parks the
  thread. `setAudioLatency` and `setUpscale` are stored for the next start.
- Headphones (H700): the kernel's jack detection turns the speaker path,
  amplifier and its supply off while headphones are in (kernel patch 0164);
  the launcher never sets the Speaker switch, so it does not undo that.

### Input during a game

While a session runs and is not paused, the launcher sends the profile's
RetroPad buttons to `set_buttons(0, mask, event time)` instead of Flutter
key events. Menu (or Start + Select) sends `onMenuRequested` and releases
all buttons. Paused or no session: keys go to Flutter as before. Releases
follow their presses and the D-pad repeats in menus (handheld-input.md).

### Volume keys

The launcher handles the profile's `volume_up` / `volume_down` keys itself,
in the UI and in games: each press or auto-repeat moves a level 0..20
(`dena_volume_next`) and saves it to `Dena/user/volume` on the card (default
16). The level drives the profile's `volume` control, else the first of
Master, PCM, Speaker, Headphone, DAC, Playback (`dena_pick_mixer`). Controls
with dB information get -50 dB..0 dB in 2.5 dB steps (`dena_volume_db100`),
others an equal share of their range (`dena_volume_raw`). Level 0 is the
control's minimum with its switch off.

### Dart

On Linux the session screen's game view is `Texture(textureId: 1)` with
`FilterQuality.none` (`defaultGameView`); the launcher registers texture 1
at engine start. Evdev events use `CLOCK_MONOTONIC` (`EVIOCSCLOCKID`) so
input-to-post latency compares with the runner's clock.

### Storage and platform calls

The handheld has no XDG user folders, so path_provider's documents folder
throws there. With `DENA_HANDHELD=1` and `DENA_CARD` set, every app store
(library database `library.sqlite`, theme, skins, art, carts, sync state)
lives in `<card>/Dena/user/data` (`appDataDir`, `libraryDatabaseDir`;
sd-card.md keeps `user/` across updates). Android keeps its old locations.

The embedder answers only GameHostApi, so the app calls no other
`dena_android` Pigeon API there (`hasAndroidShell` false): no SAF picker,
share sheet, shortcuts, PDF raster or media players (`CardGameFiles` finds nothing; card games join in place, sd-card.md).

## Acceptance tests

Host (`ctest`, shells/linux):

- bridge: every method round trip with a fake host, including the
  StartResult encoding (fresh / resumed / bad state / failed), error
  envelopes for bad arguments, refused screenshot names, core paths;
- mailbox: the reader always gets the newest complete frame, never one
  being written; no frame → nothing; size changes;
- RGBA conversion of known pixels;
- slot mailbox: the reader's slot is never the writer's back slot;
- setShader: id validation, the card path, the platform's error.

Cross build: the launcher with the platform links for aarch64 and passes
the ELF check. On a device (human checkpoint): a game shows, sounds and
responds to buttons; Menu opens the pause sheet.
