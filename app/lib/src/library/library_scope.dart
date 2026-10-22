// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../achievements/retro_achievements.dart';
import '../shaders/shader_store.dart';
import '../skins/skin_store.dart';
import 'box_art.dart';
import 'database.dart';
import 'game_folders.dart';
import 'importer.dart';
import 'media_art.dart';

/// Where picked files come from. The app uses the Android shell's SAF picker;
/// tests use a fake. Without a system picker (the handheld) the library opens
/// the in-app explorer instead (file_explorer.dart).
abstract interface class GameFileSource {
  /// Whether [pickFiles] and [pickFolder] open a system picker. False on the
  /// handheld, where Add games and Add a folder use the in-app explorer.
  bool get hasPicker;

  /// Picked files, already readable as local paths (empty if cancelled).
  Future<List<String>> pickFiles();

  /// Every file under a picked folder whose name ends with one of [extensions].
  Future<List<String>> pickFolder(List<String> extensions);

  /// Files shared to the app since the last call.
  Future<List<String>> takeSharedFiles();

  /// Removes the temporary copies the calls above made.
  Future<void> clearCache();
}

/// A [GameFileSource] that can also read shared storage directly once the
/// user allows it (Android's All files access). Add games and Add a folder
/// then open the in-app explorer, with the system picker as the fallback:
/// some phones' pickers show game folders as empty (file-explorer.md).
abstract interface class StorageAccess {
  /// Whether the explorer can read shared storage now.
  Future<bool> hasStorageAccess();

  /// Asks Android for the access; whether it was granted.
  Future<bool> requestStorageAccess();
}

/// Deep links and launcher shortcuts (docs/specs/shortcuts.md). The app uses
/// the Android shell; tests use a fake.
abstract interface class GameLinks {
  /// The SHA-1 of a `dena://play/<sha1>` link the app was opened with since
  /// the last call, or null.
  Future<String?> takeLaunchLink();

  /// Pins a home-screen shortcut; false when the launcher can't.
  Future<bool> pin(Game game, String? iconPath);

  /// Makes [game] the first recent-game shortcut.
  Future<void> reportPlayed(Game game, String? iconPath);

  /// Removes or disables the shortcuts of a deleted game.
  Future<void> remove(String sha1);
}

/// The image a shortcut shows for [game]: its custom art or cached cover.
Future<String?> shortcutIcon(LibraryScope scope, Game game) async {
  try {
    return (await scope.art?.coverFor(game))?.path;
  } on Object {
    return null;
  }
}

/// Extensions the folder import looks for (docs/specs/library.md, Import).
const importExtensions = [
  '.nes',
  '.sfc',
  '.smc',
  '.gb',
  '.gbc',
  '.gba',
  '.nds',
  '.z64',
  '.n64',
  '.v64',
  '.chd',
  '.cue',
  '.cdi',
  '.gdi',
  '.iso',
  '.cso',
  '.pbp',
  '.gcm',
  '.rvz',
  '.wia',
  '.gcz',
  '.wbfs',
  '.ciso',
  '.dol',
  '.elf',
  '.p8',
  '.p8.png',
  '.md',
  '.gen',
  '.smd',
  '.bin',
  '.zip',
];

/// Gives screens access to the library database, the importer and file picking.
class LibraryScope extends InheritedWidget {
  const LibraryScope({
    super.key,
    required this.db,
    required this.importer,
    required this.files,
    this.skins,
    this.shaders,
    this.art,
    this.media,
    this.links,
    this.achievements,
    this.folders,
    required super.child,
  });

  final LibraryDatabase db;
  final Importer importer;
  final GameFileSource files;

  /// Imported skins (skins.md); null in tests that don't need them.
  final SkinStore? skins;

  /// Shader choices (shaders.md); the session reads its data dir when null.
  final ShaderStore? shaders;

  /// Box art (box-art.md); placeholders only when null.
  final BoxArtCache? art;

  /// Cartridge labels and disc faces (launch-animation.md); covers stand in
  /// when null.
  final MediaArtCache? media;

  /// Shortcuts and deep links (shortcuts.md); none when null.
  final GameLinks? links;

  /// RetroAchievements (achievements.md); hidden when null.
  final RetroAchievements? achievements;

  /// Watched game folders on a PC (desktop-library.md): games picked there
  /// join the library in place instead of being copied. Null elsewhere.
  final GameFolders? folders;

  static LibraryScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LibraryScope>();
    assert(scope != null, 'No LibraryScope above this widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(LibraryScope oldWidget) =>
      db != oldWidget.db ||
      importer != oldWidget.importer ||
      files != oldWidget.files ||
      skins != oldWidget.skins ||
      shaders != oldWidget.shaders ||
      art != oldWidget.art ||
      media != oldWidget.media ||
      links != oldWidget.links ||
      achievements != oldWidget.achievements ||
      folders != oldWidget.folders;
}

/// Summary of one import batch.
class ImportSummary {
  int added = 0, duplicates = 0;
  final rejected = <Rejected>[];
}

/// Imports [paths], reporting progress, then deletes the temporary copies.
/// Each new game's cover starts downloading as soon as it is added. On a PC
/// ([LibraryScope.folders]) the picked files are the user's own and join the
/// library in place.
Future<ImportSummary> importPaths(
  LibraryScope scope,
  List<String> paths, {
  void Function(int done, int total)? onProgress,
}) async {
  final summary = ImportSummary();
  var done = 0;
  paths = await withoutCueTracks(paths);
  for (final path in paths) {
    final file = File(path);
    // A zip of several discs adds each one.
    final outcomes = await scope.importer.importEach(
      file,
      inPlace: scope.folders != null,
    );
    for (final out in outcomes) {
      switch (out) {
        case Imported():
          summary.added++;
          // Fetch the cover now so it is ready when the grid shows the game.
          final game = await scope.db.gameById(out.gameId);
          if (game != null) {
            scope.art?.prefetch([game]);
            scope.media?.prefetch([game]);
          }
        case Duplicate():
          summary.duplicates++;
        case Rejected():
          summary.rejected.add(out);
      }
    }
    onProgress?.call(++done, paths.length);
  }
  await scope.files.clearCache();
  return summary;
}
