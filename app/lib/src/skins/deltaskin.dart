// SPDX-License-Identifier: GPL-3.0-or-later
// `.deltaskin` reading, written from the public format description only.
// Spec: docs/specs/skins.md (8b). Provenance: docs/provenance.md.
import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';

import 'skin_layout.dart';

/// `gameTypeIdentifier` suffixes to our system ids.
const _gameTypes = {
  'nes': 'nes',
  'snes': 'snes',
  'gbc': 'gbc',
  'gba': 'gba',
  'ds': 'nds',
  'n64': 'n64',
  'genesis': 'genesis',
  // Beyond Delta's systems; our bundled skins use `com.denaemu.game.<id>`.
  'psx': 'psx',
  'psp': 'psp',
  'pico8': 'pico8',
};

/// Per-system input names in skins to our RetroPad names, matching the
/// built-in skins (n64.md: A is RetroPad B, B is Y, Z is L2, C is the right
/// stick).
const _inputRenames = {
  'n64': {
    'a': 'b',
    'b': 'y',
    'z': 'l2',
    'cUp': 'cup',
    'cDown': 'cdown',
    'cLeft': 'cleft',
    'cRight': 'cright',
  },
};

/// Systems a skin with this game type can be used for.
List<String> skinSystems(String gameType) => switch (gameType) {
  'gbc' => const ['gb', 'gbc'],
  final t => [t],
};

class SkinFormatException implements Exception {
  SkinFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One orientation of one display type: artwork, items and screens.
class DeltaRepresentation {
  DeltaRepresentation({
    required this.layout,
    required this.pdf,
    required this.pngs,
  });

  final SkinLayout layout;

  /// The `resizable` PDF asset, if any.
  final String? pdf;

  /// PNG assets by size tier (`small`, `medium`, `large`).
  final Map<String, String> pngs;

  /// The PNG to use when there is no PDF: the largest available.
  String? get bestPng => pngs['large'] ?? pngs['medium'] ?? pngs['small'];
}

class DeltaSkin {
  DeltaSkin({
    required this.name,
    required this.identifier,
    required this.gameType,
    required this.representations,
    required this.debug,
  });

  final String name;
  final String identifier;

  /// Our system id from `gameTypeIdentifier` (`gbc` covers gb and gbc).
  final String gameType;
  final bool debug;

  /// device → display type → orientation.
  final Map<String, Map<String, Map<String, DeltaRepresentation>>>
  representations;

  /// Picks a representation for a screen of [size] (skins.md, Selection).
  DeltaRepresentation? pick(Size size, {required bool tablet}) {
    final landscape = size.width > size.height;
    final orientations = landscape
        ? const ['landscape', 'portrait']
        : const ['portrait', 'landscape'];
    final tall =
        math.max(size.width, size.height) / math.min(size.width, size.height) >
        2.0;
    final devices = tablet
        ? const ['ipad', 'iphone']
        : const ['iphone', 'ipad'];
    for (final o in orientations) {
      for (final device in devices) {
        final displays = representations[device];
        if (displays == null) continue;
        final order = device == 'iphone'
            ? (tall
                  ? const ['edgeToEdge', 'standard']
                  : const ['standard', 'edgeToEdge'])
            : const ['standard', 'splitView'];
        for (final display in order) {
          final rep = displays[display]?[o];
          if (rep != null) return rep;
        }
      }
    }
    return null;
  }
}

/// Reads a `.deltaskin` (zip) and returns the skin and its files.
({DeltaSkin skin, Archive archive}) readDeltaSkin(List<int> bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw SkinFormatException('This file is not a skin archive');
  }
  final info = archive.files.where(
    (f) => f.isFile && f.name.split('/').last == 'info.json',
  );
  if (info.isEmpty) throw SkinFormatException('The skin has no info.json');
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(info.first.content as List<int>));
  } on FormatException {
    throw SkinFormatException("The skin's info.json is not valid JSON");
  }
  return (skin: parseDeltaSkinInfo(json), archive: archive);
}

/// Parses a decoded `info.json`.
DeltaSkin parseDeltaSkinInfo(Object? json) {
  if (json is! Map) throw SkinFormatException('info.json is not an object');
  final type = (json['gameTypeIdentifier'] as String? ?? '').split('.').last;
  final system = _gameTypes[type];
  if (system == null) {
    throw SkinFormatException('Unsupported system "$type"');
  }
  final reps = <String, Map<String, Map<String, DeltaRepresentation>>>{};
  final raw = json['representations'];
  if (raw is Map) {
    for (final MapEntry(key: device, value: displays) in raw.entries) {
      if (displays is! Map) continue;
      for (final MapEntry(key: display, value: orients) in displays.entries) {
        if (orients is! Map) continue;
        for (final MapEntry(key: orientation, value: rep) in orients.entries) {
          if (rep is! Map) continue;
          final parsed = _representation(
            rep,
            _inputRenames[system] ?? const {},
          );
          if (parsed == null) continue;
          reps
                  .putIfAbsent('$device', () => {})
                  .putIfAbsent('$display', () => {})['$orientation'] =
              parsed;
        }
      }
    }
  }
  if (reps.isEmpty) throw SkinFormatException('The skin has no layouts');
  return DeltaSkin(
    name: json['name'] as String? ?? 'Skin',
    identifier: json['identifier'] as String? ?? 'skin.${json.hashCode}',
    gameType: system,
    representations: reps,
    debug: json['debug'] == true,
  );
}

Rect? _rect(Object? v) {
  if (v is! Map) return null;
  double n(String k) => (v[k] as num?)?.toDouble() ?? 0;
  return Rect.fromLTWH(n('x'), n('y'), n('width'), n('height'));
}

EdgeInsets _edges(Object? v, EdgeInsets fallback) {
  if (v is! Map) return fallback;
  double n(String k) => (v[k] as num?)?.toDouble() ?? 0;
  return EdgeInsets.fromLTRB(n('left'), n('top'), n('right'), n('bottom'));
}

DeltaRepresentation? _representation(Map rep, Map<String, String> renames) {
  final size = rep['mappingSize'];
  if (size is! Map) return null;
  final mapping = Size(
    (size['width'] as num?)?.toDouble() ?? 0,
    (size['height'] as num?)?.toDouble() ?? 0,
  );
  if (mapping.isEmpty) return null;
  final edges = _edges(rep['extendedEdges'], EdgeInsets.zero);
  final items = <SkinItem>[];
  for (final item in (rep['items'] as List?) ?? const []) {
    if (item is! Map) continue;
    final frame = _rect(item['frame']);
    if (frame == null) continue;
    final itemEdges = _edges(item['extendedEdges'], edges);
    final inputs = item['inputs'];
    if (inputs is Map && item['thumbstick'] is Map) {
      // An analog stick: the item's frame is its travel area.
      items.add(
        SkinItem(
          kind: SkinItemKind.thumbstick,
          frame: frame,
          inputs: const ['leftstick'],
          extended: itemEdges,
        ),
      );
    } else if (inputs is Map) {
      // dpad: a direction per edge.
      items.add(
        SkinItem(kind: SkinItemKind.dpad, frame: frame, extended: itemEdges),
      );
    } else if (inputs is List) {
      final names = [
        for (final n in inputs.whereType<String>()) renames[n] ?? n,
      ];
      items.add(
        SkinItem(
          kind: names.contains('menu')
              ? SkinItemKind.menu
              : SkinItemKind.button,
          frame: frame,
          inputs: names,
          extended: itemEdges,
        ),
      );
    }
  }
  Rect? screen;
  final screens = rep['screens'];
  if (screens is List && screens.isNotEmpty && screens.first is Map) {
    screen = _rect((screens.first as Map)['outputFrame']);
  }
  final assets = rep['assets'];
  final pngs = <String, String>{};
  String? pdf;
  if (assets is Map) {
    pdf = assets['resizable'] as String?;
    for (final tier in const ['small', 'medium', 'large']) {
      final f = assets[tier];
      if (f is String) pngs[tier] = f;
    }
  }
  return DeltaRepresentation(
    layout: SkinLayout(
      mappingSize: mapping,
      items: items,
      // No screens entry: the game fills the top of the skin at width.
      screen:
          screen ?? Rect.fromLTWH(0, 0, mapping.width, mapping.width * 3 / 4),
      translucent: rep['translucent'] == true,
    ),
    pdf: pdf,
    pngs: pngs,
  );
}
