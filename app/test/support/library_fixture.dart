import 'package:dena_emu/src/desktop/open_with.dart';

import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/shaders/shader_store.dart';
import 'package:dena_emu/src/shell/app_shell.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';

/// [FakeFiles] that can also read storage directly, like the Android app
/// with All files access (file-explorer.md).
class FakeStorageFiles extends FakeFiles implements StorageAccess {
  bool granted = false;
  bool grantOnRequest = false;
  int requests = 0;

  @override
  Future<bool> hasStorageAccess() async => granted;

  @override
  Future<bool> requestStorageAccess() async {
    requests++;
    return granted = grantOnRequest;
  }
}

class FakeFiles implements GameFileSource {
  List<String> picked = [];
  List<String> shared = [];
  int clears = 0;
  @override
  bool hasPicker = true;

  /// Set to make the system picker fail, like Android without DocumentsUI.
  Object? pickError;

  @override
  Future<List<String>> pickFiles() async {
    if (pickError case final e?) throw e;
    return picked;
  }

  @override
  Future<List<String>> pickFolder(List<String> extensions) async {
    if (pickError case final e?) throw e;
    return picked;
  }

  @override
  Future<List<String>> takeSharedFiles() async {
    final s = shared;
    shared = [];
    return s;
  }

  @override
  Future<void> clearCache() async => clears++;
}

class FakeLinks implements GameLinks {
  String? pending;
  bool canPin = true;
  final pinned = <String>[];
  final removed = <String>[];

  @override
  Future<String?> takeLaunchLink() async {
    final s = pending;
    pending = null;
    return s;
  }

  @override
  Future<bool> pin(Game game, String? iconPath) async {
    if (canPin) pinned.add(game.sha1);
    return canPin;
  }

  @override
  Future<void> reportPlayed(Game game, String? iconPath) async {}

  @override
  Future<void> remove(String sha1) async => removed.add(sha1);
}

/// An in-memory library with [titles] (cycling through systems).
Future<LibraryDatabase> seededDb(List<String> titles) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final db = LibraryDatabase(NativeDatabase.memory());
  const systems = ['gba', 'snes', 'nes', 'gb'];
  for (var i = 0; i < titles.length; i++) {
    await db.addGame(
      system: systems[i % systems.length],
      title: titles[i],
      fileName: '${titles[i]}.rom',
      path: '/nowhere/$i',
      sha1: 'sha$i',
      size: 1,
      crc32: '0',
      addedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
    );
  }
  return db;
}

List<Game> played = [];

Widget shellApp(
  LibraryDatabase db, {
  FakeFiles? files,
  FakeLinks? links,
  Directory? gamesDir,
  ShaderStore? shaders,
  ThemeSettings? theme,
  OpenedFiles? opened,
}) => LibraryScope(
  db: db,
  links: links,
  shaders: shaders,
  importer: Importer(db, gamesDir ?? Directory.systemTemp),
  files: files ?? FakeFiles(),
  child: DenaApp(
    theme: theme,
    home: AppShell(onPlay: (context, game) => played.add(game), opened: opened),
  ),
);
