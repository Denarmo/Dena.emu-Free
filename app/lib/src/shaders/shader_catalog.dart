// SPDX-License-Identifier: GPL-3.0-or-later
// The bundled shaders the app offers, by id: phones and the handheld
// (`host/shaders/<id>/<id>.glslp`) and the desktop
// (`host/slang-shaders/<id>.slangp`).
// Spec: docs/specs/shaders.md, docs/specs/shader-stacks.md
import 'shader_store.dart' show desktopResolution;

class ShaderInfo {
  const ShaderInfo(
    this.id,
    this.name,
    this.description,
    this.suggestedFor, {
    this.passes = 1,
  });

  /// Folder and preset name under `host/shaders`; what `setShader` takes.
  final String id;
  final String name;

  /// One line saying what it looks like.
  final String description;

  /// System ids this shader suits (empty: any system).
  final Set<String> suggestedFor;

  /// Shader passes (desktop stacks); the sheet notes stacks of more than one.
  final int passes;

  bool suits(String system) =>
      suggestedFor.isEmpty || suggestedFor.contains(system);
}

/// In the order the spec lists them (shaders.md, Bundled shaders).
const shaderCatalog = [
  ShaderInfo(
    'sharp-bilinear',
    'Sharp pixels',
    'Crisp pixels at any scale, without shimmer',
    {},
  ),
  ShaderInfo('scanlines', 'Scanlines', 'Dark lines between pixel rows', {
    'nes',
    'snes',
    'psx',
    'n64',
  }),
  ShaderInfo('crt-fast', 'CRT (fast)', 'Light CRT look for slower devices', {
    'nes',
    'snes',
    'psx',
    'n64',
    'pico8',
  }),
  ShaderInfo('crt-lottes', 'CRT (Lottes)', 'Shadow mask and soft scanlines', {
    'nes',
    'snes',
    'psx',
  }),
  ShaderInfo('crt-easymode', 'CRT (EasyMode)', 'Flat CRT with a fine mask', {
    'nes',
    'snes',
    'psx',
  }),
  ShaderInfo(
    'crt-aperture',
    'CRT (aperture grille)',
    'Vertical stripe mask with glow',
    {'nes', 'snes', 'psx'},
  ),
  ShaderInfo('crt-geom', 'CRT (curved)', 'Curved glass and rounded corners', {
    'nes',
    'snes',
    'psx',
    'n64',
  }),
  ShaderInfo(
    'crt-bloom',
    'CRT (bloom)',
    'Curved CRT with glow and a refresh sweep',
    {'nes', 'snes', 'psx', 'n64'},
  ),
  ShaderInfo(
    'lcd-grid',
    'LCD grid',
    'Thin gaps between pixels, like a handheld screen',
    {'gb', 'gbc', 'gba', 'nds', 'psp'},
  ),
  ShaderInfo('lcd3x', 'LCD subpixels', 'Red, green and blue subpixel stripes', {
    'gb',
    'gbc',
    'gba',
  }),
  ShaderInfo(
    'dot-matrix',
    'Dot matrix',
    'Round dots of an early handheld screen',
    {'gb', 'gbc'},
  ),
];

const _crt = {
  'nes',
  'snes',
  'psx',
  'n64',
  'saturn',
  'dreamcast',
  'ps2',
  'gamecube',
  'wii',
};

/// The desktop's slang presets (shader-stacks.md, Bundled presets). Same ids as phones where the look is the same.
const desktopShaderCatalog = [
  ShaderInfo(
    'sharp-bilinear',
    'Sharp pixels',
    'Crisp pixels at any scale, without shimmer',
    {},
  ),
  ShaderInfo('scanlines', 'Scanlines', 'Dark lines between pixel rows', {
    'nes',
    'snes',
    'psx',
    'n64',
  }),
  ShaderInfo('crt-fast', 'CRT (fast)', 'Light CRT look', {
    'nes',
    'snes',
    'psx',
    'n64',
    'pico8',
  }),
  ShaderInfo('crt-lottes', 'CRT (Lottes)', 'Shadow mask and soft scanlines', {
    'nes',
    'snes',
    'psx',
  }),
  ShaderInfo('crt-easymode', 'CRT (EasyMode)', 'Flat CRT with a fine mask', {
    'nes',
    'snes',
    'psx',
  }),
  ShaderInfo(
    'crt-aperture',
    'CRT (aperture grille)',
    'Vertical stripe mask with glow',
    {'nes', 'snes', 'psx'},
  ),
  ShaderInfo('crt-geom', 'CRT (curved)', 'Curved glass and rounded corners', {
    'nes',
    'snes',
    'psx',
    'n64',
  }),
  ShaderInfo(
    'crt-royale',
    'CRT-Royale',
    'Phosphor mask, bloom and curvature, best at 4K',
    _crt,
    passes: 12,
  ),
  ShaderInfo(
    'crt-guest-advanced',
    'CRT (Guest advanced)',
    'Sharp CRT with mask and glow, best at 4K',
    _crt,
    passes: 12,
  ),
  ShaderInfo('gtu', 'NTSC TV (GTU)', 'Composite signal blur and colour bleed', {
    'nes',
    'snes',
    'psx',
    'n64',
    'saturn',
  }, passes: 3),
  ShaderInfo(
    'lcd-grid',
    'LCD grid',
    'Thin gaps between pixels, like a handheld screen',
    {'gb', 'gbc', 'gba', 'nds', 'psp'},
  ),
  ShaderInfo('lcd3x', 'LCD subpixels', 'Red, green and blue subpixel stripes', {
    'gb',
    'gbc',
    'gba',
  }),
  ShaderInfo(
    'dot-matrix',
    'Dot matrix',
    'Round dots of an early handheld screen',
    {'gb', 'gbc'},
  ),
];

/// The catalog of this build: the desktop's slang presets, else the phone's.
List<ShaderInfo> shaderCatalogFor({bool? desktop}) =>
    (desktop ?? desktopResolution) ? desktopShaderCatalog : shaderCatalog;

/// The shader with [id], or null (also for "" = Off).
ShaderInfo? shaderById(String id, {bool? desktop}) {
  for (final s in shaderCatalogFor(desktop: desktop)) {
    if (s.id == id) return s;
  }
  return null;
}

/// Display name of [id]; "Off" for "" or an unknown id.
String shaderName(String id, {bool? desktop}) =>
    shaderById(id, desktop: desktop)?.name ?? 'Off';

/// The catalog with the shaders suggested for [system] first; the catalogue
/// order is kept within each group.
List<({ShaderInfo shader, bool suggested})> shadersFor(
  String system, {
  bool? desktop,
}) {
  final all = shaderCatalogFor(desktop: desktop);
  return [
    for (final s in all)
      if (s.suits(system)) (shader: s, suggested: true),
    for (final s in all)
      if (!s.suits(system)) (shader: s, suggested: false),
  ];
}
