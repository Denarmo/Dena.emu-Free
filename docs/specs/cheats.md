# Spec: Cheats

Status: draft (Milestone 2, package 9)

## Purpose

Let players add cheat codes per game and switch them on and off while
playing. The cores apply the codes (libretro `retro_cheat_set`); we store,
validate and pass them.

## Formats (detected from the code's shape)

Each cheat holds one or more lines (multi-line codes such as GBA master codes);
every line must match one format of the game's system. Spaces and dashes in
the input are normalised as below; letters are upper-cased.

| System | Format | Shape |
| --- | --- | --- |
| nes | Game Genie | 6 or 8 letters of `APZLGITYEOXUKSVN` |
| nes | Raw | `AAAA:VV` or `AAAA?CC:VV` (hex) |
| snes | Game Genie | `XXXX-XXXX` (hex) |
| snes | Pro Action Replay | `XXXXXXXX` (8 hex) |
| gb, gbc | Game Genie | `XXX-XXX` or `XXX-XXX-XXX` (hex) |
| gb, gbc | GameShark | `XXXXXXXX` (8 hex) |
| gba | GameShark / Action Replay | `XXXXXXXX YYYYYYYY` (8 + 8 hex) |
| gba | CodeBreaker | `XXXXXXXX YYYY` (8 + 4 hex) |

The lines of one cheat are joined with `+` when passed to the core (the
libretro convention). A code whose lines don't all match is rejected with
"This doesn't look like a <system> code" and is not saved.

## Storage

Drift table `cheats` (schema v2): id, game id, name, code (normalised lines
joined by `\n`), format label, enabled, created at. Deleting a game deletes its
cheats (in the same transaction).

## Behaviour

- Pause sheet gains **Cheats**: a sheet listing the game's cheats with a switch
  each, a delete button, and **Add cheat** (name + code, multi-line).
- Every change sends the enabled codes to the core at once
  (`GameHostApi.setCheats(codes)`: reset, then set each). Enabled cheats are
  applied right after the game starts.
- Cheats live outside save states: loading a state keeps the current switches.
- D-pad: switches and buttons are focusable in order; A toggles, B closes.

## Native API

- Host: `dena_core_cheats_reset(core)`, `dena_core_cheat_set(core, index,
  enabled, code)`, wrapping the core's functions (no-ops when missing).
- Runner: `set_cheats(codes)` on the emulator thread between frames.

## Cheat database (browse)

Players can pick cheats for the running game from a public cheat collection
instead of typing codes.

### Source

- libretro-database `cht/` (CC-BY-SA-4.0), pinned to the same commit as the
  box-art index (`12c21cf7…`). Systems: nes, snes, gb, gbc, gba, n64, nds,
  psx, psp.
- **Index (bundled):** `assets/cheats/index.tsv.gz`, built by
  `tools/cheats/build_index.py`: one line per cheat file, `system<TAB>file
  name without .cht`. Only the names are bundled (about 21 k files, a few
  hundred KB); the files themselves (about 160 MB) are not.
- **Files (on demand):** downloaded from
  `https://raw.githubusercontent.com/libretro/libretro-database/<commit>/cht/<folder>/<file>.cht`
  and cached in `<app data>/cheats/<system>/<file>.cht` (atomic write). The
  commit is pinned, so cached files never go stale. A download failure is not
  cached; the browser shows "Couldn't download cheats" with **Retry**.

### Matching the running game

1. The game's canonical name comes from the box-art index (CRC-32, then
   `nameForFile`), else its file name without extension.
2. Candidates are files whose *key* equals the game's key. The key is the
   name without `(…)`/`[…]` tags, lower-cased, letters and digits only.
3. A file's base name drops a trailing device tag (e.g. `(Game Genie)`,
   `(Code Breaker)`, `(GameShark)`). Keep the candidates whose base shares the
   most tags with the game's name (`USA`≈`US`, `Europe`≈`EU`, `Japan`≈`JP`);
   ties keep all. So `Zelda (USA)` gets `Zelda (USA)` and `Zelda (USA,
   Europe) (Game Genie)` but not `Zelda (Japan)`.
4. All matched files are merged in file-name order. Unknown systems and games
   with no match show "No cheats for this game in the database" without
   touching the network.

### Parsing `.cht`

- `cheatN_desc` / `cheatN_code` (quoted values, `cheats = N` header,
  `cheatN_enable` ignored). Codes are split on `+` (PSP: on `_L` entries).
- Skipped: empty codes and codes containing `?` (they need a value typed in).
- Each cheat is passed through the validator above; if it validates, its
  normalised form and format label are stored, else the raw lines and the
  file's device label (or "Database").

### Popular

There is no public usage data, so "popular" is a heuristic: each description
is scored by the first matching category below (case-insensitive), minus 10
for player-2-only cheats (`P2`, `player 2`, `2P`). Cheats scoring 0, and
master/enabler codes, are never popular. The top 5 by score form **Popular**
(ties keep file order).

| Score | Category | Keywords |
| --- | --- | --- |
| 100 | Infinite health | infinite/unlimited/max + health, HP, energy, life (not lives) |
| 95 | Invincibility | invincib, invulnerab, god mode, no damage |
| 90 | Infinite lives | infinite/unlimited + lives / men |
| 85 | Money | infinite/max + money, gold, coins, cash, rupees, gil, zenny |
| 80 | Ammo / magic | infinite/unlimited + ammo, bullets, magic, MP, bombs, weapons |
| 75 | Unlock all | all items, all weapons, have all, unlock all, all levels, level/stage select |
| 70 | Stats / XP | max stats, max level, experience, exp |
| 60 | Time | infinite/stop time, timer |
| 55 | Movement | moon jump, super jump, walk through walls |
| 50 | One-hit kills | one hit kill, 1 hit kill |

Master codes: descriptions containing `must be on`, `master code`, `enable
code`, `enabler` or `(m)`.

### Behaviour

- The Cheats sheet gains **Browse** (tonal, next to **Add cheat**), opening
  the **Cheat database** sheet: search field, **Popular** (hidden while
  searching), then **All cheats (N)** filtered by the search text. Each row is
  a switch with the description and format.
- A switch is on when the game has an enabled cheat with the same name and
  code. Turning one on adds it to the game's cheats (or re-enables the
  existing one) and also turns on the file's master codes; turning it off
  deletes it. Every change sends the enabled codes to the core at once, as
  above. The cheats list behind updates live.
- Footer credit: "Cheats from libretro-database (CC-BY-SA 4.0)".
- D-pad: the first popular (else first) switch takes focus; Up reaches the
  search field; B closes.

### Acceptance tests (browse)

- Parser: header, quoted values, `+` splitting, PSP `_L` splitting, skips `?`
  and empty codes; validator fallback keeps raw lines.
- Matching: exact name, device suffix, loose key with region preference,
  unknown game; ranking order, P2 penalty, master codes excluded.
- Cache: one download then cached; failure is not cached; no network for
  unmatched games.
- Sheet: loading, empty, error + retry; enabling adds the cheat and its master
  code and calls `setCheats`; disabling deletes; search filters and hides
  Popular; goldens at the matrix sizes.

## Acceptance tests

- Host: the test core understands the cheat `REDSQUARE` (square drawn red);
  enabling it changes the frame hash, resetting restores it.
- Dart: the validator accepts and normalises each format above and rejects
  wrong shapes per system; database round trip and cascade delete; the cheats
  sheet adds, toggles (calls `setCheats` with the enabled codes) and deletes;
  goldens at the matrix sizes.
