// SPDX-License-Identifier: GPL-3.0-or-later
// Long-press on a game: an inspection viewport shows its box on blue grid
// paper, with Play, the option keys and hold-to-delete under it.
// Spec: docs/specs/game-boxes.md (Zoom and options),
// docs/specs/brutalist-ui.md (4.3)
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../achievements/achievements_ui.dart';
import '../achievements/retro_achievements.dart';
import '../desktop/texture_packs.dart';
import '../shell/handheld.dart';
import '../shell/platform_features.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';
import '../romtools/rom_manager.dart';
import '../romtools/rom_page.dart';
import 'database.dart';
import 'foil.dart';
import 'game_box.dart';
import 'game_box_model.dart';
import 'games_tab.dart';
import 'importer.dart';
import 'import_rules.dart';
import 'library_scope.dart';

/// Opens [game]'s inspection view with its options: a full-screen page on
/// phones, a right-hand sheet over the library on handhelds and desktops.
/// It appears in one frame (no zoom tween), so [from] is not used for
/// motion; it is kept for callers that pass the box's rect.
Future<void> showGameBoxMenu(
  BuildContext context,
  Game game,
  PlayGame onPlay, {
  Rect? from,
}) {
  final phone = _phoneLayout(context);
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: phone,
      barrierDismissible: !phone,
      barrierColor: phone ? null : BrutalTokens.scrim,
      barrierLabel: 'Close',
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (routeContext, _, _) => _BoxMenu(
        game: game,
        // Actions run against the library's context, which outlives the menu.
        host: context,
        onPlay: onPlay,
      ),
    ),
  );
}

/// One option key: its keyboard letter, icon, label and action.
typedef _Option = ({
  LogicalKeyboardKey key,
  String letter,
  IconData icon,
  String label,
  VoidCallback onPressed,
});

class _BoxMenu extends StatelessWidget {
  const _BoxMenu({
    required this.game,
    required this.host,
    required this.onPlay,
  });

  final Game game;
  final BuildContext host;
  final PlayGame onPlay;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final options = _options(context);
    void close() => Navigator.of(context).maybePop();
    return CallbackShortcuts(
      // B is the app's Back already; Escape closes too. The option letters
      // are shortcuts for desktop keyboards.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): close,
        for (final o in options) SingleActivator(o.key): o.onPressed,
      },
      child: FocusTraversalGroup(
        child: _phoneLayout(context)
            ? _phone(context, t, options)
            : _side(
                context,
                t,
                options,
                width: t.density == BrutalDensity.handheld ? 300 : 440,
              ),
      ),
    );
  }

  /// Phone: a full-screen page, viewport on top, options under it.
  Widget _phone(BuildContext context, BrutalTokens t, List<_Option> options) {
    final size = MediaQuery.sizeOf(context);
    final viewport = math.min(size.width * 0.86, size.height * 0.42);
    return Material(
      type: MaterialType.transparency,
      child: BrutalGridPaper(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(BrutalTokens.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    BrutalButton(
                      label: '<- BACK',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: BrutalTokens.s3),
                    Expanded(
                      child: Text(
                        _path(game),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.small,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: BrutalTokens.s4),
                SizedBox(
                  height: viewport,
                  child: InspectViewport(game: game),
                ),
                const SizedBox(height: BrutalTokens.s4),
                ..._details(context, t),
                const SizedBox(height: BrutalTokens.s4),
                LayoutBuilder(
                  builder: (context, box) {
                    const gap = BrutalTokens.s3;
                    final w = (box.maxWidth - gap) / 2;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final o in options)
                          SizedBox(
                            width: w,
                            child: BrutalButton(
                              label: o.label,
                              icon: o.icon,
                              expand: true,
                              onPressed: o.onPressed,
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: BrutalTokens.s4),
                _delete(context),
                const SizedBox(height: BrutalTokens.s4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Handheld and desktop: the library stays behind the scrim; the
  /// viewport sits top-left on handhelds and at the top of the panel on
  /// desktops. A tap outside the panel closes it.
  Widget _side(
    BuildContext context,
    BrutalTokens t,
    List<_Option> options, {
    required double width,
  }) {
    final handheld = t.density == BrutalDensity.handheld;
    final gap = handheld ? BrutalTokens.s2 : BrutalTokens.s3;
    final panel = BrutalSheet(
      side: BrutalSheetSide.right,
      width: width,
      title: 'INSPECT',
      child: SingleChildScrollView(
        // Room on the right for the `<-` focus marker.
        padding: EdgeInsets.fromLTRB(
          BrutalTokens.s3,
          BrutalTokens.s3,
          BrutalTokens.s8,
          BrutalTokens.s3,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!handheld) ...[
              SizedBox(height: 240, child: InspectViewport(game: game)),
              SizedBox(height: gap * 2),
            ],
            ..._details(context, t),
            SizedBox(height: gap * 2),
            for (final o in options) ...[
              BrutalButton(
                label: o.label,
                icon: o.icon,
                value: '[${o.letter}]',
                expand: true,
                onPressed: o.onPressed,
              ),
              SizedBox(height: gap),
            ],
            SizedBox(height: gap),
            _delete(context),
          ],
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: handheld
              ? Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(BrutalTokens.s3),
                    child: SizedBox(
                      width: 300,
                      height: 230,
                      child: InspectViewport(game: game),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        panel,
      ],
    );
  }

  /// Title, meta strip and the PLAY key (focused first).
  List<Widget> _details(BuildContext context, BrutalTokens t) {
    final played = game.playSeconds == 0
        ? 'NEVER'
        : '${(game.playSeconds / 60).ceil()} MIN';
    return [
      Text(
        BrutalTokens.fileName(game.title),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: t.title,
      ),
      const SizedBox(height: BrutalTokens.s2),
      KeyValueStrip(
        entries: [
          ('SYS', systemShortName(game.system)),
          // The library keeps no release year yet.
          ('YEAR', '----'),
          ('PLAYED', played),
          ('FILE', game.fileName),
        ],
      ),
      const SizedBox(height: BrutalTokens.s4),
      PlayKey(
        onPressed: () {
          Navigator.of(context).pop();
          onPlay(host, game);
        },
      ),
    ];
  }

  Widget _delete(BuildContext context) {
    final scope = LibraryScope.of(host);
    return HoldToConfirm(
      icon: DenaIcons.trash,
      expand: true,
      onConfirmed: () async {
        final db = scope.db;
        final rom = RomManagerScope.of(host);
        final g = await db.deleteGame(game.id);
        if (g != null) {
          await deleteGameFiles(
            g,
            dataDir: scope.importer.gamesDir.parent.path,
          );
          await scope.folders?.forget(g.path);
          await scope.art?.forget(g);
          await scope.links?.remove(g.sha1);
          await rom?.forget(g);
        }
        if (context.mounted) Navigator.of(context).pop();
      },
    );
  }

  List<_Option> _options(BuildContext context) {
    final scope = LibraryScope.of(host);
    final db = scope.db;
    void close() => Navigator.of(context).pop();
    return [
      (
        key: LogicalKeyboardKey.keyF,
        letter: 'F',
        icon: game.favorite ? DenaIcons.star : DenaIcons.starOutline,
        label: game.favorite ? 'Unfavourite' : 'Favourite',
        onPressed: () async {
          await db.setFavorite(game.id, !game.favorite);
          if (context.mounted) close();
        },
      ),
      (
        key: LogicalKeyboardKey.keyR,
        letter: 'R',
        icon: DenaIcons.edit,
        label: 'Rename',
        onPressed: () async {
          final name = await askGameName(context, game.title);
          if (name != null && name.trim().isNotEmpty) {
            await db.rename(game.id, name.trim());
          }
          if (context.mounted) close();
        },
      ),
      if (scope.links case final links?)
        (
          key: LogicalKeyboardKey.keyH,
          letter: 'H',
          icon: DenaIcons.addToHome,
          label: 'Home screen',
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(host);
            final ok = await links.pin(game, await shortcutIcon(scope, game));
            if (!ok) {
              messenger.showSnackBar(
                brutalToast(
                  "this home screen can't pin shortcuts",
                  kind: ToastKind.err,
                ),
              );
            }
            if (context.mounted) close();
          },
        ),
      if (scope.achievements case final ra?
          when raConsoleIds.containsKey(game.system))
        (
          key: LogicalKeyboardKey.keyA,
          letter: 'A',
          icon: DenaIcons.trophy,
          label: 'Achievements',
          onPressed: () {
            close();
            Navigator.of(host).push(
              MaterialPageRoute<void>(
                builder: (_) => GameAchievementsPage(ra: ra, game: game),
              ),
            );
          },
        ),
      if (scope.art case final art?)
        (
          key: LogicalKeyboardKey.keyC,
          letter: 'C',
          icon: DenaIcons.image,
          label: 'Choose cover',
          onPressed: () async {
            final picked = await scope.files.pickFiles();
            final image = picked.where(
              (f) => const {
                '.png',
                '.jpg',
                '.jpeg',
                '.webp',
              }.contains(p.extension(f).toLowerCase()),
            );
            if (image.isNotEmpty) {
              final path = await art.storeCustom(game, File(image.first));
              await db.setCustomArt(game.id, path);
            }
            await scope.files.clearCache();
            if (context.mounted) close();
          },
        ),
      // texture-packs.md: the per-game switch, on once the folder has files.
      if (TexturePacksScope.maybeOf(host) case final packs?
          when TexturePacks.supports(game.system))
        _texturesOption(context, packs),
      // rom-manager.md 5.
      if (RomManagerScope.of(host) != null)
        (
          key: LogicalKeyboardKey.keyV,
          letter: 'V',
          icon: DenaIcons.check,
          label: 'ROM check',
          onPressed: () {
            close();
            openRomPage(host, game);
          },
        ),
      (
        key: LogicalKeyboardKey.keyI,
        letter: 'I',
        icon: DenaIcons.info,
        label: 'Game info',
        onPressed: () => _showInfo(context, game),
      ),
    ];
  }
}

extension on _BoxMenu {
  /// `TEXTURES: ON` / `OFF` for this game; turning it on with an empty
  /// folder opens the folder to drop a pack in.
  _Option _texturesOption(BuildContext context, TexturePacks packs) {
    final pack = (sha1: game.sha1, system: game.system, path: game.path);
    final on = packs.enabledFor(pack);
    return (
      key: LogicalKeyboardKey.keyT,
      letter: 'T',
      icon: DenaIcons.image,
      label: on ? 'Textures: on' : 'Textures: off',
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(host);
        packs.setGame(game.sha1, !on);
        if (!on && !TexturePacks.hasFiles(packs.gameFolder(pack))) {
          messenger.showSnackBar(
            brutalToast(
              'no pack yet: drop it in ${packs.gameFolder(pack).path}',
              kind: ToastKind.info,
            ),
          );
          await packs.open(game.system, game: pack);
        } else {
          messenger.showSnackBar(
            brutalToast(
              on
                  ? 'texture pack off for this game'
                  : 'texture pack on '
                        'from the next start',
            ),
          );
        }
        if (context.mounted) Navigator.of(context).pop();
      },
    );
  }
}

/// Whether the menu takes the phone layout: on Android (or anything that is
/// neither the handheld launcher nor the desktop runner).
bool _phoneLayout(BuildContext context) =>
    !Handheld.of(context) &&
    (hasAndroidShell || shellProfile != ShellProfile.desktop);

/// `/games/moonlight_quest.gba`: where the game lives, as a path.
String _path(Game game) => '/games/${game.fileName.toLowerCase()}';

/// The full-width primary PLAY key: Archivo Black label on electric blue,
/// yellow when focused. Focus starts here.
class PlayKey extends StatelessWidget {
  const PlayKey({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final phone = _phoneLayout(context);
    return BrutalPressable(
      autofocus: true,
      semanticLabel: 'Play',
      onPressed: onPressed,
      builder: (context, s) {
        final lit = s.highlighted;
        final fill = lit ? t.focus : t.primary;
        final text = lit ? t.onFocus : t.onPrimary;
        final style = (phone ? t.display : t.displaySmall).copyWith(
          color: text,
        );
        return BrutalShadowBox(
          pressed: s.pressed,
          offset: t.shadowOffset,
          color: t.shadow,
          child: Container(
            height: phone ? 72 : 48,
            padding: const EdgeInsets.symmetric(horizontal: BrutalTokens.s4),
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: t.ink, width: BrutalTokens.border),
            ),
            child: Row(
              children: [
                Icon(
                  DenaIcons.play,
                  size: BrutalTokens.iconSizeLarge,
                  color: text,
                ),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('PLAY', style: style),
                        const SizedBox(width: BrutalTokens.s3),
                        Text('->', style: style),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: BrutalTokens.iconSizeLarge),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The inspection viewport: the box on blue grid paper with dashed
/// crosshairs, tilted 6 degrees on a hard 6 px shadow, with annotation
/// callouts. No perspective, no blur.
class InspectViewport extends StatelessWidget {
  const InspectViewport({super.key, required this.game});

  final Game game;

  /// The box's tilt in the viewport.
  static const tilt = -6 * math.pi / 180;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final spec = boxSpecFor(game.system);
    final note = t.small.copyWith(color: const Color(0xFFFFFFFF));
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: t.primary,
          border: Border.all(color: t.ink, width: BrutalTokens.border),
        ),
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, c) {
              final stageSide = math.min(c.maxWidth, c.maxHeight) * 0.74;
              final stage = Size.square(stageSide);
              final scale = boxScaleFor(stage);
              final front = Size(spec.widthMm * scale, spec.heightMm * scale);
              final d = spec.depthMm * boxDepthSlant * scale;
              // GameBox centres its footprint; the front face sits at its
              // bottom left.
              final foot = Size(front.width + d, front.height + d);
              final faceRect =
                  Offset(
                    (stageSide - foot.width) / 2,
                    (stageSide - foot.height) / 2 + d,
                  ) &
                  front;
              return Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _BlueprintPainter()),
                  ),
                  Center(
                    child: Transform.rotate(
                      angle: tilt,
                      child: SizedBox.fromSize(
                        size: stage,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fromRect(
                              rect: faceRect.shift(const Offset(6, 6)),
                              child: ColoredBox(color: t.shadow),
                            ),
                            Positioned.fill(
                              child: GameBox(
                                game: game,
                                alignment: Alignment.center,
                              ),
                            ),
                            Positioned.fromRect(
                              rect: faceRect,
                              child: const FoilOverlay(
                                child: SizedBox.expand(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: BrutalTokens.s2,
                    top: BrutalTokens.s2,
                    child: Container(
                      color: t.headerBar,
                      padding: const EdgeInsets.symmetric(
                        horizontal: BrutalTokens.s2,
                        vertical: 2,
                      ),
                      child: Text(
                        'INSPECT // ${systemShortName(game.system)}',
                        style: t.label.copyWith(color: t.onHeaderBar),
                      ),
                    ),
                  ),
                  Positioned(
                    right: BrutalTokens.s2,
                    top: c.maxHeight * 0.24,
                    child: Text('foil layer ->', style: note),
                  ),
                  Positioned(
                    right: BrutalTokens.s2,
                    bottom: c.maxHeight * 0.2,
                    child: Text(
                      '<- spine ${spec.depthMm.round()}mm',
                      style: note,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: BrutalTokens.s2,
                    child: Text(
                      '<-- ratio 1:${(1 / spec.aspect).toStringAsFixed(2)} -->',
                      textAlign: TextAlign.center,
                      style: note,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// White 8 px grid at 15% and dashed crosshairs through the middle.
class _BlueprintPainter extends CustomPainter {
  const _BlueprintPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x26FFFFFF)
      ..strokeWidth = BrutalTokens.hairline;
    const cell = BrutalTokens.gridCell;
    for (var x = 0.5; x < size.width; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.5; y < size.height; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final dash = Paint()
      ..color = const Color(0xB3FFFFFF)
      ..strokeWidth = BrutalTokens.hairline;
    final cx = (size.width / 2).floorToDouble() + 0.5;
    final cy = (size.height / 2).floorToDouble() + 0.5;
    for (var x = 0.0; x < size.width; x += cell) {
      canvas.drawLine(Offset(x, cy), Offset(x + cell / 2, cy), dash);
    }
    for (var y = 0.0; y < size.height; y += cell) {
      canvas.drawLine(Offset(cx, y), Offset(cx, y + cell / 2), dash);
    }
  }

  @override
  bool shouldRepaint(_BlueprintPainter old) => false;
}

Future<void> _showInfo(BuildContext context, Game game) {
  String date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  final mb = game.size / (1024 * 1024);
  final rows = [
    ('System', systemShortName(game.system)),
    ('File', game.fileName),
    (
      'Size',
      mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${game.size ~/ 1024} KB',
    ),
    ('Added', date(game.addedAt)),
    (
      'Last played',
      game.lastPlayedAt == null ? 'Never' : date(game.lastPlayedAt!),
    ),
    ('Play time', '${(game.playSeconds / 60).ceil()} min'),
    ('CRC-32', game.crc32.toUpperCase()),
    ('SHA-1', game.sha1),
  ];
  return showBrutalDialog<void>(
    context: context,
    builder: (d) => BrutalDialog(
      title: BrutalTokens.fileName(game.title),
      body: KeyValueStrip(entries: rows),
      actions: [
        BrutalDialogAction(
          label: 'Close',
          autofocus: true,
          onPressed: () => Navigator.pop(d),
        ),
      ],
    ),
  );
}

/// The short name of a system id for labels.
String systemShortName(String id) =>
    GameSystem.values
        .where((s) => s.id == id)
        .map((s) => s.shortName)
        .firstOrNull ??
    id;
