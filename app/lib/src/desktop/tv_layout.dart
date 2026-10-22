// SPDX-License-Identifier: GPL-3.0-or-later
// The TV layout: in controller mode the whole UI is scaled up for 10-foot
// viewing, so the screens laid out for 640x480 and phones read from the
// sofa at 1080p and 4K. Same widgets, bigger. Spec: docs/specs/controller-mode.md
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The logical size the TV layout lays out at, at most: 1080p shows 1.5x,
/// 4K at 100 % shows 3x, a 1280x800 Steam Deck stays at 1x.
const tvLayoutSize = Size(1280, 720);

/// The scale for a window of [size] logical pixels: as large as keeps at
/// least [tvLayoutSize] of room, never below 1.
double tvScale(Size size) => math.max(
  1.0,
  math.min(size.width / tvLayoutSize.width, size.height / tvLayoutSize.height),
);

/// Scales [child] by [tvScale] when [enabled]: it lays out at the smaller
/// size with a matching MediaQuery and is painted (and hit-tested) larger,
/// so text and vector art stay sharp.
class TvScale extends StatelessWidget {
  const TvScale({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final scale = enabled ? tvScale(mq.size) : 1.0;
    // The same tree either way, so switching keeps every route's state.
    return Align(
      alignment: Alignment.topLeft,
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: mq.size / scale,
          child: MediaQuery(
            data: mq.copyWith(
              size: mq.size / scale,
              devicePixelRatio: mq.devicePixelRatio * scale,
              padding: mq.padding / scale,
              viewPadding: mq.viewPadding / scale,
              viewInsets: mq.viewInsets / scale,
              systemGestureInsets: mq.systemGestureInsets / scale,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
