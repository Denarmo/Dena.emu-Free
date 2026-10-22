# Spec: Handheld UI

Status: draft (Milestone 4, package 1)

## Handheld mode

- On a Linux handheld the SD-card launcher starts the app with
  `DENA_HANDHELD=1`; `detectHandheld()` turns that into `Handheld(enabled:
  true)` at the top of the widget tree. Phones and tablets never set it.
- Handheld mode means no touch: everything works with the D-pad and buttons.
  Screens are designed at 640×480 and 720×720 first (CLAUDE.md §5).
- Handheld GPUs are weak (one-core Mali-G31 at 432 MHz on the H700), so
  handheld mode keeps decorative animations still: the foil sheen does not
  sweep. Everything else looks the same.

## What handhelds hide

Parity with Android minus what has no meaning without a touch screen or
Android:

- No touch skin in games, ever: the session starts and stays with the plain
  picture, a tap or a controller disconnect does not bring a skin back, and
  touch mode is off. The pause sheet lists "Built-in controls" as player 1
  (the launcher reports no players).
- Tabs: Games / Carts / Settings (no Apps tab: no other apps to launch, and
  the media players use Android's media store).
- Settings hides Skins, Audio latency (ALSA keeps fixed periods), the Latency
  test and the home-launcher tile; shader sheets hide the internal
  resolution row (the launcher draws at native resolution).

## Buttons (all platforms)

- A activates the focused control (Flutter's default for gameButtonA).
- **B goes back everywhere:** it pops the top route (a sheet, a dialog or a
  page) and does nothing on the root screen. In a running game the
  controller belongs to the game; B only reaches the UI while the pause
  sheet is open, where it resumes.
- Y opens a game's details (library grid), L1/R1 switch tabs (M2).
- Menu, Start and Select do nothing in the library; Menu opens the pause
  sheet in a game (the embedder calls `onMenuRequested`).

## Focus

- Something always has focus: the first game at start, and the first item
  of the new tab after L1/R1 (Carts: Dena Explore; Settings: Brightness on a handheld card, else Theme). Sheets, dialogs and
  pages focus their first or current choice (a delete asks with focus on
  Cancel).
- Held D-pad directions repeat (KeyRepeatEvent, 400 ms then every 80 ms);
  each repeat moves focus one item and the list scrolls it into view.
- The D-pad never gets stuck: on handhelds it leaves text fields (there is
  no keyboard to move their cursor), up/down leave the Brightness slider
  (left/right change it), and in radio lists (Theme, Audio latency, Skins)
  it moves between choices while A picks one.

## Button-hint bar

- In handheld mode a 30 px bar at the bottom lists what the buttons do, with
  button glyphs: Games and Carts "A Play, Y Details, L1/R1 Tabs"; Skins "A
  Choose, L1/R1 Tabs" (phones only); Settings "A Open, L1/R1 Tabs"; pause sheet "A Select,
  B Resume". With a navigation rail (≥600 px, every handheld) it replaces
  the empty bottom bar; on narrow screens the bottom navigation bar stays.

## Device settings

- Settings starts with a Device section on handhelds running from a card
  with the power daemon: Brightness, 5-100 % in steps of 5, changed by
  D-pad left/right, applied at once through the daemon.
- Kept in `Dena/user/settings.json` (survives updates, sd-card.md), written
  one at a time through a temporary file; unknown keys are kept, a damaged
  file means defaults (brightness 100 %). Sent to the daemon at start.
- Volume waits for the embedder's ALSA mixer (embedder.md); Wi-Fi and time
  depend on each stock firmware and wait for the devices.

## Network

- At startup the launcher probes for Wi-Fi hardware: a PHY in
  `/sys/class/ieee80211` or an interface with `/sys/class/net/*/wireless`
  (`detectWifiHardware`, `shell/network.dart`). Phones always count as
  online. The result is the `NetworkScope` the UI reads.
- Without Wi-Fi hardware these stay out of the UI, so the D-pad never lands
  on a dead entry: Your server (RomM), the Web
  file manager (the Files label goes too unless USB storage is there), the
  Dena Explore and Browse the BBS cards in Carts, RetroAchievements (sign-in
  tile and in-game reporting) and the link cable in the pause sheet. There
  is no update check to hide.

## Wi-Fi

- Settings > Network > Wi-Fi, only on a handheld with Wi-Fi hardware
  (`NetworkScope.wifi`). It drives the wpa_supplicant that dena-net starts
  on `wlan0` with `wpa_cli -p /run/wpa_supplicant -i wlan0`
  (`shell/wifi.dart`); networks live in `Dena/user/wpa_supplicant.conf`
  (single-card.md) and every change ends with `save_config`.
- The page scans on open and refreshes every 3 s: the connection (state,
  name, address), the networks around (one row per name, strongest first,
  signal bars, lock when a password is needed; hidden networks left out) and
  the saved networks. "Look for networks" has focus.
- A on a network: connected says so; saved or open joins it; secured opens
  the on-screen keyboard for the password (8 to 63 characters). New
  networks are added with a hex SSID and a quoted passphrase, then
  `select_network` and `enable_network` for the other saved ones so they
  stay usable. A on a saved network: Connect, New password or Forget.
- No control socket (wpa_supplicant didn't start): "Wi-Fi isn't running".

## On-screen keyboard

- Full-screen page for text entry by D-pad (`ui/onscreen_keyboard.dart`):
  the text (dots for a password, Show toggles), number and letter rows,
  then Shift, ?123, Space, Delete, Done. Q has focus. A types, X deletes,
  Y space, L1 shift (one letter), R1 symbols, START or Done accepts, B goes
  back without text. Done is disabled until the text is acceptable, with a
  hint underneath.

### Every text field

A on any focused text field (cheat codes, sign-ins, server addresses,
searches) opens the keyboard with the field's text, titled with its label;
Done writes the text back and fires the field's change, and its submit when
the field's action is search, done, go or send. B leaves the field unchanged.
Renaming a game opens the keyboard directly instead of a dialog.

## USB storage

- Settings > Files > USB storage, only on the single-card system (the app
  is the handheld launcher and `/usr/lib/dena/system/dena-usb-storage`
  exists; the stock-firmware boot hook has no session to come back to) on
  a handheld with a USB device controller (`/sys/class/udc` not empty).
- Opens a confirmation page: connect a USB-C cable; Dena.emu closes and the
  games card shows up on the computer as a drive; eject it, unplug the
  cable or press the power key to come back, or wait 2 minutes with no
  computer. "Start USB
  storage" has focus; B or Cancel goes back.
- Start writes `/run/dena/usb-storage`, closes the library database and
  exits with status 0; dena-session does the rest (single-card.md). If the
  file can't be written the page says so and stays.

## Acceptance tests

- B closes a bottom sheet, then a page, and leaves the root alone.
- Handheld shell: R1 goes Games, Carts, Settings and wraps; Settings shows no
  Skins, Audio latency or Latency test. Handheld session: no `SkinView`
  before or after a tap, touch mode off, "Built-in controls" in the sheet.
- Buttons only at 640×480 (`handheld_navigation_test`): focus and ring at
  start, held arrows scroll the grid, out of the search field, Y details /
  B close, rename and delete dialogs, L1/R1 through every tab, Brightness
  and Theme by D-pad and A, Menu/Start/Select harmless, pause sheet focus
  and B resumes.
- Network (`network_test`): the probe on fake sysfs trees; offline, Settings and Carts show none of the online features.
- Wi-Fi (`wifi_test`): parsing `scan_results` and `list_networks`, SSID
  escapes, the wpa_cli command sequence for new, saved and open networks,
  typing a password by D-pad and joining, Done waiting for 8 characters,
  Settings showing Wi-Fi only with a control.
- Golden: handheld library (rail + hint bar) and handheld pause sheet at
  640×480 and 720×720 in focus mode; the hints follow the selected tab.
- `detectHandheld()` is false off a handheld.
- Device settings (`device_settings_test`): file location, defaults,
  damaged file, unknown keys kept, D-pad slider sends and saves.
- USB storage (`usb_storage_test`): hidden without the helper, without a
  USB device controller or off a handheld; the tile and page work by D-pad; A on Start writes the request,
  runs the close hook and exits 0; B goes back without writing; a request
  that can't be written shows the error and does not exit.
