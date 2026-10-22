// SPDX-License-Identifier: GPL-3.0-or-later
// Per-system accent colours for placeholders, chips and badges.
// Spec: docs/specs/ui-look-and-feel.md
import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';

/// A generic hue per system (no console branding), nudged towards the app's
/// primary colour so it sits well with any dynamic palette.
const _systemSeeds = <String, Color>{
  'nes': Color(0xFFC6423B),
  'snes': Color(0xFF9A4A9E),
  'gb': Color(0xFF7C9A3A),
  'gbc': Color(0xFF2E9C8C),
  'gba': Color(0xFF4459C9),
  'nds': Color(0xFF5E7A8C),
  'psx': Color(0xFF8A8F99),
  'n64': Color(0xFF2F8F4E),
  'psp': Color(0xFF3A6FB0),
  'saturn': Color(0xFF5B5F73),
  'dreamcast': Color(0xFFD9822B),
  'gamecube': Color(0xFF5A4FA3),
  'wii': Color(0xFF9AA3AD),
  'ps2': Color(0xFF2B3A8F),
  'pico8': Color(0xFFE0457B),
  'genesis': Color(0xFF3B4A6B),
};

final _cache = <(String, Color, Brightness), ColorScheme>{};

/// A tonal scheme for [system] that matches [scheme]'s brightness: use its
/// primaryContainer / onPrimaryContainer for placeholders and badges.
ColorScheme systemScheme(String system, ColorScheme scheme) {
  final key = (system, scheme.primary, scheme.brightness);
  return _cache.putIfAbsent(key, () {
    final seed = (_systemSeeds[system] ?? scheme.primary).harmonizeWith(
      scheme.primary,
    );
    return ColorScheme.fromSeed(seedColor: seed, brightness: scheme.brightness);
  });
}
