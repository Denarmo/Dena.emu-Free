// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:dena_emu/src/turbo/turbo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('turbo'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('games follow the global setup until overridden', () {
    final store = TurboStore(dir.path);
    expect(store.resolve('g1'), turboOff);
    store.global = (mask: 1 << 8, rate: 30);
    expect(store.resolve('g1'), (mask: 1 << 8, rate: 30));
    store.setGame('g1', (mask: 1, rate: 10));
    expect(store.resolve('g1'), (mask: 1, rate: 10));
    expect(store.resolve('g2'), (mask: 1 << 8, rate: 30));
    store.clearGame('g1');
    expect(store.hasGameOverride('g1'), isFalse);
    expect(store.resolve('g1'), (mask: 1 << 8, rate: 30));
  });

  test('damaged file and bad values fall back safely', () {
    File('${dir.path}/turbo.json').writeAsStringSync('{nope');
    expect(TurboStore(dir.path).global, turboOff);
    File('${dir.path}/turbo.json')
        .writeAsStringSync('{"global":{"mask":65535,"rate":99}}');
    final g = TurboStore(dir.path).global;
    expect(g.rate, defaultTurboRate);
    expect(g.mask, turboButtons.fold<int>(0, (a, b) => a | b.$2));
  });

  test('summary and rates', () {
    expect(turboSummary(turboOff), 'Off');
    expect(turboSummary((mask: (1 << 8) | 1, rate: 15)), 'A, B · 15/s');
    expect(turboHalfFrames(30), 1);
    expect(turboHalfFrames(7), 4);
  });
}
