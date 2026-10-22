// SPDX-License-Identifier: GPL-3.0-or-later
// Where the app keeps its files. Spec: docs/specs/handheld-session.md
// (Storage), desktop-shell.md (Storage) and sd-card.md (layout).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'platform_features.dart';

/// The app's data folder on a handheld: `<card>/Dena/user/data`, which
/// survives updates (sd-card.md). Null off the handheld, or when the
/// launcher did not say where the card is (`DENA_CARD`).
///
/// The handheld has no XDG user folders (no `xdg-user-dir`, often no HOME),
/// so path_provider's documents folder throws there; every store uses this
/// folder instead.
Directory? handheldDataDir([Map<String, String>? env]) {
  final vars = env ?? Platform.environment;
  if (!Platform.isLinux || vars['DENA_HANDHELD'] != '1') return null;
  final card = vars['DENA_CARD'];
  if (card == null || card.isEmpty) return null;
  return Directory(p.join(card, 'Dena', 'user', 'data'));
}

/// The desktop storage root (desktop-shell.md, Storage): `Bios/`,
/// `Screenshots/`, `cores/` (cores the user adds) and `logs/` live in it.
///
/// - Portable mode, a `portable.txt` beside the executable: `<exe dir>/Dena`.
/// - Windows: `%APPDATA%\Dena.emu`.
/// - Flatpak (`FLATPAK_ID`): `$XDG_DATA_HOME`, the app's own
///   `~/.var/app/<id>/data`.
/// - Other Linux: `$XDG_DATA_HOME/dena.emu`, else `~/.local/share/dena.emu`.
///
/// Null off the desktop profile, or when no folder can be found. [env],
/// [os], [executable] and [exists] are for tests.
Directory? desktopRoot({
  Map<String, String>? env,
  String? os,
  String? executable,
  bool Function(String path)? exists,
}) => _desktopStorage(env, os, executable, exists)?.root;

/// The app's data folder on the desktop: the [desktopRoot] itself, or
/// `Dena/user/data` in portable mode (the SD card's layout). Null off the
/// desktop, and in tests, which drive the Android UI ([hasAndroidShell]).
Directory? desktopDataDir({
  Map<String, String>? env,
  String? os,
  String? executable,
  bool Function(String path)? exists,
}) {
  if (hasAndroidShell) return null;
  final storage = _desktopStorage(env, os, executable, exists);
  if (storage == null) return null;
  return storage.portable
      ? Directory(storage.context.join(storage.root.path, 'user', 'data'))
      : storage.root;
}

/// The portable build's `Dena/Roms` (sd-card.md layout): always one of the
/// watched game folders (desktop-library.md). Null when not portable.
Directory? desktopRomsDir({
  Map<String, String>? env,
  String? os,
  String? executable,
  bool Function(String path)? exists,
}) {
  if (hasAndroidShell) return null;
  final storage = _desktopStorage(env, os, executable, exists);
  if (storage == null || !storage.portable) return null;
  return Directory(storage.context.join(storage.root.path, 'Roms'));
}

({Directory root, bool portable, p.Context context})? _desktopStorage(
  Map<String, String>? env,
  String? os,
  String? executable,
  bool Function(String path)? exists,
) {
  final system = os ?? Platform.operatingSystem;
  final vars = env ?? Platform.environment;
  if (detectShellProfile(env: vars, os: system) != ShellProfile.desktop) {
    return null;
  }
  final ctx = system == 'windows' ? p.windows : p.posix;
  ({Directory root, bool portable, p.Context context}) at(
    String path, {
    bool portable = false,
  }) => (root: Directory(path), portable: portable, context: ctx);

  final exeDir = ctx.dirname(executable ?? Platform.resolvedExecutable);
  final isFile = exists ?? (String path) => File(path).existsSync();
  if (isFile(ctx.join(exeDir, 'portable.txt'))) {
    return at(ctx.join(exeDir, 'Dena'), portable: true);
  }
  if (system == 'windows') {
    final appData = vars['APPDATA'];
    return appData == null || appData.isEmpty
        ? null
        : at(ctx.join(appData, 'Dena.emu'));
  }
  final xdg = vars['XDG_DATA_HOME'] ?? '';
  if (xdg.isNotEmpty) {
    // In the Flatpak this is already the app's own folder.
    final flatpak = vars['FLATPAK_ID']?.isNotEmpty ?? false;
    return at(flatpak ? xdg : ctx.join(xdg, 'dena.emu'));
  }
  final home = vars['HOME'] ?? '';
  return home.isEmpty
      ? null
      : at(ctx.join(home, '.local', 'share', 'dena.emu'));
}

Directory? _cached;

/// The folder for the library database, settings, skins, art and the other
/// stores: app-private support storage on Android and iOS, the card on a
/// handheld, [desktopDataDir] on a PC. Created if missing.
Future<Directory> appDataDir() async {
  final cached = _cached;
  if (cached != null) return cached;
  final dir =
      handheldDataDir() ??
      desktopDataDir() ??
      await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return _cached = dir;
}

/// Where the library database lives when it isn't the platform default: the
/// data folder on a handheld or a PC. Null elsewhere, so Android keeps its
/// database where earlier versions put it.
Directory? libraryDatabaseDir([Map<String, String>? env]) =>
    handheldDataDir(env) ?? (env == null ? desktopDataDir() : null);
