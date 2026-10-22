# Spec: PICO-8 launcher cart ("Dena Explore")

Status: implemented (Milestone 3, package 10c)

## What it is

A starting cart in the style of a console cart browser: PICO-8 boots into it,
it lists the carts in the library and, when the BBS browser is permitted, the
BBS lists, and it downloads and launches carts. It is **our own cart**
(`app/assets/carts/dena-explore.p8`, GPL-3.0-or-later), written clean-room.
Lexaloffle's own browser cart is part of proprietary PICO-8: it is never
shipped, fetched, read or reproduced (CLAUDE.md §7). What we took from it is
only its observed shape (tabs across the top, a list of carts, a button to run
and a button for options); see docs/provenance.md.

## Starting it

- Carts tab: a **Dena Explore** card (the first card) opens it.
- The app copies the asset to `<data dir>/carts/dena-explore.p8` (rewritten
  when the bundled one changes) and starts a normal PICO-8 session with it.
  It is not a library game: not listed, never played-time counted, no
  shortcut.
- **Launch** from the cart ends its session and plays the chosen library game
  as usual (recently played, shortcut). When that game quits, Dena Explore
  opens again, like returning to a browser. Quitting Dena Explore from the
  pause menu returns to the Carts tab.

## Host API (GPIO mailbox)

The cart and the app talk through the 128 PICO-8 GPIO bytes at `0x5f80`, the
runtime's documented channel to its host. The runtime exposes PICO-8 RAM as
libretro system RAM (fake-08 fixup in `cores/fake08/build.sh`); the runner
copies the GPIO window out after every frame and puts queued writes in before
the next (`Runner::watch_ram / read_ram / write_ram`, shared-runner.md). The
app polls the snapshot every 16 ms while the launcher runs (not a game, so
not the input hot path) through `dart:ffi`: `dena_ram_watch`, `dena_ram_read`
and `dena_ram_write` copy through a 256-byte buffer (`dena_ram_buffer`) in
`libdena_android.so`, or in the `dena-launcher` process on Linux. Shells
without these symbols (desktop, tests) get no host, and the cart shows its
no-host screen.

The cart runs at 60 fps (`_update60`): fake-08 runs a 30 fps cart's update on
every other frame and can miss a button press that starts on the skipped one.

| Byte | Meaning |
| --- | --- |
| 0 | state: 0 idle, 1 request (cart), 2 working (app), 3 reply ready (app) |
| 1 | command |
| 2 | request: chunk index wanted (command `more`) |
| 3 | payload length (0–120) |
| 4 | reply flags: bit 0 more chunks follow, bit 1 error |
| 5 | sequence number, 1–255, set by the cart per request; the app echoes it |
| 6–7 | reserved, 0 |
| 8–127 | payload: text, bytes 32–126 plus tab and newline |

The cart writes the payload, length, command and a new sequence number, then
state 1. The app handles a request only when the sequence number differs from
the last one it handled, writes state 2 at once, and state 3 with the first
chunk of the reply when done. A reply longer than 120 bytes is split; the cart
asks for chunk *n* with `more`. All text the app sends is lowercased (PICO-8
draws lowercase as its normal letters) and anything outside 32–126 becomes `?`.
Fields are tab-separated, records newline-separated.

| Command | Request payload | Reply |
| --- | --- | --- |
| 1 hello | — | `online` 0/1 (BBS permitted and client present) |
| 2 local | `all` or `fav` | records `id, title, author, fav 0/1` |
| 3 bbs | `f <page>`, `n <page>` or `s <page> <text>` | first line `more 0/1`, then records `index, title, author, id` (library id, or `-` when not in the library) |
| 4 get | `<index>` of the last BBS list | `ok <id>`, `dup <id>`, or error flag + message |
| 5 run | `<id>` | `ok`, then the app ends the session and plays it |
| 6 fav | `<id>` | new favourite state 0/1 |
| 7 more | — (chunk index in byte 2) | that chunk of the last reply |

`author` is the BBS credit (`credits.json`) when there is one, else empty.
Unknown commands and bad arguments reply with the error flag and a short
message (`bad request`, `unknown command`, `not in your library`, or the
BBS client's message). `bbs` and `get` with the browser off reply `offline`
with the error flag. With the browser on but no network on the
device (no interface besides loopback has an address, e.g. Wi-Fi not joined)
they reply `no internet: connect to wi-fi` with the error flag, so the status
line says what to do instead of reporting a BBS failure. `run` and `fav` accept PICO-8 library games only. The app
sends at most 200 library carts; BBS lists come a page at a time.

## Cart behaviour

- Tabs across the top, switched with left / right: **library**, **favourites**
  and, only when `hello` says online, **featured**, **new**, **search**.
- Up / down move through the list (it scrolls); the selected row is
  highlighted with title and author below.
- O (Z key) on a library cart: **run** it. On a BBS cart: **download**
  (status line "downloading…"), then the row shows it is in the library; O
  again runs it. A finished download also appears in the app's library at
  once (normal importer and credits, pico8-cart-browser.md).
- X on a library cart toggles **favourite** (a `*`).
- Search: an on-screen letter grid (a–z, 0–9, space, delete, go) driven by the
  D-pad and O; X opens it from the search tab and leaves it. No keyboard
  needed.
- BBS lists with a next page end in **load more**.
- No host (the app does not answer `hello` within 2 seconds): a message that
  Dena Explore needs the Dena.emu app, and nothing else.
- Errors show on the status line; the list stays.

## Acceptance tests

- Runner (`host/runner/runner_tests.cpp`): the RAM mailbox writes before a
  frame and reads the window after; out-of-range windows and writes are
  ignored.
- Runtime + cart (`host/tests/pico8_launcher_tests.c`, needs the fake-08
  core): the cart sends `hello` in its first frames; answered with online 0
  and a two-cart `local` reply it draws the library list (golden frame hash);
  pressing O sends `run` with the first cart's id; online, left twice reaches
  **new** and sends `bbs n 1`, O on a listed cart sends `get`, the row shows
  it added (golden), and O again sends `run` with its new id; without a host
  it shows the no-host screen (golden).
- App (`test/carts/launcher_host_test.dart`, fake GPIO port, fixture-backed
  fake BBS client, in-memory database): hello online/offline; local lists all
  and favourites with credits; chunking of long replies; bbs and get are
  refused offline; with the browser on, a `get` imports the cart so it is in
  the library database and credited, a second `get` says `dup`; fav toggles;
  run calls the launch callback with the game; stale sequence numbers are
  ignored; unknown commands reply with an error.
- Widget (`test/carts/cart_browser_test.dart`): the Carts tab shows the Dena
  Explore card in touch and focus modes at every screen size, and tapping it
  opens the launcher; no card without a launcher callback.
