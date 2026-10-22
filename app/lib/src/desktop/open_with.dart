// SPDX-License-Identifier: GPL-3.0-or-later
// Games opened from outside the app on Windows and desktop Linux: "Open
// with", a double-click, the Flatpak's file handler or a path argument.
// Spec: docs/specs/open-with.md
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../library/database.dart';
import '../library/importer.dart';

/// The game file a launch names: the first argument that is not a flag.
/// `file://` URIs (some file managers) become paths.
String? gameArgument(List<String> args) {
  for (final a in args) {
    if (a.isEmpty || a.startsWith('-')) continue;
    if (a.startsWith('file:')) {
      try {
        return Uri.parse(a).toFilePath();
      } on Object {
        continue;
      }
    }
    return a;
  }
  return null;
}

/// Files to open, oldest first: the launch argument, then each file a
/// second launch hands over through the runners' `dena/window` channel
/// (`openFile`). Listeners hear about every new file.
class OpenedFiles extends ChangeNotifier {
  OpenedFiles({
    String? initial,
    MethodChannel? channel = const MethodChannel('dena/window'),
  }) {
    if (initial != null) _queue.add(initial);
    channel?.setMethodCallHandler((call) async {
      if (call.method == 'openFile' && call.arguments is String) {
        add(call.arguments as String);
      }
    });
  }

  final _queue = <String>[];

  void add(String path) {
    _queue.add(path);
    notifyListeners();
  }

  /// The next file to open, or null.
  String? take() => _queue.isEmpty ? null : _queue.removeAt(0);
}

sealed class OpenResult {
  const OpenResult();
}

class OpenedGame extends OpenResult {
  const OpenedGame(this.game);
  final Game game;
}

class OpenFailed extends OpenResult {
  const OpenFailed(this.message);
  final String message;
}

/// The library game for [path], added in place when the library doesn't
/// have it yet (only that file, not its folder). A copy of a game already
/// in the library opens that game.
Future<OpenResult> openGameFile(
  String path, {
  required LibraryDatabase db,
  required Importer importer,
}) async {
  final file = File(p.normalize(p.absolute(path)));
  final name = p.basename(file.path);
  if (!await file.exists()) return OpenFailed('Could not find $name');
  if (await _byPath(db, file.path) case final g?) return OpenedGame(g);
  switch (await importer.importInPlace(file)) {
    case Imported(:final gameId):
      if (await db.gameById(gameId) case final g?) return OpenedGame(g);
    case Duplicate(:final gameId):
      // A folder scan added it meanwhile, or the same game lies elsewhere.
      if (await _byPath(db, file.path) case final g?) return OpenedGame(g);
      if (gameId != null) {
        if (await db.gameById(gameId) case final g?) return OpenedGame(g);
      }
      final sha = await _sha1Of(file);
      if (sha != null) {
        if (await db.gameBySha1(sha) case final g?) return OpenedGame(g);
      }
    case Rejected(:final reason):
      return OpenFailed('$name: $reason');
  }
  return OpenFailed('Could not add $name to the library');
}

Future<Game?> _byPath(LibraryDatabase db, String path) async {
  for (final g in await db.allGames()) {
    if (p.equals(g.path, path)) return g;
  }
  return null;
}

/// The SHA-1 the library keys [file] by: the unzipped ROM for a zip, else
/// the file itself (importer.dart).
Future<String?> _sha1Of(File file) async {
  try {
    if (p.extension(file.path).toLowerCase() == '.zip') {
      final rom = await prepare(file);
      return rom is PreparedRom ? rom.sha1 : null;
    }
    return (await sha1.bind(file.openRead()).first).toString();
  } on FileSystemException {
    return null;
  }
}
