// SPDX-License-Identifier: GPL-3.0-or-later
// Fake ROM bytes that pass the importer's content check
// (romContentLooksValid, docs/specs/library.md Import item 3).
import 'package:dena_emu/src/library/import_rules.dart';

/// [size] bytes of [fill] (grown to the smallest size the format's header
/// needs) carrying a valid header for [fileName]'s extension. Different
/// [fill] values give different hashes.
List<int> fakeRom(String fileName, {int fill = 0, int size = 64}) {
  final name = fileName.toLowerCase();
  final ext = name.endsWith('.p8.png') ? 'p8.png' : name.split('.').last;
  final min = switch (ext) {
    'gb' || 'gbc' => 0x150,
    'gba' => 0xc0,
    'nds' => 0x200,
    'sfc' || 'smc' => 0x8000,
    'iso' => 0x8800,
    _ => 16,
  };
  final b = List<int>.filled(size < min ? min : size, fill & 0xff);
  void put(int at, List<int> magic) => b.setRange(at, at + magic.length, magic);
  switch (ext) {
    case 'nes':
      put(0, const [0x4e, 0x45, 0x53, 0x1a]);
    case 'gb' || 'gbc':
      var x = 0;
      for (var i = 0x134; i <= 0x14c; i++) {
        x = (x - b[i] - 1) & 0xff;
      }
      b[0x14d] = x;
    case 'gba':
      b[0xb2] = 0x96;
      var chk = 0;
      for (var i = 0xa0; i <= 0xbc; i++) {
        chk = (chk - b[i]) & 0xff;
      }
      b[0xbd] = (chk - 0x19) & 0xff;
    case 'nds':
      put(0x15c, const [0x56, 0xcf]);
    case 'sfc' || 'smc':
      b[0] = 0;
    case 'z64' || 'n64' || 'v64':
      put(0, const [0x80, 0x37, 0x12, 0x40]);
    case 'chd':
      put(0, 'MComprHD'.codeUnits);
    case 'pbp':
      put(0, const [0x00, 0x50, 0x42, 0x50]);
    case 'iso':
      put(0x8001, 'CD001'.codeUnits);
    case 'cso':
      put(0, 'CISO'.codeUnits);
    case 'p8':
      put(0, 'pico-8 cartridge'.codeUnits);
    case 'p8.png':
      put(0, const [0x89, 0x50, 0x4e, 0x47]);
  }
  final system = detectSystem(fileName);
  assert(system == null || romContentLooksValid(system, fileName, b, b.length));
  return b;
}
