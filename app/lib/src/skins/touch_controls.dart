// SPDX-License-Identifier: GPL-3.0-or-later
// Draws a skin's controls and turns touches into RetroPad masks.
// Spec: docs/specs/skins.md
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'skin_layout.dart';

/// Multi-touch controls for [layout], drawn in a box of the layout's mapping
/// size scaled to fit. Reports the combined mask on every change.
class TouchControls extends StatefulWidget {
  const TouchControls({
    super.key,
    required this.layout,
    required this.onMask,
    required this.onMenu,
    this.onAnalog,
    this.paintItems = true,
    this.art,
  });

  /// Stick tilt changed: stick 0 left / 1 right, x and y -1..1 (+y down).
  final void Function(int stick, Offset tilt)? onAnalog;

  /// Draw the controls (built-in skins, or a skin's debug mode); imported
  /// skins bring their own artwork, so only pressed items move on it.
  final bool paintItems;

  /// The skin's artwork, laid out over the same box: pressed keys sink by
  /// redrawing their piece of it.
  final Widget? art;

  final SkinLayout layout;
  final ValueChanged<int> onMask;
  final VoidCallback onMenu;

  @override
  State<TouchControls> createState() => _TouchControlsState();
}

const _dpadBits =
    1 << RetroPad.up |
    1 << RetroPad.down |
    1 << RetroPad.left |
    1 << RetroPad.right;

class _TouchControlsState extends State<TouchControls>
    with SingleTickerProviderStateMixin {
  final _pointers = <int, Offset>{};
  TouchState _state = TouchState.none;
  double _scale = 1;
  late final _travel = KeyTravel(this);

  void _update() {
    final next = touchState(widget.layout, _pointers, previous: _state);
    // Input goes out first; the keys' travel only follows it on screen.
    if (next.menu && !_state.menu) widget.onMenu();
    if (next.mask != _state.mask) widget.onMask(next.mask);
    for (final stick in const [0, 1]) {
      final a = next.analog[stick] ?? Offset.zero;
      if (a != (_state.analog[stick] ?? Offset.zero)) {
        widget.onAnalog?.call(stick, a);
      }
    }
    final newPress = next.pressed.entries.any(
      (e) => _state.pressed[e.key] != e.value,
    );
    final dpad = next.mask & _dpadBits;
    if (newPress ||
        next.mask & ~_state.mask != 0 ||
        (dpad != 0 && dpad != _state.mask & _dpadBits)) {
      HapticFeedback.selectionClick();
    }
    final changedItems =
        newPress || _state.pressed.length != next.pressed.length;
    _travel.follow(widget.layout, next);
    _state = next;
    // Painted controls repaint from the travel alone; skins with their own
    // art only rebuild when the set of moving keys changes.
    if (changedItems || widget.paintItems) setState(() {});
  }

  void _move(PointerEvent e) {
    _pointers[e.pointer] = e.localPosition / _scale;
    _update();
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    _update();
  }

  @override
  void didUpdateWidget(TouchControls old) {
    super.didUpdateWidget(old);
    if (old.layout != widget.layout) {
      _travel.reset();
      if (_pointers.isNotEmpty) {
        _pointers.clear();
        _state = TouchState.none;
        widget.onMask(0);
        widget.onAnalog?.call(0, Offset.zero);
        widget.onAnalog?.call(1, Offset.zero);
      }
    }
  }

  @override
  void dispose() {
    _travel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.layout.mappingSize;
    return LayoutBuilder(
      builder: (context, box) {
        _scale = (box.maxWidth / size.width).clamp(
          0.01,
          box.maxHeight / size.height,
        );
        final items = widget.layout.items;
        return Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: size.width * _scale,
            height: size.height * _scale,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _move,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: !widget.paintItems
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.art case final art?)
                          for (final i in _travel.moving)
                            if (i < items.length)
                              _ArtKey(
                                key: ValueKey(i),
                                item: items[i],
                                pose: _travel.pose(i),
                                scale: _scale,
                                art: art,
                              ),
                      ],
                    )
                  : RepaintBoundary(
                      child: CustomPaint(
                        painter: _SkinPainter(
                          layout: widget.layout,
                          scale: _scale,
                          state: _state,
                          travel: _travel,
                          scheme: _onBlack(Theme.of(context).colorScheme),
                          text: Theme.of(context).textTheme.labelLarge!,
                        ),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// Where a control is in its travel: [press] 0 up to 1 fully down, and for
/// a D-pad or stick the [tilt] towards the held direction (-1..1, +y down).
typedef KeyPose = ({double press, Offset tilt});

const KeyPose _rest = (press: 0, tilt: Offset.zero);

/// Eases every control towards the pose the touch state puts it in, so keys
/// travel down and spring back instead of jumping. Each control has its own
/// listenable, so only the keys in motion rebuild, and the whole notifier
/// drives painted skins' repaints without any widget rebuild.
class KeyTravel extends ChangeNotifier {
  KeyTravel(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  final _poses = <int, ValueNotifier<KeyPose>>{};
  final _targets = <int, KeyPose>{};
  Duration _last = Duration.zero;

  /// Time constants: a key goes down faster than it comes back up.
  static const downTau = 0.012, upTau = 0.035, tiltTau = 0.02;

  /// Controls not at rest (pressed, or still coming back up).
  Iterable<int> get moving => _poses.keys;

  ValueListenable<KeyPose> pose(int item) =>
      _poses[item] ?? ValueNotifier(_rest);

  /// The current pose of [item], at rest when it isn't moving.
  KeyPose poseOf(int item) => _poses[item]?.value ?? _rest;

  /// Sets where each control is heading for [state].
  void follow(SkinLayout layout, TouchState state) {
    _targets.clear();
    for (final i in state.pressed.values.toSet()) {
      if (i >= layout.items.length) continue;
      final item = layout.items[i];
      _targets[i] = switch (item.kind) {
        SkinItemKind.dpad => _dpadPose(state.mask),
        SkinItemKind.thumbstick => (
          press: 1,
          tilt:
              state.analog[item.inputs.contains('rightstick') ? 1 : 0] ??
              Offset.zero,
        ),
        _ => (press: 1, tilt: Offset.zero),
      };
    }
    for (final MapEntry(key: i, value: t) in _targets.entries) {
      final n = _poses.putIfAbsent(i, () => ValueNotifier(_rest));
      final kind = layout.items[i].kind;
      if (kind == SkinItemKind.thumbstick) {
        // The knob is under the thumb: no lag.
        n.value = t;
      } else if (n.value.press < 0.5 && t.press > n.value.press) {
        // A press shows on the very next frame, then settles.
        n.value = (press: math.max(n.value.press, 0.5), tilt: n.value.tilt);
      }
    }
    if (_poses.isNotEmpty && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
    notifyListeners();
  }

  static KeyPose _dpadPose(int mask) {
    bool on(int b) => mask & (1 << b) != 0;
    final dir = Offset(
      (on(RetroPad.right) ? 1.0 : 0.0) - (on(RetroPad.left) ? 1.0 : 0.0),
      (on(RetroPad.down) ? 1.0 : 0.0) - (on(RetroPad.up) ? 1.0 : 0.0),
    );
    // A thumb in the dead zone rests on the pad without rocking it.
    if (dir == Offset.zero) return (press: 0.25, tilt: Offset.zero);
    return (press: 1, tilt: dir / dir.distance);
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    double ease(double tau) => 1 - math.exp(-dt / tau);
    final done = <int>[];
    for (final MapEntry(key: i, value: n) in _poses.entries) {
      final t = _targets[i] ?? _rest;
      final v = n.value;
      final down = t.press > v.press;
      var press = v.press + (t.press - v.press) * ease(down ? downTau : upTau);
      var tilt = Offset.lerp(
        v.tilt,
        t.tilt,
        ease(t.tilt == Offset.zero ? upTau : tiltTau),
      )!;
      if ((press - t.press).abs() < 0.01) press = t.press;
      if ((tilt - t.tilt).distance < 0.01) tilt = t.tilt;
      n.value = (press: press, tilt: tilt);
      if (!_targets.containsKey(i) && press == 0 && tilt == Offset.zero) {
        done.add(i);
      }
    }
    final settled = _poses.entries.every((e) {
      final t = _targets[e.key] ?? _rest;
      return e.value.value == t;
    });
    // Keys back at rest drop out; their last pose (at rest) draws nothing.
    done.forEach(_poses.remove);
    if (settled) _ticker.stop();
    notifyListeners();
  }

  /// Everything back at rest at once (a new layout).
  void reset() {
    _ticker.stop();
    _targets.clear();
    for (final n in _poses.values) {
      n.dispose();
    }
    _poses.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    for (final n in _poses.values) {
      n.dispose();
    }
    super.dispose();
  }
}

/// How far a pressed D-pad rocks about its pivot, in radians (about 10°).
const dpadTiltAngle = 0.17;

/// The D-pad as one moulded cross with arms a third of its size.
Path dpadCross(Rect r) {
  final t = r.width / 3, u = r.height / 3;
  final radius = Radius.circular(math.min(t, u) * 0.22);
  return Path.combine(
    PathOperation.union,
    Path()..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: r.center, width: r.width, height: u),
        radius,
      ),
    ),
    Path()..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: r.center, width: t, height: r.height),
        radius,
      ),
    ),
  );
}

/// Where a D-pad in [frame] is drawn for [pose]: rocked about its centre
/// towards [KeyPose.tilt] in perspective (the held arm goes down, the
/// opposite one comes up) and sunk a little by [KeyPose.press].
Matrix4 dpadTransform(Rect frame, KeyPose pose) {
  final c = frame.center;
  final s = 1 - 0.03 * pose.press;
  return Matrix4.translationValues(
      c.dx,
      c.dy + frame.height * 0.012 * pose.press,
      0,
    )
    ..multiply(Matrix4.identity()..setEntry(3, 2, 1 / frame.shortestSide))
    ..multiply(Matrix4.rotationX(dpadTiltAngle * pose.tilt.dy))
    ..multiply(Matrix4.rotationY(-dpadTiltAngle * pose.tilt.dx))
    ..multiply(Matrix4.diagonal3Values(s, s, 1))
    ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
}

/// The face of a button or the menu key: a circle for square frames, else a
/// stadium.
RRect keyFace(Rect r) {
  final side = r.shortestSide;
  final square = (r.width - r.height).abs() < 2;
  final box = square
      ? Rect.fromCenter(center: r.center, width: side, height: side)
      : r;
  return RRect.fromRectAndRadius(box, Radius.circular(side / 2));
}

/// How far a pressed key sinks: its art shrinks to this size about its
/// centre and moves down by [_sinkDrop] of its height.
const _sinkScale = 0.92;
const _sinkDrop = 0.03;

class _SkinPainter extends CustomPainter {
  _SkinPainter({
    required this.layout,
    required this.scale,
    required this.state,
    required this.travel,
    required this.scheme,
    required this.text,
  }) : super(repaint: travel);

  final SkinLayout layout;
  final double scale;
  final TouchState state;
  final KeyTravel travel;
  final ColorScheme scheme;
  final TextStyle text;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(scale);
    final alpha = layout.translucent ? 0.5 : 1.0;
    final idle = scheme.surfaceContainerHighest.withValues(alpha: alpha);
    for (final (i, item) in layout.items.indexed) {
      final pose = travel.poseOf(i);
      final r = item.frame;
      switch (item.kind) {
        case SkinItemKind.dpad:
          _dpad(canvas, r, pose, idle, alpha);
        case SkinItemKind.menu:
          _key(canvas, keyFace(r), pose.press, idle, alpha, (c, f, color) {
            _icon(c, f, Icons.menu, color);
          });
        case SkinItemKind.thumbstick:
          // Base ring, and the knob where the stick is tilted.
          canvas.drawCircle(r.center, r.width / 2, Paint()..color = idle);
          final stick = item.inputs.contains('rightstick') ? 1 : 0;
          final tilt = state.analog[stick] ?? Offset.zero;
          canvas.drawCircle(
            r.center + tilt * (r.width * 0.3),
            r.width * 0.22,
            Paint()
              ..color = Color.lerp(
                scheme.outline,
                scheme.primary,
                pose.press,
              )!.withValues(alpha: alpha),
          );
        case SkinItemKind.button:
          _key(canvas, keyFace(r), pose.press, idle, alpha, (c, f, color) {
            _label(c, f, item.label, color, alpha);
          });
      }
    }
  }

  /// A moulded key: a dark well, a lip in shade below the cap and a cap lit
  /// from above. Pressed, the cap travels down over its lip and falls into
  /// shadow, taking its label with it.
  void _key(
    Canvas canvas,
    RRect face,
    double press,
    Color idle,
    double alpha,
    void Function(Canvas, Rect, Color) mark,
  ) {
    final lip = face.height * 0.08;
    canvas.drawRRect(
      face.inflate(1),
      Paint()..color = Color.fromRGBO(0, 0, 0, 0.45 * alpha),
    );
    canvas.drawRRect(
      face,
      Paint()..color = Color.lerp(idle, Colors.black, 0.35)!,
    );
    final s = 1 - (1 - _sinkScale) * 0.5 * press;
    final c = face.center;
    final cap = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: c.translate(0, -lip * (1 - press)),
        width: face.width * s,
        height: face.height * s,
      ),
      face.tlRadius * s,
    );
    final base = Color.lerp(
      idle,
      Color.alphaBlend(scheme.primary.withValues(alpha: 0.35), idle),
      press,
    )!;
    canvas.drawRRect(cap, Paint()..color = base);
    canvas.drawRRect(
      cap,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.fromRGBO(255, 255, 255, 0.28 * (1 - press) * alpha),
            const Color(0x00000000),
            Color.fromRGBO(0, 0, 0, (0.12 + 0.22 * press) * alpha),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(cap.outerRect),
    );
    final ink = Color.lerp(
      scheme.onSurfaceVariant,
      scheme.onSurface,
      press,
    )!.withValues(alpha: alpha < 1 ? 0.8 : 1);
    mark(canvas, cap.outerRect, ink);
  }

  void _dpad(Canvas canvas, Rect r, KeyPose pose, Color idle, double alpha) {
    final cross = dpadCross(r);
    final t = r.shortestSide / 3;
    // The socket the cross sits in, and its shadow, which the raised side
    // throws further.
    canvas.drawPath(
      cross.shift(Offset(0, t * 0.04)),
      Paint()..color = Color.fromRGBO(0, 0, 0, 0.5 * alpha),
    );
    canvas.drawPath(
      cross.shift(
        Offset(0, t * 0.12 * (1 - 0.5 * pose.press)) - pose.tilt * (t * 0.08),
      ),
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, 0.35 * alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, t * 0.08),
    );
    canvas.save();
    canvas.transform(dpadTransform(r, pose).storage);
    canvas.drawPath(cross, Paint()..color = idle);
    canvas.drawPath(
      cross,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.fromRGBO(255, 255, 255, 0.22 * alpha),
            const Color(0x00000000),
            Color.fromRGBO(0, 0, 0, 0.2 * alpha),
          ],
        ).createShader(r),
    );
    _tiltShade(canvas, cross, r, pose.tilt, alpha);
    // Centre dimple and engraved arrows.
    canvas.drawCircle(
      r.center,
      t * 0.26,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.fromRGBO(0, 0, 0, 0.18 * alpha),
            const Color(0x00000000),
          ],
        ).createShader(Rect.fromCircle(center: r.center, radius: t * 0.26)),
    );
    final ink = Paint()
      ..color = scheme.onSurfaceVariant.withValues(alpha: 0.45 * alpha);
    for (final dir in const [
      Offset(0, -1),
      Offset(0, 1),
      Offset(-1, 0),
      Offset(1, 0),
    ]) {
      final tip = r.center + dir * (t * 1.25);
      final back = r.center + dir * (t * 1.0);
      final side = Offset(-dir.dy, dir.dx) * (t * 0.16);
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(back.dx + side.dx, back.dy + side.dy)
          ..lineTo(back.dx - side.dx, back.dy - side.dy)
          ..close(),
        ink,
      );
    }
    canvas.restore();
  }

  void _label(Canvas canvas, Rect r, String label, Color color, double alpha) {
    if (label.isEmpty) return;
    TextPainter make(double size) => TextPainter(
      text: TextSpan(
        text: label,
        style: text.copyWith(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    var size = (r.height * 0.42).clamp(10.0, 22.0);
    var tp = make(size);
    // Shrink to fit the item's width instead of wrapping.
    if (tp.width > r.width * 0.85) {
      size = (size * r.width * 0.85 / tp.width).clamp(8.0, 22.0);
      tp = make(size);
    }
    tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
  }

  void _icon(Canvas canvas, Rect r, IconData icon, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: r.height * 0.6,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_SkinPainter old) =>
      old.layout != layout ||
      old.scale != scale ||
      old.state != state ||
      old.travel != travel ||
      old.scheme != scheme;
}

/// Light across a rocked D-pad: the arm going down falls into shade, the one
/// coming up catches the light.
void _tiltShade(Canvas canvas, Path cross, Rect r, Offset tilt, double alpha) {
  final m = tilt.distance.clamp(0.0, 1.0);
  if (m == 0) return;
  final half = r.shortestSide / 2;
  final dir = tilt / tilt.distance;
  canvas.drawPath(
    cross,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment(dir.dx, dir.dy),
        end: Alignment(-dir.dx, -dir.dy),
        colors: [
          Color.fromRGBO(0, 0, 0, 0.38 * m * alpha),
          const Color(0x00000000),
          Color.fromRGBO(255, 255, 255, 0.16 * m * alpha),
        ],
        stops: const [0, 0.5, 1],
      ).createShader(Rect.fromCircle(center: r.center, radius: half)),
  );
}

/// A moving key of a skin that brings its own art: the key's piece of the
/// art, redrawn as it travels. Buttons sink into a dark gap, darker and
/// shaded from the rim above; the D-pad rocks as one cross towards the held
/// direction over its socket, its shadow shifting; a stick's knob follows
/// the thumb. Only this key rebuilds while it moves.
class _ArtKey extends StatelessWidget {
  const _ArtKey({
    super.key,
    required this.item,
    required this.pose,
    required this.scale,
    required this.art,
  });

  final SkinItem item;
  final ValueListenable<KeyPose> pose;
  final double scale;
  final Widget art;

  @override
  Widget build(BuildContext context) {
    final r = item.frame;
    final f = Rect.fromLTRB(
      r.left * scale,
      r.top * scale,
      r.right * scale,
      r.bottom * scale,
    );
    return IgnorePointer(
      child: ValueListenableBuilder<KeyPose>(
        valueListenable: pose,
        builder: (context, p, _) {
          if (p.press <= 0 && p.tilt == Offset.zero) {
            return const SizedBox.shrink();
          }
          return switch (item.kind) {
            SkinItemKind.dpad => _dpad(f, p),
            SkinItemKind.thumbstick => _stick(f, p),
            _ => _button(f, p),
          };
        },
      ),
    );
  }

  Widget _button(Rect f, KeyPose p) {
    final face = keyFace(f);
    final c = face.center;
    final sink = 1 - (1 - _sinkScale) * p.press;
    final drop = face.height * _sinkDrop * p.press;
    final m = Matrix4.translationValues(c.dx, c.dy + drop, 0)
      ..multiply(Matrix4.diagonal3Values(sink, sink, 1))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
    final path = Path()..addRRect(face);
    return Stack(
      fit: StackFit.expand,
      children: [
        // The gap the key leaves as it goes down.
        CustomPaint(painter: _GapPainter(path, 0.8 * p.press)),
        Transform(
          transform: m,
          child: ClipPath(
            clipper: _PathClip(path),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColorFiltered(colorFilter: _pressedTone(p.press), child: art),
                CustomPaint(painter: _RimShadePainter(face, p.press)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dpad(Rect f, KeyPose p) {
    final cross = dpadCross(f);
    final t = f.shortestSide / 3;
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _GapPainter(
            cross,
            0.85 * math.max(p.press, p.tilt.distance),
            shadow: Offset(0, t * 0.1) - p.tilt * (t * 0.1),
            blur: t * 0.1,
          ),
        ),
        Transform(
          transform: dpadTransform(f, p),
          child: ClipPath(
            clipper: _PathClip(cross),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColorFiltered(
                  colorFilter: _pressedTone(p.press * 0.5),
                  child: art,
                ),
                CustomPaint(painter: _TiltShadePainter(cross, f, p.tilt)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _stick(Rect f, KeyPose p) {
    // The knob follows the thumb.
    final k = f.shortestSide * 0.37;
    final knob = Path()..addOval(Rect.fromCircle(center: f.center, radius: k));
    final move = p.tilt * (f.shortestSide * 0.2);
    const sink = 0.97;
    final c = f.center;
    final m =
        Matrix4.translationValues(
            c.dx + move.dx,
            c.dy + move.dy + k * 2 * _sinkDrop,
            0,
          )
          ..multiply(Matrix4.diagonal3Values(sink, sink, 1))
          ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _GapPainter(knob, 0.8)),
        Transform(
          transform: m,
          child: ClipPath(
            clipper: _PathClip(knob),
            child: ColorFiltered(colorFilter: _pressedTone(1), child: art),
          ),
        ),
      ],
    );
  }
}

/// Darker and a little flatter, as a key out of the light, by [press].
ColorFilter _pressedTone(double press) {
  final k = 1 - 0.2 * press;
  return ColorFilter.matrix([
    k, 0, 0, 0, 0, //
    0, k, 0, 0, 0, //
    0, 0, k, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
}

class _PathClip extends CustomClipper<Path> {
  _PathClip(this.path);
  final Path path;
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(_PathClip old) => old.path != path;
}

/// The dark gap a key leaves as it moves, and optionally its soft shadow.
class _GapPainter extends CustomPainter {
  _GapPainter(this.path, this.opacity, {this.shadow, this.blur = 0});
  final Path path;
  final double opacity;
  final Offset? shadow;
  final double blur;
  @override
  void paint(Canvas canvas, Size size) {
    if (shadow case final s?) {
      canvas.drawPath(
        path.shift(s),
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, 0.35 * opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }
    canvas.drawPath(path, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
  }

  @override
  bool shouldRepaint(_GapPainter old) =>
      old.path != path || old.opacity != opacity || old.shadow != shadow;
}

class _TiltShadePainter extends CustomPainter {
  _TiltShadePainter(this.cross, this.frame, this.tilt);
  final Path cross;
  final Rect frame;
  final Offset tilt;
  @override
  void paint(Canvas canvas, Size size) =>
      _tiltShade(canvas, cross, frame, tilt, 1);

  @override
  bool shouldRepaint(_TiltShadePainter old) =>
      old.tilt != tilt || old.frame != frame;
}

/// The shell's rim shades the top of a sunk key; its lower edge stays lit.
class _RimShadePainter extends CustomPainter {
  _RimShadePainter(this.r, this.press);
  final RRect r;
  final double press;
  @override
  void paint(Canvas canvas, Size size) {
    final box = r.outerRect;
    canvas.drawRRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.fromRGBO(0, 0, 0, 0.45 * press),
            const Color(0x00000000),
            Color.fromRGBO(255, 255, 255, 0.08 * press),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(box),
    );
  }

  @override
  bool shouldRepaint(_RimShadePainter old) => old.r != r || old.press != press;
}

/// The most a skin's art is stretched to fill bars around it (see [SkinView]).
const maxArtStretch = 1.15;

/// A whole skin: optional artwork, the game view at the skin's screen frame
/// and the touch controls, scaled to fit and aligned to the bottom.
class SkinView extends StatelessWidget {
  const SkinView({
    super.key,
    required this.layout,
    required this.game,
    required this.onMask,
    required this.onMenu,
    this.onAnalog,
    this.artwork,
    this.paintItems = true,
  });

  final void Function(int stick, Offset tilt)? onAnalog;
  final SkinLayout layout;
  final Widget game;
  final Widget? artwork;
  final bool paintItems;
  final ValueChanged<int> onMask;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final size = layout.mappingSize;
    return LayoutBuilder(
      builder: (context, box) {
        final scale = (box.maxWidth / size.width).clamp(
          0.01,
          box.maxHeight / size.height,
        );
        final s = layout.screen;
        final screen = Rect.fromLTWH(
          s.left * scale,
          s.top * scale,
          s.width * scale,
          s.height * scale,
        );
        final skin = Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: size.width * scale,
            height: size.height * scale,
            child: Stack(
              children: [
                if (artwork != null) Positioned.fill(child: artwork!),
                Positioned.fromRect(rect: screen, child: game),
                Positioned.fill(
                  child: TouchControls(
                    layout: layout,
                    onMask: onMask,
                    onMenu: onMenu,
                    onAnalog: onAnalog,
                    paintItems: paintItems,
                    art: artwork,
                  ),
                ),
              ],
            ),
          ),
        );
        // When the screen is a little wider or taller than the skin, a
        // stretched copy of the art fills the bars, so the shell reaches the
        // screen's edges. Only the art's outer edge shows there.
        final stretch = math.max(
          box.maxWidth / (size.width * scale),
          box.maxHeight / (size.height * scale),
        );
        final art = artwork;
        if (art == null || stretch <= 1.001 || stretch > maxArtStretch) {
          return skin;
        }
        return Stack(
          children: [
            Positioned.fill(child: ExcludeSemantics(child: art)),
            Positioned.fill(child: skin),
          ],
        );
      },
    );
  }
}

final _lightSchemes = <Color, ColorScheme>{};

/// The game backdrop is black in light and dark mode alike, so the built-in
/// controls keep the light palette's tones (theming.md); a dark scheme's
/// containers would vanish against it.
ColorScheme _onBlack(ColorScheme scheme) =>
    scheme.brightness == Brightness.light
    ? scheme
    : _lightSchemes.putIfAbsent(
        scheme.primary,
        () => ColorScheme.fromSeed(
          seedColor: scheme.primary,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        ),
      );
