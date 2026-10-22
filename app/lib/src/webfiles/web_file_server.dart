// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/web-file-manager.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../library/database.dart';
import '../library/importer.dart';
import 'web_page.dart';

/// One folder the browser can open. [games] is the library: its entries are
/// games, not files, and uploads go through the importer.
enum WebRoot {
  games('Games'),
  saves('Saves'),
  states('States'),
  skins('Skins'),
  carts('Carts');

  const WebRoot(this.label);
  final String label;
}

/// A local HTTP server that lets a browser on the same network manage the
/// app's games, saves, states, skins and carts (web-file-manager.md).
class WebFileServer {
  WebFileServer({
    required this.dataDir,
    required this.db,
    required this.importer,
    Random? random,
  }) : _random = random ?? Random.secure();

  final String dataDir;
  final LibraryDatabase db;
  final Importer importer;
  final Random _random;

  HttpServer? _server;
  String _code = '';
  final _sessions = <String>{};

  /// Four-digit code the browser must enter; new on every start.
  String get code => _code;
  bool get running => _server != null;
  int? get port => _server?.port;

  /// Starts listening on every interface at [port] (0 picks a free one).
  Future<void> start({int port = 8080}) async {
    if (_server != null) return;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _code = (_random.nextInt(9000) + 1000).toString();
    _sessions.clear();
    _server = server;
    server.listen((r) => unawaited(_handle(r)));
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _sessions.clear();
    await s?.close(force: true);
  }

  /// `http://<wifi address>:<port>` addresses the server answers on.
  Future<List<String>> addresses() async {
    final port = _server?.port;
    if (port == null) return const [];
    final out = <String>[];
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        if (!a.isLoopback) out.add('http://${a.address}:$port');
      }
    }
    return out;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Cache-Control', 'no-store');
    res.headers.set('X-Content-Type-Options', 'nosniff');
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/') {
        res.headers.contentType = ContentType.html;
        res.write(webPageHtml);
      } else if (req.method == 'POST' && path == '/api/login') {
        await _login(req);
      } else if (!_authorised(req)) {
        _error(
          res,
          HttpStatus.unauthorized,
          'Enter the code shown in Dena.emu',
        );
      } else {
        await _api(req);
      }
    } on _HttpError catch (e) {
      _error(res, e.status, e.message);
    } on Object catch (e) {
      _error(res, HttpStatus.internalServerError, '$e');
    }
    try {
      await res.close();
    } on Object {
      // The browser went away.
    }
  }

  Future<void> _login(HttpRequest req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join());
    if (body is! Map || body['code'] != _code) {
      throw const _HttpError(HttpStatus.forbidden, 'Wrong code');
    }
    final token = List.generate(
      24,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _sessions.add(token);
    req.response.cookies.add(
      Cookie('dena_session', token)
        ..httpOnly = true
        ..path = '/',
    );
    _json(req.response, {'ok': true});
  }

  bool _authorised(HttpRequest req) => req.cookies.any(
    (c) => c.name == 'dena_session' && _sessions.contains(c.value),
  );

  Future<void> _api(HttpRequest req) async {
    final q = req.uri.queryParameters;
    if (req.uri.path == '/api/roots') {
      return _json(req.response, {
        'roots': [
          for (final r in WebRoot.values) {'id': r.name, 'label': r.label},
        ],
      });
    }
    final root = WebRoot.values.asNameMap()[q['root']];
    if (root == null) {
      throw const _HttpError(HttpStatus.notFound, 'No such folder');
    }
    final rel = q['path'] ?? '';
    final op = (req.method, req.uri.path);
    if (root == WebRoot.games) return _games(req, op, rel);
    final target = _resolve(root, rel);
    switch (op) {
      case ('GET', '/api/list'):
        return _list(req.response, root, target);
      case ('GET', '/api/file'):
        return _download(req.response, File(target), p.basename(target));
      case ('PUT', '/api/upload'):
        final name = _safeName(q['name']);
        final dest = File(p.join(target, name));
        await dest.parent.create(recursive: true);
        await _receive(req, dest);
        return _json(req.response, {'ok': true, 'message': 'Uploaded $name'});
      case ('POST', '/api/mkdir'):
        await Directory(p.join(target, _safeName(q['name'])))
            .create(recursive: true);
        return _json(req.response, {'ok': true});
      case ('POST', '/api/rename'):
        if (rel.isEmpty) {
          throw const _HttpError(HttpStatus.badRequest, 'Pick a file');
        }
        final to = p.join(p.dirname(target), _safeName(q['name']));
        if (await FileSystemEntity.type(to) != FileSystemEntityType.notFound) {
          throw const _HttpError(HttpStatus.conflict, 'That name is taken');
        }
        await _entity(target).rename(to);
        return _json(req.response, {'ok': true});
      case ('POST', '/api/delete'):
        if (rel.isEmpty) {
          throw const _HttpError(HttpStatus.badRequest, 'Pick a file');
        }
        await _entity(target).delete(recursive: true);
        return _json(req.response, {'ok': true});
    }
    throw const _HttpError(HttpStatus.notFound, 'Unknown request');
  }

  /// The library as a folder per system with one entry per game. Rename
  /// changes the title; delete removes the game with its saves and states.
  Future<void> _games(HttpRequest req, (String, String) op, String rel) async {
    final q = req.uri.queryParameters;
    switch (op) {
      case ('GET', '/api/list'):
        final games = await db.allGames();
        final parts = p.posix.split(rel).where((s) => s.isNotEmpty).toList();
        if (parts.isEmpty) {
          final systems = <String, int>{};
          for (final g in games) {
            systems[g.system] = (systems[g.system] ?? 0) + 1;
          }
          return _json(req.response, {
            'entries': [
              for (final s in systems.keys.toList()..sort())
                {'name': s, 'dir': true, 'label': '${systems[s]} games'},
            ],
            'upload': true,
          });
        }
        return _json(req.response, {
          'entries':
              [
                for (final g in games.where((g) => g.system == parts.first))
                  {
                    'name': '${g.id}',
                    'label': g.title,
                    'detail': g.fileName,
                    'dir': false,
                    'size': g.size,
                    'modified': g.addedAt.millisecondsSinceEpoch,
                  },
              ]..sort(
                (a, b) =>
                    (a['label'] as String).compareTo(b['label'] as String),
              ),
          'upload': true,
        });
      case ('GET', '/api/file'):
        final g = await _game(rel);
        return _download(req.response, File(g.path), g.fileName);
      case ('PUT', '/api/upload'):
        final name = _safeName(q['name']);
        final tmp = await Directory(p.join(dataDir, 'web-uploads')).create();
        final file = File(p.join(tmp.path, name));
        try {
          await _receive(req, file);
          final out = await importer.importOne(file);
          final (ok, msg) = switch (out) {
            Imported(:final title) => (true, 'Added $title'),
            Duplicate() => (true, '$name is already in your library'),
            Rejected(:final reason) => (false, '$name: $reason'),
          };
          return _json(req.response, {'ok': ok, 'message': msg});
        } finally {
          if (await file.exists()) await file.delete();
        }
      case ('POST', '/api/rename'):
        final g = await _game(rel);
        final title = (q['name'] ?? '').trim();
        if (title.isEmpty) {
          throw const _HttpError(HttpStatus.badRequest, 'Enter a name');
        }
        await db.rename(g.id, title);
        return _json(req.response, {'ok': true});
      case ('POST', '/api/delete'):
        final g = await _game(rel);
        final removed = await db.deleteGame(g.id);
        if (removed != null) await deleteGameFiles(removed, dataDir: dataDir);
        return _json(req.response, {'ok': true});
    }
    throw const _HttpError(HttpStatus.badRequest, 'Not possible in Games');
  }

  Future<Game> _game(String rel) async {
    final id = int.tryParse(p.posix.basename(rel));
    final g = id == null ? null : await db.gameById(id);
    if (g == null) throw const _HttpError(HttpStatus.notFound, 'No such game');
    return g;
  }

  /// [rel] under [root]'s folder; never outside it.
  String _resolve(WebRoot root, String rel) {
    final base = p.normalize(p.join(dataDir, root.name));
    final parts = p.posix.split(rel).where((s) => s.isNotEmpty && s != '.');
    if (parts.any((s) => s == '..' || s.contains('\\'))) {
      throw const _HttpError(HttpStatus.badRequest, 'Bad path');
    }
    final full = p.normalize(p.joinAll([base, ...parts]));
    if (full != base && !p.isWithin(base, full)) {
      throw const _HttpError(HttpStatus.badRequest, 'Bad path');
    }
    return full;
  }

  Future<void> _list(HttpResponse res, WebRoot root, String dir) async {
    final d = Directory(dir);
    final entries = <Map<String, Object?>>[];
    if (await d.exists()) {
      final titles = root == WebRoot.saves || root == WebRoot.states
          ? {for (final g in await db.allGames()) g.sha1: g.title}
          : const <String, String>{};
      await for (final e in d.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        final stat = await e.stat();
        final sha = name.split('.').first;
        entries.add({
          'name': name,
          'dir': stat.type == FileSystemEntityType.directory,
          'size': stat.size,
          'modified': stat.modified.millisecondsSinceEpoch,
          'label': ?titles[sha],
        });
      }
    }
    entries.sort((a, b) {
      final dir = (b['dir'] == true ? 1 : 0) - (a['dir'] == true ? 1 : 0);
      if (dir != 0) return dir;
      return (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      );
    });
    _json(res, {'entries': entries, 'upload': true});
  }

  Future<void> _download(HttpResponse res, File f, String name) async {
    if (!await f.exists()) {
      throw const _HttpError(HttpStatus.notFound, 'File not found');
    }
    res.headers.contentType = ContentType.binary;
    res.headers.contentLength = await f.length();
    res.headers.set(
      'Content-Disposition',
      "attachment; filename*=UTF-8''${Uri.encodeComponent(name)}",
    );
    await res.addStream(f.openRead());
  }

  Future<void> _receive(HttpRequest req, File dest) async {
    final tmp = File('${dest.path}.part');
    try {
      final sink = tmp.openWrite();
      await sink.addStream(req);
      await sink.close();
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
    } on Object {
      if (await tmp.exists()) await tmp.delete();
      throw const _HttpError(HttpStatus.insufficientStorage, 'Upload failed');
    }
  }

  static FileSystemEntity _entity(String path) =>
      FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);

  static String _safeName(String? raw) {
    final name = (raw ?? '').trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.startsWith('.')) {
      throw const _HttpError(HttpStatus.badRequest, 'Bad file name');
    }
    return name;
  }

  static void _json(HttpResponse res, Object body) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
  }

  static void _error(HttpResponse res, int status, String message) {
    try {
      res.statusCode = status;
      _json(res, {'ok': false, 'message': message});
    } on StateError {
      // Headers already sent (a download failed part way).
    }
  }
}

class _HttpError implements Exception {
  const _HttpError(this.status, this.message);
  final int status;
  final String message;
}
