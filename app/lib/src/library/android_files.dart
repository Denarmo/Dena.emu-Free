// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dena_android/dena_android.dart';

import 'database.dart';
import 'library_scope.dart';

/// [GameFileSource] backed by the Android shell's SAF picker, with All files
/// access for the in-app explorer.
class AndroidGameFiles implements GameFileSource, StorageAccess {
  AndroidGameFiles([LibraryHostApi? api]) : _api = api ?? LibraryHostApi();

  final LibraryHostApi _api;

  @override
  bool get hasPicker => true;

  @override
  Future<List<String>> pickFiles() => _api.pickFiles();

  @override
  Future<List<String>> pickFolder(List<String> extensions) =>
      _api.pickFolder(extensions);

  @override
  Future<bool> hasStorageAccess() => _api.hasStorageAccess();

  @override
  Future<bool> requestStorageAccess() => _api.requestStorageAccess();

  @override
  Future<List<String>> takeSharedFiles() => _api.takeSharedFiles();

  @override
  Future<void> clearCache() => _api.clearImportCache();
}

/// [GameLinks] backed by the Android shell's ShortcutManager (shortcuts.md).
class AndroidGameLinks implements GameLinks {
  AndroidGameLinks([LibraryHostApi? api]) : _api = api ?? LibraryHostApi();

  final LibraryHostApi _api;

  @override
  Future<String?> takeLaunchLink() => _api.takeLaunchLink();

  @override
  Future<bool> pin(Game game, String? iconPath) =>
      _api.pinShortcut(game.sha1, game.title, iconPath);

  @override
  Future<void> reportPlayed(Game game, String? iconPath) =>
      _api.reportPlayed(game.sha1, game.title, iconPath);

  @override
  Future<void> remove(String sha1) => _api.removeShortcut(sha1);
}
