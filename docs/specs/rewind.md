# Spec: Rewind

Status: draft (Milestone 3, package 1)

## Behaviour

- While a game runs with rewind on, the host captures a save state every
  `interval` frames (default 2) into a ring buffer with a memory budget
  (default 32 MB on phones; the handhelds will use 8 MB).
- The capture runs after the frame's picture is posted: it holds the state
  the next frame starts from. A large state (DS: 6.5 MB, its serialize and
  delta cost about as much as a frame) must not sit between an input and the
  frame that shows it, or every other frame posts late (desktop pass 3, DS).
- **Rewind** plays backwards while a gamepad's **L2** is held (systems without an
  L2 button), or from the pause-menu tile until the player taps the screen
  ("Rewinding · tap to stop"). Skins can hold it through `dena_rewind_hold`.
- Each step restores the previous capture and shows its frame, stepping every
  `interval` frames so playback runs at roughly real speed. Audio is muted.
- Releasing continues from that point; captures made after it are dropped.
- When the buffer is empty the game stays paused on the oldest point.
- Loading a save state, resetting or changing disc clears the buffer.
- Rewind is off when the core can't serialize (state size 0) or when one
  state is larger than half the budget (PPSSPP, ~40 MB; 128 MB before boot):
  capturing it every few frames stalls the game. With rewind off, a held L2
  is an ordinary button.
- Later: a setting turns rewind off (it costs CPU on slow handhelds).

## Long rewind (Windows and SteamOS)

Desktop feature 5 (features-proposal.md): minutes of rewind instead of seconds.

- **Budget.** Settings > INPUT.CFG > Rewind buffer: `SHORT` (32 MB, as on
  phones), `256 MB`, `[1 GB]` (default) or `2 GB`, kept in
  `desktop_rewind.json`. It takes effect at the next game start
  (`dena_rewind_budget`). Memory is only used as the game plays: at one capture
  every 2 frames, 1 GB holds roughly tens of minutes of a 2D game and several
  minutes of a 3D one. The state-size limit stays 16 MB whatever the budget
  (PPSSPP and other heavy states still have no rewind).
- **Hold to rewind.** Keyboard **R** while held (RetroArch's key), a gamepad's
  **L2** on systems without L2 (as above), or a skin's `dena_rewind_hold`.
- **Scrub bar.** Pause > Rewind opens the REWIND sheet (right panel, game not
  dimmed) instead of starting playback: the time behind now in large type
  (`-01:23`), a 20-cell bracket bar (Left/Right one cell), `-10S -1S +1S +10S`
  buttons, Page Up/Down or L1/R1 for 10 s. The game picture follows every move.
  **RESUME HERE** keeps that point (the captures after it are dropped) and
  resumes; **BACK TO NOW** or B returns to the pause menu at exactly the paused
  point. Hardcore mode, games without states and an empty buffer fall back to
  the phone behaviour (Rewind plays backwards until a tap).
- **Host.** Starting a scrub captures the live state as the newest entry. The
  ring keeps a cursor (`dena_rewind_seek`): the XOR deltas undo themselves, so
  the cursor moves back and forward without losing anything until a push,
  `step_back` or `dena_rewind_keep` drops what is newer. A seek applies at most
  48 MB of deltas per step, shows that picture and continues on the emulator
  thread, so a jump across a full buffer never blocks the UI.
- **FFI** (desktop host library): `dena_rewind_budget(bytes)`,
  `dena_rewind_info(int64 out[5])`, `dena_rewind_scrub_begin(int64 out[5])`
  (0 ok, -1 no rewind; out = count, position, bytes, budget, fps * 1000),
  `dena_rewind_scrub(position)`, `dena_rewind_scrub_end(keep)`. Phones and
  handhelds don't export them; the app then keeps the phone behaviour.

## Storage format (host, `dena/rewind.h`)

- The newest state is kept in full. Each older capture is stored as the XOR of
  it and the next newer state, run-length encoded: repeated
  `(zero_run varint, literal_len varint, literal bytes)`. Most bytes are equal
  between adjacent frames, so entries are small.
- Stepping back XORs the newest entry into the current state, which yields
  the previous state exactly.
- The oldest entries are evicted to stay within the budget. A change in state
  size clears the buffer.

## API

```c
dena_rewind *dena_rewind_create(size_t budget_bytes);
void dena_rewind_destroy(dena_rewind *rw);
int dena_rewind_push(dena_rewind *rw, const void *state, size_t size); /* 0 or -1 (out of memory) */
int dena_rewind_step_back(dena_rewind *rw, void *out, size_t size);    /* 0, DENA_NO_DATA when empty */
size_t dena_rewind_count(const dena_rewind *rw);   /* steps available */
size_t dena_rewind_bytes(const dena_rewind *rw);   /* memory in use */
void dena_rewind_clear(dena_rewind *rw);
/* Long rewind: scrub without dropping, then keep. */
int dena_rewind_seek(dena_rewind *rw, size_t target, size_t max_bytes, void *out, size_t size);
void dena_rewind_keep(dena_rewind *rw);
size_t dena_rewind_position(const dena_rewind *rw);
```

## Acceptance tests

- Codec: random and mostly-equal buffers encode and decode exactly.
- Ring: push N states, step back N-1 times and get each state byte for byte;
  the budget evicts the oldest; a size change clears.
- Seek: back, forward and back again give each state byte for byte without
  dropping anything; a byte limit stops short; keep and push drop the newer
  captures; eviction keeps the cursor on the newest.
- Runner: scrub while paused, keep resumes from that point; cancel resumes
  exactly as if there had been no scrub; a new budget empties the buffer.
- App: Settings choice saved and loaded (1 GB default); the scrub sheet's keys
  and buttons move by cells and seconds and clamp; Pause > Rewind on desktop
  opens the sheet, resume keeps, Back to now returns to the menu.
- With the test core: run 120 frames capturing each frame, record frame hashes,
  step back 30 times, load and run one frame: the hash matches the recorded one.
