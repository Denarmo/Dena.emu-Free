# Apps tab and home launcher

## Behaviour
- Bottom navigation is Games / Carts / **Apps** / Settings. Skins moved to
  Settings → Appearance → Skins (same page as the old tab).
- Apps tab: a **Built-in** section (apps shipped inside Dena.emu), then
  **Installed**: every launchable app on the device (MAIN/LAUNCHER), shown in
  one `BrutalTable` (icon tile, name, package, `[OPEN]`) sorted by label, built-in
  apps pinned on top, Dena.emu itself excluded. A / tap on a row launches.
  D-pad navigable, first row focused at start (brutalist-ui.md 4.8).
- Built-in apps come from `builtInApps()` in `app/lib/src/apps/builtin_apps.dart`.
  Adding one is one list entry (`BuiltInApp(id, label, icon, builder)`); it opens
  on the named route `apps/builtin/<id>` (`openBuiltInApp`, or `pushNamed`, resolved
  by `MaterialApp.onGenerateRoute`).
- Settings → Launcher → "Set Dena.emu as home launcher" (Android only): enables
  the disabled-by-default `HomeAlias` (MAIN/HOME/DEFAULT on MainActivity), then
  requests `RoleManager.ROLE_HOME` on Android 10+, else opens
  `Settings.ACTION_HOME_SETTINGS`. The subtitle shows whether Dena.emu is home,
  re-checked on resume.
- Platform bridge: method channel `app.dena/apps` (`list`, `launch`, `isHome`,
  `requestHome`); lifecycle only, never the hot path.

## Edge cases
- No platform (tests, Linux, iOS): Installed shows "No apps to show"; the
  launcher option is hidden.
- App uninstalled before launch: snackbar "Could not open <label>".

## Acceptance tests
- `app/test/apps/apps_tab_test.dart`: built-ins and fake installed apps render
  and launch; goldens at phone and 640×480, touch and focus.
