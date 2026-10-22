// SPDX-License-Identifier: GPL-3.0-or-later
// The foil layer on library covers: a static diagonal holo stripe that may
// step a few pixels with the phone's tilt.
// Spec: docs/specs/foil-covers.md, docs/specs/brutalist-ui.md (4.3)
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../shell/handheld.dart';

/// One tilt source shared by every cover. Listens to the phone's motion
/// sensors only while at least one visible cover listens and the app is in
/// the foreground. Without a sensor the value stays at zero: the stripe is
/// static.
class FoilTilt extends ValueNotifier<Offset> with WidgetsBindingObserver {
  FoilTilt._() : super(Offset.zero);

  static final FoilTilt instance = FoilTilt._();
  static const _channel = EventChannel('app.dena/tilt');

  /// Off in tests: the stripe then stays put (no sensors).
  static bool animate = true;

  StreamSubscription<dynamic>? _sub;
  bool _noSensor = false;
  bool _observing = false;
  bool _foreground = true;
  int _users = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_users++ == 0) _start();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (--_users == 0) _stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    fg ? _start() : _stop();
  }

  void _start() {
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    if (_users == 0 || !_foreground || !animate || _noSensor) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _sub ??= _channel.receiveBroadcastStream().listen(
      (e) {
        final l = e as List;
        value = Offset((l[0] as num).toDouble(), (l[1] as num).toDouble());
      },
      onError: (_) {
        _noSensor = true;
        _stop();
        value = Offset.zero;
      },
    );
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
  }
}

/// How far the stripe moves at most, in logical pixels.
const double foilMaxShift = 8;

/// The stripe moves in steps of this many pixels, never smoothly.
const double foilShiftStep = 2;

/// The stripe's sideways shift for [tilt] (-1..1 per axis): at most
/// [foilMaxShift], in whole [foilShiftStep]s.
double foilShiftFor(Offset tilt) {
  final raw = (tilt.dx * 0.75 + tilt.dy * 0.25).clamp(-1.0, 1.0);
  return (raw * foilMaxShift / foilShiftStep).roundToDouble() * foilShiftStep;
}

/// Paints the foil stripe above [child]. On phones it follows the tilt in
/// steps while ticker mode is on (the tab is visible); on handhelds it
/// never moves.
class FoilOverlay extends StatefulWidget {
  const FoilOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<FoilOverlay> createState() => _FoilOverlayState();
}

class _FoilOverlayState extends State<FoilOverlay> {
  bool _listening = false;
  double _shift = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final listening =
        TickerMode.valuesOf(context).enabled && !Handheld.of(context);
    if (listening == _listening) return;
    _listening = listening;
    if (listening) {
      FoilTilt.instance.addListener(_onTilt);
      _shift = foilShiftFor(FoilTilt.instance.value);
    } else {
      FoilTilt.instance.removeListener(_onTilt);
    }
  }

  void _onTilt() {
    final shift = foilShiftFor(FoilTilt.instance.value);
    // Only a new step repaints.
    if (shift != _shift) setState(() => _shift = shift);
  }

  @override
  void dispose() {
    if (_listening) FoilTilt.instance.removeListener(_onTilt);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(painter: FoilStripePainter(shift: _shift)),
          ),
        ),
      ),
    ],
  );
}

/// Two 6 px bands, cyan and magenta at 40%, running diagonally through the
/// middle of the cover, moved sideways by [shift].
class FoilStripePainter extends CustomPainter {
  const FoilStripePainter({this.shift = 0});

  final double shift;

  static const band = 6.0;
  static const cyan = Color(0x6600FFFF);
  static const magenta = Color(0x66FF00FF);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final long = size.width + size.height;
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..translate(size.width / 2 + shift, size.height / 2)
      ..rotate(-math.pi / 4)
      ..drawRect(
        Rect.fromLTWH(-long, -band, long * 2, band),
        Paint()..color = cyan,
      )
      ..drawRect(
        Rect.fromLTWH(-long, 0, long * 2, band),
        Paint()..color = magenta,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(FoilStripePainter old) => old.shift != shift;
}
