// SPDX-License-Identifier: GPL-3.0-or-later
// Playing a game opens its box and loads the cartridge, disc or UMD while the
// core starts underneath, so the load hides behind the animation: a short,
// hard-stepped sequence with no easing.
// Spec: docs/specs/launch-animation.md, docs/specs/brutalist-ui.md (4.4)
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'database.dart';
import 'game_box_model.dart' show BoxHinge, boxSpecFor;
import 'game_media.dart';
import 'library_scope.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// How a box opens.
enum BoxOpening {
  /// Cardboard: the top flap lifts and the media slides up out of the box.
  flap,

  /// Plastic case: the front swings open on its spine and the media lifts
  /// off the tray.
  clamshell,
}

/// The way [system]'s retail box opens (game_box_model.dart's hinge).
BoxOpening boxOpeningFor(String system) =>
    boxSpecFor(system).hinge == BoxHinge.left
    ? BoxOpening.clamshell
    : BoxOpening.flap;

/// Width / height and depth (fraction of the width) of [system]'s box, from
/// the library's box model (game-boxes.md).
({double aspect, double depth}) launchBoxSize(String system) {
  final spec = boxSpecFor(system);
  return (aspect: spec.aspect, depth: spec.depthMm / spec.widthMm);
}

/// The launch's hard steps (brutalist-ui.md 4.4): no easing, each step
/// lasts 80 ms and the picture changes only at step edges.
abstract final class LaunchTimeline {
  /// The tapped row or box inverts to black with yellow text.
  static const invert = Duration.zero;

  /// The box snaps to the centre over a black scrim.
  static const centre = Duration(milliseconds: 80);

  /// The lid: closed from [centre], 45 degrees at [lidHalf], open at
  /// [lidOpen].
  static const lidHalf = Duration(milliseconds: 240);
  static const lidOpen = Duration(milliseconds: 320);

  /// The media rises out of the box in two steps.
  static const mediaHalf = Duration(milliseconds: 280);
  static const mediaOut = Duration(milliseconds: 360);

  /// The boot log line prints under the box.
  static const log = Duration(milliseconds: 400);

  /// The cut to the game.
  static const total = Duration(milliseconds: 560);

  /// With animations off: one still frame (box open, media out, log) for
  /// this long, then the cut.
  static const reduced = Duration(milliseconds: 360);

  /// The session is hidden until the scrim covers the library.
  static const sessionShownAt = centre;
}

/// What the launch shows at one instant.
typedef LaunchStep = ({
  bool inverted,
  bool centred,
  int lid,
  int media,
  bool log,
});

/// The step shown [elapsed] into the launch. [lid] and [media] count the
/// steps taken: lid 0 closed, 1 at 45 degrees, 2 open; media 0 in the box,
/// 1 half out, 2 out.
LaunchStep launchStepAt(Duration elapsed) {
  bool at(Duration d) => elapsed >= d;
  return (
    inverted: !at(LaunchTimeline.centre),
    centred: at(LaunchTimeline.centre),
    lid: at(LaunchTimeline.lidOpen)
        ? 2
        : at(LaunchTimeline.lidHalf)
        ? 1
        : 0,
    media: at(LaunchTimeline.mediaOut)
        ? 2
        : at(LaunchTimeline.mediaHalf)
        ? 1
        : 0,
    log: at(LaunchTimeline.log),
  );
}

/// The still frame shown with animations off.
const LaunchStep reducedLaunchStep = (
  inverted: false,
  centred: true,
  lid: 2,
  media: 2,
  log: true,
);

/// The boot line, printed as `> boot moonlight_quest.gba ... ok`.
String bootLine(Game game) => 'boot ${game.fileName.toLowerCase()}';

/// Where the tapped box is on screen, so the launch starts from it. Wrap a
/// game's box in the grid with this.
class LaunchOrigin extends StatefulWidget {
  const LaunchOrigin({super.key, required this.game, required this.child});

  final Game game;
  final Widget child;

  static final _mounted = <String, List<_LaunchOriginState>>{};
  static _LaunchOriginState? _lastTouched;

  /// The on-screen rect of [game]'s box: the focused one, else the one last
  /// touched, else any that is showing.
  static Rect? rectOf(Game game) {
    final mounted = _mounted[game.sha1] ?? const <_LaunchOriginState>[];
    // With a D-pad the focused card is the one played.
    for (final s in mounted) {
      if (Focus.maybeOf(s.context)?.hasFocus ?? false) return s.rect;
    }
    final last = _lastTouched;
    if (last != null && last.mounted && last.widget.game.sha1 == game.sha1) {
      return last.rect;
    }
    for (final s in mounted) {
      final r = s.rect;
      if (r != null) return r;
    }
    return null;
  }

  @override
  State<LaunchOrigin> createState() => _LaunchOriginState();
}

class _LaunchOriginState extends State<LaunchOrigin> {
  late String _sha1;

  Rect? get rect {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  void initState() {
    super.initState();
    _sha1 = widget.game.sha1;
    LaunchOrigin._mounted.putIfAbsent(_sha1, () => []).add(this);
  }

  @override
  void didUpdateWidget(LaunchOrigin old) {
    super.didUpdateWidget(old);
    if (widget.game.sha1 == _sha1) return;
    _remove();
    _sha1 = widget.game.sha1;
    LaunchOrigin._mounted.putIfAbsent(_sha1, () => []).add(this);
  }

  void _remove() {
    final list = LaunchOrigin._mounted[_sha1];
    list?.remove(this);
    if (list != null && list.isEmpty) LaunchOrigin._mounted.remove(_sha1);
    if (LaunchOrigin._lastTouched == this) LaunchOrigin._lastTouched = null;
  }

  @override
  void dispose() {
    _remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => LaunchOrigin._lastTouched = this,
    child: widget.child,
  );
}

/// The art the launch shows, loaded before the route starts so the first
/// frame has it.
class LaunchArt {
  const LaunchArt({this.cover, this.media});

  final ImageProvider? cover, media;

  /// Waits at most [wait] for each image; a slow download only means the
  /// launch shows the fallback this time.
  static Future<LaunchArt> load(
    LibraryScope scope,
    Game game, {
    Duration wait = const Duration(milliseconds: 350),
  }) async {
    Future<File?> quick(Future<File?>? f) => (f ?? Future.value(null))
        .timeout(wait, onTimeout: () => null)
        .then((f) => f, onError: (Object _) => null);
    final media = scope.media;
    final cached = media?.cachedFor(game);
    final (cover, art) = await (
      quick(scope.art?.coverFor(game)),
      cached != null ? Future.value(cached) : quick(media?.mediaFor(game)),
    ).wait;
    return LaunchArt(
      cover: cover == null ? null : FileImage(cover),
      media: art == null ? null : FileImage(art),
    );
  }
}

/// A full-screen route that plays the launch over [builder]'s page. The page
/// is built at once, so the core loads during the animation. A tap or any
/// button skips to the game; with reduced motion it is one still frame,
/// then a cut.
class LaunchRoute<T> extends PageRoute<T> {
  LaunchRoute({
    required this.builder,
    required this.game,
    this.art = const LaunchArt(),
    this.origin,
    this.reduceMotion = false,
    this.duration = defaultDuration,
  });

  final WidgetBuilder builder;
  final Game game;
  final LaunchArt art;

  /// The tapped box or row on screen; the centre when null.
  final Rect? origin;
  final bool reduceMotion;

  static const defaultDuration = LaunchTimeline.total;

  /// Handhelds run the same stepped sequence: it is already cheap.
  static const handheldDuration = LaunchTimeline.total;

  /// How long the launch runs; the steps scale with it.
  final Duration duration;

  @override
  Duration get transitionDuration =>
      reduceMotion ? LaunchTimeline.reduced : duration;

  /// Leaving the game is a hard cut.
  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  /// Jumps to the end of the animation.
  void skip() {
    final c = controller;
    if (c != null && c.isAnimating && c.status == AnimationStatus.forward) {
      c.value = 1;
    }
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (animation.status == AnimationStatus.reverse) return child;
    return LaunchAnimation(
      animation: animation,
      game: game,
      art: art,
      origin: origin,
      onSkip: skip,
      duration: duration,
      reduceMotion: reduceMotion,
      child: child,
    );
  }
}

/// The launch drawn at [animation]'s value over [child] (the game page).
class LaunchAnimation extends StatelessWidget {
  const LaunchAnimation({
    super.key,
    required this.animation,
    required this.game,
    required this.child,
    this.art = const LaunchArt(),
    this.origin,
    this.onSkip,
    this.duration = LaunchTimeline.total,
    this.reduceMotion = false,
  });

  final Animation<double> animation;
  final Game game;
  final LaunchArt art;
  final Rect? origin;
  final VoidCallback? onSkip;
  final Widget child;

  /// What [animation] runs over; the steps are laid out on
  /// [LaunchTimeline.total] and scaled to it.
  final Duration duration;
  final bool reduceMotion;

  /// The step at [t] (0 to 1) of the route's animation.
  LaunchStep stepAt(double t) => reduceMotion
      ? reducedLaunchStep
      : launchStepAt(LaunchTimeline.total * t);

  @override
  Widget build(BuildContext context) {
    // The page stays in the tree from the first frame (its state loads the
    // core); it is only painted once the scrim hides the library.
    final page = AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Opacity(
        opacity: stepAt(animation.value).centred ? 1 : 0,
        child: child,
      ),
      child: child,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        _SkipKeys(
          animation: animation,
          onSkip: onSkip,
          // Gone once the launch ends, so it never takes the game's touches.
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, _) => animation.value >= 1
                ? const SizedBox.shrink()
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onSkip,
                    child: _frame(context, stepAt(animation.value)),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _frame(BuildContext context, LaunchStep step) {
    final t = BrutalTokens.ink().copyWith(
      focus: BrutalTokens.of(context).focus,
      density: BrutalDensity.of(context),
    );
    final screen = MediaQuery.sizeOf(context);
    if (step.inverted) {
      // The tapped row or box, inverted where it was.
      final r = origin;
      if (r == null) return const SizedBox.shrink();
      return Stack(
        children: [
          Positioned.fromRect(
            rect: r,
            child: Container(
              color: const Color(0xFF000000),
              padding: const EdgeInsets.all(BrutalTokens.s1),
              alignment: Alignment.center,
              child: Text(
                BrutalTokens.fileName(game.title),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: t.label.copyWith(color: t.focus),
              ),
            ),
          ),
        ],
      );
    }
    final box = launchBoxSize(game.system);
    // The box at rest a little below the middle, leaving room above for the
    // media to rise and below for the log line.
    final maxW = math.min(screen.width * 0.56, 380.0);
    final maxH = screen.height * 0.4;
    var w = maxW, h = maxW / box.aspect;
    if (h > maxH) {
      h = maxH;
      w = h * box.aspect;
    }
    final rect = Rect.fromCenter(
      center: screen.center(Offset(0, screen.height * 0.06)),
      width: w,
      height: h,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF000000)),
        _SteppedBox(
          rect: rect,
          step: step,
          game: game,
          art: art,
          opening: boxOpeningFor(game.system),
          depth: box.depth,
          tokens: t,
        ),
        if (step.log)
          Positioned(
            left: BrutalTokens.s4,
            right: BrutalTokens.s4,
            top: rect.bottom + t.shadowOffsetLarge.dy + BrutalTokens.s4,
            child: Center(
              child: Material(
                type: MaterialType.transparency,
                child: Theme(
                  data: Theme.of(context).copyWith(extensions: [t]),
                  child: LogLine(bootLine(game), status: LogStatus.ok),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Any key or button skips while the animation runs. A global handler, so
/// the game page keeps its own focus for when the launch ends.
class _SkipKeys extends StatefulWidget {
  const _SkipKeys({required this.animation, this.onSkip, required this.child});

  final Animation<double> animation;
  final VoidCallback? onSkip;
  final Widget child;

  @override
  State<_SkipKeys> createState() => _SkipKeysState();
}

class _SkipKeysState extends State<_SkipKeys> {
  bool _listening = false;

  bool _onKey(KeyEvent event) {
    if (widget.animation.value >= 1) {
      _stop();
      return false;
    }
    if (event is KeyDownEvent) widget.onSkip?.call();
    return true;
  }

  void _start() {
    if (_listening) return;
    _listening = true;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _stop() {
    if (!_listening) return;
    _listening = false;
    HardwareKeyboard.instance.removeHandler(_onKey);
  }

  void _onStatus(AnimationStatus s) =>
      s == AnimationStatus.forward ? _start() : _stop();

  @override
  void initState() {
    super.initState();
    if (widget.animation.status == AnimationStatus.forward) _start();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The box at the centre, its lid and media at [step]: flat faces, hard
/// borders and shadows, no perspective.
class _SteppedBox extends StatelessWidget {
  const _SteppedBox({
    required this.rect,
    required this.step,
    required this.game,
    required this.art,
    required this.opening,
    required this.depth,
    required this.tokens,
  });

  final Rect rect;
  final LaunchStep step;
  final Game game;
  final LaunchArt art;
  final BoxOpening opening;
  final double depth;
  final BrutalTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // A PICO-8 cart has no box lid to open.
    final lid = boxSpecFor(game.system).hinge == BoxHinge.none ? 0 : step.lid;
    final aspect = mediaAspect(game.system);
    // The media rests where the box model seats it in the open box, at its
    // real size relative to the box, drawn at its own proportions.
    var seat = boxSpecFor(game.system).mediaRect;
    // Nothing seated (a PICO-8 cart is its own box): most of the face.
    if (seat.isEmpty) {
      seat = Rect.fromCenter(
        center: const Offset(0.5, 0.5),
        width: 0.7,
        height: 0.8,
      );
    }
    final slot = Rect.fromLTWH(
      rect.left + seat.left * rect.width,
      rect.top + seat.top * rect.height,
      seat.width * rect.width,
      seat.height * rect.height,
    );
    var mw = slot.width, mh = mw / aspect;
    if (mh > slot.height) {
      mh = slot.height;
      mw = mh * aspect;
    }
    final inBox = Rect.fromCenter(center: slot.center, width: mw, height: mh);
    // Out of the box: above it for cardboard, up off the tray for a case.
    final rise = opening == BoxOpening.flap
        ? rect.height * 0.62
        : rect.height * 0.36;
    final mediaRect = inBox.shift(Offset(0, -rise * step.media / 2));
    final media = Positioned.fromRect(
      rect: mediaRect,
      child: GameMedia(system: game.system, art: art.media, cover: art.cover),
    );
    final edge = BorderSide(color: t.ink, width: BrutalTokens.border);
    final shadow = Positioned.fromRect(
      rect: rect.shift(t.shadowOffsetLarge),
      child: ColoredBox(color: t.shadow),
    );

    if (opening == BoxOpening.flap) {
      // Cardboard: the top flap stands up in two steps; the media rises
      // from behind the front face and is in front once fully out.
      final flapH = rect.width * depth * 1.6;
      final flap = lid == 0
          ? const SizedBox.shrink()
          : Positioned(
              left: rect.left,
              width: rect.width,
              top: rect.top - flapH * (lid == 1 ? 0.6 : 1),
              height: flapH * (lid == 1 ? 0.6 : 1),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: t.muted,
                  border: Border.fromBorderSide(edge),
                ),
              ),
            );
      final front = Positioned.fromRect(
        rect: rect,
        child: _CoverFace(cover: art.cover, tokens: t),
      );
      return Stack(
        fit: StackFit.expand,
        children: step.media == 2
            ? [shadow, flap, front, media]
            : [shadow, flap, media, front],
      );
    }

    // A case: the front swings off its left spine in two steps, showing the
    // tray the media sits on; open, the inside of the front lies left of
    // the spine.
    final tray = Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.panel,
          border: Border.fromBorderSide(edge),
        ),
      ),
    );
    final Widget front = switch (lid) {
      0 => Positioned.fromRect(
        rect: rect,
        child: _CoverFace(cover: art.cover, tokens: t),
      ),
      1 => Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width * 0.55,
        height: rect.height,
        child: _CoverFace(cover: art.cover, tokens: t),
      ),
      _ => Positioned(
        left: rect.left - rect.width * 0.35,
        top: rect.top,
        width: rect.width * 0.35,
        height: rect.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: t.muted,
            border: Border.fromBorderSide(edge),
          ),
        ),
      ),
    };
    return Stack(
      fit: StackFit.expand,
      children: lid == 2
          ? [shadow, tray, front, media]
          : [shadow, tray, media, front],
    );
  }
}

/// The front of the box: the cover in a hard border, or the controller
/// glyph on the panel without one.
class _CoverFace extends StatelessWidget {
  const _CoverFace({required this.cover, required this.tokens});

  final ImageProvider? cover;
  final BrutalTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final c = cover;
    return Container(
      decoration: BoxDecoration(
        color: t.panel,
        border: Border.all(color: t.ink, width: BrutalTokens.border),
      ),
      child: c == null
          ? Center(
              child: Icon(DenaIcons.controller, color: t.focus, size: 54),
            )
          : Image(
              image: c,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => ColoredBox(color: t.panel),
            ),
    );
  }
}

/// Opens [game]'s box and loads its media over [page]. Images come from
/// [scope]; the animation starts from the box last tapped.
Future<T?> pushLaunch<T>(
  NavigatorState navigator,
  LibraryScope scope,
  Game game, {
  required WidgetBuilder page,
  bool reduceMotion = false,
  Duration duration = LaunchRoute.defaultDuration,
}) async {
  final origin = LaunchOrigin.rectOf(game);
  final art = reduceMotion
      ? const LaunchArt()
      : await LaunchArt.load(scope, game);
  // Fetch genuine media art for next time when it isn't here yet.
  scope.media?.prefetch([game]);
  return navigator.push<T>(
    LaunchRoute<T>(
      builder: page,
      game: game,
      art: art,
      origin: origin,
      reduceMotion: reduceMotion,
      duration: duration,
    ),
  );
}
