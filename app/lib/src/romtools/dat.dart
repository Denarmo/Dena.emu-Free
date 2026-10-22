// SPDX-License-Identifier: GPL-3.0-or-later
// DAT files: Logiqx XML and ClrMamePro parsing, lookup by hash and name.
// Spec: docs/specs/rom-manager.md
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// One file of a DAT game, with its hashes in lower-case hex.
class DatRom {
  const DatRom({
    required this.name,
    this.size,
    this.crc32,
    this.md5,
    this.sha1,
    this.badDump = false,
  });

  final String name;
  final int? size;
  final String? crc32, md5, sha1;

  /// The DAT marks this dump as bad (`status="baddump"`).
  final bool badDump;
}

/// One game (or machine) of a DAT and its files.
class DatGame {
  const DatGame(this.name, this.roms);

  final String name;
  final List<DatRom> roms;
}

/// A parsed DAT: its header name and version and its games.
class DatFile {
  const DatFile({required this.name, this.version, required this.games});

  /// The header name, such as `Nintendo - Game Boy (Parent-Clone)`.
  final String name;
  final String? version;
  final List<DatGame> games;

  /// Parses Logiqx XML or ClrMamePro text; throws a [FormatException] for
  /// anything else.
  static DatFile parse(String text) {
    final start = text.trimLeft();
    if (start.startsWith('<')) {
      if (_xmlGame.hasMatch(text) || text.contains('<datafile')) {
        return _parseXml(text);
      }
    } else if (_cmpStart.hasMatch(text)) {
      return _parseCmp(text);
    }
    throw const FormatException('Not a DAT file');
  }

  /// Parses a DAT file's bytes; a `.zip` holding one `.dat` or `.xml` is
  /// unpacked first. Text is UTF-8, or Latin-1 when it isn't valid UTF-8.
  static DatFile parseBytes(List<int> bytes) {
    var data = bytes;
    if (data.length >= 4 &&
        data[0] == 0x50 &&
        data[1] == 0x4b &&
        data[2] == 0x03 &&
        data[3] == 0x04) {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(data);
      } on Object {
        throw const FormatException('The zip file is damaged');
      }
      final dats = [
        for (final f in archive.files)
          if (f.isFile &&
              const {
                '.dat',
                '.xml',
              }.contains(p.extension(f.name).toLowerCase()))
            f,
      ];
      if (dats.length != 1) throw const FormatException('Not a DAT file');
      data = dats.single.content;
    }
    String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      text = latin1.decode(data);
    }
    if (text.startsWith('﻿')) text = text.substring(1);
    return parse(text);
  }
}

final _xmlGame = RegExp(r'<(game|machine)\b');
final _cmpStart = RegExp(
  r'^\s*(clrmamepro|game|machine|resource)\s*\(',
  multiLine: true,
);
final _xmlBlock = RegExp(r'<(game|machine)\b([^>]*?)(/>|>([\s\S]*?)</\1\s*>)');
final _xmlRom = RegExp(r'<rom\b([^>]*?)/?>');
final _xmlAttr = RegExp(r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final _xmlHeader = RegExp(r'<header\b[^>]*>([\s\S]*?)</header\s*>');
final _xmlEntity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt);');

String _unescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_xmlEntity, (m) {
    final e = m[1]!;
    return switch (e) {
      'amp' => '&',
      'quot' => '"',
      'apos' => "'",
      'lt' => '<',
      'gt' => '>',
      _ => String.fromCharCode(
        e.startsWith('#x')
            ? int.parse(e.substring(2), radix: 16)
            : int.parse(e.substring(1)),
      ),
    };
  });
}

Map<String, String> _attrs(String s) => {
  for (final m in _xmlAttr.allMatches(s)) m[1]!: _unescape(m[2] ?? m[3]!),
};

String? _xmlTag(String body, String tag) {
  final m = RegExp('<$tag\\b[^>]*>([\\s\\S]*?)</$tag\\s*>').firstMatch(body);
  return m == null ? null : _unescape(m[1]!.trim());
}

String? _hex(String? s) {
  final t = s?.trim().toLowerCase();
  return t == null || t.isEmpty || t == '-' ? null : t;
}

DatRom _rom(Map<String, String> a, {bool badDump = false}) => DatRom(
  name: a['name'] ?? '',
  size: int.tryParse(a['size']?.trim() ?? ''),
  crc32: _hex(a['crc']),
  md5: _hex(a['md5']),
  sha1: _hex(a['sha1']),
  badDump:
      badDump ||
      a['status']?.toLowerCase() == 'baddump' ||
      a['flags']?.toLowerCase() == 'baddump',
);

DatFile _parseXml(String text) {
  final header = _xmlHeader.firstMatch(text)?[1] ?? '';
  final games = <DatGame>[];
  for (final m in _xmlBlock.allMatches(text)) {
    final name = _attrs(m[2]!)['name'] ?? '';
    final body = m[4] ?? '';
    games.add(
      DatGame(name, [
        for (final r in _xmlRom.allMatches(body)) _rom(_attrs(r[1]!)),
      ]),
    );
  }
  return DatFile(
    name: _xmlTag(header, 'name') ?? '',
    version: _xmlTag(header, 'version'),
    games: games,
  );
}

/// A ClrMamePro block: its key/value pairs in order, values being a [String]
/// or a nested block.
typedef _Block = List<(String, Object)>;

DatFile _parseCmp(String text) {
  final top = _CmpReader(text).block(topLevel: true);
  var name = '';
  String? version;
  final games = <DatGame>[];
  for (final (key, value) in top) {
    if (value is! _Block) continue;
    switch (key.toLowerCase()) {
      case 'clrmamepro':
        for (final (k, v) in value) {
          if (v is! String) continue;
          if (k == 'name') name = v;
          if (k == 'version') version = v;
        }
      case 'game' || 'machine' || 'resource':
        var gameName = '';
        final roms = <DatRom>[];
        for (final (k, v) in value) {
          if (k == 'name' && v is String) gameName = v;
          if (k == 'rom' && v is _Block) {
            roms.add(
              _rom({
                for (final (rk, rv) in v)
                  if (rv is String) rk.toLowerCase(): rv,
              }),
            );
          }
        }
        games.add(DatGame(gameName, roms));
    }
  }
  return DatFile(name: name, version: version, games: games);
}

class _CmpReader {
  _CmpReader(this.s);

  final String s;
  var i = 0;

  /// The next token: `(`, `)`, a word or a quoted string; null at the end.
  String? _token({required void Function() quoted}) {
    final n = s.length;
    while (i < n && s.codeUnitAt(i) <= 0x20) {
      i++;
    }
    if (i >= n) return null;
    final c = s.codeUnitAt(i);
    if (c == 0x28 || c == 0x29) {
      i++;
      return c == 0x28 ? '(' : ')';
    }
    if (c == 0x22) {
      final buf = StringBuffer();
      i++;
      while (i < n && s.codeUnitAt(i) != 0x22) {
        if (s.codeUnitAt(i) == 0x5c && i + 1 < n) i++;
        buf.writeCharCode(s.codeUnitAt(i));
        i++;
      }
      i++;
      quoted();
      return buf.toString();
    }
    final from = i;
    while (i < n) {
      final d = s.codeUnitAt(i);
      if (d <= 0x20 || d == 0x28 || d == 0x29) break;
      i++;
    }
    return s.substring(from, i);
  }

  _Block block({bool topLevel = false}) {
    final out = <(String, Object)>[];
    var q = false;
    void quoted() => q = true;
    while (true) {
      q = false;
      final key = _token(quoted: quoted);
      if (key == null) {
        if (!topLevel) throw const FormatException('Not a DAT file');
        return out;
      }
      if (key == ')' && !q) {
        if (topLevel) throw const FormatException('Not a DAT file');
        return out;
      }
      q = false;
      final value = _token(quoted: quoted);
      if (value == null) throw const FormatException('Not a DAT file');
      if (value == '(' && !q) {
        out.add((key, block()));
      } else if (value == ')' && !q) {
        // A lone word before the block ends (e.g. a bare flag).
        out.add((key, ''));
        if (topLevel) throw const FormatException('Not a DAT file');
        return out;
      } else {
        out.add((key, value));
      }
    }
  }
}

/// Fast lookups into a [DatFile] by SHA-1, CRC-32 + size and file name.
class DatIndex {
  DatIndex(this.dat) {
    for (final game in dat.games) {
      _byName.putIfAbsent(game.name.toLowerCase(), () => game);
      for (final rom in game.roms) {
        if (rom.sha1 case final sha1?) {
          _bySha1.putIfAbsent(sha1, () => (game: game, rom: rom));
        }
        if (rom.crc32 case final crc?) {
          (_byCrc[crc] ??= []).add((game: game, rom: rom));
        }
        if (rom.name.isNotEmpty) {
          final stem = p.withoutExtension(rom.name).toLowerCase();
          _byRomName.putIfAbsent(stem, () => game);
        }
      }
    }
  }

  final DatFile dat;
  final _bySha1 = <String, ({DatGame game, DatRom rom})>{};
  final _byCrc = <String, List<({DatGame game, DatRom rom})>>{};
  final _byName = <String, DatGame>{};
  final _byRomName = <String, DatGame>{};

  /// The entry whose SHA-1 is [sha1] (any case).
  ({DatGame game, DatRom rom})? bySha1(String sha1) =>
      _bySha1[sha1.toLowerCase()];

  /// The entry whose CRC-32 is [crc32] (any case) and whose size, when the
  /// DAT gives one, is [size].
  ({DatGame game, DatRom rom})? byCrc(String crc32, int size) {
    for (final e in _byCrc[crc32.toLowerCase()] ?? const []) {
      if (e.rom.size == null || e.rom.size == size) return e;
    }
    return null;
  }

  /// The game [fileName] names: without its extension (or two, as in
  /// `.p8.png`), equal to a game name or a rom name without extension,
  /// ignoring case.
  DatGame? byFileName(String fileName) {
    var stem = p.withoutExtension(p.basename(fileName));
    for (var tries = 0; tries < 2; tries++) {
      final key = stem.toLowerCase();
      final hit = _byName[key] ?? _byRomName[key];
      if (hit != null) return hit;
      if (!_shortExtension.hasMatch(stem)) break;
      stem = p.withoutExtension(stem);
    }
    return null;
  }

  static final _shortExtension = RegExp(r'\.[A-Za-z0-9]{1,4}$');
}
