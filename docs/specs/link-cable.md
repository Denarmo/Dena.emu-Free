# Link cable (GB, GBC, GBA)

Two devices running Dena.emu on the same Wi-Fi play linked, as if a link cable joined
them: trades, battles, multiplayer modes. Requested by the user on 2026-10-17.

## Behaviour

- Systems: `gb`, `gbc`, `gba` (all on mGBA). Other systems show no link controls.
- Pause menu → **Link cable** row (shows the state) → sheet with:
  - **Host**: this device listens on TCP 47320 and broadcasts a UDP beacon on 47321
    once a second with the game title. While waiting, the sheet shows this device's
    IPv4 address.
  - **Devices nearby**: hosts heard in the last 3 s; tap one to join.
  - **Join by address**: for networks that drop broadcasts (guest Wi-Fi, some phones).
  - **Disconnect** / **Cancel** while connected or waiting.
- The host is player 1: GBA multiplayer parent (`SIOCNT` SI = 0, id 0); the joiner is
  the child (id 1). On GB/GBC the role comes from the game (whoever drives the clock).
- Both devices should run the same game, or games made to link (Red/Blue, Ruby/Sapphire).
  Different games still connect; what they do is up to the games.
- Leaving the game ends the link. A dropped connection shows "Disconnected" with the reason;
  the game sees an unplugged cable (it reads 0xFF / 0xFFFF).
- Only two devices. GBA 3–4 player and the GBA wireless adapter are not supported.

## Design

```
Flutter sheet ── dart:ffi ──> host/src/link.c (socket thread, beacon, scan)
                                   │ dena_link_api (send / recv / role)
mGBA core (cores/mgba/dena_link.inc, SIO drivers) <── dena_link_attach()
```

- `host/include/dena/link_api.h` is the core-facing contract; `dena_core_load` looks up the
  optional `dena_link_attach` export and hands the transport over. Cores without it are
  unaffected.
- Wire format: 8-byte messages `'D', kind, 0, 0, value (u32 big-endian)`; both sides send
  `HELLO` with the API version first. `TCP_NODELAY`.
- The clock-driving side (GB internal clock, GBA normal internal clock, GBA multiplayer
  parent) sends its word and blocks up to 40 ms for the reply; on timeout the transfer
  completes with "nothing connected" (0xFF / 0xFFFF / 0xFFFFFFFF).
- The other side polls its inbox every 512 emulated cycles (lock-free check, no syscall),
  answers with its own word and finishes its transfer (data registers, IRQ). A side that is
  not ready answers "nothing" and keeps its state, so games' own retry loops work.
- GB uses mGBA's own bit-shift event for the master (it shifts in `pendingSB`). GBA transfers
  complete after the hardware transfer time via a timing event.
- The poll is re-armed every frame because resets and state loads clear mGBA's timing queue.
- Latency: each master transfer costs one network round trip (≈2–5 ms on home Wi-Fi). Link
  menus and trades tolerate this; frame-perfect link action games may slow down.
- `cores/mgba/build.sh` copies `dena_link.inc` and `link_api.h` into mGBA's libretro folder and
  inserts four lines into a pristine `libretro.c` on every build; the build fails if they
  do not apply (an mGBA bump that moved them).
- Windows: the desktop DLL (MinGW) runs the link through host/src/net_sock.h (Winsock); only
  MSVC harness builds still compile the stub that reports "not supported".
- Desktop over the internet: joining by room code through a relay server, with
  the same socket underneath ([netplay.md](netplay.md), Link cable over the internet). Over a
  room, the relay or a non-private address, a master waits up to 400 ms for the reply instead
  of what the core asks for.

## Android notes

- Needs `INTERNET` (already declared). Beacons are plain broadcasts; when a phone drops them,
  joining by address still works.

## Tests

- `link_tests` (host): two processes over loopback; discovery sees the beacon, 500 request /
  reply round trips of all three kinds, the host notices the joiner leaving, joining nobody fails.
- `link_gb` / `link_gba` (need `DENA_CORES_DIR`): two processes each run mGBA on our own ROMs
  (`host/tests/roms/link/make_rom.py`): GB master/slave exchange three bytes over the serial port;
  GBA parent/child exchange three words in multiplayer mode. Both sides must receive the other's
  bytes.
- `app/test/session/link_cable_test.dart`: sheet states, host / join / cancel, scan parsing, the
  pause-menu row only for systems with a link.
- Not covered automatically: two real phones. Manual check: host on one, join from the other,
  trade in a GB, GBC and GBA game.
