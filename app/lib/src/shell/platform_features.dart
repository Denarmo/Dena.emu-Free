// SPDX-License-Identifier: GPL-3.0-or-later
// Which platform host the app runs on. Spec: docs/specs/handheld-session.md,
// desktop-shell.md
import 'dart:io';

/// Whether the Android shell is there to answer the `dena_android` Pigeon
/// host APIs (file picker, share sheet, shortcuts, PDF raster, media,
/// sign-in, background work). False on the Linux handheld, whose embedder
/// only answers GameHostApi, so the app must not call the others there.
///
/// Tests on a desktop host set it to true to drive the Android-only UI with
/// fakes (test/flutter_test_config.dart).
bool hasAndroidShell = Platform.isAndroid;

/// The platform layer the app runs on (desktop-shell.md, Profiles).
enum ShellProfile {
  /// The Kotlin shell on Android.
  android,

  /// The SD-card launcher on a Linux handheld (`DENA_HANDHELD=1`), with its
  /// own embedder (handheld-session.md).
  handheld,

  /// The stock Flutter Windows or Linux runner on a PC or Steam Deck, with
  /// the desktop host library (dena_host.dll / libdena_host.so).
  desktop,

  /// Anything else (iOS before its shell, macOS): no native host.
  none,
}

/// The profile for this process. [env] and [os] are for tests.
ShellProfile detectShellProfile({Map<String, String>? env, String? os}) {
  final vars = env ?? Platform.environment;
  switch (os ?? Platform.operatingSystem) {
    case 'android':
      return ShellProfile.android;
    case 'linux':
      return vars['DENA_HANDHELD'] == '1'
          ? ShellProfile.handheld
          : ShellProfile.desktop;
    case 'windows':
      return ShellProfile.desktop;
    default:
      return ShellProfile.none;
  }
}

/// This process's profile.
final ShellProfile shellProfile = detectShellProfile();
