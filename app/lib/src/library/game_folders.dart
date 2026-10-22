// SPDX-License-Identifier: GPL-3.0-or-later
// Watched game folders on Windows and Linux PCs: games stay where they are
// and join the library in place; the folders are rescanned when they change.
// Spec: docs/specs/desktop-library.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'card_library.dart';
import 'database.dart';
import 'importer.dart';

/// Watches a folder tree and calls back on any change. Tests pass a fake.
typedef FolderWatcher = Stream<FileSystemEvent> Function(Directory dir);

/// The folders the desktop library is built from, kept in `folders.json` in
/// the data folder: `{"folders": [...], "ignored": [...]}`.
class GameFolders extends ChangeNotifier {
  GameFolders({
    required this.file,
    required this.db,
    required this.importer,
    this.fixed = const [],
    FolderWatcher? watcher,
    this.debounce = const Duration(seconds: 2),
  }) : _watcher = watcher ?? watchTree;

  final File file;
  final LibraryDatabase db;
  final Importer importer;

  /// Folders that are always scanned and can't be removed: the portable
  /// build's `Dena/Roms` (sd-card.md layout).
  final List<String> fixed;

  /// How long changes settle before a rescan.
  final Duration debounce;
  final FolderWatcher _watcher;

  final _folders = <String>[];
  final _ignored = <String>{};
  final _subs = <String, StreamSubscription<FileSystemEvent>>{};
  final _timers = <String, Timer>{};
  bool _watching = false;

  /// Whether a scan is running (Settings shows a spinner).
  bool get scanning => _running > 0;
  int _running = 0;

  /// The user's folders, in the order added.
  List<String> get folders => List.unmodifiable(_folders);

  /// [fixed] then [folders].
  List<String> get all => [...fixed, ..._folders];

  Future<void> load() async {
    try {
      final v = jsonDecode(await file.readAsString());
      if (v case {'folders': final List<Object?> f}) {
        _folders.addAll(f.whereType<String>());
      }
      if (v case {'ignored': final List<Object?> i}) {
        _ignored.addAll(i.whereType<String>());
      }
    } on Object {
      // None yet, or damaged: start empty.
    }
  }

  Future<void> _save() async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({'folders': _folders, 'ignored': _ignored.toList()}),
        flush: true,
      );
      await tmp.rename(file.path);
    } on FileSystemException catch (e) {
      debugPrint('Game folders not saved: $e');
    }
  }

  /// Whether [path] lies in one of the folders.
  bool contains(String path) => all.any((f) => p.isWithin(f, path));

  /// Adds [path] and scans it. A folder inside one already watched (or
  /// already in the list) is only rescanned; one that holds watched folders
  /// replaces them.
  Future<CardScan> add(String path) async {
    final dir = p.normalize(path);
    if (!all.any((f) => p.equals(f, dir) || p.isWithin(f, dir))) {
      for (final inner in _folders.where((f) => p.isWithin(dir, f)).toList()) {
        _unwatch(inner);
        _folders.remove(inner);
      }
      _folders.add(dir);
      // Adding a folder again brings back games deleted from it before.
      _ignored.removeWhere((g) => p.isWithin(dir, g));
      await _save();
      if (_watching) _watch(dir);
      notifyListeners();
    }
    return scan(dir);
  }

  /// Stops watching [path] and takes its games out of the library. The
  /// files stay, and so do their saves and states.
  Future<int> remove(String path) async {
    if (!_folders.remove(path)) return 0;
    _unwatch(path);
    _ignored.removeWhere((g) => p.isWithin(path, g));
    await _save();
    var removed = 0;
    for (final g in await db.allGames()) {
      if (p.isWithin(path, g.path) && !contains(g.path)) {
        if (await db.deleteGame(g.id) != null) removed++;
      }
    }
    notifyListeners();
    return removed;
  }

  /// A game in a folder was deleted from the library: don't add it again.
  Future<void> forget(String romPath) async {
    if (!contains(romPath) || !_ignored.add(romPath)) return;
    await _save();
  }

  /// Scans [dir] in place: adds new games, drops games whose file is gone.
  Future<CardScan> scan(String dir) async {
    _running++;
    if (_running == 1) notifyListeners();
    try {
      return await scanFolderInPlace(
        Directory(dir),
        db,
        importer,
        ignored: _ignored,
        prune: true,
      );
    } finally {
      _running--;
      if (_running == 0) notifyListeners();
    }
  }

  /// Scans every folder, one after the other.
  Future<CardScan> scanAll() async {
    final total = CardScan();
    for (final dir in all) {
      final s = await scan(dir);
      total
        ..added += s.added
        ..skipped += s.skipped
        ..removed += s.removed
        ..rejected.addAll(s.rejected);
    }
    return total;
  }

  /// Starts watching every folder; changes rescan that folder after
  /// [debounce].
  void startWatching() {
    _watching = true;
    all.forEach(_watch);
  }

  void _watch(String dir) {
    if (_subs.containsKey(dir)) return;
    try {
      _subs[dir] = _watcher(Directory(dir)).listen(
        (e) => _changed(dir, e),
        onError: (Object e) => debugPrint('Watching $dir stopped: $e'),
      );
    } on FileSystemException catch (e) {
      // Missing folder (unplugged drive): scanned again at the next start.
      debugPrint('Cannot watch $dir: $e');
    }
  }

  void _changed(String dir, FileSystemEvent e) {
    // Our own temporary files and hidden files don't count.
    if (p.basename(e.path).startsWith('.')) return;
    _timers[dir]?.cancel();
    _timers[dir] = Timer(debounce, () {
      _timers.remove(dir);
      scan(dir).then(
        (s) =>
            debugPrint('Rescan $dir: ${s.added} added, ${s.removed} removed'),
        onError: (Object e) => debugPrint('Rescan $dir failed: $e'),
      );
    });
  }

  void _unwatch(String dir) {
    _subs.remove(dir)?.cancel();
    _timers.remove(dir)?.cancel();
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    for (final t in _timers.values) {
      t.cancel();
    }
    _subs.clear();
    _timers.clear();
    super.dispose();
  }
}

/// Every change under [dir]. Windows and macOS watch a tree natively; on
/// Linux (inotify) each folder gets its own watch, and new folders are
/// added as they appear.
Stream<FileSystemEvent> watchTree(Directory dir) {
  if (!Platform.isLinux) return dir.watch(recursive: true);
  late final StreamController<FileSystemEvent> out;
  final subs = <String, StreamSubscription<FileSystemEvent>>{};
  void add(Directory d) {
    if (subs.containsKey(d.path) || subs.length >= 4096) return;
    try {
      subs[d.path] = d.watch().listen((e) {
        out.add(e);
        if (e is FileSystemCreateEvent && e.isDirectory) {
          add(Directory(e.path));
        } else if (e is FileSystemDeleteEvent || e is FileSystemMoveEvent) {
          subs.remove(e.path)?.cancel();
        }
      }, onError: (Object _) => subs.remove(d.path)?.cancel());
    } on FileSystemException {
      // Unreadable folder: skip it.
    }
  }

  out = StreamController<FileSystemEvent>(
    onListen: () {
      add(dir);
      try {
        for (final e in dir.listSync(recursive: true, followLinks: false)) {
          if (e is Directory &&
              !p
                  .split(p.relative(e.path, from: dir.path))
                  .any((s) => s.startsWith('.'))) {
            add(e);
          }
        }
      } on FileSystemException {
        // Keep the watches found so far.
      }
    },
    onCancel: () async {
      for (final s in subs.values) {
        await s.cancel();
      }
      subs.clear();
    },
  );
  return out.stream;
}
