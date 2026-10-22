// SPDX-License-Identifier: GPL-3.0-or-later
// A game drawn as its console's real box: carton, keep case, jewel case or
// cart, with the cover in the label window and the box's side showing.
// Spec: docs/specs/game-boxes.md
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../ui/brutal/table.dart';
import '../ui/system_palette.dart';
import 'database.dart';
import 'game_box_model.dart';
import 'games_tab.dart';

/// [game]'s box, standing on the bottom of the space it is given and sized
/// by [boxScaleFor] so every console's box keeps its real size relative to
/// the others. [focused] draws the D-pad focus ring around the box.
class GameBox extends StatefulWidget {
  const GameBox({
    super.key,
    required this.game,
    this.focused = false,
    this.alignment = Alignment.bottomCenter,
  });

  final Game game;
  final bool focused;

  /// Where the box sits in its stage (the grid stands boxes on a shelf).
  final Alignment alignment;

  @override
  State<GameBox> createState() => _GameBoxState();
}

class _GameBoxState extends State<GameBox> {
  double? _coverAspect;

  @override
  void didUpdateWidget(GameBox old) {
    super.didUpdateWidget(old);
    if (old.game.sha1 != widget.game.sha1 ||
        old.game.customArtPath != widget.game.customArtPath) {
      _coverAspect = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final spec = boxSpecFor(game.system).orientedFor(_coverAspect);
    final scheme = Theme.of(context).colorScheme;
    final tint = systemScheme(game.system, scheme).primary;
    return LayoutBuilder(
      builder: (context, box) {
        final stage = box.biggest;
        final scale = boxScaleFor(stage);
        final front = Size(spec.widthMm * scale, spec.heightMm * scale);
        final d = spec.depthMm * boxDepthSlant * scale;
        final label = spec.labelRect(front);
        final radius = spec.cornerMm * scale;
        final labelRadius = spec.material == BoxMaterial.cardboard
            ? radius
            : math.max(0.0, radius - math.min(label.left, label.top));
        return Align(
          alignment: widget.alignment,
          child: SizedBox(
            width: front.width + d,
            height: front.height + d,
            child: CustomPaint(
              painter: _ShellPainter(
                spec: spec,
                front: front,
                depth: d,
                radius: radius,
                tint: tint,
              ),
              foregroundPainter: _FinishPainter(
                spec: spec,
                front: front,
                depth: d,
                radius: radius,
                ring: widget.focused ? scheme.primary : null,
              ),
              child: Padding(
                padding: EdgeInsets.only(top: d, right: d),
                child: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: label,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(labelRadius),
                        child: GameCover(
                          game: game,
                          placeholder: SystemPlaceholder(system: game.system),
                          onAspect: (a) {
                            if (mounted && a != _coverAspect) {
                              setState(() => _coverAspect = a);
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shadow, side and top faces, and the front face's base under the art.
class _ShellPainter extends CustomPainter {
  _ShellPainter({
    required this.spec,
    required this.front,
    required this.depth,
    required this.radius,
    required this.tint,
  });

  final BoxSpec spec;
  final Size front;
  final double depth, radius;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final d = depth;
    final face = Offset(0, d) & front;
    final rrect = RRect.fromRectAndRadius(face, Radius.circular(radius));

    // Contact shadow on the shelf, then a soft drop shadow.
    canvas.drawRRect(
      rrect.shift(Offset(d * 0.6 + 1, 2)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + d * 0.4),
    );

    final (side, top) = _sideColors();
    final r = math.min(radius, d);
    // Right side face.
    canvas.drawPath(
      Path()
        ..moveTo(face.right - r * 0.3, face.top + r)
        ..lineTo(face.right + d - r * 0.3, face.top - d + r)
        ..lineTo(face.right + d, face.bottom - d - r)
        ..lineTo(face.right, face.bottom - r)
        ..close(),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [side, Color.lerp(side, const Color(0xFF000000), 0.25)!],
        ).createShader(Rect.fromLTRB(face.right, 0, size.width, size.height)),
    );
    // Top face.
    canvas.drawPath(
      Path()
        ..moveTo(face.left + r, face.top)
        ..lineTo(face.left + d + r, face.top - d)
        ..lineTo(face.right + d - r * 0.3, face.top - d + r * 0.3)
        ..lineTo(face.right - r * 0.3, face.top + r * 0.3)
        ..close(),
      Paint()..color = top,
    );
    if (spec.material == BoxMaterial.cardboard) {
      // The tuck flap's fold along the top edge.
      canvas.drawLine(
        Offset(face.left + d * 0.5, face.top - d * 0.5),
        Offset(face.right + d * 0.5, face.top - d * 0.5),
        Paint()
          ..color = const Color(0x22000000)
          ..strokeWidth = 0.6,
      );
    }

    // Front face base: card stock, moulded plastic, or the jewel case tray.
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = switch (spec.material) {
          BoxMaterial.cardboard => const Color(0xFFEDE8DC),
          _ => spec.shellColor,
        },
    );
  }

  /// Side and top colours: a carton's printed sides take the system colour,
  /// cases show their plastic.
  (Color, Color) _sideColors() {
    final base = switch (spec.material) {
      BoxMaterial.cardboard => Color.lerp(tint, const Color(0xFF000000), 0.35)!,
      BoxMaterial.jewel => const Color(0xFF2A2C31),
      _ => Color.lerp(spec.shellColor, const Color(0xFF000000), 0.2)!,
    };
    final top = Color.lerp(base, const Color(0xFFFFFFFF), 0.18)!;
    return (base, top);
  }

  @override
  bool shouldRepaint(_ShellPainter old) =>
      old.spec != spec ||
      old.front != front ||
      old.depth != depth ||
      old.tint != tint;
}

/// Material details over the art: the clear sleeve's gloss and frame, a
/// jewel case's hinge strip, a carton's printed edge, a cart's grip ridges;
/// then the focus ring.
class _FinishPainter extends CustomPainter {
  _FinishPainter({
    required this.spec,
    required this.front,
    required this.depth,
    required this.radius,
    required this.ring,
  });

  final BoxSpec spec;
  final Size front;
  final double depth, radius;
  final Color? ring;

  @override
  void paint(Canvas canvas, Size size) {
    final face = Offset(0, depth) & front;
    final rrect = RRect.fromRectAndRadius(face, Radius.circular(radius));
    final label = spec.labelRect(front).shift(face.topLeft);
    switch (spec.material) {
      case BoxMaterial.cardboard:
        _cardboard(canvas, face, rrect);
      case BoxMaterial.plastic:
        _plastic(canvas, face, rrect, label);
      case BoxMaterial.jewel:
        _jewel(canvas, face, rrect, label);
      case BoxMaterial.cart:
        _cart(canvas, face, rrect, label);
    }
    final ring = this.ring;
    if (ring != null) {
      canvas.drawRRect(
        rrect.inflate(3),
        Paint()
          ..color = ring.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawRRect(
        rrect.inflate(1.5),
        Paint()
          ..color = ring
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  void _cardboard(Canvas canvas, Rect face, RRect rrect) {
    // Light catching the folded top-left edges, shade on the far ones.
    canvas.drawPath(
      Path()
        ..moveTo(face.left, face.bottom)
        ..lineTo(face.left, face.top)
        ..lineTo(face.right, face.top),
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0x40000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6,
    );
    // Matte card: a broad, faint sheen only.
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x14FFFFFF), Color(0x00FFFFFF), Color(0x10000000)],
        ).createShader(face),
    );
  }

  void _plastic(Canvas canvas, Rect face, RRect rrect, Rect label) {
    // The sleeve's edge where it meets the moulded frame.
    canvas.drawRect(
      label,
      Paint()
        ..color = const Color(0x30FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7,
    );
    _gloss(canvas, face, rrect, strength: 0.16);
    if (spec.hinge == BoxHinge.left) {
      // The spine's moulded hinge just inside the left edge.
      final x = face.left + math.max(1.5, label.left - face.left) * 0.5;
      canvas.drawLine(
        Offset(x, face.top + radius),
        Offset(x, face.bottom - radius),
        Paint()
          ..color = const Color(0x55000000)
          ..strokeWidth = 1,
      );
    }
    _rim(canvas, rrect);
  }

  void _jewel(Canvas canvas, Rect face, RRect rrect, Rect label) {
    // Hinge strip: clear plastic over the dark tray, with two ridges.
    final strip = Rect.fromLTRB(face.left, face.top, label.left, face.bottom);
    canvas.drawRect(
      strip,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF3A3D44), Color(0xFF1A1B1F), Color(0xFF2E3036)],
        ).createShader(strip),
    );
    for (final f in const [0.35, 0.7]) {
      final x = strip.left + strip.width * f;
      canvas.drawLine(
        Offset(x, strip.top + 1),
        Offset(x, strip.bottom - 1),
        Paint()
          ..color = const Color(0x40FFFFFF)
          ..strokeWidth = 0.8,
      );
    }
    _gloss(canvas, face, rrect, strength: 0.24);
    _rim(canvas, rrect);
  }

  void _cart(Canvas canvas, Rect face, RRect rrect, Rect label) {
    // Recessed label well.
    canvas.drawRRect(
      RRect.fromRectAndRadius(label.inflate(1.2), const Radius.circular(2)),
      Paint()
        ..color = const Color(0x66000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    // Grip ridges under the label.
    final top = label.bottom + (face.bottom - label.bottom) * 0.3;
    final ridge = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 0.8;
    final shade = Paint()
      ..color = const Color(0x55000000)
      ..strokeWidth = 0.8;
    for (var i = 0; i < 4; i++) {
      final y = top + i * (face.bottom - top - radius) / 4;
      canvas.drawLine(
        Offset(face.left + face.width * 0.22, y),
        Offset(face.right - face.width * 0.22, y),
        shade,
      );
      canvas.drawLine(
        Offset(face.left + face.width * 0.22, y + 1),
        Offset(face.right - face.width * 0.22, y + 1),
        ridge,
      );
    }
    _gloss(canvas, face, rrect, strength: 0.08);
    _rim(canvas, rrect);
  }

  /// A diagonal reflection band across clear or glossy plastic.
  void _gloss(
    Canvas canvas,
    Rect face,
    RRect rrect, {
    required double strength,
  }) {
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      face,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, 0.32, 0.42, 0.55, 1],
          colors: [
            Color.fromRGBO(255, 255, 255, strength * 0.6),
            Color.fromRGBO(255, 255, 255, strength * 0.15),
            Color.fromRGBO(255, 255, 255, strength),
            const Color(0x00FFFFFF),
            const Color(0x14000000),
          ],
        ).createShader(face),
    );
    canvas.restore();
  }

  /// A thin bright rim where the plastic edge catches light.
  void _rim(Canvas canvas, RRect rrect) {
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..color = const Color(0x2EFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_FinishPainter old) =>
      old.spec != spec ||
      old.front != front ||
      old.depth != depth ||
      old.ring != ring;
}

/// [game]'s cover as a table thumbnail (brutalist-ui.md 3, BoxThumb): the
/// art in a black-bordered box of its console's box shape.
class GameBoxThumb extends StatelessWidget {
  const GameBoxThumb({super.key, required this.game});

  final Game game;

  @override
  Widget build(BuildContext context) {
    final spec = boxSpecFor(game.system);
    return BoxThumb(
      aspect: spec.widthMm / spec.heightMm,
      child: GameCover(
        game: game,
        placeholder: SystemPlaceholder(system: game.system),
      ),
    );
  }
}
