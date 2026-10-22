# Spec: Box art

Status: draft (Milestone 2, package 4)

## Purpose

Show each game's cover in the library grid without bundling any images, and
let players pick their own cover.

## Data source (differs from CLAUDE.md, flagged to the user)

CLAUDE.md names a bundled OpenVGDB database. OpenVGDB's repository carries no
licence, so we can't bundle it. Instead:

- **Lookup index (bundled):** generated from libretro-database's No-Intro
  (cartridge) and Redump (PS1, PSP) DATs (CC-BY-SA-4.0) by
  `tools/boxart/build_index.py` at a pinned commit:
  `assets/boxart/index.tsv.gz`, one line per ROM: system, CRC-32, game name
  (about 51 k ROMs, 0.75 MB). The index is credited in the app's licence page
  and in docs/licenses.md; it stays under CC-BY-SA-4.0.
- **Images (never bundled):** fetched on demand from the libretro thumbnail
  server, `https://thumbnails.libretro.com/<system>/Named_Boxarts/<name>.png`,
  where `&*/:\`<>?\|"` in the name become `_`.

## Behaviour

- A card shows, in order: the custom cover, the cached cover, or the tonal
  placeholder while loading / when there is none.
- Lookup is by the CRC-32 stored at import (NES DATs list both headered and
  headerless CRCs, so iNES files match). Redump CRCs are of the `.bin` track
  or `.iso`, so `.chd`, `.pbp` and `.cso` discs rarely match by CRC.
- **Name fallback:** when the CRC is unknown (hacks, re-dumps, compressed
  discs, obscure releases), the file name and then the library title are
  matched against the index, first hit wins:
  1. a disc serial in the name (`[ULUS-10018]`, `SLUS_005.94`; Redump rows
     carry the serial);
  2. a known romhack (`lib/src/library/romhacks.dart`): Polished Crystal,
     Emerald Seaglass, Unbound, Radical Red, Crystal Clear and friends map
     to their base game even when the name doesn't say it;
  3. the title key: lower-case, accents folded (`Pokémon` = `Pokemon`), without extension, `(...)`/`[...]` tags,
     leading or `, The` articles and punctuation, `&` read as `and`;
  4. the hack key: the title key without romhack/version noise (`v1.2`,
     `hack`, `kaizo`, `translated`, `patched`, `... by Author`);
  5. the parent title: the part before ` - ` or `:` (two words or more), then dropping trailing
     words, while at least two words and half the key remain (a hack shows
     its base game's cover);
  6. fuzzy: the closest title key by bigram (Dice) similarity >= 0.8.
  Names sharing the matched key are ranked: the region in the file's own
  tags, then USA, World, Europe, Japan; final releases over beta/proto/
  demo/rev. Up to four are tried in order, so a region missing on the
  server falls back to another.
- **Romhacks:** a known hack's own cover on the thumbnail server (a few,
  such as Glazed or Liquid Crystal, have one) is tried before its base game.
  Titles ending in `Version`/`Edition` also answer to the key without it, so
  `Pokemon Emerald <anything>` reaches Emerald by parent title. When the
  base game's cover stands in for a hack (a table hit, or `hack`/`kaizo` in
  the name, and no CRC match), `art/<sha1>.hack` is written and the card
  shows a small gold **HACK** badge in its corner.
- **Fetched at import:** each newly imported game's cover starts downloading
  in the background as soon as it is added, so the grid shows it without
  waiting. Cards that come into view also request their cover (same cache,
  one download per game).
- **PICO-8:** a `.p8.png` cart is shown as its own cover (its label art);
  nothing is downloaded.
- Covers are cached in `<app data>/art/<sha1>.png` (atomic write). A miss (no
  index entry, or the server answers 404) writes `<sha1>.none` and is retried
  after 7 days. The marker holds the matcher version; markers from an older
  version are ignored, so improvements reach games that missed before. A failed download (offline, timeout, other HTTP error) writes
  nothing and is retried on the next app start. Games matching neither by CRC
  nor by name never touch the network.
- **Choose cover** in the game's details sheet picks an image (PNG, JPEG,
  WebP), copies it to `art/<sha1>.custom.<ext>` and stores the path on the
  game. Deleting a game deletes its covers.

## Acceptance tests

- URL building and escaping; the bundled index resolves a known CRC per
  system format (including PS1 and PSP); title keys and name fallback with
  region preference; serial, hack-key, parent and fuzzy matches (PSP
  `PoPoLoCrois` files); romhacks (Seaglass, Polished Crystal, Unbound,
  Radical Red, Crystal Clear) reach their base game, own art first, badge
  only on stand-ins; next region tried after a 404; old-version miss
  markers ignored; prefetch at import; cache: one download then cached, miss marker and retry, offline failure
  leaves no marker,
  unknown CRC is offline, custom cover wins and is removed with the game.
- Golden: a game card with a cover.
