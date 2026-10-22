// SPDX-License-Identifier: GPL-3.0-or-later
// The QR encoder against reference symbols from an independent encoder
// (python-qrcode 8, level M, byte mode, mask forced).
// Spec: docs/specs/web-file-manager.md
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/webfiles/qr_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = (jsonDecode(
    File('test/webfiles/qr_reference.json').readAsStringSync(),
  ) as List).cast<Map<String, dynamic>>();

  for (final c in cases) {
    final text = c['text'] as String;
    final mask = c['mask'] as int;
    final short = text.length > 24 ? '${text.substring(0, 24)}…' : text;
    test('matches the reference: "$short" mask $mask', () {
      final code = QrCode.encode(text, mask: mask);
      expect(code.version, c['version']);
      final rows = [
        for (var y = 0; y < code.size; y++)
          [for (var x = 0; x < code.size; x++) code.dark(x, y) ? '1' : '0']
              .join(),
      ];
      expect(rows, c['rows']);
    });
  }

  test('picks the smallest version and a mask by itself', () {
    final code = QrCode.encode('http://192.168.1.20:8080');
    expect(code.version, 2);
    expect(code.mask, inInclusiveRange(0, 7));
  });

  test('refuses text longer than version 10 holds', () {
    expect(() => QrCode.encode('z' * 214), throwsArgumentError);
    expect(QrCode.encode('z' * 213).version, 10);
  });
}
