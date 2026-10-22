// SPDX-License-Identifier: GPL-3.0-or-later
// RomM in the app: the account, library downloads and save/state sync.
// Spec: docs/specs/romm.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/database.dart';
import '../library/importer.dart';
import '../net/http.dart' show HttpStreamSend;
import 'romm_client.dart';

/// A local game known to be a ROM on the server.
class RommLink {
  const RommLink(this.romId, this.fileName);

  final int romId;

  /// The server's file name; saves are named after it there.
  final String fileName;

  String get stem => p.basenameWithoutExtension(fileName);
}

class RommSyncReport {
  int uploaded = 0, downloaded = 0, conflicts = 0;
  final failures = <String>[];

  bool get changedNothing => uploaded == 0 && downloaded == 0;
}

typedef RommClientFactory = RommClient Function(
  String server,
  String username,
  String password,
);

class RommController extends ChangeNotifier {
  RommController({
    required this.dataDir,
    this.db,
    this.importer,
    RommClientFactory? client,
    HttpStreamSend? send,
    DateTime Function()? clock,
  }) : _factory =
           client ??
           ((s, u, pw) =>
               RommClient(server: s, username: u, password: pw, send: send)),
       _clock = clock ?? DateTime.now;

  final Directory dataDir;
  final LibraryDatabase? db;
  final Importer? importer;
  final RommClientFactory _factory;
  final DateTime Function() _clock;

  String? _server, _user, _password;
  bool _auto = true;
  DateTime? _lastSync;
  final _links = <String, RommLink>{};

  /// file key → [local mtime ms, remote updatedAt ms] at the last sync.
  final _seen = <String, List<int>>{};
  int _sessions = 0;
  Future<RommSyncReport>? _running;
  RommClient? _client;

  /// Why the last action failed, for the settings page.
  String? problem;
  RommSyncReport? lastReport;

  /// ROM id → download progress (0–1, or null while the size is unknown).
  final downloads = <int, double?>{};

  bool get connected => _server != null;
  String? get server => _server;
  String? get username => _user;
  bool get autoSync => _auto;
  bool get syncing => _running != null;
  DateTime? get lastSync => _lastSync;
  Map<String, RommLink> get links => Map.unmodifiable(_links);

  RommClient get client =>
      _client ??= _factory(_server ?? '', _user ?? '', _password ?? '');

  File get _stateFile => File(p.join(dataDir.path, 'romm', 'account.json'));

  Future<void> load() async {
    try {
      final j = jsonDecode(await _stateFile.readAsString()) as Map;
      _server = j['server'] as String?;
      _user = j['username'] as String?;
      _password = j['password'] as String?;
      _auto = j['auto'] as bool? ?? true;
      _lastSync = DateTime.tryParse(j['lastSync'] as String? ?? '');
      for (final e in ((j['links'] as Map?) ?? const {}).entries) {
        final v = e.value as Map;
        _links[e.key as String] = RommLink(
          (v['id'] as num).toInt(),
          v['file'] as String,
        );
      }
      for (final e in ((j['seen'] as Map?) ?? const {}).entries) {
        _seen[e.key as String] = [
          for (final n in e.value as List) (n as num).toInt(),
        ];
      }
    } on Object {
      // First run or unreadable: not connected.
    }
    notifyListeners();
  }

  Future<void> _save() async {
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(
      jsonEncode({
        'server': _server,
        'username': _user,
        'password': _password,
        'auto': _auto,
        'lastSync': _lastSync?.toUtc().toIso8601String(),
        'links': {
          for (final e in _links.entries)
            e.key: {'id': e.value.romId, 'file': e.value.fileName},
        },
        'seen': _seen,
      }),
    );
  }

  /// Checks the login and keeps it. Returns null on success, else why not.
  Future<String?> connect(String server, String user, String password) async {
    final RommClient c;
    try {
      c = _factory(server, user, password);
    } on FormatException {
      return 'Enter the server address, like http://192.168.1.10:8080';
    }
    try {
      await c.me();
    } on RommException catch (e) {
      if (e.unauthorized) return 'Wrong username or password';
      if (e.offline) return "Couldn't reach that server";
      return 'The server said: $e';
    }
    if (c.base.toString() != _server) {
      _links.clear();
      _seen.clear();
    }
    _server = c.base.toString();
    _user = user;
    _password = password;
    _client = c;
    problem = null;
    await _save();
    notifyListeners();
    _autoSync();
    return null;
  }

  Future<void> disconnect() async {
    _server = _user = _password = null;
    _client = null;
    _links.clear();
    _seen.clear();
    _lastSync = null;
    lastReport = null;
    problem = null;
    await _save();
    notifyListeners();
  }

  Future<void> setAutoSync(bool on) async {
    _auto = on;
    await _save();
    notifyListeners();
  }

  /// Downloads [rom] and imports it into the library. Returns the import
  /// outcome, or throws [RommException].
  Future<ImportOutcome> download(RommRom rom) async {
    final imp = importer;
    if (imp == null) throw StateError('No importer');
    downloads[rom.id] = rom.size > 0 ? 0 : null;
    notifyListeners();
    final tmpDir = Directory(p.join(dataDir.path, 'romm', 'downloads'));
    final safe = rom.fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final tmp = File(p.join(tmpDir.path, safe));
    try {
      await tmpDir.create(recursive: true);
      final reply = await client.download(rom);
      final out = tmp.openWrite();
      final hash = _DigestSink();
      final hasher = sha1.startChunkedConversion(hash);
      var got = 0;
      var lastTick = DateTime.now();
      try {
        await for (final chunk in reply.body) {
          out.add(chunk);
          hasher.add(chunk);
          got += chunk.length;
          if (rom.size > 0 &&
              DateTime.now().difference(lastTick).inMilliseconds > 150) {
            lastTick = DateTime.now();
            downloads[rom.id] = (got / rom.size).clamp(0, 1).toDouble();
            notifyListeners();
          }
        }
      } on RommException {
        rethrow;
      } on Object catch (e) {
        throw RommException(0, 'Download interrupted ($e)');
      } finally {
        await out.close();
      }
      hasher.close();
      final outcome = await imp.importOne(tmp);
      String? sha;
      if (outcome is Imported) {
        sha = (await db?.gameById(outcome.gameId))?.sha1;
      } else if (outcome is Duplicate) {
        sha = hash.value.toString();
      }
      if (sha != null) {
        _links[sha] = RommLink(rom.id, rom.fileName);
        await _save();
      }
      return outcome;
    } finally {
      downloads.remove(rom.id);
      if (await tmp.exists()) await tmp.delete();
      notifyListeners();
    }
  }

  /// Whether the library already has [rom] (by link or hash).
  bool has(RommRom rom, Set<String> localSha1s) =>
      _links.values.any((l) => l.romId == rom.id) ||
      (rom.sha1 != null && localSha1s.contains(rom.sha1));

  /// Syncs saves and states unless disconnected or a game is running.
  Future<RommSyncReport> syncNow() {
    if (!connected || _sessions > 0) return Future.value(RommSyncReport());
    final running = _running ??= _sync().whenComplete(() {
      _running = null;
      notifyListeners();
    });
    notifyListeners();
    return running;
  }

  Future<RommSyncReport> _sync() async {
    final report = RommSyncReport();
    try {
      final games = await db?.allGames() ?? const <Game>[];
      await _matchUnlinked(games);
      for (final g in games) {
        final link = _links[g.sha1];
        if (link == null) continue;
        await _syncGame(g.sha1, link, report);
      }
      _lastSync = _clock();
      problem = report.failures.isEmpty
          ? null
          : '${report.failures.length} files not synced';
      lastReport = report;
      await _save();
    } on RommException catch (e) {
      problem = e.unauthorized
          ? 'RomM refused the login; connect again'
          : e.offline
          ? "Couldn't reach the RomM server"
          : 'Sync failed ($e)';
      debugPrint('RomM sync: $e');
    } on Object catch (e) {
      problem = 'Sync failed ($e)';
      debugPrint('RomM sync: $e');
    }
    return report;
  }

  /// Links local games the server also has (same SHA-1 or CRC32), so games
  /// imported another way still sync their saves.
  Future<void> _matchUnlinked(List<Game> games) async {
    final unlinked = games.where((g) => !_links.containsKey(g.sha1)).toList();
    if (unlinked.isEmpty) return;
    final roms = await client.roms();
    final bySha = {
      for (final r in roms)
        if (r.sha1 != null) r.sha1!: r,
    };
    final byCrc = {
      for (final r in roms)
        if (r.crc != null) r.crc!: r,
    };
    for (final g in unlinked) {
      final r = bySha[g.sha1] ?? byCrc[g.crc32.toLowerCase()];
      if (r != null) _links[g.sha1] = RommLink(r.id, r.fileName);
    }
  }

  Future<void> _syncGame(String sha, RommLink link, RommSyncReport rep) async {
    final saves = await client.files(RommKind.saves, link.romId);
    final states = await client.files(RommKind.states, link.romId);
    // Battery save.
    await _syncFile(
      key: '$sha/srm',
      local: File(p.join(dataDir.path, 'saves', '$sha.srm')),
      kind: RommKind.saves,
      romId: link.romId,
      remoteName: '${link.stem}.srm',
      remote: saves,
      report: rep,
    );
    // State slots (thumbnails stay local).
    final slots = <String>{'quick', for (var n = 1; n <= 9; n++) 'slot$n'};
    for (final slot in slots) {
      await _syncFile(
        key: '$sha/$slot',
        local: File(p.join(dataDir.path, 'states', sha, '$slot.state')),
        kind: RommKind.states,
        romId: link.romId,
        remoteName: '${link.stem}.$slot.state',
        remote: states,
        report: rep,
      );
    }
  }

  Future<void> _syncFile({
    required String key,
    required File local,
    required RommKind kind,
    required int romId,
    required String remoteName,
    required List<RommFile> remote,
    required RommSyncReport report,
  }) async {
    try {
      final r = remote
          .where((f) => f.fileName == remoteName)
          .fold<RommFile?>(
            null,
            (a, b) => a == null || b.updatedAt.isAfter(a.updatedAt) ? b : a,
          );
      final exists = await local.exists();
      final lm = exists
          ? (await local.lastModified()).millisecondsSinceEpoch
          : null;
      final rm = r?.updatedAt.millisecondsSinceEpoch;
      final seen = _seen[key];
      final localChanged = lm != null && (seen == null || seen[0] != lm);
      final remoteChanged = rm != null && (seen == null || seen[1] != rm);
      bool upload;
      if (lm == null && rm == null) return;
      if (localChanged && remoteChanged) {
        // Both sides moved (or first sync with both): the newer wins and
        // the other is kept next to it.
        upload = lm > rm;
        if (seen != null) report.conflicts++;
      } else if (localChanged) {
        upload = true;
      } else if (remoteChanged) {
        upload = false;
      } else {
        return;
      }
      if (upload) {
        final up = await client.upload(
          kind,
          romId,
          remoteName,
          await local.readAsBytes(),
        );
        var at = up?.updatedAt.millisecondsSinceEpoch;
        if (at == null) {
          final again = await client.files(kind, romId);
          at = again
              .where((f) => f.fileName == remoteName)
              .map((f) => f.updatedAt.millisecondsSinceEpoch)
              .fold<int?>(null, (a, b) => a == null || b > a ? b : a);
        }
        _seen[key] = [lm!, at ?? 0];
        report.uploaded++;
      } else {
        // A local edit about to be replaced is kept.
        if (localChanged) await _keepCopy(local);
        final bytes = await client.fetch(r!);
        await local.parent.create(recursive: true);
        final tmp = File('${local.path}.romm');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(local.path);
        final at = r.updatedAt;
        await local.setLastModified(at.toLocal());
        _seen[key] = [(await local.lastModified()).millisecondsSinceEpoch, rm!];
        report.downloaded++;
      }
    } on RommException catch (e) {
      if (e.unauthorized || e.offline) rethrow;
      report.failures.add('$remoteName: $e');
    } on FileSystemException catch (e) {
      report.failures.add('$remoteName: ${e.message}');
    }
  }

  /// Keeps a local file that is about to be replaced under
  /// `romm/conflicts/<time>/`.
  Future<void> _keepCopy(File local) async {
    final rel = p.relative(local.path, from: dataDir.path);
    final stamp = _clock().toUtc().toIso8601String().replaceAll(':', '-');
    final dest = File(p.join(dataDir.path, 'romm', 'conflicts', stamp, rel));
    await dest.parent.create(recursive: true);
    await local.copy(dest.path);
  }

  void _autoSync() {
    if (_auto) unawaited(syncNow());
  }

  void appResumed() => _autoSync();
  void appPaused() => _autoSync();

  /// A game is starting: waits for a running sync so the game loads the
  /// newest saves, then holds new syncs until it ends.
  Future<void> sessionStarted() async {
    final running = _running;
    _sessions++;
    if (running != null) await running;
  }

  void sessionEnded() {
    if (_sessions > 0) _sessions--;
    _autoSync();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
