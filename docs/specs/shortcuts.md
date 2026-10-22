# Spec: Shortcuts and deep links

Status: draft (Milestone 3, package 7)

## Deep link

- `dena://play/<sha1>` opens the app and starts the game whose SHA-1 (40 hex
  digits, any case) matches. Anything else with the `dena` scheme opens the
  app on the library and is ignored.
- Android: an `ACTION_VIEW` intent filter (DEFAULT, BROWSABLE) on the main
  activity for scheme `dena`, host `play`. The shell keeps the newest link
  from the launch intent or `onNewIntent` until Dart takes it
  (`LibraryHostApi.takeLaunchLink`, returns the lower-case SHA-1 or null).
- Dart checks for a link when the library first shows and whenever the app
  resumes. If a game is already running (the library is not the top screen)
  the link is dropped, so a tap can't throw away a session. An unknown SHA-1
  shows "That game is not in your library".

## Home-screen shortcuts

- **Pinned:** the game sheet has "Add to home screen" (Android launchers that
  support pinning). It asks the launcher to pin a shortcut with the game's
  title and cover (box art or custom art, else the app icon) whose intent is
  the deep link. Shortcut id = the SHA-1, so pinning twice updates it.
- **Recent games:** each time a game starts, it becomes the first dynamic
  shortcut (long-press on the app icon), keeping at most four, and the
  launcher is told it was used (`reportShortcutUsed`), which also feeds the
  launcher's own search and suggestions.
- Deleting a game removes its dynamic shortcut and disables a pinned one
  ("Game was removed").

## Later

- Android AppSearch indexing and Assistant App Actions (`shortcuts.xml`
  capabilities) build on the same link; not in this package.

## Acceptance tests

- Kotlin: link parsing accepts `dena://play/<40 hex>` (case-insensitive) and
  rejects other hosts, lengths, extra path segments and non-hex digits.
- Dart: a pending link on first show calls Play with the matching game; an
  unknown SHA-1 shows the message; a link arriving while a session is on top
  is dropped; the game sheet's "Add to home screen" pins the game and says so
  when the launcher can't pin.
- On device (human checkpoint): a pinned shortcut and a recent-game shortcut
  start their game; a `dena://play/...` link from another app does too.
