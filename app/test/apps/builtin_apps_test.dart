// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dena_emu/src/apps/builtin_apps.dart';
import 'package:dena_emu/src/shell/platform_features.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => hasAndroidShell = true);

  test('the media players need the Android shell', () {
    expect(builtInApps().map((a) => a.id), containsAll(['music', 'video']));
    hasAndroidShell = false;
    expect(builtInApps().map((a) => a.id), isNot(contains('music')));
    expect(builtInApps().map((a) => a.id), isNot(contains('video')));
  });
}
