# Brutalist UI

The look of the Dena.emu app on phones and tablets, the Linux handheld and
Windows/SteamOS (including controller mode and the TV layout), decided by the owner
on 2026-10-18 (proposal 13 "Brutalist"). It replaces the moulded console look and
Material You (ui-look-and-feel.md, theming.md).

Out of scope: the deltaskins and bundled touch-controller skins, the game picture,
shaders, cores and the host, and the Dena.emu GB fork (it keeps its Pocket LCD UI).

Sections 1 to 5 below are copied from the implementation spec the redesign threads
build from; the foundation (tokens, theme, component kit, fonts, icons) lives in
`app/lib/src/ui/brutal/` and `denaTheme()` in `app/lib/src/app.dart`.

Decisions where the design left a gap: Paper is the default and Ink is offered;
Material You and console palettes are gone, only the Hazard/Gold accent swap remains;
phone rows are 48 px; the table is the default library view with grid and stash kept;
delete is a 1 s hold; Nunito is removed in favour of IBM Plex Mono and Archivo Black;
icons keep their names and code points.

## 1. Principles

1. **Structure is the decoration.** Visible grid paper, thick black borders, hard offset shadows, monospace data. No gradients, blur, glass, grain, rounded corners or soft shadows anywhere in the UI chrome.
2. **Data first.** Show file names, systems, years, play time and progress openly, in aligned monospace columns. The library is a table you can play.
3. **Physical without skeuomorphism.** Buttons are hard rectangles on a solid shadow; pressing moves the button onto its shadow. This replaces the plastic key caps.
4. **Two loud spot colours, used sparingly.** Hazard Yellow marks focus and selection; Electric Blue marks the primary action. Large yellow areas are limited to focus rows and the wordmark block (eye-strain risk noted in the proposal).
5. **Honest text.** Labels in UPPERCASE mono, file-style names (`MOONLIGHT_QUEST`), bracket notation (`[x]`, `[ON]`, `[1X]`, `[#####-----]`), ASCII arrows (`->`, `<-`), and a short log line where actions happen.
6. **Same component kit everywhere.** Phone, handheld and desktop share widgets; only layout and density change.

## 2. Design tokens

Put every value below in one place: a new `ThemeExtension<BrutalTokens>` in `app/lib/src/ui/brutal/tokens.dart`, registered in `denaTheme()`. Widgets read `BrutalTokens.of(context)`; nothing hard-codes these numbers.

### 2.1 Colour

| Token | Paper (light, default) | Ink (dark) | Use |
| --- | --- | --- | --- |
| `ground` | `#F2F2EC` graph paper | `#0E0E0E` | screen background |
| `gridLine` | `#000000` at 7% | `#FFFFFF` at 7% | 8 px graph grid, 1 px lines; every 4th line at 12% |
| `panel` | `#FFFFFF` | `#000000` | tables, buttons, dialogs |
| `ink` | `#000000` | `#F2F2EC` | text, borders, icons |
| `shadow` | `#000000` | `#F2F2EC` | hard offset shadows (always = `ink`) |
| `muted` | `#CFCFC8` concrete | `#3A3A36` | disabled fills, empty progress, dividers inside panels |
| `mutedText` | `#5A5A55` | `#A4A49C` | secondary text (min 4.5:1 on panel) |
| `focus` | `#FFE600` hazard yellow | `#FFE600` | focused row/control fill; text on it is always `#000` |
| `primary` | `#1F3BFF` electric blue | `#4A63FF` | primary action fill (PLAY, RESUME, SHUFFLE), focus arrow cell; text on it `#FFFFFF` |
| `danger` | `#E10600` | `#FF3B30` | delete/quit text and hazard stripes (stripes alternate `danger`/`#000` at 45 degrees, 10 px) |
| `ok` | `#00A33A` | `#2BD46A` | log lines `... ok`, sync done |
| `headerBar` | `#000000` | `#F2F2EC` | table header row, pause meta keys; text inverted |

- Theme modes: **Paper** (default), **Ink**, and **System** (follows the OS). This replaces Dark/Light. Existing `theme.json` `mode: dark` maps to Ink, `light` to Paper, `system` to System. Default for new installs: Paper.
- `ColorScheme` mapping (so stock Material widgets come out right before each area is restyled): `primary`=primary, `onPrimary`=white, `secondary`=focus, `onSecondary`=black, `surface`=ground, every `surfaceContainer*`=panel, `onSurface`=ink, `onSurfaceVariant`=mutedText, `outline`=ink, `outlineVariant`=muted, `error`=danger, `primaryContainer`=focus, `onPrimaryContainer`=black. `focusColor`=focus.
- **Dropped:** Material You (`dynamic`) and the 26 console palettes in the theme picker. Unknown or removed palette ids load as the default (the loader already does this). The Dena gold `#F1C40F` survives only as an optional **accent swap**: Settings > Appearance > Accent `[HAZARD]` (default) or `[GOLD]`, which replaces `focus` with `#F1C40F`. The app icon is unchanged.
- System accents (`system_palette.dart`): keep per-system colours only for the tiny SYS cell marker in tables; do not tint panels by system.

### 2.2 Type

Bundle two OFL-1.1 fonts in `app/assets/fonts/` (add both to `docs/licenses.md` and `third_party_licenses.dart`; remove Nunito once nothing uses it):

- **IBM Plex Mono** 500 and 600 (and 700 for the wordmark fallback): everything functional (tables, labels, buttons, paths, logs, settings, dialogs).
- **Archivo Black** 400: display only, UPPERCASE only: the `DENA.EMU/` wordmark, the giant PLAY, the PAUSED sticker, empty-state headlines. Never for body text.

| Style | Font | Size / line | Weight | Case |
| --- | --- | --- | --- | --- |
| `display` | Archivo Black | 40 / 44 | 400 | UPPER |
| `displaySmall` | Archivo Black | 28 / 32 | 400 | UPPER |
| `title` | Plex Mono | 18 / 24 | 600 | UPPER |
| `body` | Plex Mono | 14 / 20 | 500 | as written |
| `row` (table cells) | Plex Mono | 14 / 18 | 600 | UPPER for titles (`MOONLIGHT_QUEST`) |
| `label` (buttons, tabs, headers) | Plex Mono | 13 / 16 | 600 | UPPER, letter-spacing 0.5 |
| `small` (meta, hints, logs) | Plex Mono | 11 / 14 | 500 | as written |

Map onto `TextTheme` (`displayLarge/Medium/Small` = display styles, `headline*` = displaySmall/title, `title*` = title, `body*` = body, `label*` = label/small) so untouched screens pick up mono immediately. Tabular figures are automatic in a mono face. Handheld uses the same logical sizes (640x480 at 1x already matches the reference). Game titles in tables are shown as `FILE_NAME` style: upper-case, spaces to underscores, display only (never change the stored title).

### 2.3 Space, borders, shadows, shape

- Base unit 4 px. Spacing tokens: `s1`=4, `s2`=8, `s3`=12, `s4`=16, `s6`=24, `s8`=32.
- Grid paper cell 8 px (matches `s2`).
- Borders: `border` = 3 px (panels, buttons, tables); `borderThin` = 2 px (table row dividers, inner cells); `hairline` = 1 px (grid paper only). Handheld keeps 3 px; at 640x480 it reads correctly in the reference.
- Shadow: solid, no blur, offset `shadow` = (4, 4) on phone/desktop, (3, 3) on handheld; colour `shadow`. Large panels (tables, dialogs) use (6, 6).
- Corner radius **0** everywhere (`BorderRadius.zero`). Exception: none. Box art keeps its own console shape.
- Touch targets: min 44 px tall on phone (buttons 46, table rows 48 on phone; the reference's 37 px rows are too small for thumbs, so phone uses 48). Handheld rows 28 px, desktop rows 40 px before TV scale.

### 2.4 Motion

- **No easing.** Animations are linear or stepped. No springs, no fades longer than 80 ms.
- Press: the button translates by the shadow offset and its shadow disappears, in 0 ms on press and 60 ms back on release. The selected tab is drawn already pressed.
- Focus moves instantly (no animated focus ring).
- Page transitions: hard cut (`NoTransitionsBuilder`-style for all platforms). Sheets and dialogs appear in 1 frame; the background dims instantly to `#000` at 40%.
- Stepped animations (launch, sticker) use 3 to 4 discrete steps of 60 to 80 ms each.
- Respect `MediaQuery.disableAnimations`: everything becomes instant.
- Handhelds: same motion (it is already cheap); the foil stripe does not sweep (as today).

### 2.5 Icons

- Redraw **Dena Icons** as **9x9 pixel bitmaps** in the same generator (`tools/icons/build_icons.py` gains a `--style pixel` path, made the default), keeping every existing glyph name and code point so no call site changes. Each glyph is square cells on a 9-unit grid scaled to the font's UPM, no anti-aliased curves, one-cell strokes, literal and slightly crude (bin, star, sliders, cartridge, dice, disc, folder, wifi, usb).
- Render at multiples of 9 px where possible (18 px on phone/desktop, 18 px on handheld rows, 27 px in nav tabs) so cells land on whole pixels.
- Colour: `ink` on panel, black on focus/yellow, white on primary/blue.
- Drop `debossShadows` from `iconTheme`.
- Kept from PR #71: the icon *set*, names and generator pipeline. Gone: the rounded moulded drawing style.

### 2.6 What is kept, what goes

Kept: Dena Icons names and pipeline (redrawn), the box models and real per-console box shapes (`game_box_model.dart`), box art and romhack badges (restyled as a hard label), the foil layer (as a static holo stripe), the launch-animation concept, stash/shuffle physics (restyled), TvScale, controller mode, hint bar, on-screen keyboard (restyled), every feature and setting.

Removed: plastic grain (`PlasticGrain`, `plasticGrainVisible`), key caps (`plasticButtonStyle`, `_KeycapPainter`), dimples, `BevelBorder`, Nunito, Material You and console palettes in the picker, ink ripples (already off), rounded corners, the XMB look in media players, NavigationBar at the bottom of the phone. Delete `plastic.dart` in the last PR once nothing imports it.

## 3. Component kit (`app/lib/src/ui/brutal/`)

Built and tested in the foundation PR, each with widget tests and golden tests at phone, 640x480 and 1280x720 in touch and focus modes. Area PRs only compose these; if an area needs a new component, it adds it to this folder in its own PR.

| Widget | Behaviour |
| --- | --- |
| `BrutalGridPaper` (spec name `GridPaper`; Flutter has its own) | Background painter: `ground` + 8 px grid. Static, drawn once per size (cached picture), cheap on the H700. |
| `BrutalPanel` | Box with `panel` fill, `border`, hard `shadow`. Optional `header` strip (`headerBar` fill, inverted `label` text, e.g. `VIDEO.CFG`). |
| `BrutalButton` | Hard rectangle on shadow. Variants: `plain` (panel), `primary` (blue), `focus` (yellow), `dark` (black, yellow text: QUIT), `hazard` (striped edge, `danger` text). Optional leading 9x9 icon, optional `index` (`01`), optional right `value` (`[3 ON]`). Press = move onto shadow. Focused = yellow fill + `<-` marker at the right edge outside the button on handheld/desktop (see pause_handheld.png). Also exposed as `ButtonStyle`s for `FilledButton`, `OutlinedButton`, `TextButton`, `ElevatedButton`, `IconButton` in the theme so existing buttons convert automatically. |
| `HoldToConfirm` | Wraps a hazard button: press and hold 1.0 s (touch, mouse, or A on a pad) fills the button left to right in `danger`; release early cancels. Replaces "are you sure" dialogs for Delete. Label: `HOLD TO DELETE`. |
| `BrutalTab` / `BrutalTabBar` | Pressable tabs: icon above label (phone), icon left of label (rail/header). Selected tab is yellow and drawn pressed. L1/R1 still switch. |
| `BrutalTable` | Dense table: black header row with sortable columns (`TITLE ↓`), `borderThin` row dividers, monospace cells, fixed column widths per device. Focused/selected row: yellow fill, 3 px black top/bottom border, first cell becomes a blue `->` cell. Supports leading thumbnail cell, right-aligned numeric cells and a `ProgressCell`. Virtualised (SliverList) for big libraries. Header tap/`Select` cycles sort. |
| `ProgressCell` | Hard bar: black border, black fill for the done part, no rounding, optional `%` text. |
| `CheckFilter` | `[x]ALL(12)` / `[ ]NES(2)` toggle chips as text; checked one is yellow. Wraps on phone, one line per item in the handheld rail. Exactly one system or ALL is checked (current filter semantics); multi-select is not added. |
| `CommandField` | Search/text input: panel with border, `>` prompt, mono text, block cursor `█` that blinks at 500 ms steps (off when animations are disabled), leading 9x9 search icon. Uses the on-screen keyboard on handheld/controller as today. |
| `PathBar` | `/games > all` breadcrumb in `small`, shows current tab, filter and sort; on handheld also "L/R" hints. |
| `BracketSlider` | `[#####-----] 50%` stepped slider, 10 or 20 steps; left/right change it on pads, drag/tap on touch. Replaces Material `Slider`. |
| `CfgToggle` | `[ON]` / `[OFF]` hard two-state key (ON = black fill, white text; OFF = panel). Replaces `Switch`. |
| `CfgSegment` | `[1X] 2X 4X` bracketed segment choice; selected value in brackets and yellow. Replaces `SegmentedButton`. |
| `CfgTable` | Settings section: `BrutalPanel` with a header like `VIDEO.CFG`, rows of `KEY ............ VALUE` with a control at the right (`CfgToggle`, `CfgSegment`, `BracketSlider`, or `>` to open a page). |
| `KeyValueStrip` | `FILE / SESSION / CORE` meta table: black key column, panel value column (pause_handheld.png). |
| `LogLine` | One or more `small` mono lines: `> save state 2 ... ok` (`ok` in `ok` colour, `err` in danger). Used by pause, launch, sync, import, Wi-Fi. |
| `Sticker` | Rotated (-4 degrees) yellow block with 3 px border and shadow, Archivo Black text (`PAUSED`, `NEW`, `HACK`). |
| `KeyGlyph` | Button hint glyph: a small bracketed key `[A]` drawn as a 22 px bordered square with the letter; A filled yellow. Pad-specific letters/shapes come from the existing controller glyph mapping (controller-mode.md) drawn in this style. |
| `BrutalHintBar` | Bottom bar of `KeyGlyph` + `label` pairs (`[A] OK  [B] BACK  [L][R] SLOT`). Replaces `HintBar` visuals; logic stays. |
| `BrutalDialog` | Panel with header strip title (`DELETE?`, `SIGN IN`), body in `body`, buttons right-aligned as `BrutalButton`s, 6 px shadow, instant appearance, `#000` 40% scrim. |
| `BrutalSheet` | Bottom sheet (phone) / right side panel (handheld, desktop): same as dialog, full width, top border only on phone. |
| `BrutalToast` | SnackBar replacement: black bar, white mono text, `ok`/`err` prefix (`OK > screenshot saved`), top-right on desktop, bottom elsewhere, 3 s. Implemented through `SnackBarThemeData` so existing `showSnackBar` calls convert. |
| `BoxThumb` | Tiny box art in a table cell (34x40 phone, 26x30 handheld) keeping the console's box aspect, black border. |
| `EmptyState` | Archivo Black headline + mono explanation + one primary button, e.g. `NO ROMS FOUND.` / `> add a folder to start` / `[ADD FOLDER]`. |

Focus rule for every focusable: the focused control is yellow-filled with black text; if it is already yellow, it gets a 3 px `primary` outline instead (see the focused save slot in pause_handheld.png). The focus indicator never relies on colour alone: rows also get the `->` cell, buttons the `<-` marker on pad devices.

## 4. Screens

Each subsection names the reference picture and the current code that changes. "Phone / handheld / desktop" describes layout differences only; behaviour and features stay as specified in the existing spec for that screen unless stated.

### 4.1 Shell and navigation (`shell/app_shell.dart`, `shell/handheld.dart`, `desktop/tv_layout.dart`)

- **Wordmark block**: yellow `BrutalPanel` with `DENA.EMU/` in `display`, and on the right the path (`/games`) and a stat line (`12 ROMS // 4.1 GB`). Phone: top of every tab root. Handheld: top of the left rail, smaller (`displaySmall`). Desktop: left end of the header bar.
- **Navigation**: Phone = row of four `BrutalTab`s under the wordmark (GAMES, CARTS, APPS, SETTINGS), replacing the bottom `NavigationBar`. Handheld = left rail (wordmark, the tabs stacked, then the `CheckFilter` list and a focused-box preview; see library_handheld.png). Desktop = yellow header bar with tabs inline. Tablets/foldables use the desktop arrangement. Handheld has no APPS tab (unchanged rule).
- Tabs keep their L1/R1 behaviour and focus rules from handheld-ui.md.
- `GridPaper` behind every route. The plastic grain overlay is removed.
- Footer: phone shows `12 ROWS // SORT=TITLE ASC` and `[LIST] [GRID]` view switch (library only). Handheld/desktop show `BrutalHintBar`.
- Back/predictive back unchanged.

### 4.2 Library: Games tab (`library/games_tab.dart`, `card_library.dart`, `stash_view.dart`, `library_scope.dart`)

Reference: library_phone.png, library_handheld.png, library_desktop.png.

- **Default view = TABLE** (new). Columns: `#`, `BOX` (`BoxThumb`), `TITLE`, `SYS`, `YR`, `%` (completion from achievements when known, else play-progress bar from play time; hide the bar when neither is known). Desktop adds `PLAYED` (hh:mm) and `LAST` (relative date). Sort by tapping a header or `Select` on pads: title, system, year, last played, play time.
- Control block above the table: `CommandField` search, blue `SHUFFLE` `BrutalButton` (picks a random visible game and focuses it; on long-press/hold `X` it opens the stash physics drop as today), `CheckFilter`s for ALL and each system present with counts.
- **Second view = GRID**: the existing box grid, restyled (boxes on grid paper with hard shadows, focused box gets a yellow 3 px frame and `->` label plate under it). **Stash view** stays as a third option (Settings > Library view: TABLE / GRID / STASH; default TABLE). `theme.json` `library` key gains `table` and `grid` values; existing `stash` keeps working.
- Focus: the first row at start (handheld-ui.md rule). A = play (launch animation), Y = zoom (4.3), X = shuffle, Select = sort, L1/R1 = tabs. Held D-pad repeats as today.
- Romhacks: title cell gets a small `HACK` `Sticker`-style tag. Favourites: `★` in the `#` cell.
- Empty: `EmptyState` with `[ADD FOLDER]` (Android: SAF picker; handheld: file explorer; desktop: watched folders). This is also the first-run/onboarding screen (there is no separate onboarding flow today; do not add one).
- Phone: 48 px rows, columns `# BOX TITLE SYS YR %`, YR hidden under 360 px width. Handheld: 28 px rows, columns `# BOX TITLE SYS YR`, table on the right of the rail, 12 rows visible. Desktop: three columns at 1280x720 logical: left = filters/search/shuffle, middle = table (12 rows), right = `INSPECT` panel for the focused game (box, `KeyValueStrip` with system, year, played, last, file size, core; PLAY and INFO buttons; `LogLine` of the last session). TvScale scales it for 1080p/4K unchanged.

### 4.3 Game box zoom and options (`library/game_box_menu.dart`, `game_box.dart`, `foil.dart`)

Reference: zoom_phone.png.

- An **inspection viewport**: top half is blue grid paper (`primary` ground with white 8 px grid at 15%) with dashed crosshairs, the box tilted 6 degrees with a hard 6 px shadow, and 2 to 3 annotation callouts in `small` white mono (`ratio 1:1.4`, `foil layer`, `spine`). No 3D perspective, no blur.
- Below: `title` (`MOONLIGHT_QUEST`), `KeyValueStrip` (SYS, YEAR, PLAYED, FILE), a full-width `primary` **PLAY** button with the label in `display` Archivo Black, then a 2-column grid of `BrutalButton`s with keyboard letters: `[F] FAVOURITE`, `[R] RENAME`, `[H] ADD TO HOME SCREEN` (Android only), `[A] ACHIEVEMENTS`, `[C] CHOOSE COVER`, `[I] GAME INFO`, then full-width `HoldToConfirm` hazard `HOLD TO DELETE`. The letters are hints for desktop keyboards and act as shortcuts there.
- Foil: a static diagonal holo stripe (two 6 px bands, cyan and magenta at 40%) across the box art; it may shift with tilt on phones (existing sensor logic) by at most 8 px, stepped, never on handhelds.
- Phone: full-screen route. Handheld: right-hand `BrutalSheet` over the library at 640x480, viewport on top-left, options as a vertical list with focus starting on PLAY. Desktop: the INSPECT panel expands to full height with the same content.
- Home-screen shortcut icon generation is unchanged.

### 4.4 Launch animation (`library/launch_animation.dart`)

Reference: proposal text ("launch") in the PDF.

Replaces the eased open-box animation with a **hard stepped sequence**, total 560 ms (360 ms when `disableAnimations`, then a cut):
1. 0 ms: the focused row/box inverts to black with yellow text.
2. 80 ms: the box snaps to the screen centre (no tween; one step), black scrim behind it.
3. 160 to 400 ms: the lid opens in 3 hard steps (closed, 45 degrees, open), the media (cart/disc/UMD from `media_art.dart`) rises out in 2 steps.
4. 400 ms: a `LogLine` prints `> boot moonlight_quest.gba ... ok` under the box.
5. 560 ms: cut to the game (no fade).

Handhelds run the same sequence (it is cheaper than today's). Media art and label rules from launch-animation.md stay; only motion and framing change.

### 4.5 Pause menu (`session/session_screen.dart` `PauseSheet`, `state_slots.dart`)

Reference: pause_phone.png, pause_handheld.png.

- The live game stays visible (no blur), with a `Sticker` `PAUSED` slapped on its top-left (appears in 1 frame with a 2-step scale 1.15 -> 1.0).
- **Phone**: game picture on top, then a vertical stack of full-width `BrutalButton`s with index numbers: `01 RESUME` (primary, focused first), `02 SAVE STATE` (with the 4 slot thumbnails in a row beneath when focused/expanded), `03 LOAD STATE`, `04 REWIND`, `05 CHEATS [3/8 ON]`, `06 SHADER [CRT-LITE]`, `07 SCREENSHOT`, `08 SPEED [1X|2X|4X]` (`CfgSegment` inline), `09 CONTROLLERS [2]`, `10 LINK CABLE` (GB/GBC/GBA only), `11 SETTINGS`, `12 QUIT GAME` (dark variant). Achievements entry appears when signed in. A `LogLine` at the bottom shows the last 3 actions in this session.
- **Handheld 640x480** (pause_handheld.png): two columns. Left: game picture with the sticker, `KeyValueStrip` (FILE, SESSION time and chapter if known, CORE and fps), save-slot strip (4 thumbnails, L/R move between slots). Right: the button stack, focused item yellow with `<-`. Hint bar `[A] OK [B] BACK [L][R] SLOT`. Must fit without scrolling at 640x480 (pause-menu.md rule): the stack uses 40 px buttons and shows RESUME through QUIT; REWIND, SHADER, CONTROLLERS and LINK CABLE go under SETTINGS > `GAME.CFG` on handheld only if they do not fit.
- **Desktop**: same as handheld, scaled by TvScale; mouse hover = focus.
- B resumes (unchanged). Menu/Start opens it (unchanged).
- Sub-sheets restyled with the kit: **Cheats** (`CfgTable` `CHEATS.CFG`: one row per cheat with `CfgToggle`, `[+] ADD CODE`, browser as a `BrutalTable`), **Shader** (list of shaders as a table with a `[x]` selected marker), **Slots** (grid of 4 to 8 slot cards: thumbnail, `SLOT1 NEW`, age `-2M`, empty `---` with hatched fill), **Link cable**, **Achievements** (table with unlocked `[x]`, points, `%`), **Controllers** (table of players and devices).

### 4.6 Settings (`shell/app_shell.dart` `_SettingsTab`, `ui/theme_settings_page.dart`, `shell/device_settings.dart`, `shaders/shader_settings.dart`, `turbo/turbo.dart`, `ui/audio_latency_page.dart`, `desktop/display_settings.dart`)

- Settings is **a config file you can see**: the root is a list of `CfgTable` sections, each with a header: `APPEARANCE.CFG` (Mode [PAPER|INK|SYSTEM], Accent [HAZARD|GOLD], Library view [TABLE|GRID|STASH]), `VIDEO.CFG` (shaders, resolution, display), `AUDIO.CFG` (latency, volume on handheld), `INPUT.CFG` (skins, turbo, controllers, fullscreen at launch on desktop), `LIBRARY.CFG` (folders, import rules, box art), `ACCOUNTS.CFG` (RetroAchievements, RomM), `DEVICE.CFG` (handheld: brightness, Wi-Fi, USB storage, time, power), `ABOUT.CFG` (version, licenses, latency test).
- Each row: `KEY` left in `label`, a dotted leader, value/control right. Rows that open a page end in `>`. Sliders are `BracketSlider`s; switches are `CfgToggle`s; choices are `CfgSegment`s or open a picker page that is a `BrutalTable` with a `[x]` column.
- Sub-pages use the same structure (a page = one or more `CfgTable`s), with the `PathBar` showing `/settings > video.cfg > shaders`.
- Phone: single column. Handheld: single column, 28 px rows. Desktop: two columns of sections.
- Handheld focus rules from handheld-ui.md stay (Brightness first, up/down leave sliders).

### 4.7 Carts and Pico-8 (`carts/*`, `library/carts_tab.dart`)

- Carts tab = the library table pattern: columns `#`, `CART` (the cart's label image as `BoxThumb` in 1:1), `TITLE`, `AUTHOR`, `LICENSE`, `♥`. The **Dena Explore** launcher is pinned as row `00` with a `primary` `[LAUNCH EXPLORE]` button above the table.
- BBS browser (`cart_browser.dart`): tabs `FEATURED / NEW / SEARCH / AUTHOR` as `BrutalTab`s, results as a table, a cart sheet as `BrutalSheet` with the label art, author, license, BBS link and `[DOWNLOAD]`. Licence and attribution rules in CLAUDE.md unchanged. Never use Lexaloffle branding.
- The in-cart Explore UI (PICO-8 side) is out of scope (it is the cart's own pixel UI).

### 4.8 Apps and media (`apps/*`, `media/*`)

- Apps tab (Android only): a table of apps (icon in a bordered 9x9-style tile from the system icon, name, package, `[OPEN]`). Built-in apps (music, video, web files) are pinned on top.
- Music and video players drop the **XMB** look (`xmb.dart` waves and category bar). They become: a `BrutalTable` list of tracks/videos, a `BrutalPanel` "now playing" block with `ProgressCell` seek bar (`XmbSeekBar` replaced by a `BracketSlider`-style seek with time text), and transport `BrutalButton`s. Delete `xmb.dart` when nothing uses it.

### 4.9 File explorer, folders, web files, USB, Wi-Fi (handheld and shared)

- **File explorer** (`library/file_explorer.dart`): `PathBar` with the full path, a table `NAME / SIZE / MODIFIED / TYPE`, folders first with a `/` suffix, focused row yellow; actions `[ADD FOLDER] [SELECT] [UP]` as buttons; `LogLine` for import results.
- **Game folders** (`game_folders_page.dart`): `CfgTable` `FOLDERS.CFG` with one row per watched folder and `HOLD TO REMOVE`.
- **Web files** (`webfiles/*`): the in-app page shows the address in a big `CommandField`-style read-only box (`http://192.168.1.20:8080`) and a QR code in a bordered panel. The web page served to browsers adopts the same look with plain CSS (grid paper, mono, borders); keep it dependency-free.
- **Wi-Fi** (`shell/wifi_page.dart`): table `SSID / SIGNAL [####-] / SECURITY / [x]` with the connected network checked; password entry via `CommandField` + on-screen keyboard; `LogLine` `> connect home_wifi ... ok`.
- **USB storage** (`shell/usb_storage.dart`): one `BrutalPanel` `USB.MODE` with a big status `Sticker` (`MOUNTED` / `EJECTED`), instructions in `body`, and `[EJECT]` primary button.
- **On-screen keyboard** (`ui/onscreen_keyboard.dart`): keys are square `BrutalButton`s (40 px handheld) in a grid, focused key yellow, special keys `[SPACE] [DEL] [OK]`.

### 4.10 Accounts and sync (`romm/*`, `achievements/*`)

- RetroAchievements and RomM pages become `CfgTable`s: account rows (`USER`, `SERVER`, `STATUS [ONLINE]`), actions as buttons, and a `LogLine` with the last sync result.
- RomM platform/rom pages reuse the library table.

### 4.11 Latency test, spike, misc

- Latency test and audio latency pages: `CfgTable` plus a results table; flashing test areas stay pure black/white.
- Dialogs everywhere use `BrutalDialog`; toasts use `BrutalToast` (via theme).
- `SpikeScreen` (dev) needs no restyle.

### 4.12 Desktop specifics (`desktop/*`)

- Mouse: hover shows the focus style; pressing shows the press style. Scroll wheel scrolls tables. Right-click on a row opens zoom.
- Keyboard: arrows move focus, Enter = A, Esc/Backspace = B, letters are the zoom shortcuts, `/` focuses search, F11 fullscreen (unchanged).
- Controller mode and TV layout: unchanged mechanics (`TvScale`, `PadKeySynth`, glyph mapping); glyphs are drawn as `KeyGlyph`. The three-column library (4.2) is the TV layout.
- `FullscreenAtLaunchPage` becomes a `CfgTable` row with `CfgSegment` `[AUTO] ALWAYS NEVER`.

## 5. Per-device adaptation summary

| | Phone (touch) | Handheld 640x480 (D-pad) | Desktop / TV (mouse, keyboard, controller) |
| --- | --- | --- | --- |
| Nav | Tabs under wordmark | Left rail | Yellow header bar |
| Library | Table, 48 px rows | Rail + table, 28 px rows | Filters, table, INSPECT panel |
| Zoom | Full-screen route | Right sheet | INSPECT panel expanded |
| Pause | Stacked buttons under game | Two columns, fits 640x480 | As handheld, TvScale |
| Hints | None (touch) | `BrutalHintBar` 30 px | `BrutalHintBar` with pad glyphs |
| Focus | Hidden until a key/pad is used (last input wins) | Always visible | Visible in controller mode and on hover |
| Shadow | 4 px | 3 px | 4 px (scaled) |

## Acceptance (foundation)

- Every token text pair reads at 4.5:1 or better in Paper and Ink with both accents;
  pressing a kit button moves it by `shadowOffset`; no rounded corners in
  `ui/brutal/` (`test/ui/brutal_kit_test.dart`).
- `test/ui/brutal_gallery_test.dart` renders the whole kit in Paper and Ink at
  640x480, 720x720, phone and 1280x720, touch and focus.
- An old `theme.json` loads: `dark` as Ink, `light` as Paper, palette dropped
  (`test/ui/app_theme_test.dart`).
