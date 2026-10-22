// SPDX-License-Identifier: GPL-3.0-or-later
// The game picture per platform (handheld-session.md, desktop-shell.md).
import 'package:dena_android/dena_android.dart';
import 'package:dena_emu/src/desktop/output_size.dart';
import 'package:dena_emu/src/session/session_screen.dart';
import 'package:dena_emu/src/shell/platform_features.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the handheld shows the launcher texture', () {
    final view = defaultGameView(profile: ShellProfile.handheld);
    expect(view, isA<Texture>());
    expect((view as Texture).textureId, handheldGameTexture);
    expect(view.filterQuality, FilterQuality.none);
  });

  test('the desktop shows the runner texture', () {
    final view = defaultGameView(
      profile: ShellProfile.desktop,
      desktopTexture: 42,
    );
    // Inside the size report for shader stacks (shader-stacks.md).
    final texture = (view as DesktopOutputSize).child as Texture;
    expect(texture.textureId, 42);
    expect(texture.filterQuality, FilterQuality.none);
  });

  test('the desktop without its host library shows nothing', () {
    // No dena_host next to the test runner.
    final view = defaultGameView(profile: ShellProfile.desktop);
    expect(((view as DesktopOutputSize).child as Texture).textureId, -1);
  });

  test('Android shows the SurfaceView', () {
    expect(
      defaultGameView(profile: ShellProfile.android),
      isA<EmulatorSurfaceView>(),
    );
  });
}
