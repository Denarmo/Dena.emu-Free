// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/m2-plan.md (package 10: app shell)

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../apps/apps_tab.dart';
import '../carts/bbs.dart';
import '../carts/cart_download.dart';
import '../carts/launcher.dart';
import '../carts/launcher_host.dart';
import '../desktop/open_with.dart';
import '../library/carts_tab.dart';
import '../romm/romm_settings.dart';
import 'settings_tab.dart';
import 'handheld.dart';
import 'network.dart';
import 'shell_chrome.dart';
import '../library/database.dart';
import '../library/games_tab.dart';
import '../library/launch_animation.dart';
import '../library/library_scope.dart';
import '../session/session_screen.dart';
import '../ui/brutal/surfaces.dart';
import 'app_dirs.dart';
import '../ui/dena_icons.dart';

/// Top-level navigation: Games / Carts / Apps / Settings. Tabs under the
/// wordmark on phones, a left rail on handhelds, a header bar from 600 px
/// (shell_chrome.dart). L1 / R1 switch tabs.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.onPlay, this.opened});

  final PlayGame onPlay;

  /// Game files opened from outside the app (Windows, desktop Linux).
  final OpenedFiles? opened;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.opened?.addListener(_openFiles);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openLaunchLink();
      _openFiles();
    });
  }

  bool _openingFile = false;

  /// Plays the game files opened from outside the app, newest last
  /// (open-with.md). One instance: a running game ends (it saves as on
  /// Quit) and the opened one starts with the usual launch.
  Future<void> _openFiles() async {
    final opened = widget.opened;
    if (opened == null || _openingFile || !mounted) return;
    _openingFile = true;
    try {
      while (mounted) {
        final path = opened.take();
        if (path == null) return;
        final scope = LibraryScope.of(context);
        final result = await openGameFile(
          path,
          db: scope.db,
          importer: scope.importer,
        );
        if (!mounted) return;
        switch (result) {
          case OpenFailed(:final message):
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          // The game that is already running keeps running.
          case OpenedGame(:final game) when runningGameId == game.id:
            break;
          case OpenedGame(:final game):
            await endRunningGame(Navigator.of(context));
            if (!mounted) return;
            widget.onPlay(context, game);
        }
      }
    } finally {
      _openingFile = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _openLaunchLink();
  }

  /// Opens the game of a `dena://play/<sha1>` link (shortcuts.md). Dropped
  /// while a game is running so a tap can't end the session.
  Future<void> _openLaunchLink() async {
    if (!mounted) return;
    final scope = LibraryScope.of(context);
    final sha1 = await scope.links?.takeLaunchLink();
    if (sha1 == null || !mounted) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final game = await scope.db.gameBySha1(sha1);
    if (!mounted) return;
    if (game == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That game is not in your library')),
      );
      return;
    }
    widget.onPlay(context, game);
  }

  /// Holds focus when a tab switch removes the focused widget, so L1 / R1
  /// keep working; the new tab's autofocus then picks its first item.
  final _shellFocus = FocusScopeNode(debugLabel: 'shell');

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.opened?.removeListener(_openFiles);
    _shellFocus.dispose();
    super.dispose();
  }

  void _select(int i) {
    setState(() => index = i);
    // Forget the old tab's focus: autofocus only applies in a scope without
    // a focused child, so the D-pad never ends up nowhere after a switch.
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused.enclosingScope == _shellFocus) {
      focused.unfocus();
    } else {
      _shellFocus.requestFocus();
    }
  }

  static const _allDestinations = <ShellDestination>[
    (
      icon: DenaIcons.controllerOutline,
      selectedIcon: DenaIcons.controller,
      label: 'Games',
    ),
    (icon: DenaIcons.cartOutline, selectedIcon: DenaIcons.cart, label: 'Carts'),
    (icon: DenaIcons.appsOutline, selectedIcon: DenaIcons.apps, label: 'Apps'),
    (
      icon: DenaIcons.settingsOutline,
      selectedIcon: DenaIcons.settings,
      label: 'Settings',
    ),
  ];

  /// Handhelds have no Apps tab: no other apps to launch and the media
  /// players use Android's media store (handheld-ui.md).
  List<ShellDestination> get _destinations => Handheld.of(context)
      ? [
          for (final d in _allDestinations)
            if (d.label != 'Apps') d,
        ]
      : _allDestinations;

  void _go(int delta) => _select((index + delta) % _destinations.length);

  @override
  Widget build(BuildContext context) {
    final destinations = _destinations;
    final selected = index.clamp(0, destinations.length - 1);
    final tab = destinations[selected].label;
    final body = switch (tab) {
      'Games' => GamesTab(onPlay: widget.onPlay),
      // Dena Explore and the BBS browser need a network (network.dart).
      'Carts' =>
        NetworkScope.of(context)
            ? CartsTab(onPlay: widget.onPlay, onExplore: playLauncher)
            : CartsTab(onPlay: widget.onPlay, browserEnabled: false),
      'Apps' => const AppsTab(),
      _ => const SettingsTab(),
    };
    final hints = usesButtons(context)
        ? HintBar(
            hints: [
              ...switch (tab) {
                'Games' || 'Carts' => const <ButtonHint>[
                  ([HintButton.a], 'Play'),
                  ([HintButton.y], 'Details'),
                ],
                'Apps' => const <ButtonHint>[
                  ([HintButton.a], 'Launch'),
                ],
                _ => const <ButtonHint>[
                  ([HintButton.a], 'Open'),
                ],
              },
              ([HintButton.l1, HintButton.r1], 'Tabs'),
            ],
          )
        : null;
    // Brutalist shell (brutalist-ui.md 4.1): graph paper behind every tab,
    // the wordmark and tabs on top (phone), in a left rail (handheld) or in
    // a yellow header bar (desktop, TV, tablets).
    final Widget layout = switch (ShellNav.of(context)) {
      ShellNav.tabs => SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShellTopTabs(
              destinations: destinations,
              selected: selected,
              onSelected: _select,
            ),
            Expanded(child: body),
          ],
        ),
      ),
      ShellNav.rail => SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShellRail(
              destinations: destinations,
              selected: selected,
              onSelected: _select,
            ),
            Expanded(child: body),
          ],
        ),
      ),
      ShellNav.header => SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShellHeaderBar(
              destinations: destinations,
              selected: selected,
              onSelected: _select,
            ),
            Expanded(child: body),
          ],
        ),
      ),
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.gameButtonLeft1): () =>
            _go(-1 + destinations.length),
        const SingleActivator(LogicalKeyboardKey.gameButtonRight1): () =>
            _go(1),
      },
      child: FocusScope(
        node: _shellFocus,
        child: BrutalGridPaper(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: layout,
            bottomNavigationBar: hints,
          ),
        ),
      ),
    );
  }
}

/// The [playGame] still running, if any, and its game.
Future<void>? _playing;
int? _playingId;

/// The library id of the game [playGame] is running, or null.
int? get runningGameId => _playing == null ? null : _playingId;

/// Bumped by [endRunningGame] so Dena Explore doesn't reopen over the game
/// that replaces the one it launched.
int _sessionSwitches = 0;

/// Ends the running game, if any, closes every page above the library on
/// [navigator] and waits until [playGame] is done (open-with.md).
Future<void> endRunningGame(NavigatorState navigator) async {
  _sessionSwitches++;
  await quitActiveSession();
  navigator.popUntil((r) => r.isFirst);
  await _playing;
}

/// Opens [game] in a full-screen session (docs/specs/game-session.md), or
/// says its core is not in this build.
Future<void> playGame(BuildContext context, Game game) {
  final run = _playGame(context, game);
  _playing = run;
  _playingId = game.id;
  return run.whenComplete(() {
    if (identical(_playing, run)) _playing = null;
  });
}

Future<void> _playGame(BuildContext context, Game game) async {
  if (!coreLibraries.containsKey(game.system)) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(missingCoreMessage)));
    return;
  }
  final scope = LibraryScope.of(context);
  final db = scope.db;
  final navigator = Navigator.of(context);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final handheld = Handheld.of(context);
  final links = scope.links;
  if (links != null) {
    // Recent-game shortcut (shortcuts.md); never blocks starting the game.
    shortcutIcon(scope, game).then((icon) => links.reportPlayed(game, icon));
  }
  final romm = RommScope.read(context);
  final dataDir = (await appDataDir()).path;
  await romm?.sessionStarted();
  try {
    // The box opens and loads the media while the core starts underneath
    // (launch-animation.md).
    await pushLaunch<void>(
      navigator,
      scope,
      game,
      reduceMotion: reduceMotion,
      duration: handheld
          ? LaunchRoute.handheldDuration
          : LaunchRoute.defaultDuration,
      page: (_) => SessionScreen(
        game: game,
        dataDir: dataDir,
        db: db,
        skins: scope.skins,
        shaders: scope.shaders,
        achievements: scope.achievements,
      ),
    );
  } finally {
    romm?.sessionEnded();
  }
}

/// Opens the Dena Explore launcher cart (pico8-launcher-cart.md). A game it
/// launches plays as usual; when that game quits, the launcher opens again.
Future<void> playLauncher(BuildContext context) async {
  if (!coreLibraries.containsKey('pico8')) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(missingCoreMessage)));
    return;
  }
  final scope = LibraryScope.of(context);
  final navigator = Navigator.of(context);
  final dataDir = (await appDataDir()).path;
  final cart = await installLauncher(dataDir);
  final credits = CartCredits(dataDir);
  final switches = _sessionSwitches;
  while (context.mounted && switches == _sessionSwitches) {
    final next = await navigator.push<Game>(
      MaterialPageRoute<Game>(
        builder: (_) => SessionScreen(
          game: launcherGame(cart.path),
          dataDir: dataDir,
          db: scope.db,
          skins: scope.skins,
          shaders: scope.shaders,
          launcher: (onRun) {
            final port = FfiGpioPort.open();
            if (port == null) return null;
            return LauncherHost(
              port: port,
              db: scope.db,
              importer: scope.importer,
              credits: credits,
              client: pico8BrowserEnabled ? HttpBbsClient() : null,
              onRun: onRun,
            );
          },
        ),
      ),
    );
    if (next == null || !context.mounted) return;
    await playGame(context, next);
    if (switches != _sessionSwitches) return;
  }
}
