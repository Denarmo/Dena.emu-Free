// SPDX-License-Identifier: GPL-3.0-or-later
// Per-console game box model: real proportions, material, label window and
// the open-box geometry. Pure data, shared by the library grid, the stash,
// the long-press zoom and the open-box launch animation.
// Spec: docs/specs/game-boxes.md
import 'dart:math' as math;
import 'dart:ui';

/// What the box is made of; decides corners, gloss and how the sides look.
enum BoxMaterial {
  /// Printed folding carton (NES, SNES, N64, Game Boy family).
  cardboard,

  /// Moulded keep case with a clear sleeve over the art (DS, PSP, PS2,
  /// Genesis clamshell, Saturn long case).
  plastic,

  /// Clear CD jewel case with a hinge strip and a dark tray (PS1, Dreamcast).
  jewel,

  /// No box: the cartridge itself is shown (PICO-8 carts).
  cart,
}

/// What sits inside the box and gets "loaded" when a game starts.
enum BoxMedia { cartridge, disc, umd, card, none }

/// The edge the lid swings around when the box opens.
enum BoxHinge {
  /// Keep cases and jewel cases open like a book.
  left,

  /// Cartons open by their top flap; the media slides out upwards.
  top,

  /// Nothing opens (PICO-8 cart).
  none,
}

/// One console's box. Sizes are real millimetres (front face width x height,
/// and thickness), so boxes keep their true relative size side by side.
class BoxSpec {
  const BoxSpec({
    required this.id,
    required this.widthMm,
    required this.heightMm,
    required this.depthMm,
    required this.material,
    required this.media,
    required this.mediaWidthMm,
    required this.mediaHeightMm,
    required this.hinge,
    this.label = const Rect.fromLTRB(0, 0, 1, 1),
    this.cornerMm = 0.6,
    this.shellColor = const Color(0xFF1C1C20),
    this.rotatable = false,
  });

  /// Stable key: the system id it was looked up for, or `generic`.
  final String id;

  /// Front face size and thickness in millimetres.
  final double widthMm, heightMm, depthMm;

  final BoxMaterial material;
  final BoxMedia media;

  /// The media's own size (a disc is [mediaWidthMm] across).
  final double mediaWidthMm, mediaHeightMm;
  final BoxHinge hinge;

  /// Where the cover art sits on the front face, as fractions of it
  /// (0..1 from the top left). Plastic cases frame the sleeve; a jewel case
  /// leaves room for its hinge strip.
  final Rect label;

  /// Corner radius of the front face in millimetres.
  final double cornerMm;

  /// The moulded plastic, tray or cart body colour; cartons ignore it and
  /// tint their sides from the system colour.
  final Color shellColor;

  /// Regional boxes differ in orientation (US SNES/N64 are landscape, the
  /// Japanese and European ones portrait): when the cover is the other way
  /// round the box is turned to match instead of cropping the art.
  final bool rotatable;

  @override
  bool operator ==(Object other) =>
      other is BoxSpec &&
      other.id == id &&
      other.widthMm == widthMm &&
      other.heightMm == heightMm;

  @override
  int get hashCode => Object.hash(id, widthMm, heightMm);

  /// Width / height of the front face.
  double get aspect => widthMm / heightMm;

  Size get frontMm => Size(widthMm, heightMm);

  /// This box turned to match a cover image of [coverAspect]
  /// (width / height); unchanged unless [rotatable] and the orientations
  /// disagree clearly (a near-square cover keeps the default).
  BoxSpec orientedFor(double? coverAspect) {
    if (!rotatable || coverAspect == null || coverAspect <= 0) return this;
    final landscape = aspect > 1;
    final coverLandscape = coverAspect > 1.08;
    final coverPortrait = coverAspect < 0.92;
    if (landscape && coverPortrait || !landscape && coverLandscape) {
      return BoxSpec(
        id: id,
        widthMm: heightMm,
        heightMm: widthMm,
        depthMm: depthMm,
        material: material,
        media: media,
        mediaWidthMm: mediaWidthMm,
        mediaHeightMm: mediaHeightMm,
        hinge: hinge,
        label: label,
        cornerMm: cornerMm,
        shellColor: shellColor,
      );
    }
    return this;
  }

  /// The label window in a front face of [front] logical pixels.
  Rect labelRect(Size front) => Rect.fromLTRB(
    label.left * front.width,
    label.top * front.height,
    label.right * front.width,
    label.bottom * front.height,
  );

  /// The open box: where the media rests inside, as a rectangle in front-face
  /// fractions (0..1), centred in the tray. For the launch animation.
  Rect get mediaRect {
    final w = (mediaWidthMm / widthMm).clamp(0.0, 1.0);
    final h = (mediaHeightMm / heightMm).clamp(0.0, 1.0);
    return Rect.fromCenter(
      // A carton's media rests low, below the open flap.
      center: Offset(
        0.5,
        hinge == BoxHinge.top ? math.min(0.5 + h / 4, 1 - h / 2) : 0.5,
      ),
      width: w,
      height: h,
    );
  }
}

/// The stage every grid cell represents, in millimetres: room for the
/// largest front face (a Saturn long case, a landscape SNES carton) plus
/// the box side drawn at [boxDepthSlant]. A Game Boy box then looks as small
/// next to them as it does on a real shelf.
const boxStageMm = Size(216, 216);

/// How much of a box's thickness shows as its side and top (an oblique
/// view: the side goes right and the top goes up by depth x this).
const boxDepthSlant = 0.45;

/// Pixels per millimetre for a stage of [stage] logical pixels.
double boxScaleFor(Size stage) {
  final sx = stage.width / boxStageMm.width;
  final sy = stage.height / boxStageMm.height;
  return sx < sy ? sx : sy;
}

/// Front face size in logical pixels for [spec] on a [stage].
Size boxSizeOn(BoxSpec spec, Size stage) {
  final s = boxScaleFor(stage);
  return Size(spec.widthMm * s, spec.heightMm * s);
}

/// The whole drawn box (front plus the visible side and top) in logical
/// pixels for [spec] on a [stage]: what the stash uses as a body size.
Size boxFootprintOn(BoxSpec spec, Size stage) {
  final s = boxScaleFor(stage);
  final d = spec.depthMm * boxDepthSlant * s;
  return Size(spec.widthMm * s + d, spec.heightMm * s + d);
}

// Approximate retail sizes (North American releases unless noted).

const Map<String, BoxSpec> boxSpecs = {
  'nes': BoxSpec(
    id: 'nes',
    widthMm: 127,
    heightMm: 178,
    depthMm: 25,
    material: BoxMaterial.cardboard,
    media: BoxMedia.cartridge,
    mediaWidthMm: 120,
    mediaHeightMm: 133,
    hinge: BoxHinge.top,
  ),
  'snes': BoxSpec(
    id: 'snes',
    widthMm: 190,
    heightMm: 138,
    depthMm: 32,
    material: BoxMaterial.cardboard,
    media: BoxMedia.cartridge,
    mediaWidthMm: 136,
    mediaHeightMm: 86,
    hinge: BoxHinge.top,
    rotatable: true,
  ),
  'n64': BoxSpec(
    id: 'n64',
    widthMm: 186,
    heightMm: 134,
    depthMm: 38,
    material: BoxMaterial.cardboard,
    media: BoxMedia.cartridge,
    mediaWidthMm: 116,
    mediaHeightMm: 75,
    hinge: BoxHinge.top,
    rotatable: true,
  ),
  'gb': BoxSpec(
    id: 'gb',
    widthMm: 114,
    heightMm: 127,
    depthMm: 25,
    material: BoxMaterial.cardboard,
    media: BoxMedia.cartridge,
    mediaWidthMm: 57,
    mediaHeightMm: 65,
    hinge: BoxHinge.top,
  ),
  'gbc': BoxSpec(
    id: 'gbc',
    widthMm: 114,
    heightMm: 127,
    depthMm: 25,
    material: BoxMaterial.cardboard,
    media: BoxMedia.cartridge,
    mediaWidthMm: 57,
    mediaHeightMm: 65,
    hinge: BoxHinge.top,
  ),
  'gba': BoxSpec(
    id: 'gba',
    widthMm: 125,
    heightMm: 125,
    depthMm: 25,
    material: BoxMaterial.cardboard,
    media: BoxMedia.cartridge,
    mediaWidthMm: 57,
    mediaHeightMm: 35,
    hinge: BoxHinge.top,
  ),
  'nds': BoxSpec(
    id: 'nds',
    widthMm: 125,
    heightMm: 137,
    depthMm: 14,
    material: BoxMaterial.plastic,
    media: BoxMedia.card,
    mediaWidthMm: 35,
    mediaHeightMm: 33,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.035, 0.03, 0.965, 0.97),
    cornerMm: 4,
    shellColor: Color(0xFF2A2B30),
  ),
  'n3ds': BoxSpec(
    id: 'n3ds',
    widthMm: 125,
    heightMm: 137,
    depthMm: 11,
    material: BoxMaterial.plastic,
    media: BoxMedia.card,
    mediaWidthMm: 35,
    mediaHeightMm: 33,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.035, 0.03, 0.965, 0.97),
    cornerMm: 4,
    shellColor: Color(0xFFE9E9EC),
  ),
  'psx': BoxSpec(
    id: 'psx',
    widthMm: 142,
    heightMm: 125,
    depthMm: 10,
    material: BoxMaterial.jewel,
    media: BoxMedia.disc,
    mediaWidthMm: 120,
    mediaHeightMm: 120,
    hinge: BoxHinge.left,
    // A 120 mm insert behind the lid; the hinge strip is on the left.
    label: Rect.fromLTRB(0.135, 0.02, 0.98, 0.98),
    cornerMm: 1.2,
    shellColor: Color(0xFF141416),
  ),
  'dreamcast': BoxSpec(
    id: 'dreamcast',
    widthMm: 142,
    heightMm: 125,
    depthMm: 10,
    material: BoxMaterial.jewel,
    media: BoxMedia.disc,
    mediaWidthMm: 120,
    mediaHeightMm: 120,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.135, 0.02, 0.98, 0.98),
    cornerMm: 1.2,
    shellColor: Color(0xFF141416),
  ),
  'ps2': BoxSpec(
    id: 'ps2',
    widthMm: 135,
    heightMm: 190,
    depthMm: 14,
    material: BoxMaterial.plastic,
    media: BoxMedia.disc,
    mediaWidthMm: 120,
    mediaHeightMm: 120,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.03, 0.02, 0.97, 0.98),
    cornerMm: 3,
    shellColor: Color(0xFF15161A),
  ),
  // GameCube and Wii keep cases (gamecube-wii.md): the
  // GameCube disc is 80 mm, the Wii one 120 mm.
  'gamecube': BoxSpec(
    id: 'gamecube',
    widthMm: 135,
    heightMm: 190,
    depthMm: 14,
    material: BoxMaterial.plastic,
    media: BoxMedia.disc,
    mediaWidthMm: 80,
    mediaHeightMm: 80,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.03, 0.02, 0.97, 0.98),
    cornerMm: 3,
    shellColor: Color(0xFF15161A),
  ),
  'wii': BoxSpec(
    id: 'wii',
    widthMm: 135,
    heightMm: 190,
    depthMm: 14,
    material: BoxMaterial.plastic,
    media: BoxMedia.disc,
    mediaWidthMm: 120,
    mediaHeightMm: 120,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.03, 0.02, 0.97, 0.98),
    cornerMm: 3,
    shellColor: Color(0xFFF2F2F2),
  ),
  'psp': BoxSpec(
    id: 'psp',
    widthMm: 105,
    heightMm: 180,
    depthMm: 14,
    material: BoxMaterial.plastic,
    media: BoxMedia.umd,
    mediaWidthMm: 64,
    mediaHeightMm: 65,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.035, 0.02, 0.965, 0.98),
    cornerMm: 3.5,
    shellColor: Color(0xFF15161A),
  ),
  'genesis': BoxSpec(
    id: 'genesis',
    widthMm: 133,
    heightMm: 187,
    depthMm: 23,
    material: BoxMaterial.plastic,
    media: BoxMedia.cartridge,
    mediaWidthMm: 109,
    mediaHeightMm: 81,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.04, 0.025, 0.96, 0.975),
    cornerMm: 2,
    shellColor: Color(0xFF101012),
  ),
  'saturn': BoxSpec(
    id: 'saturn',
    widthMm: 140,
    heightMm: 195,
    depthMm: 14,
    material: BoxMaterial.plastic,
    media: BoxMedia.disc,
    mediaWidthMm: 120,
    mediaHeightMm: 120,
    hinge: BoxHinge.left,
    label: Rect.fromLTRB(0.03, 0.02, 0.97, 0.98),
    cornerMm: 2,
    shellColor: Color(0xFF15161A),
    rotatable: true,
  ),
  'pico8': BoxSpec(
    id: 'pico8',
    widthMm: 86,
    heightMm: 98,
    depthMm: 12,
    material: BoxMaterial.cart,
    media: BoxMedia.none,
    mediaWidthMm: 0,
    mediaHeightMm: 0,
    hinge: BoxHinge.none,
    // The square label art sits in the top of the cart; grip ridges below.
    label: Rect.fromLTRB(0.12, 0.08, 0.88, 0.72),
    cornerMm: 5,
    shellColor: Color(0xFF2B2B33),
  ),
};

/// Anything else: a generic keep case.
const genericBoxSpec = BoxSpec(
  id: 'generic',
  widthMm: 135,
  heightMm: 190,
  depthMm: 14,
  material: BoxMaterial.plastic,
  media: BoxMedia.disc,
  mediaWidthMm: 120,
  mediaHeightMm: 120,
  hinge: BoxHinge.left,
  label: Rect.fromLTRB(0.03, 0.02, 0.97, 0.98),
  cornerMm: 3,
  shellColor: Color(0xFF202024),
);

/// The box for a game of [system] (a `GameSystem.id`).
BoxSpec boxSpecFor(String system) => boxSpecs[system] ?? genericBoxSpec;
