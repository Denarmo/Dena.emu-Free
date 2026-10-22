# Music and video players

Two self-contained apps in the Brutalist look (brutalist-ui.md 4.8): grid
paper, a `BrutalTabBar` of categories, tracks and videos in a `BrutalTable`,
a `NOW_PLAYING` `BrutalPanel` with a `ProgressCell` seek bar (elapsed/total
times in mono) and square transport keys (`media/media_kit.dart`). The old
XMB waves and category bar are gone. All drawing is our own; no third-party
assets.

## Routes

- `apps/music` → `MusicScreen`, `apps/video` → `VideoScreen` (named routes on
  the `MaterialApp`). The Apps tab links to them when it exists.

## Music

- Asks for READ_MEDIA_AUDIO (+ POST_NOTIFICATIONS) on Android 13+,
  READ_EXTERNAL_STORAGE before. Refused → "Allow access" button.
- Lists MediaStore music (`IS_MUSIC`), sorted by title. Categories: Songs,
  Albums, Artists; Albums/Artists show a horizontal row of groups and the
  group's tracks below. Empty → "No music found on this device."
- Tapping a track plays the visible list as the queue from that track.
- Playback runs in `MusicService` (Media3 `MediaSessionService`): background
  playback, media notification, lock-screen and headset controls, audio focus,
  pause on becoming noisy.
- Controls: play/pause, previous (restarts after the first seconds), next,
  seek bar, shuffle, repeat (off → all → one).
- Layout: landscape ≥560 px shows library and now playing side by side;
  portrait shows the library with a mini player that opens the full view.
- Keys: L1/R1 categories, X play/pause, Y now playing, B back, D-pad + A.
  With the seek bar focused, left/right step 1/20 of the length (held keys
  repeat); tap or drag seeks on touch.

## Video

- READ_MEDIA_VIDEO (READ_EXTERNAL_STORAGE before 13). Categories: All videos
  plus one per folder (bucket) as `CheckFilter`s. A table of 16:9 thumbnails,
  title, folder and duration with a resume progress bar.
- Playback: ExoPlayer into a Flutter texture, full screen, immersive. Controls
  auto-hide after 3 s while playing: back, title, −10 s, play/pause, +10 s,
  seek bar. Double-tap left/right half skips 10 s.
- D-pad with hidden controls: left/right ±10 s, A play/pause; any other key
  shows the controls. B leaves.
- Resume: position saved on exit to `video_resume.json`; under 5 s or within
  5 s of the end is forgotten. Opening a video pauses the music.

## Tests

- `app/test/media/media_players_test.dart` (fake backend):
  formatting, resume rule, listing, permission refused, empty, albums, video
  folders, open/seek/resume.
- `app/tool/media_screenshots_test.dart` renders both players at phone and
  640×480.
