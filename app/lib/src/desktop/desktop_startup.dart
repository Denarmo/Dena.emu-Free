// SPDX-License-Identifier: GPL-3.0-or-later
// Windows and SteamOS start-up: the controller-at-launch rule, the window,
// and gamepads driving the UI. Spec: docs/specs/controller-mode.md
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../achievements/achievements_overlay.dart';
import 'controller_mode.dart';
import 'controller_profiles.dart';
import 'controller_profiles_page.dart';
import 'deck_presets.dart';
import 'desktop_pads.dart';
import 'display_settings.dart';
import 'frame_generation.dart';
import 'gaming_mode.dart';
import 'launch_rule.dart';
import 'long_rewind.dart';
import 'netplay.dart';
import 'pad_keys.dart';
import 'run_ahead.dart';
import 'texture_packs.dart';
import 'tv_layout.dart';
import 'window_control.dart';

/// The desktop pieces the app runs with.
class DesktopShell {
  DesktopShell._(
    this.mode,
    this.display,
    this.achievements,
    this.rewind,
    this.runAhead,
    this.presets,
    this.profiles,
    this.netplay,
    this.frameGen,
    this.texturePacks,
    this._pads,
    this._keys,
  );

  final ControllerMode mode;
  final DesktopDisplaySettings display;

  /// The in-game RetroAchievements overlay (achievements.md).
  final RaOverlaySettings achievements;

  /// The long rewind buffer (rewind.md).
  final DesktopRewindSettings rewind;

  /// Run-ahead (run-ahead.md).
  final RunAheadSettings runAhead;

  /// Steam Deck presets (deck-presets.md).
  final DeckPresetSettings presets;

  /// Per-game and per-controller profiles (gamepads.md).
  final ControllerProfileStore profiles;

  /// Netplay over LAN and rooms (netplay.md).
  final NetplaySettings netplay;

  /// Frame generation (frame-generation.md).
  final FrameGenSettings frameGen;

  /// HD texture packs (texture-packs.md); null without a storage root.
  final TexturePacks? texturePacks;

  final DesktopPads? _pads;
  final PadKeySynth _keys;
  Timer? _hotplug;

  /// Applies the launch rule (waiting up to [gamepadWait] for pads) and
  /// starts listening to them. [pads] is null without the host library:
  /// the window rule still applies, with no gamepads. [runAheadSink] gets
  /// the run-ahead choice (run-ahead.md); null without the host library.
  /// [profilesHost] gets the controller profiles (gamepads.md); they live
  /// in `controller_profiles.sqlite` unless [profilesDb] is given. Texture
  /// packs live in [storageRoot]/Textures; [texturePackSink] gets the
  /// choice for each game (texture-packs.md). [frameGenHost] gets the frame
  /// generation mode of the game playing (frame-generation.md).
  static Future<DesktopShell> start({
    required Directory dataDir,
    required DesktopPads? pads,
    Directory? storageRoot,
    TexturePackSink? texturePackSink,
    RunAheadSink? runAheadSink,
    ProfilesHost? profilesHost,
    ProfilesDatabase? profilesDb,
    FrameGenHost? frameGenHost,
    WindowControl window = const WindowControl(),
    bool? steamDeck,
    DeckModel? deckModel,
    bool? gamescope,
    SteamKeyboard? steamKeyboard,
    PadKeySynth? keys,
  }) async {
    final display = DesktopDisplaySettings.load(
      File(p.join(dataDir.path, 'desktop_display.json')),
    );
    final rewind = DesktopRewindSettings.load(
      File(p.join(dataDir.path, 'desktop_rewind.json')),
    );
    final runAhead = RunAheadSettings.load(
      File(p.join(dataDir.path, 'desktop_run_ahead.json')),
      sink: runAheadSink,
    );
    final profiles = ControllerProfileStore(
      db: profilesDb ?? ProfilesDatabase.open(dataDir),
      host: profilesHost,
    );
    try {
      await profiles.load();
    } catch (e) {
      // A broken profiles file leaves every pad playing as is.
      debugPrint('controller profiles: $e');
    }
    final texturePacks = storageRoot == null
        ? null
        : TexturePacks.load(
            root: Directory(p.join(storageRoot.path, 'Textures')),
            biosDir: Directory(p.join(storageRoot.path, 'Bios')),
            file: File(p.join(dataDir.path, 'texture_packs.json')),
            sink: texturePackSink,
          );
    texturePacks?.ensureFolders();
    final deck = steamDeck ?? detectSteamDeck();
    // A Deck the board name does not tell (only `SteamDeck=1`) is an LCD.
    var model = deck ? (deckModel ?? detectDeckModel()) : DeckModel.none;
    if (deck && model == DeckModel.none) model = DeckModel.lcd;
    final presets = DeckPresetSettings.load(
      File(p.join(dataDir.path, 'desktop_presets.json')),
      model: model,
    );
    final scope = gamescope ?? detectGamescope();
    final count = pads == null ? 0 : await waitForGamepads(pads.count);
    final launch = decideLaunch(
      setting: display.fullscreenAtLaunch,
      gamepads: count,
      steamDeck: deck,
      gamescope: scope,
    );
    // Back on the monitor it was last on, then fullscreen there; gamescope
    // has one screen and no window to place.
    if (!scope) {
      await window.restorePlacement(p.join(dataDir.path, 'window.txt'));
    }
    if (scope) (steamKeyboard ?? SteamKeyboard()).install();
    if (launch.fullscreen) await window.setFullscreen(true);
    final mode = ControllerMode(
      active: launch.controllerMode,
      family: PadFamily.fromHost(pads?.family() ?? -1),
      steamDeck: deck,
    );
    final shell = DesktopShell._(
      mode,
      display,
      RaOverlaySettings.load(File(p.join(dataDir.path, 'ra_overlay.json'))),
      rewind,
      runAhead,
      presets,
      profiles,
      NetplaySettings.load(File(p.join(dataDir.path, 'desktop_netplay.json'))),
      FrameGenSettings.load(
        File(p.join(dataDir.path, 'desktop_frame_generation.json')),
        host: frameGenHost,
      ),
      texturePacks,
      pads,
      keys ?? PadKeySynth(),
    );
    shell._listen(count);
    return shell;
  }

  void _listen(int padsAtStart) {
    final pads = _pads;
    if (pads == null) return;
    pads.listen((action, down, family) {
      if (down) mode.padUsed(PadFamily.fromHost(family));
      _keys.action(action, down);
    });
    // A pad plugged in later switches the UI, not the window.
    var last = padsAtStart;
    _hotplug = Timer.periodic(const Duration(seconds: 1), (_) {
      final n = pads.count();
      if (n > last) mode.padConnected();
      last = n;
    });
  }

  /// A mouse click (controller-mode.md, Leaving controller mode).
  void mouseUsed() => mode.mouseUsed(padsConnected: _pads?.count() ?? 0);

  void dispose() {
    SteamKeyboard.uninstall();
    _hotplug?.cancel();
    _pads?.close();
    _keys.dispose();
    profiles.db?.close();
  }
}

/// Puts [shell] above the app: controller mode, the display and run-ahead
/// settings, and mouse clicks leaving controller mode.
class DesktopShellScope extends StatelessWidget {
  const DesktopShellScope({
    super.key,
    required this.shell,
    required this.child,
  });

  final DesktopShell? shell;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = shell;
    if (s == null) return child;
    return ControllerScope(
      mode: s.mode,
      child: DesktopDisplayScope(
        settings: s.display,
        child: RaOverlayScope(
          settings: s.achievements,
          child: DesktopRewindScope(
            settings: s.rewind,
            child: RunAheadScope(
              settings: s.runAhead,
              child: DeckPresetsScope(
                settings: s.presets,
                child: ControllerProfilesScope(
                  store: s.profiles,
                  child: NetplayScope(
                    settings: s.netplay,
                    child: FrameGenScope(
                      settings: s.frameGen,
                      child: _packs(
                        s.texturePacks,
                        Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (e) {
                            if (e.kind == PointerDeviceKind.mouse) {
                              s.mouseUsed();
                            }
                          },
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _packs(TexturePacks? packs, Widget child) =>
    packs == null ? child : TexturePacksScope(packs: packs, child: child);

/// The TV layout below the app's MediaQuery: on in controller mode.
class ControllerTvLayout extends StatelessWidget {
  const ControllerTvLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      TvScale(enabled: ControllerScope.activeOf(context), child: child);
}
