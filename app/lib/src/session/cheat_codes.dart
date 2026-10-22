// SPDX-License-Identifier: GPL-3.0-or-later
// Cheat code validation and normalisation. Spec: docs/specs/cheats.md
library;

/// A cheat that passed validation: its normalised lines and format label.
class ParsedCheat {
  const ParsedCheat(this.lines, this.format);

  final List<String> lines;
  final String format;

  /// Stored form: one code per line.
  String get stored => lines.join('\n');
}

class _Format {
  const _Format(this.label, this.pattern, this.normalise);

  final String label;
  final RegExp pattern;

  /// Turns a compact (no spaces or dashes, upper-case) line into its canonical
  /// spelling.
  final String Function(String compact) normalise;
}

String _same(String s) => s;

String _dashEvery(String s, int n) {
  final parts = <String>[];
  for (var i = 0; i < s.length; i += n) {
    parts.add(s.substring(i, i + n > s.length ? s.length : i + n));
  }
  return parts.join('-');
}

final _formats = <String, List<_Format>>{
  'nes': [
    _Format(
      'Game Genie',
      RegExp(r'^[APZLGITYEOXUKSVN]{6}([APZLGITYEOXUKSVN]{2})?$'),
      _same,
    ),
    _Format('Raw', RegExp(r'^[0-9A-F]{4}(\?[0-9A-F]{2})?:[0-9A-F]{2}$'), _same),
  ],
  'snes': [
    _Format('Game Genie', RegExp(r'^[0-9A-F]{8}$'), (s) => _dashEvery(s, 4)),
    _Format('Pro Action Replay', RegExp(r'^[0-9A-F]{8}$'), _same),
  ],
  'gb': _gbFormats,
  'gbc': _gbFormats,
  // CWCheat: `_L 0xAAAAAAAA 0xVVVVVVVV` (the `_L` is optional).
  'psp': [
    _Format('CWCheat', RegExp(r'^(_L)?0X[0-9A-F]{8}0X[0-9A-F]{8}$'), (s) {
      final hex = s.replaceFirst('_L', '');
      return '0x${hex.substring(2, 10)} 0x${hex.substring(12)}';
    }),
  ],
  'n64': [
    _Format(
      'GameShark',
      RegExp(r'^[0-9A-F]{12}$'),
      (s) => '${s.substring(0, 8)} ${s.substring(8)}',
    ),
  ],
  'psx': [
    _Format(
      'GameShark',
      RegExp(r'^[0-9A-F]{12}$'),
      (s) => '${s.substring(0, 8)} ${s.substring(8)}',
    ),
  ],
  'nds': [
    _Format(
      'Action Replay DS',
      RegExp(r'^[0-9A-F]{16}$'),
      (s) => '${s.substring(0, 8)} ${s.substring(8)}',
    ),
  ],
  'gba': [
    _Format(
      'GameShark / Action Replay',
      RegExp(r'^[0-9A-F]{16}$'),
      (s) => '${s.substring(0, 8)} ${s.substring(8)}',
    ),
    _Format(
      'CodeBreaker',
      RegExp(r'^[0-9A-F]{12}$'),
      (s) => '${s.substring(0, 8)} ${s.substring(8)}',
    ),
  ],
};

final _gbFormats = [
  _Format(
    'Game Genie',
    RegExp(r'^[0-9A-F]{6}([0-9A-F]{3})?$'),
    (s) => _dashEvery(s, 3),
  ),
  _Format('GameShark', RegExp(r'^[0-9A-F]{8}$'), _same),
];

/// Validates [input] (one code per line) for [system]. Returns null when any
/// line does not match a format of the system.
///
/// SNES Game Genie and Pro Action Replay codes both have 8 hex digits; a dash
/// in the input (`XXXX-XXXX`) marks Game Genie.
ParsedCheat? parseCheat(String system, String input) {
  final formats = _formats[system];
  if (formats == null) return null;
  final raw = input
      .split(RegExp(r'[\r\n+]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (raw.isEmpty) return null;
  final lines = <String>[];
  String? label;
  for (final line in raw) {
    final compact = line.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    final dashed = line.contains('-');
    _Format? match;
    for (final f in formats) {
      if (!f.pattern.hasMatch(compact)) continue;
      if (system == 'snes' && (f.label == 'Game Genie') != dashed) continue;
      match = f;
      break;
    }
    if (match == null) return null;
    lines.add(match.normalise(compact));
    label ??= match.label;
    if (label != match.label) label = 'Mixed';
  }
  return ParsedCheat(lines, label!);
}

/// Codes as the core wants them: one cheat's lines joined by '+'.
String coreCode(String stored) => stored.split('\n').join('+');

/// "NES", "SNES" etc. for messages.
String systemLabel(String system) => switch (system) {
  'nes' => 'NES',
  'snes' => 'SNES',
  'gb' => 'Game Boy',
  'gbc' => 'Game Boy Color',
  'gba' => 'Game Boy Advance',
  'nds' => 'DS',
  'psx' => 'PlayStation',
  'n64' => 'Nintendo 64',
  'psp' => 'PSP',
  'saturn' => 'Saturn',
  'dreamcast' => 'Dreamcast',
  'gamecube' => 'GameCube',
  'wii' => 'Wii',
  'ps2' => 'PlayStation 2',
  'pico8' => 'PICO-8',
  'genesis' => 'Genesis',
  _ => system,
};
