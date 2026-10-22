# ROM manager: hash check, conversion, scraping

Desktop feature "Built-in ROM manager and scraper" (desktop features proposal,
approved by the owner). Watched folders shipped in #88 (desktop-library.md);
this spec covers the rest. Free tier everywhere.

| Part | Windows / SteamOS | Phone | Handheld |
| --- | --- | --- | --- |
| Hash check against No-Intro / Redump DATs | yes | yes | yes |
| Scraping (OpenVGDB, ScreenScraper) | covers, boxes, back, screenshot, manual, video | covers, boxes, back, screenshot | covers, boxes, back, screenshot (with Wi-Fi) |
| Conversion to CHD / RVZ | yes | no | no |

Code: `app/lib/src/romtools/`. Data: `<dataDir>/romtools/` and
`<dataDir>/scrape/<sha1>/`.

## 1. DAT files (`dat.dart`, `dat_store.dart`)

- Formats: Logiqx XML (`<datafile><header><name>…</name><version>…</version>`
  `</header><game name="…"><rom name size crc md5 sha1 status/></game>`, also
  `<machine>`) and ClrMamePro text (`clrmamepro ( name "…" version … )`,
  `game ( name "…" rom ( name "…" size N crc X md5 X sha1 X ) )`). A `.zip`
  holding one `.dat`/`.xml` is unpacked first.
- Source, by default: libretro-database `metadat/no-intro/<DAT name>.dat`
  (cartridges) and `metadat/redump/<DAT name>.dat` (discs), CC-BY-SA-4.0, at
  the same pinned commit as the box-art index
  (`12c21cf79f1e20eff6ac68b80875816c717d0a7a`). **Update** fetches the same
  file from `master`. Nothing is bundled; a DAT downloads only when the user
  presses GET (or VERIFY with no DAT for that system).
- Import: the user may import their own DAT (No-Intro from datomatic, Redump
  from redump.org). The system comes from the header name (`Nintendo - Game
  Boy`, with or without ` (Parent-Clone)` / date suffixes); unknown headers are
  refused with a message. An imported DAT replaces the downloaded one for that
  system; its source says `imported <file name>`.
- Stored as `<dataDir>/romtools/dats/<system>.dat` plus `<system>.json`
  (`{"system","name","version","source","url","installedAt","games"}`).
- Systems and DAT names (`datSystems`): nes, snes, gb, gbc, gba, nds, n64,
  genesis (No-Intro); psx, psp, saturn, dreamcast, gamecube, wii (Redump).

## 2. Verification (`verify.dart`)

Statuses (`VerifyStatus`), as shown in INSPECT and the filter:

| Status | Label | Meaning |
| --- | --- | --- |
| verified | `VERIFIED` | SHA-1 (or CRC-32 + size) matches a DAT entry |
| badDump | `BAD DUMP` | matches an entry the DAT marks `status="baddump"` |
| modified | `MODIFIED` | the file name names a DAT game but the hash differs (hack, patched, trimmed, bad copy) |
| unknown | `UNKNOWN` | no match by hash or name (homebrew, prototype, hack with its own name) |
| unverifiable | `COMPRESSED` | `.chd`, `.cso`, `.pbp`, `.rvz`: DATs list the raw tracks; a file we converted keeps its source's result |
| noDat | `NO DAT` | no DAT installed for the system |

- Hashes come from the library row (`sha1`, `crc32`, `size`): zips were
  hashed after unzipping, so they match. NES: when the file starts with
  `NES\x1a`, the 16-byte header is also stripped and the rest hashed, so
  headered and headerless DATs both match.
- Results live in `<dataDir>/romtools/verify.json`, keyed by the game's SHA-1:
  `{status, name, source, checkedAt}`. A result is redone when the DAT for the
  system changes (installedAt newer than checkedAt).
- VERIFY ALL runs in the background, one game at a time, with progress.

## 3. Conversion (`convert.dart`), desktop only, manual

- CHD (MAME `chdman`, BSD-3-Clause/GPL-2.0+): `.cue`, `.gdi`, `.toc` →
  `chdman createcd`; PSP `.iso` → `chdman createdvd` (PPSSPP reads CHD).
  RVZ (Dolphin `DolphinTool`, GPL-2.0+): GameCube/Wii `.iso`, `.gcm`, `.wbfs`
  → `DolphinTool convert -f rvz -b 131072 -c zstd -l 5`; offered only for
  systems the app knows (`rvzSystems`), none yet.
- Tools are not bundled yet. Located in order: env `DENA_CHDMAN` /
  `DENA_DOLPHINTOOL`; `<app folder>/tools/`; `<dataDir>/tools/`; `PATH`
  (`chdman(.exe)`, `dolphin-tool`, `DolphinTool(.exe)`). Settings shows where
  each was found or how to get it.
- Off by default: nothing converts on its own. CONVERT in the ROM page, or
  CONVERT ALL in Settings > ROM manager, queues jobs. One job runs at a time,
  with progress parsed from the tool's output (`NN.N% complete`).
- Steps per job: write `.<name>.part` next to the original (hidden, so the
  folder scanner ignores it) → `chdman verify -i` / `DolphinTool verify -i` →
  rename to `<name>.chd` / `.rvz` → point the library row at it (path, file
  name, size; the SHA-1 identity stays, so saves, states, art and the verify
  result follow) → delete the original files (the `.cue` and every track it
  lists) unless KEEP ORIGINALS is on. A failed or cancelled job deletes the
  part file and leaves the original untouched.
- `<dataDir>/romtools/conversions.json` records `{sha1: {from, to, at}}`.

## 4. Scraping (`openvgdb.dart`, `screenscraper.dart`, `scraper.dart`)

- OpenVGDB (MIT): the SQLite release (`openvgdb.zip` from
  github.com/OpenVGDB/OpenVGDB releases, pinned v29.0), downloaded on GET
  into `<dataDir>/romtools/openvgdb.sqlite`. Lookup by SHA-1, then CRC-32,
  then file name; gives title, description, developer, publisher, genre,
  date and front/back cover URLs. Offline once downloaded.
- ScreenScraper (screenscraper.fr) with the user's own account, entered in
  Settings > ACCOUNTS > ScreenScraper and checked with `ssuserInfos.php`.
  The build's developer key comes from `--dart-define=DENA_SCREENSCRAPER_DEVID`
  / `DENA_SCREENSCRAPER_DEVPASSWORD`; without it the row says
  `no key in this build` and only OpenVGDB is used. The password is kept in
  `<dataDir>/romtools/screenscraper.json` in the app's private data folder
  (ScreenScraper has no tokens) and only ever sent to screenscraper.fr. One
  request at a time. Quota errors (HTTP 429/430/431) stop the batch with a
  message; a 404 or "not found" is a miss.
- Media kinds: `cover` (box-2D), `box3d` (box-3D), `back` (box-2D-back),
  `screenshot` (ss), `manual` (manuel, PDF), `video` (video-normalized, else
  video, MP4). Region preference as media_art.dart: the file name's region,
  then us, wor, eu, jp.
- Defaults: scraping is on demand (SCRAPE on the ROM page, SCRAPE MISSING in
  Settings); never automatic, because ScreenScraper has a daily quota.
  Desktop fetches every kind; phone and handheld fetch cover, box3d, back
  and screenshot only (manuals and videos are large).
- Files: `<dataDir>/scrape/<sha1>/<kind>.<ext>` plus `info.json` (title,
  description, developer, publisher, genre, year, players, source). A scraped
  cover becomes the library cover when the box-art cache has none (it is
  copied to `art/<sha1>.png` and the miss marker removed); a custom cover
  always wins.

## 5. UI

- Settings > LIBRARY.CFG > `ROM manager` opens ROMS.CFG pages: DATS.CFG (one
  row per system: name, version, source, GET / UPDATE; IMPORT DAT; VERIFY
  ALL with progress), SCRAPE.CFG (OpenVGDB GET; ScreenScraper account state;
  SCRAPE MISSING with progress), CONVERT.CFG on desktop (tool locations,
  KEEP ORIGINALS, CONVERT ALL, the job list with progress and CANCEL).
- Settings > ACCOUNTS.CFG > `ScreenScraper`: sign in / out, level and today's
  quota.
- Library INSPECT panel (wide desktop): a `DAT` entry with the status label
  and the matched name; `ROM [R]` button opens the ROM page.
- Library filter column: a DAT.CHK group with `Verified`, `Bad` (bad dump and
  modified), `Unknown` and `Unchecked` filters, combined with the system
  filter. Phone: the same chips after the systems.
- The game menu (every device): `ROM check` (letter V) opens the ROM page:
  status, matched DAT name and source, VERIFY, SCRAPE, CONVERT (desktop),
  and the scraped files (desktop opens a manual or video in the system's
  viewer).
- Every control is D-pad operable; Brutalist kit only.

## 6. Acceptance tests

1. DAT parsing: XML and ClrMamePro samples give the same entries; zip
   unpacking; header-name to system mapping; unknown header refused.
2. Matching: SHA-1 hit, CRC+size hit, bad dump, name-only (modified),
   unknown, compressed, no DAT; NES header stripping.
3. Store: download from the pinned URL with a mocked fetch, update from
   master, import replaces, results redone after a DAT change.
4. Conversion runner with a fake process: commands per input, progress
   parsing, verify failure keeps the original and deletes the part, success
   renames, updates the row and deletes the cue and its tracks, KEEP
   ORIGINALS, cancel.
5. ScreenScraper with mocked HTTP: user check, quota error, media pick per
   kind and region, no dev key; OpenVGDB lookup on a small fixture database.
6. Goldens: ROM page and Settings ROM manager page at phone and 1280x720,
   INSPECT panel with the DAT entry at 1280x720.
