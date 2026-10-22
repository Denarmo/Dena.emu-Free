// SPDX-License-Identifier: GPL-3.0-or-later
// Checks library games against their system's DAT and keeps the results.
// Spec: docs/specs/rom-manager.md
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/database.dart';
import 'dat.dart';
import 'dat_store.dart';
import 'models.dart';

/// Extensions DATs can't check directly (rom-manager.md 2).
const compressedExtensions = {
  '.chd',
  '.cso',
  '.pbp',
  '.rvz',
  '.wia',
  '.gcz',
  '.wbfs',
  '.ciso',
};

/// Verification results by SHA-1, stored in
/// `<dataDir>/romtools/verify.json`.
class VerifyResults extends ChangeNotifier {
  VerifyResults(this.dataDir);

  final String dataDir;
  final _results = <String, VerifyResult>{};

  File get _file => File(p.join(dataDir, 'romtools', 'verify.json'));

  /// Reads the stored results; a missing or damaged file means none.
  Future<void> load() async {
    _results.clear();
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map) {
        for (final MapEntry(:key, :value) in json.entries) {
          if (VerifyResult.fromJson(value) case final r?) {
            _results[key as String] = r;
          }
        }
      }
    } on Object {
      // Nothing stored yet, or unreadable.
    }
    notifyListeners();
  }

  /// The result stored for [sha1].
  VerifyResult? operator [](String sha1) => _results[sha1];

  /// Every stored result.
  Map<String, VerifyResult> get all => Map.unmodifiable(_results);

  /// Stores [r] for [sha1].
  Future<void> put(String sha1, VerifyResult r) async {
    _results[sha1] = r;
    await _save();
  }

  /// Forgets [sha1]'s result.
  Future<void> remove(String sha1) async {
    if (_results.remove(sha1) == null) return;
    await _save();
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({for (final e in _results.entries) e.key: e.value.toJson()}),
      flush: true,
    );
    await tmp.rename(_file.path);
    notifyListeners();
  }
}

/// Matches games against [DatStore] DATs (rom-manager.md 2).
class GameVerifier extends ChangeNotifier {
  GameVerifier({
    required this.dats,
    required this.results,
    this.clock = DateTime.now,
    Future<List<int>?> Function(String path)? readHeadless,
  }) : _readHeadless = readHeadless ?? _stripNesHeader;

  final DatStore dats;
  final VerifyResults results;
  final DateTime Function() clock;
  final Future<List<int>?> Function(String path) _readHeadless;

  var _running = false;
  var _cancelled = false;
  var _done = 0;
  var _total = 0;

  /// Whether [verifyAll] is running.
  bool get running => _running;

  /// Games [verifyAll] has finished.
  int get done => _done;

  /// Games [verifyAll] was given to check.
  int get total => _total;

  /// Checks [game]; stores and returns the result. With [download], a
  /// missing DAT for a known system is fetched first (dats.download).
  Future<VerifyResult> verify(Game game, {bool download = false}) async {
    final result = await _check(game, download: download);
    await results.put(game.sha1, result);
    return result;
  }

  /// The stored result for [game].
  VerifyResult? resultFor(Game game) => results[game.sha1];

  /// Whether [game]'s stored result predates its system's DAT.
  bool isStale(Game game) {
    final r = resultFor(game);
    final info = dats.info(game.system);
    if (r == null || info == null) return false;
    return r.checkedAt.isBefore(info.installedAt);
  }

  /// One game after the other; progress in [running], [done], [total];
  /// stops early when [cancel] was called. Skips games with a fresh result
  /// unless [force].
  Future<void> verifyAll(
    List<Game> games, {
    bool force = false,
    bool download = false,
  }) async {
    if (_running) return;
    final todo = [
      for (final g in games)
        if (force || resultFor(g) == null || isStale(g)) g,
    ];
    _running = true;
    _cancelled = false;
    _done = 0;
    _total = todo.length;
    notifyListeners();
    // A system whose DAT download failed is not retried for every game.
    final failed = <String>{};
    try {
      for (final game in todo) {
        if (_cancelled) break;
        final fetch = download && !failed.contains(game.system);
        try {
          await verify(game, download: fetch);
        } on Object {
          // A failed download leaves the game as NO DAT; any other error
          // skips it.
          if (fetch) failed.add(game.system);
          try {
            if (fetch) await verify(game);
          } on Object {
            // Skipped.
          }
        }
        _done++;
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// Stops [verifyAll] after the current game.
  void cancel() => _cancelled = true;

  Future<VerifyResult> _check(Game game, {required bool download}) async {
    VerifyResult result(VerifyStatus status, {String? name, String? source}) =>
        VerifyResult(
          status: status,
          checkedAt: clock(),
          name: name,
          source: source,
        );

    final system = game.system;
    if (!datSystems.containsKey(system)) return result(VerifyStatus.unknown);

    if (compressedExtensions.contains(p.extension(game.path).toLowerCase())) {
      final stored = results[game.sha1];
      if (stored != null &&
          stored.status != VerifyStatus.unverifiable &&
          stored.status != VerifyStatus.noDat) {
        return stored;
      }
      return result(
        VerifyStatus.unverifiable,
        source: dats.info(system)?.source,
      );
    }

    if (dats.info(system) == null && download) await dats.download(system);
    final info = dats.info(system);
    final index = await dats.indexFor(system);
    if (info == null || index == null) return result(VerifyStatus.noDat);

    VerifyResult hit(({DatGame game, DatRom rom}) e) => result(
      e.rom.badDump ? VerifyStatus.badDump : VerifyStatus.verified,
      name: e.game.name,
      source: info.source,
    );

    if (index.bySha1(game.sha1) case final e?) return hit(e);
    if (index.byCrc(game.crc32, game.size) case final e?) return hit(e);
    if (system == 'nes') {
      final headless = await _readHeadless(game.path);
      if (headless != null) {
        final hash = sha1.convert(headless).toString();
        if (index.bySha1(hash) case final e?) return hit(e);
      }
    }
    if (index.byFileName(game.fileName) case final g?) {
      return result(VerifyStatus.modified, name: g.name, source: info.source);
    }
    return result(VerifyStatus.unknown, source: info.source);
  }

  /// The bytes after an iNES header (`NES\x1a`, 16 bytes), or null when the
  /// file is missing, unreadable or has no header.
  static Future<List<int>?> _stripNesHeader(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length < 16 ||
          bytes[0] != 0x4e ||
          bytes[1] != 0x45 ||
          bytes[2] != 0x53 ||
          bytes[3] != 0x1a) {
        return null;
      }
      return bytes.sublist(16);
    } on FileSystemException {
      return null;
    }
  }
}
