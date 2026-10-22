// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/brutalist-ui.md (4.6 settings)
import 'package:material_ui/material_ui.dart';

import '../achievements/achievements_ui.dart';
import '../apps/device_apps.dart';
import '../desktop/controller_profiles_page.dart';
import '../desktop/display_settings.dart';
import '../desktop/frame_generation.dart';
import '../desktop/long_rewind.dart';
import '../desktop/netplay.dart';
import '../desktop/deck_presets.dart';
import '../desktop/run_ahead.dart';
import '../desktop/texture_packs.dart';
import '../romm/romm_settings.dart';
import '../romtools/rom_manager.dart';
import '../romtools/rom_manager_page.dart';
import '../ui/brutal/brutal.dart';
import 'cfg_page.dart';
import 'device_settings.dart';
import 'handheld.dart';
import 'network.dart';
import 'power_link.dart';
import 'usb_storage.dart';
import 'wifi_page.dart';
import '../library/desktop_files.dart';
import '../library/game_folders_page.dart';
import '../library/library_scope.dart';
import '../shaders/shader_settings.dart';
import '../skins/skins_tab.dart';
import '../spike/spike_screen.dart';
import '../turbo/turbo.dart';
import '../ui/app_theme.dart';
import '../ui/audio_latency_page.dart';
import '../ui/theme_settings_page.dart';
import '../webfiles/web_files_page.dart';

/// The Settings tab body: a config file you can see, one `.CFG` table per
/// area (brutalist-ui.md 4.6). The scaffold and navigation around it live in
/// app_shell.dart.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = LibraryScope.of(context);
    final shaders = scope.shaders;
    // Real buttons, no touch screen, Android-only tools hidden (handheld-ui.md).
    final handheld = Handheld.of(context);
    // Online features stay out of navigation without Wi-Fi (network.dart),
    // so the D-pad never lands on one that can't work.
    final online = NetworkScope.of(context);
    final theme = ThemeScope.of(context).notifier!;
    final display = DesktopDisplayScope.maybeOf(context);
    final rewind = DesktopRewindScope.maybeOf(context);
    final runAhead = RunAheadScope.maybeOf(context);
    final presets = DeckPresetsScope.maybeOf(context);
    final profiles = ControllerProfilesScope.maybeOf(context);
    final netplay = NetplayScope.maybeOf(context);
    final frameGen = FrameGenScope.maybeOf(context);
    final usb = PowerScope.usbOf(context);
    // The tab's first item takes focus after L1 / R1: Brightness on the
    // handheld, else the theme mode.
    final device = switch ((
      PowerScope.of(context),
      PowerScope.deviceOf(context),
    )) {
      (final link?, final settings?) => DeviceSection(
        settings: settings,
        link: link,
        autofocus: true,
      ),
      _ => null,
    };
    void open(Widget page) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page));

    // Other areas' list tiles (Wi-Fi, USB, game folders) until they are
    // restyled: they need a Material of their own inside a panel.
    Widget tile(Widget t) =>
        Material(type: MaterialType.transparency, child: t);

    // A section only shows when it has rows.
    Widget? cfg(String header, List<Widget> rows) =>
        rows.isEmpty ? null : CfgTable(header: header, rows: rows);

    final sections = <Widget?>[
      cfg('DEVICE.CFG', [
        ?device,
        if (NetworkScope.wifiOf(context) case final wifi?)
          tile(WifiTile(wifi: wifi)),
        if (usb != null) tile(UsbStorageTile(usb: usb)),
        if (DeviceApps.platform case final apps?) HomeLauncherTile(apps: apps),
      ]),
      AppearanceCfg(autofocus: device == null),
      cfg('VIDEO.CFG', [
        if (shaders != null)
          CfgRow(
            label: 'Shaders',
            value: 'per system',
            onOpen: () => open(ShaderSettingsPage(store: shaders)),
          ),
        if (presets != null) PresetsTile(settings: presets),
        // frame-generation.md: Windows and SteamOS.
        if (frameGen != null)
          FrameGenTile(settings: frameGen, model: presets?.model),
        // texture-packs.md: Windows and SteamOS.
        if (TexturePacksScope.maybeOf(context) case final packs?)
          TexturePacksTile(packs: packs),
      ]),
      cfg('AUDIO.CFG', [
        if (!handheld)
          CfgRow(
            label: 'Latency',
            value: audioLatencyLabel(theme.audioLatencyMs),
            onOpen: () => open(const AudioLatencyPage()),
          ),
      ]),
      cfg('INPUT.CFG', [
        if (!handheld)
          CfgRow(
            label: 'Skins',
            value: 'per system',
            onOpen: () => open(const SkinsPage()),
          ),
        if (shaders != null)
          CfgRow(
            label: 'Turbo',
            value: turboSummary(TurboStore(shaders.dataDir).global),
            onOpen: () =>
                open(TurboSettingsPage(store: TurboStore(shaders.dataDir))),
          ),
        // Windows and SteamOS (controller-mode.md).
        if (display != null) FullscreenAtLaunchTile(settings: display),
        // Windows and SteamOS (rewind.md, Long rewind).
        if (rewind != null) RewindBufferTile(settings: rewind),
        // run-ahead.md: Windows and SteamOS.
        if (runAhead != null) RunAheadTile(settings: runAhead),
        // gamepads.md (Desktop: profiles and gyro).
        if (profiles != null)
          ControllerProfilesTile(
            store: profiles,
            games: () async => [
              for (final g in await scope.db.allGames())
                (sha1: g.sha1, title: g.title),
            ],
          ),
      ]),
      // netplay.md: Windows and SteamOS.
      cfg('NETPLAY.CFG', [if (netplay != null) NetplayTile(settings: netplay)]),
      cfg('LIBRARY.CFG', [
        if (scope.folders case final folders?)
          tile(
            GameFoldersTile(
              folders: folders,
              files: switch (scope.files) {
                final DesktopGameFiles f => f,
                _ => null,
              },
            ),
          ),
        // rom-manager.md 5.
        if (RomManagerScope.of(context) case final rom?)
          RomManagerTile(manager: rom),
        if (online)
          CfgRow(
            label: 'Web files',
            value: 'browser upload',
            onOpen: () => open(const WebFilesPage()),
          ),
      ]),
      cfg('ACCOUNTS.CFG', [
        if (scope.achievements case final ra? when online)
          RetroAchievementsTile(ra: ra),
        if (RommScope.of(context) != null && online) const RommSection(),
        if (RomManagerScope.of(context)?.account case final ss? when online)
          ScreenScraperTile(account: ss),
      ]),
      cfg('ABOUT.CFG', [
        const CfgRow(label: 'Version', control: Text(appVersionLabel)),
        CfgRow(
          label: 'Licenses',
          onOpen: () => showLicensePage(
            context: context,
            applicationName: 'Dena.emu',
            applicationVersion: appVersionLabel,
          ),
        ),
        if (!handheld)
          CfgRow(
            label: 'Latency test',
            value: 'dev',
            onOpen: () => open(const SpikeScreen()),
          ),
      ]),
    ];
    return SafeArea(
      child: CfgSections(
        // The shell's header bar already shows /settings.
        path: const [],
        sections: [for (final s in sections) ?s],
      ),
    );
  }
}

/// The build's version name, or `dev` for a local build.
const appVersionLabel = String.fromEnvironment(
  'FLUTTER_BUILD_NAME',
  defaultValue: 'dev',
);

/// The Skins tab as a Settings page (apps-tab.md).
class SkinsPage extends StatelessWidget {
  const SkinsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Skins')),
    body: const BrutalGridPaper(child: SkinsTab()),
  );
}

/// `HOME LAUNCHER ... ON >`: set Dena.emu as the home screen (apps-tab.md).
class HomeLauncherTile extends StatefulWidget {
  const HomeLauncherTile({super.key, required this.apps});

  final DeviceApps apps;

  @override
  State<HomeLauncherTile> createState() => _HomeLauncherTileState();
}

class _HomeLauncherTileState extends State<HomeLauncherTile>
    with WidgetsBindingObserver {
  bool? home;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The choice is made in a system screen; re-check on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final h = await widget.apps.isHome();
      if (mounted) setState(() => home = h);
    } on Object {
      // Leave the subtitle generic.
    }
  }

  @override
  Widget build(BuildContext context) => CfgRow(
    label: 'Home launcher',
    value: home == true ? 'ON' : 'OFF',
    onOpen: () async {
      try {
        await widget.apps.requestHome();
      } on Object {
        // The system screen could not open; nothing to do.
      }
      _refresh();
    },
  );
}
