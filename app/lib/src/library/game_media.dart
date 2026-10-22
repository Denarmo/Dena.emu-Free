// SPDX-License-Identifier: GPL-3.0-or-later
// Cartridges, discs, UMDs and PICO-8 carts drawn with the game's media art,
// or its cover on the console's own label frame when there is none.
// Our own drawings: no logos, no traced artwork.
// Spec: docs/specs/launch-animation.md
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'media_art.dart';

/// How one system's cartridge looks: outline proportions, plastic, and
/// where the label sits (fractions of the cartridge size).
class CartShape {
  const CartShape({
    required this.aspect,
    required this.body,
    required this.label,
    this.labelFrame,
    this.radius = 0.04,
    this.topRadius,
    this.ridges = 0,
    this.notch = false,
    this.shoulders = false,
  });

  /// Width / height.
  final double aspect;
  final Color body;

  /// The label window in 0..1 cartridge coordinates.
  final Rect label;

  /// The printed band around the cover when the cover stands in for the
  /// label (the console's label style), or null for a borderless sticker.
  final Color? labelFrame;

  /// Corner radius as a fraction of the width; [topRadius] when the top
  /// corners differ (SNES, N64).
  final double radius;
  final double? topRadius;

  /// Grip ridges below the label.
  final int ridges;

  /// A notch in the top edge (Game Boy Advance, DS).
  final bool notch;

  /// Wider top with stepped shoulders (N64).
  final bool shoulders;
}

/// Cartridge proportions per system, from the real carts' outside
/// dimensions; colours are the common retail plastic.
const cartShapes = <String, CartShape>{
  'nes': CartShape(
    aspect: 120 / 133,
    body: Color(0xFF8E8E92),
    label: Rect.fromLTWH(0.12, 0.06, 0.76, 0.56),
    labelFrame: Color(0xFF151515),
    radius: 0.02,
    ridges: 9,
  ),
  'snes': CartShape(
    aspect: 135 / 87,
    body: Color(0xFFB4B4B8),
    label: Rect.fromLTWH(0.18, 0.12, 0.64, 0.6),
    labelFrame: Color(0xFFE9E9EC),
    radius: 0.03,
    topRadius: 0.12,
    ridges: 4,
  ),
  'n64': CartShape(
    aspect: 116 / 75,
    body: Color(0xFF4B4B51),
    label: Rect.fromLTWH(0.16, 0.08, 0.68, 0.58),
    radius: 0.03,
    topRadius: 0.08,
    shoulders: true,
  ),
  'gb': CartShape(
    aspect: 57 / 65,
    body: Color(0xFF9C9CA2),
    label: Rect.fromLTWH(0.11, 0.18, 0.78, 0.6),
    labelFrame: Color(0xFF2B2B33),
    radius: 0.05,
    ridges: 3,
  ),
  'gbc': CartShape(
    aspect: 57 / 65,
    body: Color(0xFF2A2A30),
    label: Rect.fromLTWH(0.11, 0.18, 0.78, 0.6),
    labelFrame: Color(0xFFE6E6EA),
    radius: 0.05,
    ridges: 3,
  ),
  'gba': CartShape(
    aspect: 57 / 35,
    body: Color(0xFF6F6F78),
    label: Rect.fromLTWH(0.09, 0.2, 0.82, 0.72),
    radius: 0.07,
    notch: true,
  ),
  'nds': CartShape(
    aspect: 35 / 33,
    body: Color(0xFF55555C),
    label: Rect.fromLTWH(0.1, 0.24, 0.8, 0.68),
    radius: 0.06,
    notch: true,
  ),
  '3ds': CartShape(
    aspect: 35 / 33,
    body: Color(0xFFE2E2E6),
    label: Rect.fromLTWH(0.1, 0.24, 0.8, 0.68),
    radius: 0.06,
    notch: true,
  ),
  'genesis': CartShape(
    aspect: 109 / 138,
    body: Color(0xFF1C1C1F),
    label: Rect.fromLTWH(0.1, 0.1, 0.8, 0.62),
    radius: 0.03,
    ridges: 6,
  ),
};

/// A cartridge shape for [system]; the NES cart for systems without one.
CartShape cartShapeFor(String system) =>
    cartShapes[system] ?? cartShapes['nes']!;

/// Width / height of [system]'s media.
double mediaAspect(String system) => switch (mediaKindFor(system)) {
  MediaKind.disc => 1,
  MediaKind.umd => 64 / 65,
  MediaKind.pico8Cart => 160 / 205,
  MediaKind.cartridge => cartShapeFor(system).aspect,
};

/// One game's physical media: its genuine art when [art] is given, else
/// [cover] on the console's label frame, else bare plastic.
class GameMedia extends StatelessWidget {
  const GameMedia({
    super.key,
    required this.system,
    this.art,
    this.cover,
    this.spin = 0,
  });

  final String system;

  /// Genuine media art (label texture, disc face).
  final ImageProvider? art;

  /// The game's cover, the fallback.
  final ImageProvider? cover;

  /// Disc and UMD rotation in turns (the disc spins up as it loads).
  final double spin;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: mediaAspect(system),
    child: switch (mediaKindFor(system)) {
      MediaKind.cartridge => _Cartridge(
        shape: cartShapeFor(system),
        art: art,
        cover: cover,
      ),
      MediaKind.disc => _Disc(art: art, cover: cover, spin: spin),
      MediaKind.umd => _Umd(art: art, cover: cover, spin: spin),
      MediaKind.pico8Cart => _Pico8Cart(art: art ?? cover),
    },
  );
}

Widget _image(ImageProvider p, {BoxFit fit = BoxFit.cover}) => Image(
  image: p,
  fit: fit,
  gaplessPlayback: true,
  filterQuality: FilterQuality.medium,
  errorBuilder: (_, _, _) => const SizedBox.shrink(),
);

class _Cartridge extends StatelessWidget {
  const _Cartridge({required this.shape, this.art, this.cover});

  final CartShape shape;
  final ImageProvider? art, cover;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      final l = shape.label;
      final rect = Rect.fromLTWH(
        l.left * size.width,
        l.top * size.height,
        l.width * size.width,
        l.height * size.height,
      );
      final r = Radius.circular(size.width * 0.015);
      final frame = shape.labelFrame;
      final art = this.art;
      final cover = this.cover;
      final Widget label;
      if (art != null) {
        label = _image(art, fit: BoxFit.fill);
      } else if (cover != null) {
        // The cover cropped onto the console's printed label frame.
        final pad = frame == null ? 0.0 : rect.width * 0.05;
        label = Container(
          color: frame ?? Colors.transparent,
          padding: EdgeInsets.fromLTRB(pad, pad * 1.6, pad, pad),
          child: ClipRRect(
            borderRadius: BorderRadius.all(r),
            child: _image(cover),
          ),
        );
      } else {
        label = ColoredBox(color: frame ?? shape.body);
      }
      return CustomPaint(
        painter: _CartPainter(shape),
        foregroundPainter: _SheenPainter(BorderRadius.all(r), rect),
        child: Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: ClipRRect(borderRadius: BorderRadius.all(r), child: label),
            ),
          ],
        ),
      );
    },
  );
}

class _CartPainter extends CustomPainter {
  _CartPainter(this.shape);

  final CartShape shape;

  Path outline(Size s) {
    final w = s.width, h = s.height;
    final r = Radius.circular(w * shape.radius);
    final top = Radius.circular(w * (shape.topRadius ?? shape.radius));
    if (shape.shoulders) {
      // Wide top, narrower body below a step.
      final inset = w * 0.06, step = h * 0.62;
      return Path()
        ..addRRect(
          RRect.fromLTRBAndCorners(0, 0, w, step, topLeft: top, topRight: top),
        )
        ..addRRect(
          RRect.fromLTRBAndCorners(
            inset,
            step - 1,
            w - inset,
            h,
            bottomLeft: r,
            bottomRight: r,
          ),
        );
    }
    final path = Path()
      ..addRRect(
        RRect.fromLTRBAndCorners(
          0,
          0,
          w,
          h,
          topLeft: top,
          topRight: top,
          bottomLeft: r,
          bottomRight: r,
        ),
      );
    if (!shape.notch) return path;
    final notch = Path()
      ..addRRect(
        RRect.fromLTRBR(
          w * 0.38,
          -1,
          w * 0.62,
          h * 0.07,
          Radius.circular(w * 0.02),
        ),
      );
    return Path.combine(PathOperation.difference, path, notch);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = outline(size);
    canvas.drawShadow(path, Colors.black, size.height * 0.04, false);
    final body = shape.body;
    final lighter = Color.lerp(body, Colors.white, 0.18)!;
    final darker = Color.lerp(body, Colors.black, 0.22)!;
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [lighter, body, darker],
          stops: const [0, 0.55, 1],
        ).createShader(Offset.zero & size),
    );
    // Moulded rim: light top-left, dark bottom-right.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, size.width * 0.008)
        ..color = darker,
    );
    // Recessed label well.
    final l = shape.label;
    final well = Rect.fromLTWH(
      l.left * size.width,
      l.top * size.height,
      l.width * size.width,
      l.height * size.height,
    ).inflate(size.width * 0.012);
    canvas.drawRRect(
      RRect.fromRectAndRadius(well, Radius.circular(size.width * 0.02)),
      Paint()..color = darker,
    );
    if (shape.ridges > 0) {
      final top = l.bottom * size.height + size.height * 0.05;
      final bottom = size.height * 0.95;
      final gap = (bottom - top) / (shape.ridges * 2);
      final ridge = Paint()
        ..color = darker
        ..strokeWidth = math.max(1, gap * 0.6)
        ..strokeCap = StrokeCap.round;
      final hi = Paint()
        ..color = lighter
        ..strokeWidth = math.max(0.5, gap * 0.25);
      for (var i = 0; i < shape.ridges; i++) {
        final y = top + gap * (i * 2 + 1);
        if (y > bottom) break;
        final a = Offset(size.width * 0.22, y),
            b = Offset(size.width * 0.78, y);
        canvas.drawLine(a, b, ridge);
        canvas.drawLine(
          a.translate(0, gap * 0.4),
          b.translate(0, gap * 0.4),
          hi,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CartPainter old) => old.shape != shape;
}

/// A soft gloss over a label: printed stickers catch the light.
class _SheenPainter extends CustomPainter {
  _SheenPainter(this.radius, this.rect);

  final BorderRadius radius;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      radius.toRRect(rect),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment(-1, -1),
          end: Alignment(1, 1),
          colors: [Color(0x33FFFFFF), Color(0x00FFFFFF), Color(0x14000000)],
          stops: [0, 0.45, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SheenPainter old) => old.rect != rect;
}

/// The printed face of a disc: [art] fills it; [cover] sits on a white print
/// band; with neither, bare silver.
class _Disc extends StatelessWidget {
  const _Disc({this.art, this.cover, this.spin = 0});

  final ImageProvider? art, cover;
  final double spin;

  @override
  Widget build(BuildContext context) {
    final art = this.art, cover = this.cover;
    final Widget face;
    if (art != null) {
      face = _image(art);
    } else if (cover != null) {
      face = Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFFF2F2F0)),
          FractionallySizedBox(
            widthFactor: 0.94,
            heightFactor: 0.94,
            child: ClipOval(child: _image(cover)),
          ),
        ],
      );
    } else {
      face = const SizedBox.shrink();
    }
    // The centre hole shows what is behind the disc.
    return Transform.rotate(
      angle: spin * 2 * math.pi,
      child: ClipPath(
        clipper: const _AnnulusClipper(0.075),
        child: CustomPaint(
          painter: const _DiscBasePainter(),
          foregroundPainter: const _DiscHubPainter(),
          child: ClipPath(clipper: const _AnnulusClipper(0.17), child: face),
        ),
      ),
    );
  }
}

class _AnnulusClipper extends CustomClipper<Path> {
  const _AnnulusClipper(this.inner);

  /// Inner radius as a fraction of the size.
  final double inner;

  @override
  Path getClip(Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: c, radius: r))
      ..addOval(Rect.fromCircle(center: c, radius: size.shortestSide * inner));
  }

  @override
  bool shouldReclip(_AnnulusClipper old) => old.inner != inner;
}

class _DiscBasePainter extends CustomPainter {
  const _DiscBasePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawShadow(Path()..addOval(rect), Colors.black, r * 0.08, false);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const SweepGradient(
          colors: [
            Color(0xFFD8D8DC),
            Color(0xFFB9C6D6),
            Color(0xFFE8E2C8),
            Color(0xFFC9B8D8),
            Color(0xFFD8D8DC),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_DiscBasePainter old) => false;
}

/// Clear hub, stacking ring and the centre hole.
class _DiscHubPainter extends CustomPainter {
  const _DiscHubPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final s = size.shortestSide;
    canvas.drawCircle(c, s * 0.17, Paint()..color = const Color(0x55D0D4DA));
    canvas.drawCircle(
      c,
      s * 0.12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.008
        ..color = const Color(0x66FFFFFF),
    );
    canvas.drawCircle(
      c,
      s * 0.49,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.006
        ..color = const Color(0x40000000),
    );
  }

  @override
  bool shouldRepaint(_DiscHubPainter old) => false;
}

/// A UMD: dark shell, label across the top, a window on the disc below.
class _Umd extends StatelessWidget {
  const _Umd({this.art, this.cover, this.spin = 0});

  final ImageProvider? art, cover;
  final double spin;

  @override
  Widget build(BuildContext context) {
    final label = art ?? cover;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final window = Rect.fromCenter(
          center: Offset(w / 2, h * 0.68),
          width: w * 0.62,
          height: w * 0.62,
        );
        return CustomPaint(
          painter: const _UmdShellPainter(),
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: window,
                child: ClipOval(child: _Disc(spin: spin)),
              ),
              Positioned(
                left: w * 0.08,
                right: w * 0.08,
                top: h * 0.05,
                height: h * 0.42,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(w * 0.03),
                  child: label == null
                      ? const ColoredBox(color: Color(0xFF26262C))
                      : _image(label),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UmdShellPainter extends CustomPainter {
  const _UmdShellPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Flat top, round bottom.
    final path = Path()
      ..moveTo(w * 0.06, 0)
      ..lineTo(w * 0.94, 0)
      ..quadraticBezierTo(w, 0, w, h * 0.06)
      ..lineTo(w, h * 0.5)
      ..arcToPoint(Offset(0, h * 0.5), radius: Radius.elliptical(w / 2, h / 2))
      ..lineTo(0, h * 0.06)
      ..quadraticBezierTo(0, 0, w * 0.06, 0)
      ..close();
    canvas.drawShadow(path, Colors.black, h * 0.04, false);
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A3A42), Color(0xFF1E1E24)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.01
        ..color = const Color(0x22FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_UmdShellPainter old) => false;
}

/// A PICO-8 `.p8.png` is already a picture of a cartridge; drawn as is.
/// Without one, a chunky blank cart.
class _Pico8Cart extends StatelessWidget {
  const _Pico8Cart({this.art});

  final ImageProvider? art;

  @override
  Widget build(BuildContext context) {
    final art = this.art;
    if (art != null) {
      return Image(
        image: art,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.none,
        gaplessPlayback: true,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF202024),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFF1C40F), width: 3),
      ),
    );
  }
}
