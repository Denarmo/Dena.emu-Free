# Netplay and link cable over the internet (desktop)

Two people play one game together from two PCs (Windows, SteamOS / Linux),
at home or over the internet: two-player NES, SNES, PS1, N64, Saturn,
Dreamcast and PICO-8 games through **netplay**, and Game Boy / Game Boy
Color / Game Boy Advance trades and battles through the **link cable**
([link-cable.md](link-cable.md)) reaching past the home network.
Desktop wave 2 (port-plan.md, features-proposal.md "Netplay and link cable
over LAN/internet").

## Scope

- Hosting and joining on the same network (LAN), joining a **room** by its
  code through a relay server, and connecting straight to an address (a
  host who forwarded the port). All free. The app joins rooms; it does not
  open them.
- No relay server ships with the app. **Settings > NETPLAY.CFG > Relay
  server** is empty until the owner runs one (docs/dev/relay-server.md,
  `tools/relay/dena_relay.py`). Without one, the room buttons say so.
- Phone and handheld: unchanged (LAN link cable only, no netplay).

## Systems and methods

| Systems | Core | Method |
| --- | --- | --- |
| NES, SNES, PICO-8 | FCEUmm, bsnes, fake-08 | Rollback |
| PS1, N64, Saturn, Dreamcast | Beetle PSX / PCSX ReARMed, Mupen64Plus-Next, Beetle Saturn, Flycast | Lockstep |
| GB, GBC, GBA | mGBA | Link cable (each player runs their own game) |
| DS, PSP | — | Not offered (one-console multiplayer is not how these games link) |

The method comes from the core (`netplay_method` in host/runner/netplay.h):
rollback for the cores whose save states are small and fast enough for
run-ahead (run-ahead.md), lockstep for every other core.

- **Rollback.** Each side runs its own input at once and predicts the other
  player's (the last input it saw). When the real input arrives and differs,
  it loads the state from before that frame and replays to the present,
  muted and not shown. Input delay **1 frame** by default (Settings: AUTO,
  0–4); prediction window 8 frames: a side that would run more than 8 frames
  past the last input it has from the other waits.
- **Lockstep.** A frame runs only when both inputs for it are known. Input
  delay AUTO = half the measured round trip in frames, plus 1 (at most 8);
  the Settings value overrides it.
- **Time sync (rollback).** A side that keeps running more than about one
  frame ahead of the other skips a frame now and then so neither keeps
  waiting at the edge of the window.
- **Desync check.** Every 60 frames the joiner sends a hash of its state at a
  frame both inputs are known for; the host compares it with its own and, on
  a difference, sends its state for that frame. The joiner loads it and
  replays to the present (at most one resync per 5 s). `desyncs` counts them.

## Players

- Two players. The host is player 1 (core port 0), the joiner player 2
  (port 1). Each side's own first controller (or keyboard) drives its player;
  other local pads are not sent.
- Inputs sent per frame: the 16 RetroPad buttons, both sticks and the pointer
  (16 bytes).

## Rooms and connecting

```
host ──TCP 47330──> listens (LAN, or a forwarded port)
host ──control──> relay: HOST → ROOM <code>          (opens a room)
joiner ──> relay: LOOKUP <code> → candidates; tries each directly (1.5 s)
joiner ──> relay: JOIN <code> → relay tells host PEER <token>;
           host ──> relay: ACCEPT <code> <token>; relay bridges the bytes
```

- **Host on LAN:** listens on TCP 47330 (netplay) or 47320 (link cable) and
  shows this PC's address. A room code is 6 letters and digits
  (`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, no 0/O/1/I).
- **Join:** one field. Six letters and digits are a room code (needs the
  relay setting); anything with a dot or colon is an address (`host[:port]`).
- **Direct first, relay fallback:** the relay's LOOKUP answers the host's
  public address and LAN address. The joiner tries the LAN address first when
  both share the public address, then the public one; only when none
  connects within 1.5 s each does it ask the relay to bridge. The sheet shows
  `DIRECT` or `RELAY`.
- Relay protocol (text lines, then raw bytes): `DENA-RELAY 1 <verb> ...`;
  verbs `HOST <port> <lan-ip>`, `LOOKUP <code>`, `JOIN <code>`,
  `ACCEPT <code> <token>`. Answers `ROOM <code> <public-ip>`,
  `HOST <ip:port> <lan-ip:port> YOU <ip>`, `PEER <token>`, `OK`, `ERR <why>`.
  A room lives while the host's control connection stays open (rooms expire
  after 6 hours; one host IP holds at most 4 rooms).
- Same transport for both features: host/src/net_room.c gives link.c and the
  netplay session a connected TCP socket; everything above it is unchanged.

## Netplay session

- Wire format: `type u8, length u32 (big-endian), payload`. `HELLO` (version,
  core name, ROM id), `START` (method, delay, state), `INPUT` (frame, sender's
  frame, 16-byte inputs), `HASH`, `STATE`, `PING`/`PONG`, `BYE`.
- **ROM id:** FNV-1a 64 over the file size, its first 16 MB and last 1 MB.
  A different core or ROM is refused ("the other player runs a different
  game").
- **Start:** the host sends its current state; the joiner loads it; both
  start at frame 0. The host's game is the one both continue.
- While connected: fast-forward, rewind, loading states, cheats and the
  achievements frame hook are off (they would split the two games).
  Run-ahead is off (netplay owns the save-state path). Pausing on one side
  makes the other wait ("Waiting for the other player").
- Leaving: either side's Disconnect, closing the game or a dropped
  connection ends netplay; both keep playing alone from where they were.
- Status (`dena_netplay_info`, JSON): state, host, slot, method, delay,
  rtt_ms, via_relay, frame, rollback_frames, max_rollback, stalls, waiting,
  desyncs, resyncs, code, address, peer, error. The sheet polls it twice a
  second.

## Link cable over the internet

- Pause menu > Link cable on the desktop: the join field accepts room
  codes. LAN host, nearby list and join by address
  are unchanged.
- A link over a room, through the relay, or to a non-private address waits
  up to 400 ms for each reply instead of what the core asks for: trades and
  battles work; link-heavy action games slow down with distance.
- Windows now runs the link cable too (it was a stub): link.c uses
  host/src/net_sock.h for sockets on both systems (MinGW DLL; MSVC harness
  builds keep the stub).
- The join field: a room code joins through the relay setting; an address
  joins directly (`host[:port]`, default port 47320).

## UI (brutal kit only)

- Pause menu: **Netplay** row (`[OFF]`, `[WAIT]`, `[P1]`/`[P2]`) for the
  systems above on the desktop. Sheet: STATUS panel (state, DIRECT/RELAY,
  ping, rollback/delay), **Host** (LAN), **Join** field, **Disconnect**.
- Settings > NETPLAY.CFG: **Netplay** row → page with Relay server
  (`host:port`) and Input delay (`AUTO 0 1 2 3 4`).
- Every control is reachable by D-pad; the sheet's first button takes focus.

## Tests

- `netplay_tests` (host/runner): two engines over a simulated link with
  latency and jitter: rollback and lockstep end in identical states; rollback
  replays happen; the window stalls; a planted desync is found and resynced.
- `netplay_loopback` (host): two runners in two processes (one core per
  process) over 127.0.0.1 with the test core: handshake, START, 500 frames
  of the host's input, the same picture at frame 500 on both; loading
  states and rewind refused while connected; the joiner leaves and the host
  plays on alone; a different ROM id is refused; nobody listening and a code
  without a relay fail with a message.
- `net_room_tests` (host, skipped without python3): with
  `tools/relay/dena_relay.py` on 127.0.0.1, a room code joins directly, with
  `DENA_NET_RELAY_ONLY=1` through the relay bridge, codes ignore case, an
  address skips the relay, an unknown code says "no room", a closed room is
  gone; a link cable room exchanges words through the relay.
- `app/test/desktop/netplay_test.dart`: settings file, join-field parsing,
  info parsing, sheet states, the relay gate on room codes, the settings
  page by D-pad, the pause-menu row only when given a state.
  `app/test/session/link_cable_test.dart`: room codes on the desktop only.
- Not covered here: Windows build (no MSVC/MinGW in the cloud), two real PCs,
  a real relay on the internet. See desktop/netplay-verify.md.
