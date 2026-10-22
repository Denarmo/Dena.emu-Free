import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/webfiles/web_file_server.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late LibraryDatabase db;
  late WebFileServer server;
  late HttpClient client;
  Cookie? session;

  Future<(int, Map<String, dynamic>)> call(
    String method,
    String path, {
    Map<String, String>? query,
    List<int>? body,
    bool auth = true,
  }) async {
    final uri = Uri.parse('http://127.0.0.1:${server.port}$path')
        .replace(queryParameters: query);
    final req = await client.openUrl(method, uri);
    if (auth && session != null) req.cookies.add(session!);
    if (body != null) req.add(body);
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    final json = res.headers.contentType?.mimeType == 'application/json'
        ? jsonDecode(text) as Map<String, dynamic>
        : <String, dynamic>{'text': text};
    return (res.statusCode, json);
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    dir = await Directory.systemTemp.createTemp('webfiles');
    db = LibraryDatabase(NativeDatabase.memory());
    server = WebFileServer(
      dataDir: dir.path,
      db: db,
      importer: Importer(db, Directory(p.join(dir.path, 'games'))),
    );
    await server.start(port: 0);
    client = HttpClient();
    final req = await client.post('127.0.0.1', server.port!, '/api/login');
    req.write(jsonEncode({'code': server.code}));
    final res = await req.close();
    await res.drain<void>();
    session = res.cookies.firstWhere((c) => c.name == 'dena_session');
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await db.close();
    await dir.delete(recursive: true);
  });

  test('serves the page and refuses the API without the code', () async {
    final (status, page) = await call('GET', '/', auth: false);
    expect(status, 200);
    expect(page['text'], contains('Dena'));
    final (denied, _) = await call(
      'GET',
      '/api/list',
      query: {'root': 'saves'},
      auth: false,
    );
    expect(denied, HttpStatus.unauthorized);
  });

  test('wrong code is rejected', () async {
    final req = await client.post('127.0.0.1', server.port!, '/api/login');
    req.write(jsonEncode({'code': 'nope'}));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, HttpStatus.forbidden);
  });

  test('upload, list, rename, download and delete in a folder', () async {
    final (up, _) = await call(
      'PUT',
      '/api/upload',
      query: {'root': 'saves', 'path': '', 'name': 'a.srm'},
      body: [1, 2, 3],
    );
    expect(up, 200);
    expect(File(p.join(dir.path, 'saves', 'a.srm')).readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    var (_, list) = await call('GET', '/api/list', query: {'root': 'saves'});
    expect((list['entries'] as List).single['name'], 'a.srm');
    await call(
      'POST',
      '/api/rename',
      query: {'root': 'saves', 'path': 'a.srm', 'name': 'b.srm'},
    );
    final (got, file) = await call(
      'GET',
      '/api/file',
      query: {'root': 'saves', 'path': 'b.srm'},
    );
    expect(got, 200);
    expect(file['text'], '\x01\x02\x03');
    await call(
      'POST',
      '/api/delete',
      query: {'root': 'saves', 'path': 'b.srm'},
    );
    (_, list) = await call('GET', '/api/list', query: {'root': 'saves'});
    expect(list['entries'], isEmpty);
  });

  test('paths cannot leave the folder', () async {
    for (final path in ['..', '../games', 'a/../../x']) {
      final (status, _) = await call(
        'GET',
        '/api/list',
        query: {'root': 'saves', 'path': path},
      );
      expect(status, HttpStatus.badRequest, reason: path);
    }
    final (status, _) = await call(
      'PUT',
      '/api/upload',
      query: {'root': 'saves', 'name': '../evil'},
      body: [0],
    );
    expect(status, HttpStatus.badRequest);
  });

  test('a game upload is imported into the library', () async {
    final rom = [0x4E, 0x45, 0x53, 0x1A, ...List.filled(16 + 16384, 0)];
    final (status, body) = await call(
      'PUT',
      '/api/upload',
      query: {'root': 'games', 'name': 'Test Game.nes'},
      body: rom,
    );
    expect(status, 200, reason: '$body');
    expect(body['ok'], isTrue, reason: '$body');
    final games = await db.allGames();
    expect(games.single.system, 'nes');
    final (_, systems) = await call(
      'GET',
      '/api/list',
      query: {'root': 'games'},
    );
    expect((systems['entries'] as List).single['name'], 'nes');
    final (_, list) = await call(
      'GET',
      '/api/list',
      query: {'root': 'games', 'path': 'nes'},
    );
    final entry = (list['entries'] as List).single as Map;
    expect(entry['label'], 'Test Game');
    await call(
      'POST',
      '/api/rename',
      query: {
        'root': 'games',
        'path': 'nes/${entry['name']}',
        'name': 'Renamed',
      },
    );
    expect((await db.allGames()).single.title, 'Renamed');
    await call(
      'POST',
      '/api/delete',
      query: {'root': 'games', 'path': 'nes/${entry['name']}'},
    );
    expect(await db.allGames(), isEmpty);
    expect(Directory(p.join(dir.path, 'web-uploads')).listSync(), isEmpty);
  });
}
