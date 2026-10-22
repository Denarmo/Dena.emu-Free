// SPDX-License-Identifier: GPL-3.0-or-later
// OpenVGDB (MIT): the offline SQLite game database, downloaded on demand.
// Spec: docs/specs/rom-manager.md
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../library/box_art.dart' show Fetch, httpFetch;
import '../library/database.dart' show Game;
import 'models.dart';

/// Our system id → OpenVGDB `SYSTEMS.systemShortName` (release v29.0).
const openVgdbSystems = <String, String>{
  'nes': 'NES',
  'snes': 'SNES',
  'gb': 'GB',
  'gbc': 'GBC',
  'gba': 'GBA',
  'n64': 'N64',
  'nds': 'NDS',
  'genesis': 'MD',
  'segacd': 'SCD',
  'saturn': 'Saturn',
  'psx': 'PSX',
  'psp': 'PSP',
};

/// The OpenVGDB release database at `<dataDir>/romtools/openvgdb.sqlite`.
///
/// Opened read-only once and kept open. [download] adds indexes on the
/// hash and file name columns, so a lookup is a few index probes and runs
/// on the calling isolate.
class OpenVgdb {
  OpenVgdb(
    this.dataDir, {
    this.fetch = httpFetch,
    Database Function(String path)? open,
  }) : _open = open ?? ((path) => sqlite3.open(path, mode: OpenMode.readOnly));

  final String dataDir;
  final Fetch fetch;
  final Database Function(String path) _open;
  Database? _db;

  /// The pinned release (the latest, checked 2026-10-18).
  static final url = Uri.parse(
    'https://github.com/OpenVGDB/OpenVGDB/releases/download/v29.0/openvgdb.zip',
  );

  File get file => File(p.join(dataDir, 'romtools', 'openvgdb.sqlite'));

  bool get installed => file.existsSync();

  /// Downloads the release zip, extracts its `.sqlite`, indexes it and
  /// moves it into place. Throws on failure.
  Future<void> download() async {
    final bytes = await fetch(url);
    if (bytes == null || bytes.isEmpty) {
      throw const HttpException('OpenVGDB download not found');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.files.firstWhere(
      (f) =>
          f.isFile &&
          f.name.toLowerCase().endsWith('.sqlite') &&
          !f.name.startsWith('__MACOSX'),
      orElse: () => throw const FormatException('No database in openvgdb.zip'),
    );
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(entry.content, flush: true);
    final db = sqlite3.open(tmp.path);
    try {
      db.execute('''
        CREATE INDEX IF NOT EXISTS dena_sha1 ON ROMs(romHashSHA1);
        CREATE INDEX IF NOT EXISTS dena_crc ON ROMs(romHashCRC);
        CREATE INDEX IF NOT EXISTS dena_file ON ROMs(romFileName COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS dena_base
          ON ROMs(romExtensionlessFileName COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS dena_release ON RELEASES(romID);
      ''');
    } finally {
      db.close();
    }
    close();
    await tmp.rename(file.path);
  }

  /// What OpenVGDB knows about [game]: matched by SHA-1, then CRC-32 and
  /// system, then file name and system. Null when the database is not
  /// installed or has no match.
  Future<ScrapedGame?> lookup(Game game) async {
    if (!installed) return null;
    final db = _db ??= _open(file.path);
    final system = openVgdbSystems[game.system];
    const select = '''
      SELECT r.romID, r.regionID FROM ROMs r
      JOIN SYSTEMS s ON s.systemID = r.systemID''';
    final base = p.basenameWithoutExtension(game.fileName);
    final queries = <(String, List<Object?>)>[
      ('$select WHERE r.romHashSHA1 = ?', [game.sha1.toUpperCase()]),
      if (system != null) ...[
        (
          '$select WHERE r.romHashCRC = ? AND s.systemShortName = ?',
          [game.crc32.toUpperCase(), system],
        ),
        (
          '$select WHERE (r.romFileName = ? COLLATE NOCASE '
              'OR r.romExtensionlessFileName = ? COLLATE NOCASE) '
              'AND s.systemShortName = ?',
          [game.fileName, base, system],
        ),
      ],
    ];
    for (final (sql, args) in queries) {
      final rows = db.select('$sql LIMIT 1', args);
      if (rows.isEmpty) continue;
      return _release(db, rows.first['romID'] as int, rows.first['regionID']);
    }
    return null;
  }

  ScrapedGame? _release(Database db, int romId, Object? regionId) {
    final rows = db.select(
      '''
      SELECT * FROM RELEASES WHERE romID = ?
      ORDER BY regionLocalizedID = ? DESC,
        releaseCoverFront IS NOT NULL DESC, releaseID
      LIMIT 1''',
      [romId, regionId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    String? text(String column) {
      final v = r[column];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final year = RegExp(r'\b(1[89]\d\d|20\d\d)\b')
        .firstMatch(text('releaseDate') ?? '')?[1];
    return ScrapedGame(
      source: 'openvgdb',
      title: text('releaseTitleName'),
      description: text('releaseDescription'),
      developer: text('releaseDeveloper'),
      publisher: text('releasePublisher'),
      // "Action,Platformer,2D": the first is the main genre.
      genre: text('releaseGenre')?.split(',').first.trim(),
      year: year == null ? null : int.parse(year),
      media: {
        if (Uri.tryParse(text('releaseCoverFront') ?? '') case final u?
            when u.hasScheme)
          ScrapeKind.cover: u,
        if (Uri.tryParse(text('releaseCoverBack') ?? '') case final u?
            when u.hasScheme)
          ScrapeKind.back: u,
      },
    );
  }

  /// Closes the database; the next lookup reopens it.
  void close() {
    _db?.close();
    _db = null;
  }
}
