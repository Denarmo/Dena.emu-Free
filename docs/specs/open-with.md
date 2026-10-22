# Spec: Open a game from outside the app (Windows, desktop Linux)

Status: implemented (thread "Open games passed on the command line"); first
real run in the next desktop test pass. Builds on the Windows packaging
("Open with" entries, `tools/release/windows/dena-emu.iss`) and the Flatpak
desktop entry (`tools/release/linux/io.github.denarmo.DenaEmu.desktop`).

## Behaviour

- A launch names a game file when its first argument that is not a flag
  (not starting with `-`) is a path or a `file://` URI. This covers Windows
  "Open with" and double-click (`"Dena.emu.exe" "%1"`), the Flatpak's file
  handler (`Exec=dena-emu %f`; `flatpak run --file-forwarding` hands over a
  document-portal path) and `dena_emu <path>` from a terminal. A relative
  path resolves from the working folder.
- The app starts as usual, then launches straight into that game with the
  normal launch sequence (box opens, core starts underneath).
- The game joins the library **in place** if it is not there yet: only that
  file, not its folder, and no copy (a `.zip` is unpacked into the library
  as any import). A file already in the library by path, or the same game
  (SHA-1) at another path, opens the library entry. Deleting it from the
  library later keeps the file, as for watched folders.
- A missing file or one that is not a supported game shows a snackbar
  ("Could not find X", "X: Not a supported game file") and the library
  stays as it was.

## One instance

The app runs once per user. A second launch hands its file to the running
window and exits; without a file it only raises the window.

- If a game is running it ends as its Quit does (pause menu or sheets close,
  the core saves, play time is recorded), then the opened game starts. Dena
  Explore does not reopen over it. Opening the game that is already
  running only raises the window; the game keeps running.
- Windows: a named mutex `Local\io.github.denarmo.DenaEmu`; the second
  process finds the window carrying the `DenaEmu.Instance` property, sends
  the full path as `WM_COPYDATA` (UTF-16, tag `0x44454E41`) and brings the
  window to the front. If the window does not appear within 2 s it starts
  as its own instance.
- Linux: a unique `GtkApplication` (`G_APPLICATION_HANDLES_OPEN`) on the
  session bus under the app id; the second launch calls
  `g_application_open`. Without a session bus every launch is its own
  instance.
- Both runners pass the file to Dart as `openFile(path)` on the
  `dena/window` channel.

## Code

`app/lib/src/desktop/open_with.dart` (`gameArgument`, `OpenedFiles`,
`openGameFile`), `AppShell.opened` and `endRunningGame` in
`app/lib/src/shell/app_shell.dart`, `quitActiveSession` in
`app/lib/src/session/session_screen.dart`, the runners' `main.cpp` /
`flutter_window.cpp` and `my_application.cc`.

## Edge cases

- Flatpak: the document portal exposes only the opened file, so a `.cue`
  or `.m3u` whose tracks lie beside it cannot load its tracks; add the
  folder in Settings instead. Single-file games work.
- Windows: one instance per user session, also across a portable copy and
  an installed copy (they share the mutex name).

## Acceptance tests

Unit tests in `app/test/desktop/open_with_test.dart`: argument parsing
(flags, `file://`), the open queue and channel, adding in place (only the
file), the same game at another path, relative paths, missing and
unsupported files, and the shell playing the launch file and a later file
(closing pages on top). Device checks: `/mnt/project-files/desktop/open-with-verify.md`
(project files).
