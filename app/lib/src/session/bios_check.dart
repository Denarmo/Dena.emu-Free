// SPDX-License-Identifier: GPL-3.0-or-later
// BIOS files the desktop-only systems read from the Bios folder.
// Spec: docs/specs/dreamcast-saturn.md (BIOS), docs/specs/ps2.md (BIOS)
import 'dart:io';

import 'package:path/path.dart' as p;

import '../shell/app_dirs.dart';

/// Saturn BIOS files Beetle Saturn loads from the Bios folder by the disc's
/// region: Japan, then North America and Europe.
const saturnBiosJapan = 'sega_101.bin';
const saturnBiosWest = 'mpr-17933.bin';

/// The Dreamcast boot ROM Flycast loads from `Bios/dc/`; without it Flycast
/// boots its built-in replacement BIOS.
const dreamcastBios = 'dc_boot.bin';

/// Where LRPS2 looks for PS2 BIOS files, under the Bios folder.
const ps2BiosFolder = ['pcsx2', 'bios'];

/// Common PS2 BIOS file names by region; LRPS2 takes any PS2 BIOS file of
/// 4 to 8 MB in [ps2BiosFolder], whatever its name.
const ps2BiosUs = 'SCPH-70012.bin';
const ps2BiosEurope = 'SCPH-70004.bin';
const ps2BiosJapan = 'SCPH-70000.bin';

const _ps2BiosMin = 4 * 1024 * 1024;
const _ps2BiosMax = 8 * 1024 * 1024;

/// What the Bios folder holds for a game's system.
sealed class BiosCheck {
  const BiosCheck();
}

/// Nothing missing, or the system needs no BIOS.
class BiosReady extends BiosCheck {
  const BiosReady();
}

/// The game can't start: [message] says which files go where.
class BiosMissing extends BiosCheck {
  const BiosMissing(this.message);
  final String message;
}

/// The game starts on the core's replacement BIOS; [message] says how to
/// do better.
class BiosReplaced extends BiosCheck {
  const BiosReplaced(this.message);
  final String message;
}

/// The Bios folder on the desktop (desktop-shell.md, Storage); null
/// elsewhere.
String? desktopBiosDir() {
  final root = desktopRoot();
  return root == null ? null : p.join(root.path, 'Bios');
}

/// Checks [biosDir] for [system]'s BIOS files. [exists] and [fileSizes]
/// (the sizes of the files in a folder) are for tests.
BiosCheck checkBios(
  String system,
  String biosDir, {
  bool Function(String path)? exists,
  Iterable<int> Function(String dir)? fileSizes,
}) {
  final has = exists ?? (String path) => File(path).existsSync();
  switch (system) {
    case 'saturn':
      if (has(p.join(biosDir, saturnBiosWest)) ||
          has(p.join(biosDir, saturnBiosJapan))) {
        return const BiosReady();
      }
      return BiosMissing(saturnBiosMessage(biosDir));
    case 'dreamcast':
      if (has(p.join(biosDir, 'dc', dreamcastBios))) return const BiosReady();
      return BiosReplaced(
        'No Dreamcast BIOS: playing on the built-in one. If a game fails, '
        'put $dreamcastBios from your own console in '
        '${p.join(biosDir, 'dc')}',
      );
    case 'ps2':
      final dir = p.joinAll([biosDir, ...ps2BiosFolder]);
      final sizes = (fileSizes ?? _fileSizes)(dir);
      if (sizes.any((s) => s >= _ps2BiosMin && s <= _ps2BiosMax)) {
        return const BiosReady();
      }
      return BiosMissing(ps2BiosMessage(biosDir));
    default:
      return const BiosReady();
  }
}

/// What a Saturn game needs: the BIOS of its region, dumped from the
/// player's own console. Also the message when a Saturn game fails to start
/// with only the other region's file present.
String saturnBiosMessage(String biosDir) =>
    'Saturn games need the BIOS of their region, dumped from your own '
    'console: $saturnBiosWest (US and Europe) or $saturnBiosJapan (Japan), '
    'in $biosDir';

/// What a PS2 game needs: a BIOS dumped from the player's own console, in
/// the folder LRPS2 reads. Also the hint when a PS2 game fails to start.
String ps2BiosMessage(String biosDir) =>
    'PS2 games need a BIOS dumped from your own console, such as '
    '$ps2BiosUs (US), $ps2BiosEurope (Europe) or $ps2BiosJapan (Japan), '
    'in ${p.joinAll([biosDir, ...ps2BiosFolder])}';

Iterable<int> _fileSizes(String dir) {
  try {
    return [
      for (final e in Directory(dir).listSync())
        if (e is File) e.lengthSync(),
    ];
  } on FileSystemException {
    return const [];
  }
}
