// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop profile: which shell, where the host library and the files
// are (desktop-shell.md).
import 'package:dena_emu/src/shell/app_dirs.dart';
import 'package:dena_emu/src/shell/host_library.dart';
import 'package:dena_emu/src/shell/platform_features.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectShellProfile', () {
    test('per platform', () {
      expect(detectShellProfile(env: {}, os: 'android'), ShellProfile.android);
      expect(detectShellProfile(env: {}, os: 'windows'), ShellProfile.desktop);
      expect(detectShellProfile(env: {}, os: 'linux'), ShellProfile.desktop);
      expect(
        detectShellProfile(env: {'DENA_HANDHELD': '1'}, os: 'linux'),
        ShellProfile.handheld,
      );
      expect(detectShellProfile(env: {}, os: 'ios'), ShellProfile.none);
    });
  });

  group('hostLibraryPath', () {
    test('Android names its packaged library', () {
      expect(hostLibraryPath(ShellProfile.android), 'libdena_android.so');
    });

    test('Windows: beside the executable', () {
      expect(
        hostLibraryPath(
          ShellProfile.desktop,
          executable: r'C:\Games\Dena.emu\dena_emu.exe',
          os: 'windows',
        ),
        r'C:\Games\Dena.emu\dena_host.dll',
      );
    });

    test("Linux: in the bundle's lib folder", () {
      expect(
        hostLibraryPath(
          ShellProfile.desktop,
          executable: '/app/bin/dena_emu',
          os: 'linux',
        ),
        '/app/bin/lib/libdena_host.so',
      );
    });

    test('the handheld launcher is the process itself', () {
      expect(hostLibraryPath(ShellProfile.handheld), isNull);
    });
  });

  group('desktopRoot', () {
    bool none(String _) => false;

    test('Windows: %APPDATA%\\Dena.emu', () {
      expect(
        desktopRoot(
          env: {'APPDATA': r'C:\Users\d\AppData\Roaming'},
          os: 'windows',
          executable: r'C:\Program Files\Dena.emu\dena_emu.exe',
          exists: none,
        )?.path,
        r'C:\Users\d\AppData\Roaming\Dena.emu',
      );
    });

    test('Linux: XDG data home, else ~/.local/share', () {
      expect(
        desktopRoot(
          env: {'XDG_DATA_HOME': '/home/d/.data', 'HOME': '/home/d'},
          os: 'linux',
          executable: '/opt/dena/dena_emu',
          exists: none,
        )?.path,
        '/home/d/.data/dena.emu',
      );
      expect(
        desktopRoot(
          env: {'HOME': '/home/d'},
          os: 'linux',
          executable: '/opt/dena/dena_emu',
          exists: none,
        )?.path,
        '/home/d/.local/share/dena.emu',
      );
    });

    test("Flatpak: the app's own data folder", () {
      expect(
        desktopRoot(
          env: {
            'FLATPAK_ID': 'io.github.denarmo.DenaEmu',
            'XDG_DATA_HOME': '/home/d/.var/app/io.github.denarmo.DenaEmu/data',
            'HOME': '/home/d',
          },
          os: 'linux',
          executable: '/app/dena_emu',
          exists: none,
        )?.path,
        '/home/d/.var/app/io.github.denarmo.DenaEmu/data',
      );
    });

    test('portable.txt keeps everything in Dena beside the executable', () {
      bool portable(String path) => path == r'E:\Dena.emu\portable.txt';
      expect(
        desktopRoot(
          env: {'APPDATA': r'C:\Users\d\AppData\Roaming'},
          os: 'windows',
          executable: r'E:\Dena.emu\dena_emu.exe',
          exists: portable,
        )?.path,
        r'E:\Dena.emu\Dena',
      );
    });

    test('not on Android or the handheld', () {
      expect(desktopRoot(env: {}, os: 'android'), isNull);
      expect(
        desktopRoot(env: {'DENA_HANDHELD': '1', 'HOME': '/root'}, os: 'linux'),
        isNull,
      );
    });

    test('tests drive the Android UI, so no desktop data folder', () {
      // flutter_test_config.dart sets hasAndroidShell.
      expect(hasAndroidShell, isTrue);
      expect(
        desktopDataDir(env: {'HOME': '/home/d'}, os: 'linux', exists: none),
        isNull,
      );
    });

    test('portable data lives in Dena/user/data, as on the card', () {
      hasAndroidShell = false;
      addTearDown(() => hasAndroidShell = true);
      bool portable(String path) => path == '/media/usb/Dena.emu/portable.txt';
      expect(
        desktopDataDir(
          env: {'HOME': '/home/d'},
          os: 'linux',
          executable: '/media/usb/Dena.emu/dena_emu',
          exists: portable,
        )?.path,
        '/media/usb/Dena.emu/Dena/user/data',
      );
      expect(
        desktopDataDir(
          env: {'HOME': '/home/d'},
          os: 'linux',
          executable: '/opt/dena/dena_emu',
          exists: none,
        )?.path,
        '/home/d/.local/share/dena.emu',
      );
    });
  });
}
