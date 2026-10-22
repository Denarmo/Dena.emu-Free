# Web file manager

Manage the app's files from a browser on the same network, in the Brutalist look
([brutalist-ui.md](brutalist-ui.md) 4.9): the served page uses plain CSS with grid
paper, monospace type, 3 px ink borders, hard shadows and yellow focus, follows the
browser's light/dark preference, and loads nothing from outside. Concept: a phone-hosted web file
manager as seen in other emulator front ends; our own implementation (no code reused).

## Behaviour

- Settings › Files › **Web file manager** opens a page with a "Share files over Wi-Fi"
  switch. On: a `dart:io` HTTP server starts on port 8080 (any free port if taken) and
  the page shows `http://<device address>:<port>` in a big read-only box, a QR code of
  the first address (own encoder in `webfiles/qr_code.dart`: byte mode, level M,
  versions 1–10, always black on white) and a random 4-digit access code.
- The server runs only while that page is open; leaving it or switching off stops it.
- The browser asks for the code once; a session cookie (HttpOnly) is set. New code on every start.
- Folders: **Games** (the library), **Saves**, **States**, **Skins**, **Carts** (the app-support
  sub-folders of the same names).
- Games: one folder per system, one entry per game (title, original file name, size).
  Upload (button or drag and drop, several files, progress per file) runs the normal importer,
  so files are hashed, detected and added to the library; unsupported files are reported.
  Rename changes the title; delete removes the game with its saves and states; download
  returns the ROM under its original file name.
- Other folders: list, open sub-folders, upload, download, rename, delete, new folder.
  Saves and states named by SHA-1 show the game's title.

## Edge cases

- Paths with `..`, backslashes or leading dots are refused (400); nothing outside the folder is reachable.
- Uploads land in `<name>.part` and are renamed when complete; a failed upload leaves nothing.
- No Wi-Fi address: the page says to connect to Wi-Fi.

## Tests

`app/test/webfiles/web_file_server_test.dart`: login, refused without code, folder round trip,
path escape, game upload imported/renamed/deleted.
