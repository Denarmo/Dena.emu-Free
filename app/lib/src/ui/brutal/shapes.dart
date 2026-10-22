// SPDX-License-Identifier: GPL-3.0-or-later
// Shapes the theme hands to stock Material widgets: a square border with a
// hard offset shadow, and a square slider thumb.
// Spec: docs/specs/brutalist-ui.md (2.3, 3)
import 'package:material_ui/material_ui.dart';

/// A square border of [side] with a solid, unblurred shadow [shadowOffset]
/// down and right. The shadow is painted outside the box, so it never covers
/// the content; [shadowOffset] zero draws the pressed state.
class BrutalBorder extends OutlinedBorder {
  const BrutalBorder({
    super.side = const BorderSide(width: 3),
    this.shadowOffset = Offset.zero,
    this.shadowColor = const Color(0xFF000000),
  });

  final Offset shadowOffset;
  final Color shadowColor;

  @override
  BrutalBorder copyWith({
    BorderSide? side,
    Offset? shadowOffset,
    Color? shadowColor,
  }) => BrutalBorder(
    side: side ?? this.side,
    shadowOffset: shadowOffset ?? this.shadowOffset,
    shadowColor: shadowColor ?? this.shadowColor,
  );

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect.deflate(side.strokeInset));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);

  @override
  bool get preferPaintInterior => true;

  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) => canvas.drawRect(rect, paint);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (shadowOffset != Offset.zero) {
      final shadow = Path.combine(
        PathOperation.difference,
        Path()..addRect(rect.shift(shadowOffset)),
        Path()..addRect(rect),
      );
      canvas.drawPath(shadow, Paint()..color = shadowColor);
    }
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawRect(
      rect.deflate(side.width / 2),
      Paint()
        ..color = side.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width,
    );
  }

  @override
  ShapeBorder scale(double t) => BrutalBorder(
    side: side.scale(t),
    shadowOffset: shadowOffset * t,
    shadowColor: shadowColor,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is BrutalBorder
      ? BrutalBorder(
          side: BorderSide.lerp(a.side, side, t),
          shadowOffset: Offset.lerp(a.shadowOffset, shadowOffset, t)!,
          shadowColor: Color.lerp(a.shadowColor, shadowColor, t)!,
        )
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is BrutalBorder
      ? BrutalBorder(
          side: BorderSide.lerp(side, b.side, t),
          shadowOffset: Offset.lerp(shadowOffset, b.shadowOffset, t)!,
          shadowColor: Color.lerp(shadowColor, b.shadowColor, t)!,
        )
      : super.lerpTo(b, t);

  @override
  bool operator ==(Object other) =>
      other is BrutalBorder &&
      other.side == side &&
      other.shadowOffset == shadowOffset &&
      other.shadowColor == shadowColor;

  @override
  int get hashCode => Object.hash(side, shadowOffset, shadowColor);
}

/// A square slider thumb: [fill] with a 3 px [border].
class BrutalSliderThumb extends SliderComponentShape {
  const BrutalSliderThumb({
    required this.fill,
    required this.border,
    this.size = 18,
  });

  final Color fill;
  final Color border;
  final double size;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.square(size);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final rect = Rect.fromCenter(center: center, width: size, height: size);
    context.canvas
      ..drawRect(rect, Paint()..color = fill)
      ..drawRect(
        rect.deflate(1.5),
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
  }
}

/// Page changes are a hard cut on every platform (brutalist-ui.md 2.4).
class BrutalPageTransitions extends PageTransitionsBuilder {
  const BrutalPageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
