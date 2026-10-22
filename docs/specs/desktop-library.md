# Spec: Desktop library (Windows and Linux PCs, Steam Deck)

Status: implemented in code (thread "Desktop library, storage and sync");
first run on DENA-PC in the combined desktop test pass. Storage folders and
portable mode are in [desktop-shell.md](desktop-shell.md) (Storage).

## Behaviour

On a PC the user's games stay where they are. Nothing is copied into the
data folder, except games downloaded from RomM (`<data>/games`, as on
Android).

### Native dialogs

`DesktopGameFiles` (`app/lib/src/library/desktop_files.dart`) uses the
system's own dialogs through `file_selector_windows` / `file_selector_linux`
(Windows' file dialog; GTK's chooser, which is the file-chooser portal inside
the Flatpak). Add games, cart import and skin import open the file dialog;
the picked files are the user's own, so `clearCache` deletes nothing. If the
folder dialog can't start, Add a folder falls back to the in-app explorer
(one-time import).

### Watched game folders

`GameFolders` (`app/lib/src/library/game_folders.dart`), kept in
`<data>/folders.json` as `{"folders": [...], "ignored": [...]}`.

- **Add a folder** (Games tab button, or Settings › Files › Game folders ›
  Add a folder) picks a folder, adds it to the list and scans it.
- A scan walks the folder (hidden files and folders skipped) and adds each
  supported game in place (`importInPlace`; zips are extracted into the
  data folder because cores read the ROM). Paths already in the library are
  not hashed again. Games under the folder whose file is gone leave the
  library (their saves and states stay, so re-adding the file brings them
  back); not when the folder itself is missing (unplugged drive).
- A folder inside a watched one is only rescanned; a folder holding watched
  ones replaces them.
- All folders are scanned at start-up in the background, then watched:
  Windows natively for the whole tree, Linux with one inotify watch per
  folder (new folders get one as they appear; at most 4096). A change
  rescans that folder after 2 s of quiet.
- **Remove** (Settings › Files › Game folders, bin button) stops watching and
  takes the folder's games out of the library; the files stay.
- **Scan again** rescans every folder.
- **Portable mode:** `Dena/Roms` beside the executable (sd-card.md layout)
  is always a watched folder and can't be removed.

### Deleting a game

Delete removes the game, its saves and its states, as on Android. A ROM
outside the data folder (a user's file in a game folder or picked with Add
games) stays on disk; the path is added to `ignored`, so rescans don't add
it back. Adding its folder again clears that folder's `ignored` entries.

### RomM

Unchanged from Android and free (romm.md): Settings › RomM shows on a PC
whenever the network is available.

## Tests

`app/test/library/game_folders_test.dart`: in-place add and persistence,
nested folders, watch-triggered rescan (add and prune), unplugged folder,
delete keeps the user's file and stays ignored, remove, portable Roms
folder, folder file listing.
