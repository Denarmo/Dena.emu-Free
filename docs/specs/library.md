# Spec: Game library

Status: draft (Milestone 2, package 3)

## Purpose

Keep the user's games in one place: import them, recognise their system, show them
as a box-art grid, and get back to the last game in one tap. Dart-only; storage is
Drift (SQLite) in app-private storage (CLAUDE.md §3).

## Data model (Drift)

`games`
| Column | Type | Notes |
| --- | --- | --- |
| id | int, PK | |
| system | text | `nes`, `snes`, `gb`, `gbc`, `gba`, `genesis` (more in M3) |
| title | text | from the file name, cleaned (see below); user-editable |
| file_name | text | original name |
| path | text | app-private copy: `<files>/games/<system>/<sha1>.<ext>` |
| sha1 | text, unique | of the ROM content (inside the zip if zipped) |
| size | int | bytes |
| crc32 | text | for OpenVGDB matching (package 4) |
| added_at | datetime | |
| last_played_at | datetime? | |
| play_seconds | int | default 0 |
| favorite | bool | default false |
| custom_art_path | text? | package 4 |

Schema version 1, with migrations tested from the start (Drift `schemaVersion` plus a
migration test per version).

## Import

Sources: the system file picker (SAF `OpenMultipleDocuments`), the Android share sheet
(`ACTION_SEND` / `ACTION_SEND_MULTIPLE`) and a whole folder (`OpenDocumentTree`, scanned
recursively). Quick Share arrives through the share sheet. On Android, Add games and
Add a folder open the in-app file explorer once the user grants All files access, and
the system picker otherwise; without a system picker (the Linux handheld, or Android
without DocumentsUI) both open the explorer ([file-explorer.md](file-explorer.md)).

For each file:
1. Read the extension. `.zip` → read the central directory and pick the single entry
   with a known extension; zips with none, or several, are rejected with a reason.
   A zip holding `.cue` (or `.gdi`) sheets is a zipped disc on every platform: each
   sheet and the tracks it names are unpacked (in a background isolate) and added
   like a picked `.cue`, one game per sheet, so a multi-disc zip adds each disc. A
   track the sheet names that the zip lacks rejects it with "The zip is missing
   <track>, which its .cue names". A zip the library already has (same sheet name
   and first-track CRC-32 from the zip's directory) is a duplicate without being
   unpacked, so folder rescans stay quick. A zip of `.bin` tracks without its sheet
   is refused with a hint to add the `.cue`.
   (`.chd`, `.cue`, `.iso`, `.cso`, `.p8.png` are Milestone 3 systems. `.m3u` playlists
   are refused for now; multi-disc comes later, [psx.md](psx.md).)
   A `.cue` copies the sheet and every track its `FILE` lines name into
   `games/<system>/<sha1>/`; a track missing beside it rejects the sheet with its name.
   When a batch holds a `.cue` and its tracks, the tracks are skipped instead of being
   refused one by one; a `.bin` alone that is a disc track is refused with "add the
   game's .cue". On Android the system picker and the folder import copy the picked
   files of one pick (or one source folder) into one cache folder, so the tracks stay
   beside the sheet.
2. Detect the system from the extension: `.nes` nes; `.sfc`/`.smc` snes; `.gb` gb;
   `.gbc` gbc; `.gba` gba; `.md`/`.gen`/`.smd`/`.bin` genesis. For `.bin`, also require
   the Genesis header text `SEGA` at offset 0x100; otherwise reject it as unknown.
3. Check the content, so a renamed text file is not taken for a game (one rule set for
   every Add flow, the folder scanners and Open with: `romContentLooksValid` in
   `import_rules.dart`). An empty file always fails. Then, per system:
   - NES: `NES\x1a` at offset 0.
   - GB/GBC: at least 0x150 bytes and a correct cartridge header checksum (0x14D).
   - GBA: fixed byte 0x96 at 0xB2 and a correct header complement (0xBD).
   - SNES: at least 32 KB (after a 512-byte copier header) and not plain text (SNES has
     no magic number and many homebrew ROMs carry a wrong checksum).
   - N64: one of the three byte orders of `80 37 12 40` at offset 0.
   - DS: a correct header CRC-16 (0x15E) or the fixed logo CRC `CF56` (0x15C).
   - PS1 `.chd`: `MComprHD`; `.pbp`: `\0PBP`. PSP `.iso`: `CD001` at 0x8001; `.cso`:
     `CISO`. PICO-8 `.p8`: starts with `pico-8 cartridge`; `.p8.png`: the PNG signature.
     Saturn and Dreamcast `.chd`: `MComprHD`; Dreamcast `.cdi`: not text;
     their `.cue`/`.gdi` sheets pass once their first track was read
     (dreamcast-saturn.md). GameCube and Wii discs: their header for the
     extension (`.iso` magic words, `CISO`, GCZ, WIA/RVZ, `WBFS`); `.dol` not
     text, `.elf` PowerPC (gamecube-wii.md).
     (dreamcast-saturn.md). PS2 `.chd`: `MComprHD`; `.cso`: `CISO`; `.iso`:
     `CD001` at 0x8001; `.cue` passes once its track was read (ps2.md).
   - A zip is checked on its chosen entry. Other formats pass on the extension.
   A file that fails is rejected as "Not a supported game file" and nothing is added.
   Games already in the library are never re-checked.
4. Hash (SHA-1, CRC32) while copying into app-private storage. Same SHA-1 already in the
   library → skip as a duplicate; nothing is copied.
5. Title: file name without extension, then strip bracketed tags `(...)` and `[...]`,
   collapse whitespace; keep the original in `file_name`.

Import runs in a background isolate, shows progress in a snackbar
("Importing 3 of 12"), and ends with a summary: added, duplicates, rejected (with
reasons available in a sheet). Cancelling keeps what was already imported.

## Screens

- **Games** tab: adaptive grid of cards (box art, or a tonal placeholder with the
  system's short name and the title). Columns: 3 at 640 px wide, growing to fit about
  150 px per card.
- **Filter chips** row: All, then one chip per system that has games. Chips are
  single-select.
- **Search**: a search bar above the grid filters by title (case- and
  diacritic-insensitive substring) as you type.
- **Continue playing**: when there is a last played game, a wide card above the grid
  resumes it.
- **Long-press** a card (or press Y / Menu on a gamepad) → preview bottom sheet: art,
  title, system, play time, last played; actions Play, Rename, Favourite, Share, Delete
  (asks for confirmation; deletes the copy, its saves and states).
- **Empty state**: an illustration, "Add games" (opens the picker) and "Add a folder".
- Sort menu: Recently played (default), Title, Recently added.

## D-pad and focus

Every control is reachable with the D-pad: grid cells are focusable in reading order,
L1/R1 move between filter chips, A opens the game, Y opens the preview sheet, B leaves
search or closes the sheet. The focus ring is clearly visible (see app-shell.md).

## Edge cases

- Files the app loses permission to after import are fine: we play the private copy.
- Very large libraries (5,000 games): the grid is lazy, search runs on an indexed
  lower-cased title column, and the first frame of the Games tab must not wait on a
  full table scan.
- A corrupt zip, an unreadable file, or a full disk ends that file with a reason; the
  rest of the batch continues.

## Acceptance tests

- Unit: system detection table (every extension; `.bin` with and without `SEGA`),
  title cleaning cases, zip entry selection, duplicate detection by SHA-1, zipped
  cue/GDI sets (cue_import_test.dart).
- Drift: in-memory database tests for insert, search, filters, sort, delete
  cascading to saves/states; migration test harness in place for version 1.
- Widget/golden: Games tab empty, with 3 games, with 40 games, searching, the
  preview sheet; each at 640×480, 720×720 and phone, touch and focus modes
  (ui-test-harness.md).
- D-pad: from the first card, arrows reach every card and the chips; A opens; Y
  opens the sheet; B closes it.
