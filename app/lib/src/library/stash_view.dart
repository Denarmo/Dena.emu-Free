// SPDX-License-Identifier: GPL-3.0-or-later
// The Games tab's stash view: covers to fling around until one turns up.
// Spec: docs/specs/library-stash.md
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/handheld.dart';
import '../ui/brutal/brutal.dart';
import 'database.dart';
import 'games_tab.dart';
import 'stash_physics.dart';
import '../ui/dena_icons.dart';

class StashView extends StatefulWidget {
  const StashView({
    super.key,
    required this.games,
    required this.onPlay,
    required this.onDetails,
  });

  final List<Game> games;
  final ValueChanged<Game> onPlay, onDetails;

  /// Boxes on the table on a handheld (library-stash.md, Handhelds): every
  /// box collides with every other and rebuilds each frame, which four small
  /// cores can't hold at 60 fps for a big library; 640x480 fits fewer anyway.
  static const handheldLimit = 40;

  @override
  State<StashView> createState() => StashViewState();
}

class StashViewState extends State<StashView>
    with SingleTickerProviderStateMixin {
  final world = StashWorld(Size.zero);
  final _random = math.Random(7);
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  /// Draw order: last is on top.
  final _order = <int>[];
  int? _focused;
  final _trackers = <int, VelocityTracker>{};
  final _clock = Stopwatch()..start();

  /// Whether the first layout has dropped the boxes in yet.
  bool _dropped = false;

  /// The games on the table: all of them, or the first
  /// [StashView.handheldLimit] on a handheld.
  List<Game> _games = const [];

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    world.advance(dt);
    if (!world.active) _ticker.stop();
    setState(() {});
  }

  void _wake() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  /// Scatters every box (the Shake button, X, or S).
  void shake() {
    world.shake(_random);
    _wake();
    setState(() {});
  }

  void _raise(int id) {
    _order
      ..remove(id)
      ..add(id);
  }

  /// The size a box is drawn at; physics bodies take their radius from it,
  /// so per-console box shapes collide at their own size.
  Size _boxSize(Game game, Size area) {
    final w = area.height <= 480 ? 88.0 : 104.0;
    return Size(w, w / 0.72);
  }

  /// Matches bodies to [games] and the area to [size]. New boxes drop in
  /// from above unless the platform asks for reduced motion.
  void _sync(Size size, {required bool animate}) {
    final resized = world.size != size;
    world.size = size;
    final ids = {for (final g in _games) g.id};
    world.bodies.removeWhere((b) => !ids.contains(b.id));
    _order.removeWhere((id) => !ids.contains(id));
    final known = {for (final b in world.bodies) b.id: b};
    final added = <StashBody>[];
    for (final g in _games) {
      final radius = _boxSize(g, size).width / 2;
      final body = known[g.id];
      if (body != null) {
        body.radius = radius;
        continue;
      }
      // Seeded per game so the first layout is the same every time.
      final r = math.Random(g.id * 7919 + 1);
      final b = StashBody(
        id: g.id,
        position: world.randomSpot(r, radius),
        radius: radius,
        angle: (r.nextDouble() - 0.5) * 0.6,
      );
      world.bodies.add(b);
      added.add(b);
      _order.insert(0, g.id);
    }
    if (resized) world.clamp();
    if (animate && added.isNotEmpty) {
      // Bottom of the pile lands first.
      final byOrder = {for (final (i, id) in _order.indexed) id: i};
      added.sort((a, b) => byOrder[a.id]!.compareTo(byOrder[b.id]!));
      world.drop(_random, _dropped ? added : null);
      // Runs the ticker after this build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _wake();
      });
    }
    _dropped = true;
  }

  @override
  Widget build(BuildContext context) {
    final handheld = Handheld.of(context);
    final all = widget.games;
    _games = handheld && all.length > StashView.handheldLimit
        ? all.sublist(0, StashView.handheldLimit)
        : all;
    final t = BrutalTokens.of(context);
    if (all.isEmpty) {
      return Center(child: Text('> no games match', style: t.body));
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.gameButtonX): shake,
        const SingleActivator(LogicalKeyboardKey.keyS): shake,
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, c) {
                final size = c.biggest;
                _sync(size, animate: !MediaQuery.disableAnimationsOf(context));
                final games = {for (final g in _games) g.id: g};
                final bodies = {for (final b in world.bodies) b.id: b};
                final order = [..._order];
                if (_focused != null && order.remove(_focused)) {
                  order.add(_focused!);
                }
                // Boxes still falling are drawn above the ones on the table.
                if (world.bodies.any((b) => b.airborne)) {
                  mergeSort(
                    order,
                    compare: (a, b) =>
                        bodies[a]!.height.compareTo(bodies[b]!.height),
                  );
                }
                // ClipRect, not the Stack's clip: falling boxes are moved by
                // transforms, which the Stack's overflow check doesn't see.
                return ClipRect(
                  child: Stack(
                    children: [
                      for (final id in order)
                        _box(
                          games[id]!,
                          bodies[id]!,
                          _boxSize(games[id]!, size),
                          id == order.first,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: 12,
            bottom: 16,
            child: BrutalButton(
              label: handheld ? 'SHAKE [X]' : 'SHAKE',
              icon: DenaIcons.shuffle,
              variant: BrutalButtonVariant.primary,
              onPressed: shake,
            ),
          ),
          if (_games.length < all.length)
            Positioned(
              right: 12,
              bottom: 22,
              child: Text(
                '> ${_games.length} of ${all.length} games: filter to find more',
                style: t.small,
              ),
            ),
        ],
      ),
    );
  }

  Widget _box(Game game, StashBody body, Size box, bool bottom) {
    final w = box.width, h = box.height;
    // Seen from slightly in front: a raised box sits higher on screen and
    // looks bigger, and its shadow stays on the table below it.
    final z = body.height;
    final cover = Transform.rotate(
      angle: body.angle,
      child: _StashBox(
        game: game,
        autofocus: bottom,
        onPlay: () => widget.onPlay(game),
        onDetails: () => widget.onDetails(game),
        onFocus: (f) => setState(() {
          if (f) {
            _focused = game.id;
          } else if (_focused == game.id) {
            _focused = null;
          }
        }),
      ),
    );
    return Positioned(
      key: ValueKey(game.id),
      left: body.position.dx - w / 2,
      top: body.position.dy - h / 2,
      width: w,
      height: h,
      child: GestureDetector(
        onPanStart: (d) {
          body.held = true;
          body.velocity = Offset.zero;
          body.height = 0;
          body.lift = 0;
          _trackers[body.id] = VelocityTracker.withKind(
            PointerDeviceKind.touch,
          )..addPosition(d.sourceTimeStamp ?? _clock.elapsed, d.globalPosition);
          setState(() => _raise(body.id));
          _wake();
        },
        onPanUpdate: (d) {
          _trackers[body.id]?.addPosition(
            d.sourceTimeStamp ?? _clock.elapsed,
            d.globalPosition,
          );
          body.position += d.delta;
          // Lets the held box shove the others it runs into.
          body.velocity = d.delta * 60;
          setState(() {});
        },
        onPanEnd: (_) => _release(body),
        onPanCancel: () => _release(body),
        child: z <= 0
            ? cover
            : Stack(
                clipBehavior: Clip.none,
                fit: StackFit.expand,
                children: [
                  Transform.rotate(
                    angle: body.angle,
                    child: _DropShadow(height: z),
                  ),
                  Transform.translate(
                    offset: Offset(0, -z * 0.8),
                    child: Transform.scale(scale: 1 + z / 1600, child: cover),
                  ),
                ],
              ),
      ),
    );
  }

  void _release(StashBody body) {
    final v =
        _trackers.remove(body.id)?.getVelocity().pixelsPerSecond ?? Offset.zero;
    world.fling(body, v);
    _wake();
  }
}

/// The hard shadow a falling box casts on the table: fainter and wider the
/// higher it is. Unblurred, square, cheap on the handheld's GPU.
class _DropShadow extends StatelessWidget {
  const _DropShadow({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final t = (height / 600).clamp(0.0, 1.0);
    return Transform.scale(
      scale: 0.9 + t * 0.3,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5 * (1 - t)),
        ),
      ),
    );
  }
}

class _StashBox extends StatefulWidget {
  const _StashBox({
    required this.game,
    required this.autofocus,
    required this.onPlay,
    required this.onDetails,
    required this.onFocus,
  });

  final Game game;
  final bool autofocus;
  final VoidCallback onPlay, onDetails;
  final ValueChanged<bool> onFocus;

  @override
  State<_StashBox> createState() => _StashBoxState();
}

class _StashBoxState extends State<_StashBox> {
  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.gameButtonY): widget.onDetails,
        const SingleActivator(LogicalKeyboardKey.contextMenu): widget.onDetails,
      },
      child: BrutalPressable(
        autofocus: widget.autofocus,
        onPressed: widget.onPlay,
        onLongPress: widget.onDetails,
        semanticLabel: widget.game.title,
        onFocusChange: widget.onFocus,
        builder: (context, s) {
          final lit = s.highlighted;
          // A hard box on a hard shadow; focused, a yellow frame and plate.
          return Container(
            decoration: t.panelDecoration(borderColor: lit ? t.focus : t.ink),
            child: Stack(
              fit: StackFit.expand,
              children: [
                GameCover(
                  game: widget.game,
                  placeholder: SystemPlaceholder(system: widget.game.system),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: lit ? t.focus : t.panel,
                    padding: const EdgeInsets.symmetric(
                      horizontal: BrutalTokens.s1,
                      vertical: 2,
                    ),
                    child: Text(
                      '${lit ? '-> ' : ''}'
                      '${BrutalTokens.fileName(widget.game.title)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.small.copyWith(
                        color: lit ? t.onFocus : t.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
