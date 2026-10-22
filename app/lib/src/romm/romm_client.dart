// SPDX-License-Identifier: GPL-3.0-or-later
// A client for a self-hosted RomM server's REST API (https://github.com/rommapp/romm).
// Spec: docs/specs/romm.md
import 'dart:convert';

import '../net/http.dart'
    show HttpReply, HttpStreamReply, HttpStreamSend, ioHttpStreamSend;

class RommException implements Exception {
  const RommException(this.status, this.message);

  /// HTTP status, or 0 when the server couldn't be reached.
  final int status;
  final String message;

  bool get offline => status == 0;
  bool get unauthorized => status == 401 || status == 403;

  @override
  String toString() => status == 0 ? message : 'HTTP $status: $message';
}

class RommPlatform {
  const RommPlatform({
    required this.id,
    required this.slug,
    required this.name,
    required this.romCount,
  });

  factory RommPlatform.fromJson(Map<String, Object?> j) => RommPlatform(
    id: (j['id'] as num).toInt(),
    slug: (j['slug'] ?? j['fs_slug'] ?? '') as String,
    name:
        (j['display_name'] ?? j['custom_name'] ?? j['name'] ?? j['slug'] ?? '')
            as String,
    romCount: (j['rom_count'] as num?)?.toInt() ?? 0,
  );

  final int id;
  final String slug, name;
  final int romCount;
}

class RommRom {
  const RommRom({
    required this.id,
    required this.platformId,
    required this.name,
    required this.fileName,
    required this.size,
    this.sha1,
    this.crc,
    this.coverPath,
  });

  factory RommRom.fromJson(Map<String, Object?> j) {
    final fileName = (j['fs_name'] ?? j['file_name'] ?? '') as String;
    final name = j['name'] as String?;
    return RommRom(
      id: (j['id'] as num).toInt(),
      platformId: (j['platform_id'] as num?)?.toInt() ?? 0,
      name: name == null || name.isEmpty ? fileName : name,
      fileName: fileName,
      size:
          ((j['fs_size_bytes'] ?? j['file_size_bytes']) as num?)?.toInt() ?? 0,
      sha1: (j['sha1_hash'] as String?)?.toLowerCase(),
      crc: (j['crc_hash'] as String?)?.toLowerCase(),
      coverPath: (j['path_cover_small'] ?? j['url_cover']) as String?,
    );
  }

  final int id, platformId;
  final String name;

  /// The file's name on the server (download path, import name).
  final String fileName;
  final int size;
  final String? sha1, crc;

  /// Server-relative cover path (or an absolute URL), if any.
  final String? coverPath;
}

/// A save or state file stored for a ROM.
class RommFile {
  const RommFile({
    required this.id,
    required this.fileName,
    required this.updatedAt,
    required this.downloadPath,
  });

  factory RommFile.fromJson(Map<String, Object?> j) => RommFile(
    id: (j['id'] as num).toInt(),
    fileName: (j['file_name'] ?? '') as String,
    updatedAt:
        DateTime.tryParse((j['updated_at'] ?? '') as String)?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    downloadPath: (j['download_path'] ?? '') as String,
  );

  final int id;
  final String fileName;
  final DateTime updatedAt;
  final String downloadPath;
}

enum RommKind { saves, states }

/// RomM's API with HTTP Basic auth (which RomM accepts on every endpoint).
class RommClient {
  RommClient({
    required String server,
    required this.username,
    required String password,
    HttpStreamSend? send,
  }) : base = normalizeServer(server),
       _auth = 'Basic ${base64.encode(utf8.encode('$username:$password'))}',
       _send = send ?? ioHttpStreamSend;

  /// Server root without a trailing slash.
  final Uri base;
  final String username;
  final String _auth;
  final HttpStreamSend _send;

  /// Adds `http://` when missing and drops a trailing slash or `/api`.
  static Uri normalizeServer(String server) {
    var s = server.trim();
    if (!s.contains('://')) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('/api')) s = s.substring(0, s.length - 4);
    final u = Uri.parse(s);
    if (u.host.isEmpty) throw const FormatException('No server address');
    return u;
  }

  Uri _url(String path, [Map<String, String>? query]) {
    final full = path.startsWith('/') ? path : '/$path';
    return base.replace(
      path: '${base.path}$full',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  /// Absolute URL of a cover or asset path the API returned.
  Uri asset(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    final clean = path.split('?').first;
    final rel = clean.startsWith('/') ? clean : '/assets/romm/resources/$clean';
    return _url(rel);
  }

  Map<String, String> get authHeader => {'authorization': _auth};

  Future<HttpStreamReply> _open(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    try {
      return await _send(
        method,
        url,
        {...authHeader, 'accept': 'application/json', ...?headers},
        body == null ? null : Stream.value(body),
        body?.length,
      );
    } on Object catch (e) {
      throw RommException(0, "Couldn't reach the RomM server ($e)");
    }
  }

  Future<HttpReply> _call(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final HttpReply r;
    try {
      r = await (await _open(
        method,
        url,
        headers: headers,
        body: body,
      )).buffer();
    } on RommException {
      rethrow;
    } on Object catch (e) {
      throw RommException(0, "Couldn't reach the RomM server ($e)");
    }
    if (r.status < 200 || r.status >= 300) {
      var msg = r.text;
      try {
        final j = r.json;
        if (j is Map && j['detail'] != null) msg = '${j['detail']}';
      } on Object {
        // Not JSON.
      }
      if (msg.length > 200) msg = msg.substring(0, 200);
      throw RommException(r.status, msg);
    }
    return r;
  }

  Future<Object?> _json(String path, [Map<String, String>? query]) async =>
      (await _call('GET', _url(path, query))).json;

  /// Paged lists come back as `{items: [...]}` (RomM 3+) or a bare list.
  static List<Map<String, Object?>> _items(Object? j) {
    final list = j is Map ? (j['items'] ?? const []) : j;
    return [for (final e in (list as List? ?? const [])) (e as Map).cast()];
  }

  /// The signed-in user's name; throws [RommException] on a bad login.
  Future<String> me() async {
    final j = await _json('/api/users/me');
    if (j is! Map) throw const RommException(500, 'Unexpected reply');
    return (j['username'] ?? username) as String;
  }

  Future<List<RommPlatform>> platforms() async => [
    for (final j in _items(await _json('/api/platforms')))
      RommPlatform.fromJson(j),
  ];

  /// Every ROM of [platformId], or of the whole server when null.
  Future<List<RommRom>> roms({int? platformId}) async {
    const page = 500;
    final out = <RommRom>[];
    for (var offset = 0; ; offset += page) {
      final j = await _json('/api/roms', {
        'platform_id': ?platformId?.toString(),
        'limit': '$page',
        'offset': '$offset',
        'order_by': 'name',
      });
      final items = _items(j);
      out.addAll(items.map(RommRom.fromJson));
      final total = j is Map ? (j['total'] as num?)?.toInt() : null;
      // A bare list is the whole result (older servers ignore paging).
      if (j is! Map ||
          items.length < page ||
          (total != null && out.length >= total)) {
        return out;
      }
    }
  }

  /// The ROM's file as a stream.
  Future<HttpStreamReply> download(RommRom rom) async {
    final r = await _open(
      'GET',
      _url('/api/roms/${rom.id}/content/${Uri.encodeComponent(rom.fileName)}'),
      headers: {'accept': '*/*'},
    );
    if (r.status != 200) {
      final b = await r.buffer();
      throw RommException(r.status, b.text);
    }
    return r;
  }

  Future<List<RommFile>> files(RommKind kind, int romId) async => [
    for (final j in _items(
      await _json('/api/${kind.name}', {'rom_id': '$romId'}),
    ))
      RommFile.fromJson(j),
  ];

  Future<List<int>> fetch(RommFile f) async {
    final path = f.downloadPath.isEmpty ? '/api/${f.fileName}' : f.downloadPath;
    final url = path.startsWith('http')
        ? Uri.parse(path)
        : _url(path.split('?').first, Uri.parse(path).queryParameters);
    return (await _call('GET', url, headers: {'accept': '*/*'})).body;
  }

  /// Uploads a save or state; RomM replaces a file with the same name.
  Future<RommFile?> upload(
    RommKind kind,
    int romId,
    String fileName,
    List<int> bytes, {
    String emulator = 'dena-emu',
  }) async {
    final boundary = 'dena${DateTime.now().microsecondsSinceEpoch}';
    // RomM 4 reads `saveFile`/`stateFile`; RomM 3 reads `saves`/`states`.
    final fields = kind == RommKind.saves
        ? ['saveFile', 'saves']
        : ['stateFile', 'states'];
    final safe = fileName.replaceAll('"', '');
    final body = <int>[
      for (final field in fields) ...[
        ...utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="$field"; '
          'filename="$safe"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n',
        ),
        ...bytes,
        ...utf8.encode('\r\n'),
      ],
      ...utf8.encode('--$boundary--\r\n'),
    ];
    final r = await _call(
      'POST',
      _url('/api/${kind.name}', {'rom_id': '$romId', 'emulator': emulator}),
      headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
      body: body,
    );
    final j = r.body.isEmpty ? null : r.json;
    // RomM 4 returns the file; RomM 3 a summary.
    return j is Map && j['id'] is num ? RommFile.fromJson(j.cast()) : null;
  }
}
