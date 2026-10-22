// SPDX-License-Identifier: GPL-3.0-or-later
// The bundled Dena Explore launcher cart: install and its session's game row.
// Spec: docs/specs/pico8-launcher-cart.md (Starting it)
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path/path.dart' as p;

import '../library/database.dart';

/// Asset key of our own launcher cart.
const launcherAsset = 'assets/carts/dena-explore.p8';

/// Copies the bundled cart to `<dataDir>/carts/dena-explore.p8`, rewriting
/// it only when the bundled one changed. Returns the file.
Future<File> installLauncher(String dataDir, {AssetBundle? bundle}) async {
  final data = await (bundle ?? rootBundle).load(launcherAsset);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final file = File(p.join(dataDir, 'carts', 'dena-explore.p8'));
  if (await file.exists() && listEquals(await file.readAsBytes(), bytes)) {
    return file;
  }
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// The launcher's session game: not a library row (id -1), never recorded.
Game launcherGame(String path) => Game(
  id: -1,
  system: 'pico8',
  title: 'Dena Explore',
  searchTitle: 'dena explore',
  fileName: 'dena-explore.p8',
  path: path,
  sha1: 'dena-explore',
  size: 0,
  crc32: '',
  addedAt: DateTime.utc(2026),
  playSeconds: 0,
  favorite: false,
);

/// Whether [game] is the launcher rather than a library game.
bool isLauncher(Game game) => game.id < 0;
