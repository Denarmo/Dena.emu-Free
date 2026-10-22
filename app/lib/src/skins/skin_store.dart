// SPDX-License-Identifier: GPL-3.0-or-later
// Installed `.deltaskin` files and the active skin per system.
// Spec: docs/specs/skins.md (8b)
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'deltaskin.dart';

/// Rasterises page 1 of a PDF to a PNG of the given pixel size; returns the
/// PNG path or null. The Android shell does this with `PdfRenderer`.
typedef PdfRasterizer = Future<String?> Function(
  String pdf,
  int width,
  int height,
  String outPng,
);

/// Console-style skins shipped in `assets/skins` (skins.md, 8c), with the
/// systems each one is the default for. Alternate editions (other colours
/// and plastics of the same console) are installed but default for none.
const bundledSkins = {
  'nes': ['nes'],
  'snes': ['snes'],
  'gb': ['gb'],
  'gbc': ['gbc'],
  'gba': ['gba'],
  'n64': ['n64'],
  'nds': ['nds'],
  'psx': ['psx'],
  'psp': ['psp'],
  'pico8': ['pico8'],
  'nes_cream': <String>[],
  'snes_lavender': <String>[],
  'gb_clear': <String>[],
  'gb_sunshine': <String>[],
  'gbc_teal': <String>[],
  'gbc_berry': <String>[],
  'gbc_dandelion': <String>[],
  'gba_glacier': <String>[],
  'gba_fuchsia': <String>[],
  'n64_smoke': <String>[],
  'n64_jungle': <String>[],
  'nds_polar': <String>[],
  'nds_ice': <String>[],
  'psx_midnight': <String>[],
  'psp_blue': <String>[],
  'psp_white': <String>[],
  'psp_red': <String>[],
};

/// Bump when the bundled artwork changes, so installs pick up the new files.
const bundledSkinsVersion = 6;

/// Reads an app asset (`rootBundle` in the app, files in tests).
typedef AssetLoader = Future<List<int>> Function(String asset);

class InstalledSkin {
  InstalledSkin(this.skin, this.dir);

  final DeltaSkin skin;
  final Directory dir;

  /// Shipped with the app: can't be deleted, only switched off.
  bool get bundled => skin.identifier.startsWith('com.denaemu.skins.');

  String file(String name) => p.join(dir.path, name);
}

/// Skins live in `<dataDir>/skins/<id>/` (extracted), with `index.json`
/// holding the active skin id per system.
class SkinStore {
  SkinStore(this.dataDir, {this.rasterize});

  final String dataDir;
  final PdfRasterizer? rasterize;

  Directory get _root => Directory(p.join(dataDir, 'skins'));
  File get _index => File(p.join(_root.path, 'index.json'));

  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// Installs [file]; replaces an installed skin with the same identifier.
  Future<InstalledSkin> install(File file) async =>
      installBytes(await file.readAsBytes());

  /// Installs the bundled skins when this install hasn't got the current
  /// [bundledSkinsVersion]. The first time, each becomes the active skin for
  /// its systems unless the user already chose one; later versions only
  /// refresh the files and leave the choices alone.
  Future<void> installBundled(AssetLoader load) async {
    final index = await _readIndex();
    final seen = index['bundled'];
    if (seen == bundledSkinsVersion) return;
    final active = _activeOf(index);
    for (final MapEntry(key: name, value: systems) in bundledSkins.entries) {
      final s = await installBytes(await load('assets/skins/$name.deltaskin'));
      if (seen == null) {
        for (final sys in systems) {
          active.putIfAbsent(sys, () => s.skin.identifier);
        }
      }
    }
    await _writeIndex(active, bundled: bundledSkinsVersion);
  }

  /// Installs a skin archive; replaces one with the same identifier.
  Future<InstalledSkin> installBytes(List<int> bytes) async {
    final (:skin, :archive) = readDeltaSkin(bytes);
    final dir = Directory(p.join(_root.path, _safe(skin.identifier)));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    // Files are flattened to their base names, as info.json refers to them.
    for (final f in archive.files.where((f) => f.isFile)) {
      final name = p.basename(f.name);
      if (name.isEmpty || name.startsWith('.')) continue;
      await File(p.join(dir.path, name)).writeAsBytes(f.content as List<int>);
    }
    return InstalledSkin(skin, dir);
  }

  Future<List<InstalledSkin>> list() async {
    if (!await _root.exists()) return [];
    final out = <InstalledSkin>[];
    await for (final d in _root.list()) {
      if (d is! Directory) continue;
      final info = File(p.join(d.path, 'info.json'));
      if (!await info.exists()) continue;
      try {
        out.add(
          InstalledSkin(
            parseDeltaSkinInfo(jsonDecode(await info.readAsString())),
            d,
          ),
        );
      } on Object {
        // A damaged install is skipped, not fatal.
      }
    }
    out.sort((a, b) => a.skin.name.compareTo(b.skin.name));
    return out;
  }

  /// Active skin id per system (systems using the built-in skin are absent).
  Future<Map<String, String>> activeIds() => _active();

  Future<Map<String, String>> _active() async => _activeOf(await _readIndex());

  Future<Map> _readIndex() async {
    if (!await _index.exists()) return {};
    try {
      return jsonDecode(await _index.readAsString()) as Map;
    } on Object {
      return {};
    }
  }

  static Map<String, String> _activeOf(Map index) => {
    for (final e in ((index['active'] as Map?) ?? {}).entries)
      '${e.key}': '${e.value}',
  };

  /// Writes the active ids, keeping the bundled-skins version.
  Future<void> _writeIndex(Map<String, String> active, {int? bundled}) async {
    bundled ??= (await _readIndex())['bundled'] as int?;
    await _root.create(recursive: true);
    await _index.writeAsString(
      jsonEncode({'active': active, 'bundled': ?bundled}),
    );
  }

  /// The active imported skin for [system], or null for the built-in one.
  Future<InstalledSkin?> active(String system) async {
    final id = (await _active())[system];
    if (id == null) return null;
    for (final s in await list()) {
      if (s.skin.identifier == id) return s;
    }
    return null;
  }

  Future<void> setActive(String system, String? identifier) async {
    final a = await _active();
    if (identifier == null) {
      a.remove(system);
    } else {
      a[system] = identifier;
    }
    await _writeIndex(a);
  }

  Future<void> delete(InstalledSkin s) async {
    if (await s.dir.exists()) await s.dir.delete(recursive: true);
    final a = await _active();
    a.removeWhere((_, id) => id == s.skin.identifier);
    await _writeIndex(a);
  }

  /// The artwork file for [rep] at [width]×[height] pixels: a PNG asset, or
  /// the PDF rasterised (and cached). Null when none can be produced.
  Future<File?> artwork(
    InstalledSkin s,
    DeltaRepresentation rep,
    int width,
    int height,
  ) async {
    final pdf = rep.pdf;
    if (pdf != null && rasterize != null) {
      final out = File(
        p.join(
          s.dir.path,
          'cache',
          '${p.basenameWithoutExtension(pdf)}_${width}x$height.png',
        ),
      );
      if (await out.exists()) return out;
      await out.parent.create(recursive: true);
      final path = await rasterize!(s.file(pdf), width, height, out.path);
      if (path != null) return File(path);
    }
    final png = rep.bestPng;
    if (png == null) return null;
    final f = File(s.file(png));
    return await f.exists() ? f : null;
  }
}
