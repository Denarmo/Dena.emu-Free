// SPDX-License-Identifier: GPL-3.0-or-later
// A small QR code encoder for the web file manager's address, written from
// the public QR code specification (ISO/IEC 18004): byte mode, error
// correction level M, versions 1 to 10 (up to 213 bytes). No dependency.
// Spec: docs/specs/web-file-manager.md, brutalist-ui.md (4.9)
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

/// A QR code symbol: [size] x [size] modules, dark where [dark] is true.
class QrCode {
  QrCode._(this.version, this.mask, this._modules) : size = version * 4 + 17;

  final int version;
  final int mask;
  final int size;
  final List<bool> _modules;

  /// Whether the module at column [x], row [y] is dark.
  bool dark(int x, int y) => _modules[y * size + x];

  /// Encodes [text] as UTF-8 at level M in the smallest version that fits.
  /// [version] and [mask] force those choices (tests). Throws
  /// [ArgumentError] when the text is longer than version 10 holds.
  factory QrCode.encode(String text, {int? version, int? mask}) {
    final data = utf8.encode(text);
    var v = version ?? 1;
    while (v <= 10 && data.length > _capacity(v)) {
      if (version != null) break;
      v++;
    }
    if (v > 10 || data.length > _capacity(v)) {
      throw ArgumentError('Text too long for a QR code: ${data.length} bytes');
    }
    final codewords = _addEcc(_dataCodewords(data, v), v);
    final m = _Matrix(v);
    m.drawFunctionPatterns();
    m.drawCodewords(codewords);
    var best = mask ?? -1;
    if (best < 0) {
      var lowest = 1 << 30;
      for (var k = 0; k < 8; k++) {
        m.applyMask(k);
        m.drawFormat(k);
        final p = m.penalty();
        if (p < lowest) {
          lowest = p;
          best = k;
        }
        m.applyMask(k); // XOR again undoes it.
      }
    }
    m.applyMask(best);
    m.drawFormat(best);
    return QrCode._(v, best, m.modules);
  }

  // Level M blocks per version: (ecc per block, [(blocks, data per block)]).
  static const _blocks = <(int, List<(int, int)>)>[
    (10, [(1, 16)]),
    (16, [(1, 28)]),
    (26, [(1, 44)]),
    (18, [(2, 32)]),
    (24, [(2, 43)]),
    (16, [(4, 27)]),
    (18, [(4, 31)]),
    (22, [(2, 38), (2, 39)]),
    (22, [(3, 36), (2, 37)]),
    (26, [(4, 43), (1, 44)]),
  ];

  static int _dataLength(int v) =>
      [for (final (n, k) in _blocks[v - 1].$2) n * k].reduce((a, b) => a + b);

  /// Bytes that fit in version [v] (mode and count headers taken off).
  static int _capacity(int v) =>
      (_dataLength(v) * 8 - 4 - (v < 10 ? 8 : 16)) ~/ 8;

  static List<int> _dataCodewords(List<int> data, int v) {
    final bits = <bool>[];
    void put(int value, int length) {
      for (var i = length - 1; i >= 0; i--) {
        bits.add((value >> i) & 1 == 1);
      }
    }

    put(0x4, 4); // Byte mode.
    put(data.length, v < 10 ? 8 : 16);
    for (final b in data) {
      put(b, 8);
    }
    final capacity = _dataLength(v) * 8;
    put(0, (capacity - bits.length).clamp(0, 4)); // Terminator.
    while (bits.length % 8 != 0) {
      bits.add(false);
    }
    final out = <int>[
      for (var i = 0; i < bits.length; i += 8)
        bits
            .sublist(i, i + 8)
            .fold(0, (acc, bit) => (acc << 1) | (bit ? 1 : 0)),
    ];
    for (var pad = 0xEC; out.length < _dataLength(v); pad ^= 0xEC ^ 0x11) {
      out.add(pad);
    }
    return out;
  }

  /// Splits [data] into blocks, adds Reed-Solomon codewords and interleaves.
  static List<int> _addEcc(List<int> data, int v) {
    final (ecc, groups) = _blocks[v - 1];
    final gen = _generator(ecc);
    final dataBlocks = <List<int>>[];
    final eccBlocks = <List<int>>[];
    var at = 0;
    for (final (n, k) in groups) {
      for (var i = 0; i < n; i++) {
        final block = data.sublist(at, at + k);
        at += k;
        dataBlocks.add(block);
        eccBlocks.add(_remainder(block, gen));
      }
    }
    final longest = dataBlocks
        .map((b) => b.length)
        .reduce((a, b) => a > b ? a : b);
    return [
      for (var i = 0; i < longest; i++)
        for (final b in dataBlocks)
          if (i < b.length) b[i],
      for (var i = 0; i < ecc; i++)
        for (final b in eccBlocks) b[i],
    ];
  }

  static final _exp = Uint8List(512);
  static final _log = Uint8List(256);
  static bool _tables = false;

  static void _buildTables() {
    if (_tables) return;
    var x = 1;
    for (var i = 0; i < 255; i++) {
      _exp[i] = x;
      _log[x] = i;
      x <<= 1;
      if (x & 0x100 != 0) x ^= 0x11D;
    }
    for (var i = 255; i < 512; i++) {
      _exp[i] = _exp[i - 255];
    }
    _tables = true;
  }

  static int _mul(int a, int b) =>
      a == 0 || b == 0 ? 0 : _exp[_log[a] + _log[b]];

  /// The generator polynomial with roots α^0..α^(degree-1), highest term
  /// first without its leading 1.
  static List<int> _generator(int degree) {
    _buildTables();
    var poly = <int>[1];
    for (var i = 0; i < degree; i++) {
      final next = List<int>.filled(poly.length + 1, 0);
      for (var j = 0; j < poly.length; j++) {
        next[j] ^= poly[j];
        next[j + 1] ^= _mul(poly[j], _exp[i]);
      }
      poly = next;
    }
    return poly.sublist(1);
  }

  static List<int> _remainder(List<int> data, List<int> gen) {
    final rem = List<int>.filled(gen.length, 0, growable: true);
    for (final b in data) {
      final factor = b ^ rem.first;
      rem
        ..removeAt(0)
        ..add(0);
      for (var i = 0; i < gen.length; i++) {
        rem[i] ^= _mul(gen[i], factor);
      }
    }
    return rem;
  }
}

class _Matrix {
  _Matrix(this.version)
    : size = version * 4 + 17,
      modules = List.filled((version * 4 + 17) * (version * 4 + 17), false),
      reserved = List.filled((version * 4 + 17) * (version * 4 + 17), false);

  final int version;
  final int size;
  final List<bool> modules;

  /// Function patterns: never masked or written with data.
  final List<bool> reserved;

  bool get(int x, int y) => modules[y * size + x];

  void set(int x, int y, bool dark) {
    modules[y * size + x] = dark;
    reserved[y * size + x] = true;
  }

  static const _align = <List<int>>[
    [],
    [6, 18],
    [6, 22],
    [6, 26],
    [6, 30],
    [6, 34],
    [6, 22, 38],
    [6, 24, 42],
    [6, 26, 46],
    [6, 28, 50],
  ];

  void drawFunctionPatterns() {
    for (var i = 0; i < size; i++) {
      set(6, i, i.isEven);
      set(i, 6, i.isEven);
    }
    _finder(3, 3);
    _finder(size - 4, 3);
    _finder(3, size - 4);
    final centres = _align[version - 1];
    for (final cy in centres) {
      for (final cx in centres) {
        final corner =
            (cx == 6 && cy == 6) ||
            (cx == 6 && cy == centres.last) ||
            (cx == centres.last && cy == 6);
        if (!corner) _alignment(cx, cy);
      }
    }
    drawFormat(0); // Reserves the format areas; redrawn with the mask.
    _versionInfo();
  }

  void _finder(int cx, int cy) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= size || y >= size) continue;
        final d = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        set(x, y, d != 2 && d != 4);
      }
    }
  }

  void _alignment(int cx, int cy) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final d = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        set(cx + dx, cy + dy, d != 1);
      }
    }
  }

  /// The 15 format bits (level M, [mask]) around the finders.
  void drawFormat(int mask) {
    final data = (0 << 3) | mask; // Level M is 00.
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = ((data << 10) | rem) ^ 0x5412;
    bool bit(int i) => (bits >> i) & 1 == 1;
    for (var i = 0; i <= 5; i++) {
      set(8, i, bit(i));
    }
    set(8, 7, bit(6));
    set(8, 8, bit(7));
    set(7, 8, bit(8));
    for (var i = 9; i < 15; i++) {
      set(14 - i, 8, bit(i));
    }
    for (var i = 0; i < 8; i++) {
      set(size - 1 - i, 8, bit(i));
    }
    for (var i = 8; i < 15; i++) {
      set(8, size - 15 + i, bit(i));
    }
    set(8, size - 8, true); // The dark module.
  }

  void _versionInfo() {
    if (version < 7) return;
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final bits = (version << 12) | rem;
    for (var i = 0; i < 18; i++) {
      final dark = (bits >> i) & 1 == 1;
      final a = size - 11 + i % 3, b = i ~/ 3;
      set(a, b, dark);
      set(b, a, dark);
    }
  }

  /// Fills the data area in the two-column zigzag from the bottom right.
  void drawCodewords(List<int> codewords) {
    var i = 0;
    final total = codewords.length * 8;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = ((right + 1) & 2) == 0;
          final y = upward ? size - 1 - vert : vert;
          if (reserved[y * size + x]) continue;
          if (i < total) {
            modules[y * size + x] =
                (codewords[i >> 3] >> (7 - (i & 7))) & 1 == 1;
            i++;
          }
        }
      }
    }
  }

  static bool _masked(int mask, int x, int y) => switch (mask) {
    0 => (x + y) % 2 == 0,
    1 => y % 2 == 0,
    2 => x % 3 == 0,
    3 => (x + y) % 3 == 0,
    4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
    5 => x * y % 2 + x * y % 3 == 0,
    6 => (x * y % 2 + x * y % 3) % 2 == 0,
    _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
  };

  void applyMask(int mask) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (!reserved[y * size + x] && _masked(mask, x, y)) {
          modules[y * size + x] = !modules[y * size + x];
        }
      }
    }
  }

  /// The specification's penalty score; the lowest mask wins.
  int penalty() {
    var score = 0;
    // Runs of five or more in a row or column, and finder-like patterns.
    for (final horizontal in [true, false]) {
      for (var a = 0; a < size; a++) {
        var run = 0;
        bool? colour;
        final line = <bool>[];
        for (var b = 0; b < size; b++) {
          final dark = horizontal ? get(b, a) : get(a, b);
          line.add(dark);
          if (dark == colour) {
            run++;
            if (run == 5) score += 3;
            if (run > 5) score++;
          } else {
            colour = dark;
            run = 1;
          }
        }
        score += 40 * _finderLike(line);
      }
    }
    // 2x2 blocks of one colour.
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final c = get(x, y);
        if (c == get(x + 1, y) &&
            c == get(x, y + 1) &&
            c == get(x + 1, y + 1)) {
          score += 3;
        }
      }
    }
    // Balance of dark and light.
    final dark = modules.where((m) => m).length;
    final percent = dark * 100 ~/ modules.length;
    score += 10 * ((percent - 50).abs() ~/ 5);
    return score;
  }

  /// `1011101` with four light modules on either side (light outside the
  /// symbol counts).
  static int _finderLike(List<bool> line) {
    const core = [true, false, true, true, true, false, true];
    bool at(int i) => i >= 0 && i < line.length && line[i];
    var n = 0;
    for (var i = 0; i + 7 <= line.length; i++) {
      var match = true;
      for (var k = 0; k < 7 && match; k++) {
        if (line[i + k] != core[k]) match = false;
      }
      if (!match) continue;
      final before = [for (var k = 1; k <= 4; k++) at(i - k)].every((d) => !d);
      final after = [for (var k = 0; k < 4; k++) at(i + 7 + k)]
          .every((d) => !d);
      if (before || after) n++;
    }
    return n;
  }
}

/// Paints a [QrCode] with square modules and a 4-module quiet zone,
/// [dark] on [light].
class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    required this.code,
    required this.dark,
    required this.light,
    this.size = 160,
    this.semanticLabel,
  });

  final QrCode code;
  final Color dark;
  final Color light;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: semanticLabel,
    child: CustomPaint(
      size: Size.square(size),
      painter: _QrPainter(code, dark, light),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code, this.dark, this.light);

  final QrCode code;
  final Color dark;
  final Color light;

  @override
  void paint(Canvas canvas, Size size) {
    final cells = code.size + 8;
    // Whole pixels per module so no module blurs.
    final unit = (size.shortestSide / cells).floorToDouble().clamp(1.0, 64.0);
    final origin = (size.shortestSide - unit * cells) / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = light);
    final paint = Paint()
      ..color = dark
      ..isAntiAlias = false;
    for (var y = 0; y < code.size; y++) {
      for (var x = 0; x < code.size; x++) {
        if (!code.dark(x, y)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            origin + (x + 4) * unit,
            origin + (y + 4) * unit,
            unit,
            unit,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) =>
      old.code != code || old.dark != dark || old.light != light;
}
