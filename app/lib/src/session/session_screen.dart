// SPDX-License-Identifier: GPL-3.0-or-later
// Full-screen game session and its pause menu.
// Spec: docs/specs/game-session.md, docs/specs/shaders.md
import 'dart:async';

import 'package:dena_android/dena_android.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show
        KeyDownEvent,
        LogicalKeyboardKey,
        PlatformException,
        SystemChrome,
        SystemUiMode;
import 'package:path/path.dart' as p;

import '../achievements/achievements_overlay.dart';
import '../achievements/achievements_ui.dart';
import '../achievements/retro_achievements.dart';
import '../desktop/controller_profiles.dart';
import '../desktop/controller_profiles_page.dart';
import '../desktop/deck_presets.dart';
import '../desktop/frame_generation.dart';
import '../desktop/long_rewind.dart';
import '../desktop/netplay.dart';
import '../desktop/output_size.dart';
import '../desktop/run_ahead.dart';
import '../desktop/texture_packs.dart';
import '../carts/launcher.dart';
import '../carts/launcher_host.dart';
import '../library/box_art.dart';
import '../library/database.dart';

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import '../shaders/shader_sheet.dart';
import '../shaders/shader_store.dart';
import '../turbo/turbo.dart';
import '../shell/handheld.dart';
import '../shell/network.dart';
import '../shell/host_library.dart';
import '../shell/platform_features.dart';
import '../shell/power_link.dart';
import '../skins/builtin_skins.dart';
import '../skins/deltaskin.dart';
import '../skins/skin_layout.dart';
import '../skins/skin_store.dart';
import '../skins/touch_controls.dart';
import '../skins/touch_sink.dart';
import '../ui/app_theme.dart';
import '../ui/brutal/brutal.dart';
import 'bios_check.dart';
import 'cheat_database.dart';
import 'cheats_sheet.dart';
import 'link_cable.dart';
import 'pause_sheets.dart';
import 'pointer_area.dart';
import 'state_slots.dart';
import '../ui/dena_icons.dart';

/// Core library per system. Only packaged cores are listed; a system without
/// one cannot start (game-session.md, Cores per system).
const coreLibraries = {
  'nes': 'libfceumm_libretro.so',
  'snes': 'libbsnes_libretro.so',
  'gb': 'libmgba_libretro.so',
  'gbc': 'libmgba_libretro.so',
  'gba': 'libmgba_libretro.so',
  'nds': 'libmelonds_libretro.so',
  'psx': 'libpcsx_rearmed_libretro.so',
  'n64': 'libmupen64plus_libretro.so',
  'psp': 'libppsspp_libretro.so',
  // Windows and SteamOS only (dreamcast-saturn.md, ps2.md); the desktop
  // host maps the name to mednafen_saturn_libretro / flycast_libretro /
  // pcsx2_libretro (LRPS2).
  'saturn': 'libmednafen_saturn_libretro.so',
  'dreamcast': 'libflycast_libretro.so',
  // Dolphin, the same core for both (gamecube-wii.md).
  'gamecube': 'libdolphin_libretro.so',
  'wii': 'libdolphin_libretro.so',
  'ps2': 'libpcsx2_libretro.so',
  'pico8': 'libfake08_libretro.so',
};

/// The launcher's external texture for the game picture on Linux handhelds
/// (handheld-session.md).
const handheldGameTexture = 1;

/// The game picture: Android's SurfaceView, the launcher's texture on Linux
/// handhelds, the runner's texture on Windows and desktop Linux
/// (desktop-shell.md). [desktopTexture] is for tests.
Widget defaultGameView({ShellProfile? profile, int? desktopTexture}) =>
    switch (profile ?? shellProfile) {
      ShellProfile.handheld => const Texture(
        textureId: handheldGameTexture,
        filterQuality: FilterQuality.none,
      ),
      // -1 (no host library) shows nothing, like an unregistered texture.
      // Shader stacks draw at the picture's size on screen (shader-stacks.md).
      ShellProfile.desktop => DesktopOutputSize(
        child: Texture(
          textureId: desktopTexture ?? desktopGameTexture() ?? -1,
          filterQuality: FilterQuality.none,
        ),
      ),
      _ => const EmulatorSurfaceView(),
    };

/// Systems whose cores ship only with the Windows and SteamOS apps
/// (dreamcast-saturn.md, ps2.md, gamecube-wii.md); [GameSystem.desktopOnly]
/// by id.
const desktopOnlySystems = {'saturn', 'dreamcast', 'ps2', 'gamecube', 'wii'};

/// Systems whose games use L2, so it can't double as hold-to-rewind.
const systemsWithL2 = {
  'psx',
  'n64',
  'saturn',
  'dreamcast',
  'ps2',
  'gamecube',
  'wii',
};

/// Systems whose games read analog sticks (n64.md).
const analogSystems = {'n64', 'psp', 'dreamcast', 'ps2', 'gamecube', 'wii'};

/// Systems whose core can't restore a save state faithfully: no Save/Load,
/// rewind or auto-resume; the game restarts (pico8.md).
const systemsWithoutStates = {'pico8'};

/// Display aspect ratio of each system's picture.
const systemAspect = {
  'nes': 4 / 3,
  'snes': 4 / 3,
  'gb': 10 / 9,
  'gbc': 10 / 9,
  'gba': 3 / 2,
  'nds': 256 / 384, // both screens stacked (ds.md)
  'psx': 4 / 3,
  'n64': 4 / 3,
  'psp': 480 / 272,
  'saturn': 4 / 3,
  'dreamcast': 4 / 3,
  'gamecube': 4 / 3,
  'wii': 4 / 3,
  'ps2': 4 / 3,
  'pico8': 1.0,
  'genesis': 4 / 3,
};

const missingCoreMessage = "This system's core is not included in this build";

/// Shown when the emulator library (dena_host.dll / libdena_host.so) did not
/// load, so no host call has anyone listening.
const missingHostMessage =
    "The emulator library could not be loaded, so games can't start. "
    'Reinstall Dena.emu.';

const shaderFailedMessage = 'This shader could not be loaded';

/// Battery save and auto-save state paths for [game] under [dataDir]
/// (POSIX: the session runs on Android, Linux and iOS only).
({String srm, String state}) sessionFiles(String dataDir, Game game) => (
  srm: p.posix.join(dataDir, 'saves', '${game.sha1}.srm'),
  state: p.posix.join(dataDir, 'states', game.sha1, 'auto.state'),
);

enum PauseAction {
  resume,
  saveState,
  loadState,
  rewind,
  cheats,
  shader,
  achievements,
  link,
  netplay,
  quit,
}

/// Ends the running game as its Quit does (it saves and records the play
/// time), for a game opened from outside the app (open-with.md). Completes
/// at once when no game is running.
Future<void> quitActiveSession() => _activeQuit?.call() ?? Future.value();
Future<void> Function()? _activeQuit;

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.game,
    required this.dataDir,
    required this.db,
    this.api,
    this.gameView,
    this.clock = DateTime.now,
    this.registerEvents = GameEventsApi.setUp,
    this.touchSink,
    this.skins,
    this.shaders,
    this.turbo,
    this.cheatDb,
    this.launcher,
    this.achievements,
    this.link,
    this.netplay,
    this.longRewind,
    this.biosDir,
  });

  final Game game;

  /// App-private directory holding `saves/` and `states/`.
  final String dataDir;
  final LibraryDatabase db;

  /// Injectable for tests; defaults to the platform implementation.
  final GameHostApi? api;

  /// Replaces the native surface in tests.
  final Widget? gameView;
  final DateTime Function() clock;

  /// Registers the handler for controller events (gamepads.md); tests capture it.
  final void Function(GameEventsApi? handler) registerEvents;

  /// Where touch-control masks go; the dart:ffi sink when null.
  final TouchSink? touchSink;

  /// Imported skins; built-in controls only when null.
  final SkinStore? skins;

  /// Shader choices; `<dataDir>/shaders.json` when null (shaders.md).
  final ShaderStore? shaders;

  /// Turbo buttons; `<dataDir>/turbo.json` when null (turbo.md).
  final TurboStore? turbo;

  /// The cheat database to browse (cheats.md); `<dataDir>/cheats/` when null.
  final CheatDatabase? cheatDb;

  /// For the Dena Explore launcher cart (pico8-launcher-cart.md): makes the
  /// host that answers it once the game runs, or null where the shell has no
  /// mailbox. When the cart runs a game, the session ends and its route pops
  /// with that game.
  final LauncherHost? Function(void Function(Game game) onRun)? launcher;

  /// RetroAchievements (achievements.md); none when null.
  final RetroAchievements? achievements;

  /// The link cable (link-cable.md); the native one when null.
  final LinkCable? link;

  /// Netplay (netplay.md): the desktop host's when null, none elsewhere.
  final NetplayHost? netplay;

  /// Long rewind (rewind.md): the desktop host's when null, none elsewhere.
  final LongRewindHost? longRewind;

  /// The Bios folder checked before a Saturn or Dreamcast game starts
  /// (dreamcast-saturn.md); the desktop's when null, none elsewhere.
  final String? biosDir;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    implements GameEventsApi {
  late final GameHostApi api = widget.api ?? GameHostApi();
  late final AppLifecycleListener _lifecycle;
  bool running = false;
  bool sheetOpen = false;
  int speed = 1;

  /// Playing backwards until the player taps (rewind.md).
  bool rewinding = false;
  String? error;
  late DateTime _startedAt;

  /// The save slot the pause menu's strip points at (0 = slot 1).
  int _slot = 0;

  /// What happened in this session, for the pause menu's log lines.
  final _log = ValueNotifier<List<(String, LogStatus)>>(const []);

  void _addLog(String text, bool ok) {
    final now = widget.clock();
    String two(int v) => v.toString().padLeft(2, '0');
    _log.value = [
      ..._log.value,
      (
        '$text ${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
        ok ? LogStatus.ok : LogStatus.err,
      ),
    ];
  }

  /// FILE, SESSION and CORE for the pause menu (brutalist-ui.md 4.5).
  List<(String, String)> _meta() {
    String two(int v) => v.toString().padLeft(2, '0');
    final d = widget.clock().difference(_startedAt);
    final core = (coreLibraries[widget.game.system] ?? '')
        .replaceFirst(RegExp(r'^lib'), '')
        .replaceFirst(RegExp(r'_libretro\.so$'), '');
    return [
      ('FILE', widget.game.fileName),
      (
        'SESSION',
        '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}',
      ),
      ('CORE', '$core // ${speed}X'),
    ];
  }

  /// Device name per port; empty for a free port.
  List<String> players = const ['', '', '', ''];

  /// The external display showing the picture, or null (external-display.md).
  String? externalDisplay;

  /// Touch controls are showing (skins.md, last input wins).
  bool skinVisible = true;

  /// Handhelds have real buttons and no touch screen: never a skin
  /// (handheld-ui.md).
  bool _handheld = false;
  late final TouchSink? _touch = widget.touchSink ?? FfiTouchSink.open();
  InstalledSkin? _importedSkin;

  /// Run-ahead a preset changed for this game; put back on dispose.
  RunAheadSettings? _presetRunAhead;
  TexturePacks? _packs;

  late final ShaderStore _shaders =
      widget.shaders ?? ShaderStore(widget.dataDir);

  /// The core's widescreen hack is on for this run (desktop-resolution.md),
  /// so the picture is 16:9.
  bool _wide = false;

  double get _aspect =>
      (_wide ? 16 / 9 : systemAspect[widget.game.system] ?? 4 / 3);

  late final TurboStore _turboStore =
      widget.turbo ?? TurboStore(widget.dataDir);

  /// The turbo setup in effect for this game (turbo.md).
  late TurboConfig turbo = _turboStore.resolve(widget.game.sha1);

  void _applyTurbo() =>
      _touch?.setTurbo(turbo.mask, turboHalfFrames(turbo.rate));

  /// Only for systems with a link port; ends with the session.
  late final LinkCable? _link = systemsWithLink.contains(widget.game.system)
      ? widget.link ?? FfiLinkCable.open()
      : null;

  /// Two PCs on one game (netplay.md); Windows and SteamOS only.
  late final NetplayHost? _netplay =
      systemsWithNetplay.contains(widget.game.system)
      ? widget.netplay ?? FfiNetplayHost.open()
      : null;

  /// Minutes of rewind with a scrub bar; Windows and SteamOS only.
  late final LongRewindHost? _longRewind =
      widget.longRewind ?? FfiLongRewindHost.open();

  late final CheatDatabase _cheatDb =
      widget.cheatDb ??
      CheatDatabase(
        widget.dataDir,
        loadIndex: CheatDbIndex.load,
        loadNames: BoxArtIndex.load,
      );

  /// The shader showing ("" = Off); Off for the rest of the session after
  /// one fails to load (shaders.md).
  String shader = '';

  /// The handheld power daemon (power-daemon.md); null elsewhere.
  PowerLink? _power;

  /// Answers the launcher cart (pico8-launcher-cart.md); null otherwise.
  LauncherHost? _launcherHost;

  /// This session reports to RetroAchievements (achievements.md).
  RetroAchievements? get _ra =>
      (widget.achievements?.supports(widget.game.system) ?? false)
      ? widget.achievements
      : null;

  /// Hardcore: no state loads, rewind or cheats (achievements.md).
  bool _hardcore = false;

  void _onRaChanged() {
    final h = _ra?.session?.hardcore ?? false;
    if (mounted && h != _hardcore) setState(() => _hardcore = h);
  }

  /// The status and navigation bars are hidden while playing, in both
  /// orientations (skins.md).
  bool _barsHidden = false;

  void _syncSystemBars() {
    if (_barsHidden) return;
    _barsHidden = true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSystemBars();
    _handheld = Handheld.of(context);
    if (_handheld) skinVisible = false;
    final link = PowerScope.of(context);
    if (link == _power) return;
    _releasePower();
    _power = link
      ?..onSave = _saveForPower
      ..onResumed = _openPauseSheet;
  }

  /// Before sleep or power off: stop frames and write the saves.
  Future<void> _saveForPower() async {
    if (!running) return;
    _touch?.setButtons(0);
    await api.pause();
    await api.saveNow();
  }

  void _releasePower() {
    final link = _power;
    if (link == null) return;
    if (link.onSave == _saveForPower) link.onSave = null;
    if (link.onResumed == _openPauseSheet) link.onResumed = null;
  }

  @override
  void initState() {
    super.initState();
    _activeQuit = _quitFromOutside;
    widget.registerEvents(this);
    _lifecycle = AppLifecycleListener(
      onHide: () {
        if (running) api.pause();
      },
      onShow: () {
        if (running && !sheetOpen) api.resume();
      },
    );
    _startGuarded();
  }

  /// [_start], turning a host call that fails (no host library: Pigeon's
  /// channel-error) into the error screen instead of an unhandled throw.
  Future<void> _startGuarded() async {
    try {
      await _start();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(
        () => error = e.code == 'channel-error'
            ? missingHostMessage
            : (e.message ?? 'The game could not start'),
      );
    }
  }

  FrameGenSettings? _frameGen;
  Timer? _frameGenCheck;
  ControllerProfileStore? _profiles;

  Future<void> _start() async {
    final core = coreLibraries[widget.game.system];
    if (core == null) {
      setState(() => error = missingCoreMessage);
      return;
    }
    final biosDir =
        widget.biosDir ?? (desktopResolution ? desktopBiosDir() : null);
    final bios = biosDir == null
        ? const BiosReady()
        : checkBios(widget.game.system, biosDir);
    if (bios is BiosMissing) {
      setState(() => error = bios.message);
      return;
    }
    _importedSkin = await widget.skins?.active(widget.game.system);
    if (!mounted) return;
    final files = sessionFiles(widget.dataDir, widget.game);
    final states = !systemsWithoutStates.contains(widget.game.system);
    // Set before start so the shader applies from the first frame.
    final saved = _shaders.resolve(widget.game.system, widget.game.sha1);
    final shaderOk = saved.isEmpty || await _applyShader(saved, report: false);
    if (!mounted) return;
    // The system's Steam Deck preset (deck-presets.md): its factor unless
    // the game has its own RES, and its run-ahead frames for this game.
    final plan = DeckPresetsScope.maybeOf(context)
        ?.planFor(widget.game.system, screenHeight: screenOf(context).height);
    final runAhead = RunAheadScope.maybeOf(context);
    if (plan != null && runAhead != null) {
      applyPresetRunAhead(runAhead, plan);
      _presetRunAhead = runAhead;
    }
    // Internal resolution is a core option, read when the game loads.
    await api.setUpscale(
      plan != null && !_shaders.hasGameUpscale(widget.game.sha1)
          ? plan.upscale
          : _shaders.resolveUpscale(widget.game.system, widget.game.sha1),
    );
    final wide = _shaders.resolveWidescreen(
      widget.game.system,
      widget.game.sha1,
    );
    await api.setWidescreen(wide);
    if (!mounted) return;
    // HD texture packs (texture-packs.md): the core's pack folder is linked
    // and its replacement switched on before it loads.
    _packs = TexturePacksScope.maybeOf(context)
      ?..prepare((
        sha1: widget.game.sha1,
        system: widget.game.system,
        path: widget.game.path,
      ));
    // The audio buffer target is applied when audio opens at start
    // (performance.md), so set it before the game runs.
    // This game's controller profiles (gamepads.md); cleared in dispose().
    _profiles = ControllerProfilesScope.maybeOf(context)
      ?..applyGame(widget.game.sha1, widget.game.system);
    // This system's frame generation (frame-generation.md); the host turns
    // it off when the game gets too slow, which the timer keeps.
    _frameGen = FrameGenScope.maybeOf(context)?..startGame(widget.game.system);
    await api.setAudioLatency(ThemeScope.of(context).notifier!.audioLatencyMs);
    // Hardcore never resumes the auto-save state (achievements.md).
    final resume =
        states &&
        !(widget.achievements?.hardcoreFor(widget.game.system) ?? false);
    final r = await api.start(
      core,
      widget.game.path,
      files.srm,
      resume ? files.state : '',
    );
    if (!mounted) {
      // Left while the core was loading: dispose() saw running == false, so
      // stop here or the core keeps running and blocks the next launch.
      if (r.outcome != null) await api.stop();
      return;
    }
    if (r.outcome == null) {
      // Beetle Saturn refuses a disc whose region's BIOS is missing; LRPS2
      // one it can't read as a PS2 BIOS.
      final why = r.error ?? 'The game could not start';
      final hint = biosDir == null
          ? null
          : switch (widget.game.system) {
              'saturn' => saturnBiosMessage(biosDir),
              'ps2' => ps2BiosMessage(biosDir),
              _ => null,
            };
      setState(() => error = hint == null ? why : '$why. $hint');
      return;
    }
    _startedAt = widget.clock();
    if (_frameGen case final fg?) {
      _frameGenCheck = Timer.periodic(
        const Duration(seconds: 2),
        (_) => fg.checkStatus(),
      );
    }
    setState(() {
      running = true;
      _wide = wide;
    });
    _ra?.addListener(_onRaChanged);
    await _ra?.beginSession(widget.game.path, widget.game.system);
    _launcherHost = widget.launcher?.call(_runFromLauncher)?..start();
    await api.setTouchMode(!_handheld);
    _applyTurbo();
    // A held L2 rewinds unless the system has an L2 button (rewind.md).
    await api.configureRewind(
      states,
      !systemsWithL2.contains(widget.game.system),
    );
    // The desktop's buffer holds minutes (Settings > Rewind buffer).
    if (states && mounted) {
      final buffer = DesktopRewindScope.maybeOf(context)?.buffer;
      _longRewind?.setBudget((buffer ?? RewindBuffer.gb1).bytes);
    }
    await api.setAnalogMode(analogSystems.contains(widget.game.system));
    await api.setDisplayAspect(_aspect);
    // The runner refuses cheats once hardcore is confirmed.
    final cheats = await enabledCheatCodes(widget.db, widget.game.id);
    if (cheats.isNotEmpty) await api.setCheats(cheats);
    if (!mounted) return;
    if (!shaderOk) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(shaderFailedMessage)));
    }
    if (bios is BiosReplaced) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(bios.message)));
    }
    if (r.outcome == StartOutcome.badState) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "The last session couldn't be restored; starting fresh.",
          ),
        ),
      );
    }
  }

  Future<void> _openPauseSheet() async {
    if (!running || sheetOpen) return;
    sheetOpen = true;
    _touch?.setButtons(0);
    await api.pause();
    // The sheet reopens after a cancelled slot pick or a failed load.
    while (true) {
      if (!mounted) return;
      final cheats = _hardcore
          ? null
          : await widget.db.cheatsFor(widget.game.id);
      if (!mounted) return;
      final states = !systemsWithoutStates.contains(widget.game.system);
      final action = await showGeneralDialog<PauseAction>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        // The live game stays visible behind the menu (brutalist-ui.md 4.5).
        barrierColor: Colors.transparent,
        transitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => PauseSheet(
          title: widget.game.title,
          // The launcher reads the built-in buttons itself and reports no
          // players (handheld-session.md).
          players: _handheld && players.every((p) => p.isEmpty)
              ? const ['Built-in controls', '', '', '']
              : players,
          onCapture: _capture,
          states: states,
          hardcore: _hardcore,
          achievements: _ra?.session,
          // The link cable plays over Wi-Fi (network.dart).
          link:
              systemsWithLink.contains(widget.game.system) &&
                  NetworkScope.read(context)
              ? _link
              : null,
          netplay: NetplayScope.maybeOf(context) == null
              ? null
              : _netplay?.info,
          slots: states
              ? listSlots(widget.dataDir, widget.game.sha1)
              : const [],
          slotAspect: _aspect,
          slot: _slot,
          onSlot: (i) => _slot = i,
          cheats: cheats == null
              ? null
              : (cheats.where((c) => c.enabled).length, cheats.length),
          shaderName: shader.isEmpty
              ? null
              : p.basenameWithoutExtension(shader),
          meta: _meta(),
          log: _log,
          clock: widget.clock,
          speed: speed,
          onSpeed: (s) {
            speed = s;
            api.setSpeed(s);
          },
          turbo: turbo,
          onTurbo: (c) {
            turbo = c;
            _turboStore.setGame(widget.game.sha1, c);
            _applyTurbo();
          },
        ),
      );
      if (!mounted) return;
      switch (action) {
        case PauseAction.quit:
          sheetOpen = false;
          await _quit();
          return;
        case PauseAction.saveState || PauseAction.loadState:
          final done = await _pickSlot(
            action == PauseAction.saveState ? SlotMode.save : SlotMode.load,
          );
          if (!done) continue;
        case PauseAction.cheats:
          await showSessionSheet<void>(
            context: context,
            title: CheatsSheet.title,
            builder: (_) => CheatsSheet(
              db: widget.db,
              game: widget.game,
              apply: api.setCheats,
              database: _cheatDb,
            ),
          );
          continue;
        case PauseAction.shader:
          await showSessionSheet<void>(
            context: context,
            title: 'SHADER.CFG',
            // Keeps the preview behind the sheet undimmed.
            dim: false,
            builder: (_) => ShaderSheet(
              store: _shaders,
              system: widget.game.system,
              gameSha1: widget.game.sha1,
              current: shader,
              onApply: _applyShader,
              embedded: true,
            ),
          );
          continue;
        case PauseAction.achievements:
          final ra = _ra;
          if (ra != null) {
            await showSessionSheet<void>(
              context: context,
              title: 'ACHIEVEMENTS',
              builder: (_) => SessionAchievementsSheet(ra: ra),
            );
          }
          continue;
        case PauseAction.link:
          await showSessionSheet<void>(
            context: context,
            title: 'LINK.CABLE',
            builder: (_) => LinkCableSheet(
              link: _link!,
              gameTitle: widget.game.title,
              // Desktop: rooms over the internet (netplay.md).
              internet: NetplayScope.maybeOf(context),
            ),
          );
          continue;
        case PauseAction.netplay:
          final settings = NetplayScope.maybeOf(context);
          if (settings != null) {
            await showSessionSheet<void>(
              context: context,
              title: 'NETPLAY',
              builder: (_) =>
                  NetplaySheet(netplay: _netplay!, settings: settings),
            );
          }
          continue;
        case PauseAction.rewind:
          // Desktop: scrub back through minutes; back to the menu on B.
          if (_longRewind?.begin() case final info?) {
            final keep = await showSessionSheet<bool>(
              context: context,
              title: 'REWIND',
              dim: false,
              builder: (_) => RewindScrubSheet(info: info, host: _longRewind!),
            );
            _longRewind!.end(keep: keep ?? false);
            if (!mounted) return;
            if (keep != true) continue;
            _addLog('rewind', true);
            break;
          }
          sheetOpen = false;
          await api.resume();
          await _setRewinding(true);
          return;
        case PauseAction.resume || null:
          break;
      }
      sheetOpen = false;
      await api.resume();
      return;
    }
  }

  /// Shows [id] ("" = Off). On a load error the session falls back to Off
  /// and, when [report], says so; returns whether [id] is showing.
  Future<bool> _applyShader(String id, {bool report = true}) async {
    final err = await api.setShader(id);
    if (err == null) {
      shader = id;
      return true;
    }
    // A failed load keeps the previous picture path; turn that one off too.
    if (shader.isNotEmpty) await api.setShader('');
    shader = '';
    if (report && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text(shaderFailedMessage)));
    }
    return false;
  }

  /// Saves to or loads from a slot the player picks. False when nothing
  /// happened (cancelled, or the load failed), so the pause sheet comes back.
  Future<bool> _pickSlot(SlotMode mode) async {
    final slot = await showSessionSheet<StateSlot>(
      context: context,
      title: SlotSheet.titleFor(mode),
      builder: (context) => SlotSheet(
        mode: mode,
        slots: listSlots(widget.dataDir, widget.game.sha1),
        aspectRatio: _aspect,
        initial: 'slot${_slot + 1}',
        clock: widget.clock,
      ),
    );
    if (slot == null || !mounted) return false;
    final err = mode == SlotMode.save
        ? await api.saveState(slot.statePath, slot.pngPath)
        : await api.loadState(slot.statePath);
    if (!mounted) return false;
    final message =
        err ??
        (mode == SlotMode.save
            ? 'Saved to ${slot.label.toLowerCase()}'
            : 'Loaded ${slot.label.toLowerCase()}');
    _addLog(
      '${mode == SlotMode.save ? 'state_save' : 'state_load'} '
      '${slot.id}',
      err == null,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    return err == null;
  }

  Future<void> _setRewinding(bool on) async {
    if (!mounted || rewinding == on) return;
    setState(() => rewinding = on);
    await api.setRewinding(on);
  }

  Future<void> _capture() async {
    final t = widget.clock();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
    final title = widget.game.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final err = await api.captureScreenshot('$title $stamp');
    if (!mounted) return;
    _addLog('screenshot', err == null);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(err ?? 'Screenshot saved')));
  }

  /// Before the core stops.
  void _endAchievements() {
    _ra?.removeListener(_onRaChanged);
    _ra?.endSession();
  }

  /// Before the core stops: keeps a fallback from the host, then off.
  void _endFrameGen() {
    _frameGenCheck?.cancel();
    _frameGenCheck = null;
    _frameGen?.endGame();
    _frameGen = null;
  }

  Future<void> _quit() async {
    _launcherHost?.stop();
    setState(() => running = false);
    _endAchievements();
    _endFrameGen();
    await api.stop();
    final now = widget.clock();
    if (!isLauncher(widget.game)) {
      await widget.db.recordPlay(
        widget.game.id,
        at: now,
        seconds: now.difference(_startedAt).inSeconds,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// The launcher cart chose [game]: end this session and hand it over.
  Future<void> _runFromLauncher(Game game) async {
    _launcherHost?.stop();
    if (!running) return;
    setState(() => running = false);
    _endAchievements();
    _endFrameGen();
    await api.stop();
    if (mounted) Navigator.of(context).pop(game);
  }

  /// [quitActiveSession]: closes the pause menu or a sheet first.
  Future<void> _quitFromOutside() async {
    if (!running || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null) Navigator.of(context).popUntil((r) => r == route);
    await _quit();
  }

  @override
  void dispose() {
    if (_activeQuit == _quitFromOutside) _activeQuit = null;
    widget.registerEvents(null);
    _releasePower();
    _log.dispose();
    _lifecycle.dispose();
    if (_barsHidden) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _launcherHost?.stop();
    _link?.stop();
    _netplay?.stop();
    _profiles?.applyGame('', '');
    if (running) _endAchievements();
    _endFrameGen();
    if (running) api.stop();
    if (_presetRunAhead case final r?) restoreRunAhead(r);
    _packs?.reset();
    super.dispose();
  }

  /// PICO-8 keeps its picture and controls clear of camera cutouts
  /// (pico8.md): the game area is inset by the cutout's edges.
  Widget _cutoutSafe(Size size, double aspect) {
    if (widget.game.system != 'pico8') return _gameArea(size, aspect);
    final inset = cutoutInsets(
      MediaQuery.displayFeaturesOf(context),
      MediaQuery.viewPaddingOf(context),
      size,
    );
    return Padding(
      padding: inset,
      child: _gameArea(inset.deflateSize(size), aspect),
    );
  }

  Widget _gameArea(Size size, double aspect) {
    Widget view = running
        ? (widget.gameView ?? defaultGameView())
        : const SizedBox.shrink();
    final external = externalDisplay;
    if (running && external != null) {
      // The picture is on the external display; the phone keeps the controls.
      view = Stack(
        fit: StackFit.expand,
        children: [
          view,
          ColoredBox(
            color: Colors.black,
            child: Center(
              child: Text(
                'Playing on $external',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: Colors.white70),
              ),
            ),
          ),
        ],
      );
    }
    if (running && widget.game.system == 'nds') {
      // The lower screen is a touch screen (ds.md).
      view = PointerArea(
        onPointer: (x, y, down) => _touch?.setPointer(x, y, down),
        child: view,
      );
    }
    final fold = tabletopFold(MediaQuery.displayFeaturesOf(context));
    if (!skinVisible) {
      final picture = Center(
        child: AspectRatio(aspectRatio: aspect, child: view),
      );
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _showSkin(),
        // Tabletop: the picture stays on the upright half (adaptive.md).
        child: fold == null
            ? picture
            : Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: size.width,
                  height: fold.top,
                  child: picture,
                ),
              ),
      );
    }
    final imported = _importedSkin;
    final rep = imported?.skin.pick(size, tablet: size.shortestSide >= 600);
    if (imported != null && rep != null) {
      return SkinView(
        layout: rep.layout,
        game: view,
        artwork: _SkinArtwork(store: widget.skins!, skin: imported, rep: rep),
        paintItems: imported.skin.debug,
        onMask: (m) => _touch?.setButtons(m),
        onAnalog: _onAnalog,
        onMenu: _openPauseSheet,
      );
    }
    return SkinView(
      layout: builtinSkin(widget.game.system, size, aspect, fold: fold),
      game: view,
      onMask: (m) => _touch?.setButtons(m),
      onAnalog: _onAnalog,
      onMenu: _openPauseSheet,
    );
  }

  void _onAnalog(int stick, Offset tilt) => _touch?.setAnalog(
    stick,
    (tilt.dx * 0x7fff).round(),
    (tilt.dy * 0x7fff).round(),
  );

  @override
  void onMenuRequested() => _openPauseSheet();

  @override
  void onPlayersChanged(List<String> names) {
    if (mounted) setState(() => players = List.of(names));
  }

  @override
  void onGamepadUsed() {
    if (!mounted) return;
    _touch?.setButtons(0);
    setState(() => skinVisible = false);
  }

  void _showSkin() {
    if (skinVisible || !running || _handheld) return;
    setState(() => skinVisible = true);
    api.setTouchMode(true);
  }

  @override
  void onExternalDisplayChanged(String? name) {
    if (mounted) setState(() => externalDisplay = name);
  }

  @override
  void onControllerDisconnected(int port, String name) {
    if (!mounted) return;
    _showSkin();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Controller ${port + 1} disconnected')),
      );
    _openPauseSheet();
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _aspect;
    final err = error;
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _openPauseSheet();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: err != null
            ? _StartError(message: err)
            : LayoutBuilder(
                builder: (context, box) => Stack(
                  fit: StackFit.expand,
                  children: [
                    _cutoutSafe(box.biggest, aspect),
                    if (rewinding)
                      _RewindOverlay(onStop: () => _setRewinding(false)),
                    if (_ra case final ra?)
                      Positioned.fill(
                        child: switch (RaOverlayScope.maybeOf(context)) {
                          final overlay? => RaOverlay(
                            ra: ra,
                            settings: overlay,
                            chime: desktopChime,
                          ),
                          null => RaToastLayer(notices: ra.notices),
                        },
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Covers the game while rewinding; a tap, click or A stops (rewind.md).
class _RewindOverlay extends StatelessWidget {
  const _RewindOverlay({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) onStop();
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onStop,
        child: Align(
          alignment: const Alignment(0, -0.9),
          child: Chip(
            avatar: Icon(
              DenaIcons.fastRewind,
              color: scheme.onSecondaryContainer,
            ),
            label: const Text('Rewinding · tap to stop'),
            backgroundColor: scheme.secondaryContainer,
          ),
        ),
      ),
    );
  }
}

class _StartError extends StatelessWidget {
  const _StartError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to library'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pause menu (pause-menu.md, brutalist-ui.md 4.5). The game stays
/// visible with a PAUSED sticker; every action is a numbered button.
/// Phones stack the buttons under the game; handhelds and desktops show two
/// columns (game, meta and slot strip left, buttons right) that fit without
/// scrolling, moving Rewind, Shader, Controllers and Link cable under
/// SETTINGS > GAME.CFG when the stack runs out of room. Pops with the chosen
/// [PauseAction]; Back (B) or a tap on the game resumes.
class PauseSheet extends StatefulWidget {
  const PauseSheet({
    super.key,
    required this.title,
    required this.speed,
    required this.onSpeed,
    this.players = const ['', '', '', ''],
    this.onCapture,
    this.states = true,
    this.turbo,
    this.onTurbo,
    this.hardcore = false,
    this.achievements,
    this.link,
    this.netplay,
    this.slots = const [],
    this.slotAspect = 4 / 3,
    this.slot = 0,
    this.onSlot,
    this.cheats,
    this.shaderName,
    this.meta = const [],
    this.log,
    this.clock = DateTime.now,
  });

  final String title;

  /// The link cable, for systems that have one (link-cable.md).
  final LinkCable? link;

  /// Netplay's state on the desktop (netplay.md); no row when null.
  final NetplayInfo? netplay;

  /// Offer Save, Load and Rewind (false where states don't work, pico8.md).
  final bool states;

  /// RetroAchievements hardcore: Save only, no Load, Rewind or Cheats.
  final bool hardcore;

  /// The game RetroAchievements identified; shows the Achievements button.
  final RaSession? achievements;
  final int speed;
  final ValueChanged<int> onSpeed;

  /// This game's turbo setup (turbo.md), under SETTINGS; none when null.
  final TurboConfig? turbo;
  final ValueChanged<TurboConfig>? onTurbo;

  /// Device name per port (gamepads.md); empty for a free port.
  final List<String> players;

  /// Saves a screenshot; the sheet stays open (pause-menu.md).
  final VoidCallback? onCapture;

  /// The game's save slots; slots 1 to 4 make the slot strip.
  final List<StateSlot> slots;

  /// The game's picture aspect ratio, for the slot thumbnails.
  final double slotAspect;

  /// The strip slot picked (0 = slot 1); Save and Load start on it.
  final int slot;
  final ValueChanged<int>? onSlot;

  /// Enabled and stored cheats, for `CHEATS [3/8 ON]`.
  final (int, int)? cheats;

  /// The shader showing, for `SHADER [CRT-LITE]`; Off when null or empty.
  final String? shaderName;

  /// The FILE / SESSION / CORE strip (handheld and desktop).
  final List<(String, String)> meta;

  /// The last actions of this session, newest last (phone).
  final ValueListenable<List<(String, LogStatus)>>? log;
  final DateTime Function() clock;

  /// Slots 1 to 4 of [slots]: the strip.
  static List<StateSlot> stripOf(List<StateSlot> slots) => [
    for (final s in slots)
      if (RegExp(r'^slot[1-4]$').hasMatch(s.id)) s,
  ];

  @override
  State<PauseSheet> createState() => _PauseSheetState();
}

/// One button of the pause stack.
typedef _PauseItem = ({
  String label,
  IconData icon,
  String? value,
  BrutalButtonVariant variant,
  VoidCallback? onPressed,
  bool fold,
  bool speed,
});

class _PauseSheetState extends State<PauseSheet> {
  late int speed = widget.speed;
  late TurboConfig? turbo = widget.turbo;
  late int slot = widget.slot;
  late final List<StateSlot> strip = PauseSheet.stripOf(widget.slots);

  void _pop(PauseAction a) => Navigator.of(context).pop(a);

  void _pickSlot(int i) {
    if (strip.isEmpty) return;
    final next = i % strip.length;
    setState(() => slot = next);
    widget.onSlot?.call(next);
  }

  Future<void> _controllers() => showSessionSheet<void>(
    context: context,
    title: 'CONTROLLERS',
    builder: (_) => ControllersSheet(players: widget.players),
  );

  Future<void> _settings(List<_PauseItem> folded) async {
    final picked = await showSessionSheet<int>(
      context: context,
      title: 'GAME.CFG',
      builder: (_) => GameCfgSheet(
        entries: [
          for (final f in folded)
            // Long values (a shader name) don't fit beside the label.
            (
              label: f.label,
              value: (f.value?.length ?? 0) <= 6 ? f.value : null,
            ),
        ],
        turbo: turbo,
        onTurbo: (c) {
          turbo = c;
          widget.onTurbo?.call(c);
        },
      ),
    );
    if (picked != null && mounted) folded[picked].onPressed?.call();
  }

  /// A shader file name short enough for the button's value.
  static String _short(String name) {
    final n = name.toUpperCase();
    return n.length <= 10 ? n : '${n.substring(0, 9)}…';
  }

  int get _playerCount => widget.players.where((p) => p.isNotEmpty).length;

  List<_PauseItem> _items() {
    _PauseItem item(
      String label,
      IconData icon,
      VoidCallback? onPressed, {
      String? value,
      BrutalButtonVariant variant = BrutalButtonVariant.plain,
      bool fold = false,
      bool speed = false,
    }) => (
      label: label,
      icon: icon,
      value: value,
      variant: variant,
      onPressed: onPressed,
      fold: fold,
      speed: speed,
    );
    final saved = widget.slots.where((s) => !s.isEmpty).length;
    final shader = widget.shaderName ?? '';
    final link = widget.link;
    return [
      item(
        'Resume',
        DenaIcons.play,
        () => _pop(PauseAction.resume),
        variant: BrutalButtonVariant.primary,
      ),
      if (widget.states) ...[
        item('Save state', DenaIcons.save, () => _pop(PauseAction.saveState)),
        if (!widget.hardcore) ...[
          item(
            'Load state',
            DenaIcons.restore,
            () => _pop(PauseAction.loadState),
            value: widget.slots.isEmpty
                ? null
                : '[$saved ${saved == 1 ? 'FILE' : 'FILES'}]',
          ),
          item(
            'Rewind',
            DenaIcons.fastRewind,
            () => _pop(PauseAction.rewind),
            fold: true,
          ),
        ],
      ],
      if (!widget.hardcore)
        item(
          'Cheats',
          DenaIcons.magic,
          () => _pop(PauseAction.cheats),
          value: switch (widget.cheats) {
            (final on, final all) when all > 0 => '[$on/$all ON]',
            _ => null,
          },
        ),
      item(
        'Shader',
        DenaIcons.tv,
        () => _pop(PauseAction.shader),
        value: shader.isEmpty ? '[OFF]' : '[${_short(shader)}]',
        fold: true,
      ),
      item('Screenshot', DenaIcons.camera, widget.onCapture, value: '.PNG'),
      item('Speed', DenaIcons.fastForward, null, speed: true),
      item(
        'Controllers',
        DenaIcons.controller,
        _controllers,
        value: '[$_playerCount]',
        fold: true,
      ),
      if (link != null)
        item(
          'Link cable',
          link.state == LinkState.connected
              ? DenaIcons.link
              : DenaIcons.linkOff,
          () => _pop(PauseAction.link),
          value: switch (link.state) {
            LinkState.connected => '[ON]',
            LinkState.waiting => '[WAIT]',
            _ => '[OFF]',
          },
          fold: true,
        ),
      if (widget.netplay case final n?)
        item(
          'Netplay',
          n.state == NetplayState.playing ? DenaIcons.link : DenaIcons.network,
          () => _pop(PauseAction.netplay),
          value: netplayBadge(n),
          fold: true,
        ),
      if (widget.achievements case final a?)
        item(
          'Achievements',
          DenaIcons.trophy,
          () => _pop(PauseAction.achievements),
          value: '[${a.unlocked}/${a.total}]',
        ),
      item(
        'Quit game',
        DenaIcons.exit,
        () => _pop(PauseAction.quit),
        value: '!!',
        variant: BrutalButtonVariant.dark,
      ),
    ];
  }

  /// The visible stack: with [fold] the foldable actions move under a
  /// SETTINGS button; SETTINGS also appears when there is a turbo setup.
  List<_PauseItem> _stack(List<_PauseItem> all, {required bool fold}) {
    final folded = fold ? all.where((i) => i.fold).toList() : <_PauseItem>[];
    final shown = [
      for (final i in all)
        if (!fold || !i.fold) i,
    ];
    if (GameCfgSheet.hasContent([
      for (final f in folded) (label: f.label, value: f.value),
    ], turbo)) {
      shown.insert(shown.length - 1, (
        label: 'Settings',
        icon: DenaIcons.settings,
        value: '->',
        variant: BrutalButtonVariant.plain,
        onPressed: () => _settings(folded),
        fold: false,
        speed: false,
      ));
    }
    return shown;
  }

  Widget _button(_PauseItem item, int i, {bool autofocus = false}) {
    final index = (i + 1).toString().padLeft(2, '0');
    if (item.speed) {
      return _SpeedRow(
        index: index,
        icon: item.icon,
        speed: speed,
        onChanged: (s) {
          setState(() => speed = s);
          widget.onSpeed(s);
        },
      );
    }
    return BrutalButton(
      label: item.label,
      icon: item.icon,
      index: index,
      value: item.value,
      variant: item.variant,
      expand: true,
      autofocus: autofocus,
      onPressed: item.onPressed,
    );
  }

  Widget _slotStrip({required double height}) {
    final now = widget.clock();
    // L1/R1 pick the slot on a pad, so the D-pad walks only the stack.
    return SizedBox(
      height: height,
      child: ExcludeFocus(
        child: Row(
          children: [
            for (final (i, s) in strip.indexed) ...[
              if (i > 0) const SizedBox(width: BrutalTokens.s2),
              Expanded(
                child: SlotCard(
                  slot: s,
                  now: now,
                  selected: i == slot,
                  onPressed: () => _pickSlot(i),
                ),
              ),
            ],
            for (var i = strip.length; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: BrutalTokens.s2),
              const Expanded(child: SizedBox()),
            ],
          ],
        ),
      ),
    );
  }

  /// The game area: transparent so the live game shows through, with the
  /// sticker on its top-left. A tap resumes.
  Widget _gameArea({Widget? caption}) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _pop(PauseAction.resume),
    child: Stack(
      children: [
        const Positioned(left: 4, top: 8, child: _PausedSticker()),
        if (caption != null) Positioned(right: 0, bottom: 0, child: caption),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    // Narrow windows (a phone, a portrait desktop window) stack.
    final phone =
        t.density == BrutalDensity.phone ||
        MediaQuery.sizeOf(context).width < 600;
    final body = phone ? _phone(t) : _wide(t);
    final shortcuts = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.gameButtonLeft1): () =>
            _pickSlot(slot - 1 + strip.length),
        const SingleActivator(LogicalKeyboardKey.gameButtonRight1): () =>
            _pickSlot(slot + 1),
      },
      child: FocusTraversalGroup(child: body),
    );
    if (!usesButtons(context)) {
      return Material(type: MaterialType.transparency, child: shortcuts);
    }
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          Expanded(child: shortcuts),
          BrutalHintBar(
            hints: [
              ([HintButton.a], 'OK'),
              ([HintButton.b], 'Back'),
              if (strip.isNotEmpty) ([HintButton.l1, HintButton.r1], 'Slot'),
            ],
          ),
        ],
      ),
    );
  }

  /// Phone: the game on top, the numbered stack under it, the log last.
  Widget _phone(BrutalTokens t) {
    final items = _stack(_items(), fold: false);
    final caption = [
      for (final (k, v) in widget.meta)
        if (k == 'SESSION') v.split(' ').first,
      BrutalTokens.fileName(widget.title),
    ].join(' // ');
    final size = MediaQuery.sizeOf(context);
    return Column(
      children: [
        Expanded(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.all(BrutalTokens.s3),
              child: _gameArea(
                caption: Container(
                  color: const Color(0xFF000000),
                  padding: const EdgeInsets.symmetric(
                    horizontal: BrutalTokens.s2,
                    vertical: BrutalTokens.s1,
                  ),
                  child: Text(
                    caption,
                    style: t.small.copyWith(color: const Color(0xFFF2F2EC)),
                  ),
                ),
              ),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: size.height * 0.72),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: t.ink, width: BrutalTokens.border),
              ),
            ),
            child: BrutalGridPaper(
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    BrutalTokens.s4,
                    BrutalTokens.s4,
                    BrutalTokens.s4,
                    BrutalTokens.s4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, item) in items.indexed) ...[
                        if (i > 0) const SizedBox(height: BrutalTokens.s2),
                        _button(item, i, autofocus: i == 0),
                        if (item.label == 'Save state' && strip.isNotEmpty) ...[
                          const SizedBox(height: BrutalTokens.s2),
                          _slotStrip(height: 72),
                        ],
                      ],
                      const SizedBox(height: BrutalTokens.s4),
                      _Log(log: widget.log),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Handheld and desktop: two columns that fit without scrolling.
  Widget _wide(BrutalTokens t) {
    final handheld = t.density == BrutalDensity.handheld;
    final gap = handheld ? 6.0 : BrutalTokens.s3;
    final all = _items();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(handheld ? BrutalTokens.s3 : BrutalTokens.s6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 11,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _gameArea()),
                  if (widget.meta.isNotEmpty) ...[
                    SizedBox(height: gap),
                    KeyValueStrip(entries: widget.meta),
                  ],
                  if (strip.isNotEmpty) ...[
                    SizedBox(height: gap + 2),
                    _slotStrip(height: handheld ? 70 : 104),
                  ],
                ],
              ),
            ),
            SizedBox(width: handheld ? BrutalTokens.s3 : BrutalTokens.s6),
            Expanded(
              flex: 9,
              child: LayoutBuilder(
                builder: (context, box) {
                  final extent = t.buttonHeight + t.shadowOffset.dy + gap;
                  final unfolded = _stack(all, fold: false);
                  final fits = unfolded.length * extent <= box.maxHeight + gap;
                  final items = fits ? unfolded : _stack(all, fold: true);
                  return Padding(
                    // Room for the `<-` focus marker.
                    padding: const EdgeInsets.only(right: BrutalTokens.s6 + 4),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, item) in items.indexed) ...[
                            if (i > 0) SizedBox(height: gap),
                            _button(item, i, autofocus: i == 0),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `08 SPEED  [1X] 2X 4X`: a button-shaped row with the segment inline; it
/// lights up while one of its values has focus.
class _SpeedRow extends StatefulWidget {
  const _SpeedRow({
    required this.index,
    required this.icon,
    required this.speed,
    required this.onChanged,
  });

  final String index;
  final IconData icon;
  final int speed;
  final ValueChanged<int> onChanged;

  @override
  State<_SpeedRow> createState() => _SpeedRowState();
}

class _SpeedRowState extends State<_SpeedRow> {
  bool lit = false;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final fg = lit ? t.onFocus : t.ink;
    final pad = t.density == BrutalDensity.handheld
        ? BrutalTokens.s2
        : BrutalTokens.s3;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => lit = f),
      child: BrutalShadowBox(
        pressed: false,
        offset: t.shadowOffset,
        color: t.shadow,
        child: Container(
          constraints: BoxConstraints(minHeight: t.buttonHeight),
          padding: EdgeInsets.symmetric(horizontal: pad),
          decoration: BoxDecoration(
            color: lit ? t.focus : t.panel,
            border: Border.all(color: t.ink, width: BrutalTokens.border),
          ),
          child: Row(
            children: [
              Text(
                widget.index,
                style: t.small.copyWith(color: fg.withValues(alpha: 0.75)),
              ),
              const SizedBox(width: BrutalTokens.s2),
              Icon(widget.icon, size: BrutalTokens.iconSize, color: fg),
              const SizedBox(width: BrutalTokens.s2),
              Text(
                'SPEED',
                style: t.label.copyWith(color: fg),
                maxLines: 1,
                softWrap: false,
              ),
              const SizedBox(width: BrutalTokens.s2),
              // Shrinks on narrow handheld columns rather than overflow.
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: CfgSegment<int>(
                      values: const [1, 2, 4],
                      selected: widget.speed,
                      labelOf: (v) => '${v}X',
                      onChanged: widget.onChanged,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PAUSED, slapped on in two steps (1.15 then 1.0), instant without
/// animations.
class _PausedSticker extends StatefulWidget {
  const _PausedSticker();

  @override
  State<_PausedSticker> createState() => _PausedStickerState();
}

class _PausedStickerState extends State<_PausedSticker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: BrutalTokens.step * 2,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, child) =>
        Transform.scale(scale: _c.value < 0.5 ? 1.15 : 1.0, child: child),
    child: const Sticker('PAUSED'),
  );
}

/// The last three actions of the session as log lines.
class _Log extends StatelessWidget {
  const _Log({required this.log});

  final ValueListenable<List<(String, LogStatus)>>? log;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    Widget lines(List<(String, LogStatus)> entries) {
      final last = entries.length > 3
          ? entries.sublist(entries.length - 3)
          : entries;
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: BrutalTokens.s3,
          vertical: BrutalTokens.s2,
        ),
        decoration: t.panelDecoration(shadowed: false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LogLine('paused', status: LogStatus.ok),
            for (final (text, status) in last) LogLine(text, status: status),
          ],
        ),
      );
    }

    final l = log;
    if (l == null) return lines(const []);
    return ValueListenableBuilder<List<(String, LogStatus)>>(
      valueListenable: l,
      builder: (_, entries, _) => lines(entries),
    );
  }
}

/// An imported skin's artwork for the current size (PDFs rasterised once).
class _SkinArtwork extends StatefulWidget {
  const _SkinArtwork({
    required this.store,
    required this.skin,
    required this.rep,
  });

  final SkinStore store;
  final InstalledSkin skin;
  final DeltaRepresentation rep;

  @override
  State<_SkinArtwork> createState() => _SkinArtworkState();
}

class _SkinArtworkState extends State<_SkinArtwork> {
  /// Files already found, so a pressed key's copy of the art (touch_controls)
  /// shows on its first frame.
  static final _found = <(String, String?, Size), File>{};

  File? file;
  Size? loadedFor;

  void _load(Size px) {
    if (loadedFor == px) return;
    loadedFor = px;
    final key = (
      widget.skin.dir.path,
      widget.rep.pdf ?? widget.rep.bestPng,
      px,
    );
    final known = _found[key];
    if (known != null) {
      file = known;
      return;
    }
    widget.store
        .artwork(widget.skin, widget.rep, px.width.round(), px.height.round())
        .then((f) {
          if (f != null) _found[key] = f;
          if (mounted) setState(() => file = f);
        });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        _load(box.biggest * ratio);
        final f = file;
        return f == null
            ? const SizedBox.shrink()
            : Image.file(f, fit: BoxFit.fill, gaplessPlayback: true);
      },
    );
  }
}

/// The edges a camera cutout takes from a [size] screen: each cutout in
/// [features] pushes the edge it is nearest to, falling back to the
/// [viewPadding] Android reports for the cutout when no feature is given.
EdgeInsets cutoutInsets(
  List<DisplayFeature> features,
  EdgeInsets viewPadding,
  Size size,
) {
  var l = 0.0, t = 0.0, r = 0.0, b = 0.0;
  var any = false;
  for (final f in features) {
    if (f.type != DisplayFeatureType.cutout) continue;
    any = true;
    final c = f.bounds;
    final near = [c.top, size.height - c.bottom, c.left, size.width - c.right];
    final m = near.reduce((a, b) => a < b ? a : b);
    if (m == near[0]) {
      t = math.max(t, c.bottom);
    } else if (m == near[1]) {
      b = math.max(b, size.height - c.top);
    } else if (m == near[2]) {
      l = math.max(l, c.right);
    } else {
      r = math.max(r, size.width - c.left);
    }
  }
  return any ? EdgeInsets.fromLTRB(l, t, r, b) : viewPadding;
}
