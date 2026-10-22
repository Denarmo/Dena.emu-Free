# Spec: In-app file explorer

Status: implemented (handheld feedback, 2026-10-17; Android phones, 2026-10-18)

## Purpose

"Add games" and "Add a folder" open a file explorer so the user picks what to import.
The Linux handheld has no system picker, so the app ships its own explorer.

On Android the explorer is the main path too: on a POCO F7 Ultra (Android 16, HyperOS 3)
the system picker showed the games folder as "No items" and refused it as a folder
("Can't use this folder"), although the files were there. So:
- With All files access (`MANAGE_EXTERNAL_STORAGE`, Android 11+; `READ_EXTERNAL_STORAGE`
  on 8-10) both actions open the explorer.
- Without it, the first Add of the run shows **FILE ACCESS**: ALLOW opens Android's All
  files access page for Dena.emu (the permission dialog before Android 11), then the
  explorer if access was turned on. SYSTEM PICKER, or coming back without turning it on,
  uses the system document picker (library.md, Import) and is not asked again until the
  app restarts.
- The system picker still falls back to the explorer when it is missing (no
  DocumentsUI, e.g. some TV boxes) or fails to start.

Play Store: All files access needs the Permissions Declaration Form at submission
(core purpose: importing user-owned game files from any folder); the picker path keeps
the app usable if it is not approved.

## Where it browses

Roots, shown as a list when there is more than one:
- **Handheld**: the games card (`$DENA_CARD`, opened at `Roms/` when it exists) and
  every other mounted block device from `/proc/mounts` (`/dev/sd*` USB drives,
  `/dev/mmcblk*` second card slot, `/dev/nvme*`), except `/`, `/boot*` and the card.
- **Android fallback**: shared storage (`/storage/emulated/0`) and any other volume
  under `/storage`.

Folders the app cannot read show "Can't open this folder".

## Behaviour

- Folders first, then files, case-insensitive by name; hidden entries (dot names) are
  left out.
- Files are filtered to the import extensions (`importExtensions`, `.p8.png` included).
  Y (or the filter button) toggles "All files".
- **Add games**: A on a file toggles its check mark; X checks or clears every file in
  the folder. Start, Select or the "Add N games" button imports the checked files, which
  may come from several folders.
- **Add a folder**: A opens folders; Start, Select or "Use this folder" imports every
  matching file under the open folder (recursive, up to 8 levels, at most 5000 files).
- B goes up a level; at the top it closes the explorer without importing.
- The last open folder is remembered in `<data>/explorer.json` and reopened next time if
  it still exists under a current root.
- The result goes through the same `importPaths` as the system picker. Files are copied
  into the library, so games from a USB drive keep working after it is unplugged.

## D-pad and focus

The first entry has focus when a folder opens; the focus ring is the theme's. The
button-hint bar on handhelds shows A, B, X/Y and START for the current mode.

## Tests

`test/library/file_explorer_test.dart`: mount parsing and roots, listing order and
filter, recursive folder collection, remembered location, widget flows for both
modes (D-pad keys and phone-size touch), and the Android access choice (granted,
ALLOW, SYSTEM PICKER asked once, refused).
