// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md (Import item 3)
import 'dart:convert';

import 'package:dena_emu/src/library/import_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_roms.dart';

void main() {
  final text = utf8.encode('Shopping list\nmilk\neggs\n' * 2000);

  bool ok(String name, List<int> bytes) => romContentLooksValid(
    detectSystem(name)!,
    name,
    bytes.length > romHeadLength ? bytes.sublist(0, romHeadLength) : bytes,
    bytes.length,
  );

  test('a text file renamed to any game extension is rejected', () {
    for (final ext in [
      'nes', 'sfc', 'smc', 'gb', 'gbc', 'gba', 'nds', 'z64', 'n64', 'v64', //
      'chd', 'pbp', 'iso', 'cso', 'p8.png',
    ]) {
      expect(ok('notes.$ext', text), isFalse, reason: ext);
    }
  });

  test('an empty file is rejected', () {
    expect(ok('a.nes', const []), isFalse);
    expect(
      romContentLooksValid(GameSystem.genesis, 'a.md', const [], 0),
      isFalse,
    );
  });

  test('NES needs the iNES magic', () {
    expect(ok('a.nes', [0x4e, 0x45, 0x53, 0x1a, 0, 0]), isTrue);
    expect(ok('a.nes', [0x4e, 0x45, 0x53, 0x00, 0, 0]), isFalse);
  });

  test('GB and GBC need a correct header checksum', () {
    for (final ext in ['gb', 'gbc']) {
      final rom = fakeRom('a.$ext', fill: 0x41, size: 0x8000);
      expect(ok('a.$ext', rom), isTrue);
      rom[0x14d] ^= 0xff;
      expect(ok('a.$ext', rom), isFalse);
      expect(ok('a.$ext', rom.sublist(0, 0x140)), isFalse, reason: 'short');
    }
  });

  test('GBA needs 0x96 at 0xB2 and a correct complement', () {
    final rom = fakeRom('a.gba', fill: 0x20, size: 0x400);
    expect(ok('a.gba', rom), isTrue);
    expect(ok('a.gba', [...rom]..[0xbd] ^= 1), isFalse);
    expect(ok('a.gba', [...rom]..[0xb2] = 0), isFalse);
  });

  test('SNES needs 32 KB that is not plain text', () {
    final rom = fakeRom('a.sfc', fill: 0x41);
    expect(ok('a.sfc', rom), isTrue);
    expect(
      ok('a.smc', [...List.filled(512, 0), ...rom]),
      isTrue,
      reason: 'copier header',
    );
    expect(ok('a.sfc', rom.sublist(0, 0x4000)), isFalse, reason: 'small');
    expect(ok('a.sfc', List.filled(0x8000, 0x41)), isFalse, reason: 'text');
  });

  test('N64 accepts all three byte orders', () {
    for (final magic in [
      [0x80, 0x37, 0x12, 0x40],
      [0x37, 0x80, 0x40, 0x12],
      [0x40, 0x12, 0x37, 0x80],
    ]) {
      expect(ok('a.z64', [...magic, ...List.filled(60, 0)]), isTrue);
    }
    expect(ok('a.n64', List.filled(64, 0)), isFalse);
  });

  test('DS needs the header CRC or the logo CRC', () {
    final h = List<int>.generate(0x200, (i) => i * 7 & 0xff);
    expect(ok('a.nds', h), isFalse);
    final crc = crc16Modbus(h.sublist(0, 0x15e));
    final withCrc = [...h]
      ..[0x15e] = crc & 0xff
      ..[0x15f] = crc >> 8;
    expect(ok('a.nds', withCrc), isTrue);
    expect(ok('a.nds', [...h]..setAll(0x15c, [0x56, 0xcf])), isTrue);
  });

  test('CRC-16/MODBUS matches its check value', () {
    expect(crc16Modbus(ascii.encode('123456789')), 0x4b37);
  });

  test('disc images and PICO-8 carts need their magic', () {
    for (final name in [
      'a.chd',
      'a.pbp',
      'a.iso',
      'a.cso',
      'a.p8',
      'a.p8.png',
    ]) {
      expect(ok(name, fakeRom(name, size: 0x9000)), isTrue, reason: name);
      expect(ok(name, List.filled(0x9000, 0)), isFalse, reason: name);
    }
  });
}
