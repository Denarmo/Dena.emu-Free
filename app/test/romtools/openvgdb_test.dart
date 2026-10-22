// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/rom-manager.md (acceptance test 5)
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dena_emu/src/library/database.dart' show Game;
import 'package:dena_emu/src/romtools/models.dart';
import 'package:dena_emu/src/romtools/openvgdb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

Game game({
  String sha1 = 'nope',
  String crc = '00000000',
  String fileName = 'other.sfc',
  String system = 'snes',
}) => Game(
  id: 1,
  system: system,
  title: 'x',
  searchTitle: 'x',
  fileName: fileName,
  path: '/x/$fileName',
  sha1: sha1,
  size: 1,
  crc32: crc,
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
);

/// A tiny database with OpenVGDB's table and column names.
void writeFixture(String path) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE SYSTEMS (systemID INTEGER PRIMARY KEY, systemName TEXT,
      systemShortName TEXT);
    CREATE TABLE ROMs (romID INTEGER PRIMARY KEY, systemID INTEGER,
      regionID INTEGER, romHashCRC TEXT, romHashMD5 TEXT, romHashSHA1 TEXT,
      romSize INTEGER, romFileName TEXT, romExtensionlessFileName TEXT);
    CREATE TABLE RELEASES (releaseID INTEGER PRIMARY KEY, romID INTEGER,
      releaseTitleName TEXT, regionLocalizedID INTEGER,
      releaseCoverFront TEXT, releaseCoverBack TEXT,
      releaseDescription TEXT, releaseDeveloper TEXT, releasePublisher TEXT,
      releaseGenre TEXT, releaseDate TEXT);
    INSERT INTO SYSTEMS VALUES (25, 'Nintendo Entertainment System', 'NES'),
      (26, 'Nintendo Super Nintendo Entertainment System', 'SNES');
    INSERT INTO ROMs VALUES
      (1, 26, 21, 'CAF2E99F', '', 'ABC123', 1, 'Hero (USA).sfc', 'Hero (USA)'),
      (2, 25, 21, '11111111', '', 'DEF456', 1, 'Nes Game (USA).nes',
        'Nes Game (USA)');
    INSERT INTO RELEASES VALUES
      (10, 1, 'Hero (Japan art)', 13, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
      (11, 1, 'Hero', 21, 'https://img/front.jpg', 'https://img/back.jpg',
        'A hero.', 'Dev Co', 'Pub Co', 'Action,Platformer,2D', 'Nov 21, 1991'),
      (12, 2, 'Nes Game', 21, NULL, NULL, NULL, NULL, NULL, NULL, '1987');
  ''');
  db.close();
}

void main() {
  late Directory dir;
  late OpenVgdb vgdb;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('openvgdb');
    vgdb = OpenVgdb(dir.path);
  });
  tearDown(() {
    vgdb.close();
    dir.deleteSync(recursive: true);
  });

  void install() {
    vgdb.file.parent.createSync(recursive: true);
    writeFixture(vgdb.file.path);
  }

  test('not installed: null', () async {
    expect(vgdb.installed, isFalse);
    expect(await vgdb.lookup(game(sha1: 'abc123')), isNull);
  });

  test('lookup by SHA-1, with the release of the ROM region', () async {
    install();
    final g = (await vgdb.lookup(game(sha1: 'abc123', system: 'gba')))!;
    expect(g.source, 'openvgdb');
    expect(g.title, 'Hero');
    expect(g.description, 'A hero.');
    expect(g.developer, 'Dev Co');
    expect(g.publisher, 'Pub Co');
    expect(g.genre, 'Action');
    expect(g.year, 1991);
    expect(g.media, {
      ScrapeKind.cover: Uri.parse('https://img/front.jpg'),
      ScrapeKind.back: Uri.parse('https://img/back.jpg'),
    });
  });

  test('lookup by CRC needs the same system', () async {
    install();
    expect((await vgdb.lookup(game(crc: 'caf2e99f')))!.title, 'Hero');
    expect(await vgdb.lookup(game(crc: 'caf2e99f', system: 'nes')), isNull);
  });

  test('lookup by file name, with or without extension', () async {
    install();
    expect(
      (await vgdb.lookup(game(fileName: 'hero (usa).sfc')))!.title,
      'Hero',
    );
    expect(
      (await vgdb.lookup(game(fileName: 'Nes Game (USA).zip', system: 'nes')))!
          .year,
      1987,
    );
    expect(await vgdb.lookup(game(fileName: 'Unknown.sfc')), isNull);
  });

  test('download extracts and indexes the database', () async {
    final src = p.join(dir.path, 'src.sqlite');
    writeFixture(src);
    final zip = Archive()
      ..addFile(ArchiveFile.bytes('__MACOSX/._openvgdb.sqlite', [1, 2]))
      ..addFile(
        ArchiveFile.bytes('openvgdb.sqlite', File(src).readAsBytesSync()),
      );
    Uri? asked;
    vgdb = OpenVgdb(
      dir.path,
      fetch: (url) async {
        asked = url;
        return ZipEncoder().encode(zip);
      },
    );
    await vgdb.download();
    expect(asked, OpenVgdb.url);
    expect(vgdb.installed, isTrue);
    expect((await vgdb.lookup(game(sha1: 'abc123')))!.title, 'Hero');
    final db = sqlite3.open(vgdb.file.path, mode: OpenMode.readOnly);
    final indexes = db
        .select("SELECT name FROM sqlite_master WHERE type = 'index'")
        .map((r) => r['name']);
    db.close();
    expect(indexes, contains('dena_sha1'));
  });

  test('download fails on a missing file', () async {
    vgdb = OpenVgdb(dir.path, fetch: (_) async => null);
    await expectLater(vgdb.download(), throwsA(isA<HttpException>()));
    expect(vgdb.installed, isFalse);
  });
}
