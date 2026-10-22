// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md (Import)

/// Pure import rules from the game-library spec (docs/specs/library.md,
/// "Import" items 1, 2 and 4).
///
/// Everything here is a pure function over file names (and, for `.bin`, a byte
/// header) so it has no Flutter or I/O dependencies and can run inside the
/// background import isolate and be unit tested in isolation.
library;

/// A console system the library can import.
enum GameSystem {
  nes,
  snes,
  gb,
  gbc,
  gba,
  nds,
  psx,
  n64,
  psp,
  ps2,
  saturn,
  dreamcast,
  gamecube,
  wii,
  pico8,
  genesis;

  /// Stable identifier persisted in the database; equal to the enum name.
  String get id => name;

  /// Short label shown on the box-art placeholder and filter chips.
  String get shortName => switch (this) {
    GameSystem.nes => 'NES',
    GameSystem.snes => 'SNES',
    GameSystem.gb => 'GB',
    GameSystem.gbc => 'GBC',
    GameSystem.gba => 'GBA',
    GameSystem.nds => 'DS',
    GameSystem.psx => 'PS1',
    GameSystem.n64 => 'N64',
    GameSystem.psp => 'PSP',
    GameSystem.ps2 => 'PS2',
    GameSystem.saturn => 'Saturn',
    GameSystem.dreamcast => 'Dreamcast',
    GameSystem.gamecube => 'GameCube',
    GameSystem.wii => 'Wii',
    GameSystem.pico8 => 'PICO-8',
    GameSystem.genesis => 'Genesis',
  };

  /// Whether a core ships for this system. Genesis is recognised but has no
  /// core yet (deferred by the user, docs/specs/m2-plan.md), so it can't be
  /// imported and has no skin.
  bool get playable => this != GameSystem.genesis;

  /// Whether the system's core is built for Windows and SteamOS only
  /// (dreamcast-saturn.md, ps2.md, gamecube-wii.md): Beetle Saturn, Flycast,
  /// LRPS2 and Dolphin have no Android, handheld or iOS build.
  bool get desktopOnly => switch (this) {
    GameSystem.saturn ||
    GameSystem.dreamcast ||
    GameSystem.ps2 ||
    GameSystem.gamecube ||
    GameSystem.wii => true,
    _ => false,
  };

  /// Whether games of this system can be added and played here: [playable],
  /// and on the [desktop] for the desktop-only systems.
  bool playableOn({required bool desktop}) =>
      playable && (desktop || !desktopOnly);
}

/// What a disc image's own bytes say it is (dreamcast-saturn.md, Library).
///
/// Saturn and Dreamcast discs start their first data sector with the ASCII
/// IDs `SEGA SEGASATURN` and `SEGA SEGAKATANA`: at offset 0 in a 2048-byte
/// sector image, at 0x10 after the sync header of a raw 2352-byte one.
/// Returns null for anything else (PlayStation discs carry no such ID).
GameSystem? discSystemFromHeader(List<int> header) {
  for (final at in const [0, 0x10]) {
    if (_hasAscii(header, at, 'SEGA SEGASATURN')) return GameSystem.saturn;
    if (_hasAscii(header, at, 'SEGA SEGAKATANA')) return GameSystem.dreamcast;
  }
  return null;
}

/// What a GameCube or Wii image's first bytes say it is (gamecube-wii.md,
/// Library), for [ext] (lower case, no dot): a plain disc (`iso`, `gcm`)
/// by the magic word at 0x1C (GameCube) or 0x18 (Wii); `ciso` the same
/// after its 0x8000-byte block map; `gcz` by its sub-type; `wia`/`rvz` by
/// the disc type in their second header; `wbfs` is always Wii. Null when
/// the bytes don't match, so an `.iso` that says neither is a PSP disc.
GameSystem? nintendoDiscFromHeader(List<int> head, String ext) {
  GameSystem? plain(int at) {
    if (_matchesAt(head, at + 0x1c, const [0xc2, 0x33, 0x9f, 0x3d])) {
      return GameSystem.gamecube;
    }
    if (_matchesAt(head, at + 0x18, const [0x5d, 0x1c, 0x9e, 0xa3])) {
      return GameSystem.wii;
    }
    return null;
  }

  switch (ext) {
    case 'iso' || 'gcm':
      return plain(0);
    case 'ciso':
      return _startsWith(head, 'CISO'.codeUnits) ? plain(0x8000) : null;
    case 'gcz':
      if (!_startsWith(head, const [0x01, 0xc0, 0x0b, 0xb1]) ||
          head.length < 8) {
        return null;
      }
      return switch (head[4] | head[5] << 8 | head[6] << 16 | head[7] << 24) {
        0 => GameSystem.gamecube,
        1 => GameSystem.wii,
        _ => null,
      };
    case 'wia' || 'rvz':
      final magic = ext == 'wia' ? 'WIA' : 'RVZ';
      if (!_startsWith(head, [...magic.codeUnits, 0x01]) ||
          head.length < 0x4c) {
        return null;
      }
      return switch (head[0x48] << 24 |
          head[0x49] << 16 |
          head[0x4a] << 8 |
          head[0x4b]) {
        1 => GameSystem.gamecube,
        2 => GameSystem.wii,
        _ => null,
      };
    case 'wbfs':
      return _startsWith(head, 'WBFS'.codeUnits) ? GameSystem.wii : null;
    default:
      return null;
  }
}

/// The system a folder name stands for, for disc images whose bytes don't
/// tell (a Saturn `.chd` looks like a PlayStation one without decompressing
/// it): `Saturn`, `Sega Saturn`, `ss` / `Dreamcast`, `dc` / `PS1`, `psx`,
/// `PlayStation` / `PS2`, `PlayStation 2` / `PSP` (a DVD `.chd` is PS2
/// elsewhere). Case and `_`/`-` don't matter.
GameSystem? systemFromFolderName(String folder) {
  final key = folder.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), ' ').trim();
  return switch (key) {
    'saturn' || 'sega saturn' || 'ss' => GameSystem.saturn,
    'dreamcast' || 'sega dreamcast' || 'dc' => GameSystem.dreamcast,
    'gamecube' ||
    'nintendo gamecube' ||
    'gc' ||
    'gcn' ||
    'ngc' => GameSystem.gamecube,
    'wii' || 'nintendo wii' => GameSystem.wii,
    'ps2' ||
    'playstation 2' ||
    'playstation2' ||
    'sony playstation 2' => GameSystem.ps2,
    'psx' ||
    'ps1' ||
    'playstation' ||
    'sony playstation' ||
    'playstation 1' => GameSystem.psx,
    'psp' ||
    'playstation portable' ||
    'sony playstation portable' => GameSystem.psp,
    _ => null,
  };
}

/// The nearest of [path]'s parent folders (up to three levels up) that names
/// a disc system, by [systemFromFolderName]; null when none does.
GameSystem? systemFromFolders(String path) {
  final parts = path.split(RegExp(r'[/\\]'))..removeLast();
  for (var i = parts.length - 1; i >= 0 && i >= parts.length - 3; i--) {
    final s = systemFromFolderName(parts[i]);
    if (s != null) return s;
  }
  return null;
}

/// Wii when one of [path]'s folders says so (`Wii/`), else null: the
/// system of a `.dol` or `.elf` homebrew file, GameCube by default
/// (gamecube-wii.md, Library). Other systems' folders don't count.
GameSystem? homebrewSystemFromFolders(String path) {
  final s = systemFromFolders(path);
  return s == GameSystem.wii || s == GameSystem.gamecube ? s : null;
}

/// Reads [count] 2048-byte data sectors of a disc image from sector [lba]
/// (fewer or none past its end).
typedef DiscSectorReader = Future<List<int>> Function(int lba, int count);

/// What a disc's ISO 9660 file system says it is (ps2.md, Library): its
/// `SYSTEM.CNF` boots with `BOOT2` on a PS2 disc and `BOOT` on a PS1 one; a
/// volume whose system identifier is `PSP GAME` is a UMD. Null when the
/// image has no readable ISO 9660 volume or says none of these.
Future<GameSystem?> discSystemFromIso(DiscSectorReader read) async {
  final pvd = await read(16, 1);
  if (!_hasAscii(pvd, 1, 'CD001') || pvd.length < 190) return null;
  if (_hasAscii(pvd, 8, 'PSP GAME')) return GameSystem.psp;
  final cnf = await _isoRootFile(read, pvd, 'SYSTEM.CNF');
  if (cnf != null) {
    final text = String.fromCharCodes(cnf).toUpperCase();
    if (RegExp(r'^\s*BOOT2\s*=', multiLine: true).hasMatch(text)) {
      return GameSystem.ps2;
    }
    if (RegExp(r'^\s*BOOT\s*=', multiLine: true).hasMatch(text)) {
      return GameSystem.psx;
    }
  }
  return null;
}

/// The contents of the file [name] in the root directory the primary volume
/// descriptor [pvd] points at, up to one sector; null when it isn't there.
Future<List<int>?> _isoRootFile(
  DiscSectorReader read,
  List<int> pvd,
  String name,
) async {
  // The root directory record sits at 156: extent at +2, length at +10.
  final rootLba = _le32(pvd, 156 + 2);
  final rootSize = _le32(pvd, 156 + 10);
  // A root of more than a few sectors is not a game disc's.
  final sectors = ((rootSize + 2047) ~/ 2048).clamp(1, 8);
  final dir = await read(rootLba, sectors);
  var at = 0;
  while (at + 33 < dir.length) {
    final len = dir[at];
    if (len == 0) {
      // Records never cross a sector: the rest of this one is padding.
      at = (at ~/ 2048 + 1) * 2048;
      continue;
    }
    if (at + len > dir.length) break;
    final nameLen = dir[at + 32];
    if (at + 33 + nameLen <= dir.length) {
      final entry = String.fromCharCodes(
        dir.sublist(at + 33, at + 33 + nameLen),
      ).toUpperCase();
      if (entry == name || entry.startsWith('$name;')) {
        final size = _le32(dir, at + 10).clamp(0, 2048);
        final data = await read(_le32(dir, at + 2), 1);
        return data.length < size ? data : data.sublist(0, size);
      }
    }
    at += len;
  }
  return null;
}

int _le32(List<int> b, int at) => b.length < at + 4
    ? 0
    : b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;

/// Where the 2048 data bytes of each sector start in a raw 2352-byte CD
/// track, from its first sector's sync header and mode byte: 16 for Mode 1,
/// 24 for Mode 2 (PlayStation discs); null when [head] is no raw sector.
int? rawSectorDataOffset(List<int> head) {
  const sync = [0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0];
  if (!_matchesAt(head, 0, sync) || head.length < 16) return null;
  return switch (head[15]) {
    1 => 16,
    2 => 24,
    _ => null,
  };
}

/// The first track file a `.cue` or `.gdi` sheet names, or null.
///
/// Cue sheets: the first `FILE "name" BINARY` line (quotes optional). GDI:
/// line 2, `1 <lba> <type> <sector size> <file> <offset>`, the file name
/// quoted when it has spaces.
String? firstTrackFile(String sheet, {required bool gdi}) {
  final lines = sheet.split(RegExp(r'\r?\n'));
  if (gdi) {
    for (final line in lines.skip(1)) {
      final m = RegExp(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+("([^"]+)"|(\S+))')
          .firstMatch(line);
      if (m != null) return m[2] ?? m[3];
    }
    return null;
  }
  for (final line in lines) {
    final m = RegExp(
      r'^\s*FILE\s+("([^"]+)"|(\S+))',
      caseSensitive: false,
    ).firstMatch(line);
    if (m != null) return m[2] ?? m[3];
  }
  return null;
}

/// Every track file a `.cue` [sheet] names, in order and without repeats:
/// the `FILE "name" <type>` lines (quotes optional). Used to copy a whole
/// disc on a phone import (psx.md, Import).
List<String> cueTrackFiles(String sheet) {
  final out = <String>[];
  for (final line in sheet.split(RegExp(r'\r?\n'))) {
    final m = RegExp(
      r'^\s*FILE\s+("([^"]+)"|(\S+))',
      caseSensitive: false,
    ).firstMatch(line);
    final name = m == null ? null : m[2] ?? m[3];
    if (name != null && !out.contains(name)) out.add(name);
  }
  return out;
}

/// Every track file a `.gdi` [sheet] names, in order and without repeats:
/// lines `N <lba> <type> <sector size> <file> <offset>`, the file name
/// quoted when it has spaces.
List<String> gdiTrackFiles(String sheet) {
  final out = <String>[];
  for (final line in sheet.split(RegExp(r'\r?\n')).skip(1)) {
    final m = RegExp(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+("([^"]+)"|(\S+))')
        .firstMatch(line);
    final name = m == null ? null : m[2] ?? m[3];
    if (name != null && !out.contains(name)) out.add(name);
  }
  return out;
}

/// Every track file the disc sheet [sheet] names: [gdiTrackFiles] for a
/// `.gdi` ([gdi]), else [cueTrackFiles].
List<String> sheetTrackFiles(String sheet, {required bool gdi}) =>
    gdi ? gdiTrackFiles(sheet) : cueTrackFiles(sheet);

/// Whether [fileName] is a disc sheet whose tracks lie beside it: `.cue` or
/// `.gdi`.
bool isDiscSheet(String fileName) =>
    const {'cue', 'gdi'}.contains(_extension(fileName));

/// Whether a cue sheet's track [name] stays beside the sheet: a plain or
/// sub-folder relative path, never absolute or climbing out with `..`.
bool isSafeTrackName(String name) {
  final parts = name.replaceAll(r'\', '/').split('/');
  return name.isNotEmpty &&
      !name.startsWith('/') &&
      !name.startsWith(r'\') &&
      !RegExp(r'^[A-Za-z]:').hasMatch(name) &&
      !parts.contains('..') &&
      parts.every((s) => s.isNotEmpty && s != '.');
}

/// Whether [head], the first bytes of a cue sheet's first track, is a CD
/// data track: a raw 2352-byte sector (sync header) or a 2048-byte one with
/// the ISO 9660 descriptor at `0x8001`.
bool discTrackLooksValid(List<int> head) =>
    rawSectorDataOffset(head) != null ||
    _matchesAt(head, 0x8001, 'CD001'.codeUnits);

/// The four ASCII bytes `SEGA` expected at offset `0x100` in a Genesis ROM.
const List<int> _genesisMagic = [0x53, 0x45, 0x47, 0x41];

/// The offset of the Genesis signature inside a `.bin` file.
const int _genesisMagicOffset = 0x100;

/// The exclusive end offset of the Genesis signature.
const int _genesisMagicEnd = 0x104;

/// Detects the [GameSystem] for [fileName] from its (lower-cased) extension.
///
/// `.nes` → [GameSystem.nes]; `.sfc`/`.smc` → [GameSystem.snes]; `.gb` →
/// [GameSystem.gb]; `.gbc` → [GameSystem.gbc]; `.gba` → [GameSystem.gba];
/// `.nds` → [GameSystem.nds]; `.chd`/`.pbp` → [GameSystem.psx];
/// `.z64`/`.n64`/`.v64` → [GameSystem.n64]; `.iso`/`.cso` → [GameSystem.psp]
/// unless [disc] says [GameSystem.ps2];
/// `.p8`/`.p8.png` → [GameSystem.pico8];
/// `.md`/`.gen`/`.smd` → [GameSystem.genesis]; `.cdi`/`.gdi` →
/// [GameSystem.dreamcast]; `.gcm`/`.rvz`/`.wia`/`.gcz`/`.ciso`/`.dol`/`.elf`
/// → [GameSystem.gamecube] and `.wbfs` → [GameSystem.wii].
///
/// `.bin` is ambiguous, so it maps to [GameSystem.genesis] only when [header]
/// is supplied, is at least `0x104` bytes long and carries the ASCII `SEGA`
/// signature at offset `0x100`; otherwise it is rejected as unknown (a disc
/// track joins the library through its `.cue` or `.gdi`).
///
/// [disc] is what the caller found by looking inside a disc image
/// (dreamcast-saturn.md, ps2.md, Library): a `.chd` is [disc] or else
/// PlayStation; a `.cue` is [disc] or else unknown, since only an import
/// that can see its track files beside it can look; an `.iso` or
/// `.cso` is a PS2 disc when [disc] says so and a PSP one otherwise. An
/// `.iso` can also be a GameCube or Wii disc; for the Dolphin formats [disc]
/// says GameCube or Wii (gamecube-wii.md, Library), and for `.dol`/`.elf`
/// only those two count.
///
/// Any unrecognised extension (or none) returns `null`.
GameSystem? detectSystem(
  String fileName, {
  List<int>? header,
  GameSystem? disc,
}) {
  // PICO-8 PNG carts carry a double extension (pico8.md).
  if (_baseName(fileName).toLowerCase().endsWith('.p8.png')) {
    return GameSystem.pico8;
  }
  switch (_extension(fileName)) {
    case 'p8':
      return GameSystem.pico8;
    case 'nes':
      return GameSystem.nes;
    case 'sfc':
    case 'smc':
      return GameSystem.snes;
    case 'gb':
      return GameSystem.gb;
    case 'gbc':
      return GameSystem.gbc;
    case 'gba':
      return GameSystem.gba;
    case 'nds':
      return GameSystem.nds;
    case 'z64':
    case 'n64':
    case 'v64':
      return GameSystem.n64;
    case 'iso':
      return disc == GameSystem.gamecube ||
              disc == GameSystem.wii ||
              disc == GameSystem.ps2
          ? disc
          : GameSystem.psp;
    case 'cso':
      return disc == GameSystem.ps2 ? GameSystem.ps2 : GameSystem.psp;
    case 'gcm':
    case 'rvz':
    case 'wia':
    case 'gcz':
    case 'ciso':
    case 'dol':
    case 'elf':
      return disc == GameSystem.wii ? GameSystem.wii : GameSystem.gamecube;
    case 'wbfs':
      return GameSystem.wii;
    case 'chd':
      return _isCdSystem(disc) ? disc : GameSystem.psx;
    case 'pbp':
      return GameSystem.psx;
    case 'cue':
      return _isCdSystem(disc) ? disc : null;
    case 'cdi':
    case 'gdi':
      return GameSystem.dreamcast;
    case 'md':
    case 'gen':
    case 'smd':
      return GameSystem.genesis;
    case 'bin':
      if (header != null && discSystemFromHeader(header) != null) return null;
      return _hasGenesisHeader(header) ? GameSystem.genesis : null;
    default:
      return null;
  }
}

/// Whether [s] is a disc system a `.chd` or `.cue` can hold (a `GameCube/`
/// folder doesn't make a `.chd` a GameCube disc: Dolphin can't read one).
bool _isCdSystem(GameSystem? s) => switch (s) {
  GameSystem.psx ||
  GameSystem.ps2 ||
  GameSystem.psp ||
  GameSystem.saturn ||
  GameSystem.dreamcast => true,
  _ => false,
};

/// Cleans a title out of [fileName] (docs/specs/library.md, "Import" item 4).
///
/// Strips directory parts and the last extension, removes every `(...)` and
/// `[...]` tag, collapses runs of whitespace and underscores to single spaces
/// and trims the result. If nothing is left, returns the bare name without its
/// extension (so `(Proto).nes` becomes `(Proto)`).
String cleanTitle(String fileName) {
  var base = _baseName(fileName);
  final dot = base.lastIndexOf('.');
  if (dot > 0) {
    base = base.substring(0, dot);
  }
  final cleaned = base
      .replaceAll(RegExp(r'\([^)]*\)'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .replaceAll(RegExp(r'[\s_]+'), ' ')
      .trim();
  return cleaned.isEmpty ? base : cleaned;
}

/// The outcome of picking a ROM out of a `.zip` archive's entry list.
sealed class ZipChoice {
  const ZipChoice();
}

/// Exactly one entry was recognised.
class ZipPick extends ZipChoice {
  const ZipPick(this.entryName, this.system);

  /// The archive-relative path of the chosen entry.
  final String entryName;

  /// The system detected for [entryName].
  final GameSystem system;
}

/// No entry in the archive was a recognised game.
class ZipNoGame extends ZipChoice {
  const ZipNoGame();
}

/// More than one entry was recognised, so the archive is ambiguous.
class ZipAmbiguous extends ZipChoice {
  const ZipAmbiguous(this.entries);

  /// The recognised entry names, in archive order.
  final List<String> entries;
}

/// Picks the single game entry from a `.zip`'s [entryNames] (spec "Import"
/// item 1).
///
/// Directory entries (ending `/`) and macOS `__MACOSX` metadata entries are
/// ignored, as are entries whose extension [detectSystem] does not recognise
/// (notably header-less `.bin` files). Exactly one surviving entry yields a
/// [ZipPick]; none yields [ZipNoGame]; several yield [ZipAmbiguous].
ZipChoice chooseZipEntry(List<String> entryNames) {
  final matches = <String>[];
  var system = GameSystem.nes;
  for (final name in entryNames) {
    if (isIgnoredZipEntry(name)) continue;
    final detected = detectSystem(name);
    if (detected == null) continue;
    matches.add(name);
    system = detected;
  }
  if (matches.isEmpty) return const ZipNoGame();
  if (matches.length == 1) return ZipPick(matches.single, system);
  return ZipAmbiguous(matches);
}

/// The file name part of [path], with `/` and `\` both treated as separators.
String _baseName(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf(r'\');
  final index = slash > backslash ? slash : backslash;
  return index < 0 ? path : path.substring(index + 1);
}

/// The lower-cased extension of [fileName], without the dot; `''` if none.
String _extension(String fileName) {
  final base = _baseName(fileName);
  final dot = base.lastIndexOf('.');
  return dot < 0 ? '' : base.substring(dot + 1).toLowerCase();
}

/// Whether [bytes] hold the ASCII [text] at offset [at].
bool _hasAscii(List<int> bytes, int at, String text) {
  if (bytes.length < at + text.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[at + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

/// Whether [header] starts with the Genesis `SEGA` signature at `0x100`.
bool _hasGenesisHeader(List<int>? header) {
  if (header == null || header.length < _genesisMagicEnd) return false;
  for (var i = 0; i < _genesisMagic.length; i++) {
    if (header[_genesisMagicOffset + i] != _genesisMagic[i]) return false;
  }
  return true;
}

/// Whether a zip entry is a directory or macOS metadata and must be ignored.
bool isIgnoredZipEntry(String entry) {
  if (entry.endsWith('/')) return true;
  return entry.split('/').contains('__MACOSX');
}

/// How many leading bytes [romContentLooksValid] needs: enough for the disc
/// header after a GameCube/Wii `.ciso` block map (0x8000 + 0x20), the
/// deepest header read (the PSP ISO 9660 descriptor ends at 0x8006).
const int romHeadLength = 0x8020;

/// Whether a file detected as [system] from [fileName] looks like a real game
/// rather than, say, a text file given a game extension (library.md, Import
/// item 3). [head] is the first [romHeadLength] bytes (fewer for a smaller
/// file) and [size] the whole file's length. Formats without a check pass.
bool romContentLooksValid(
  GameSystem system,
  String fileName,
  List<int> head,
  int size,
) {
  if (size <= 0 || head.isEmpty) return false;
  final ext = _extension(fileName);
  switch (system) {
    case GameSystem.nes:
      return _startsWith(head, const [0x4e, 0x45, 0x53, 0x1a]);
    case GameSystem.gb:
    case GameSystem.gbc:
      return _gbHeaderOk(head);
    case GameSystem.gba:
      return _gbaHeaderOk(head);
    case GameSystem.snes:
      final romSize = size % 1024 == 512 ? size - 512 : size;
      return romSize >= 0x8000 && !_looksLikeText(head);
    case GameSystem.n64:
      return _startsWith(head, const [0x80, 0x37, 0x12, 0x40]) ||
          _startsWith(head, const [0x37, 0x80, 0x40, 0x12]) ||
          _startsWith(head, const [0x40, 0x12, 0x37, 0x80]);
    case GameSystem.nds:
      return _ndsHeaderOk(head);
    case GameSystem.psx:
      if (ext == 'chd') return _startsWith(head, 'MComprHD'.codeUnits);
      if (ext == 'pbp') return _startsWith(head, const [0, 0x50, 0x42, 0x50]);
      return true;
    case GameSystem.psp:
      if (ext == 'cso') return _startsWith(head, 'CISO'.codeUnits);
      if (ext == 'iso') return _matchesAt(head, 0x8001, 'CD001'.codeUnits);
      return true;
    case GameSystem.pico8:
      if (_baseName(fileName).toLowerCase().endsWith('.p8.png')) {
        return _startsWith(head, const [0x89, 0x50, 0x4e, 0x47]);
      }
      return _startsWith(head, 'pico-8 cartridge'.codeUnits);
    case GameSystem.ps2:
      if (ext == 'chd') return _startsWith(head, 'MComprHD'.codeUnits);
      if (ext == 'cso') return _startsWith(head, 'CISO'.codeUnits);
      if (ext == 'iso') return _matchesAt(head, 0x8001, 'CD001'.codeUnits);
      // A `.cue` is a text sheet whose track was already read.
      return true;
    case GameSystem.saturn:
    case GameSystem.dreamcast:
      // `.cue`/`.gdi` are text sheets whose track was already read.
      if (ext == 'chd') return _startsWith(head, 'MComprHD'.codeUnits);
      if (ext == 'cdi') return !_looksLikeText(head);
      return true;
    case GameSystem.gamecube:
    case GameSystem.wii:
      // DOL executables have no magic: a binary header of 0x100 bytes.
      if (ext == 'dol') return size >= 0x100 && !_looksLikeText(head);
      // ELF homebrew: 32-bit big-endian PowerPC (e_machine 20).
      if (ext == 'elf') {
        return _startsWith(head, const [0x7f, 0x45, 0x4c, 0x46, 1, 2]) &&
            _matchesAt(head, 0x12, const [0, 20]);
      }
      return nintendoDiscFromHeader(head, ext) == system;
    case GameSystem.genesis:
      return true;
  }
}

bool _startsWith(List<int> bytes, List<int> magic) =>
    _matchesAt(bytes, 0, magic);

bool _matchesAt(List<int> bytes, int offset, List<int> magic) {
  if (bytes.length < offset + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }
  return true;
}

/// The Game Boy cartridge header checksum over 0x134..0x14C, stored at 0x14D.
bool _gbHeaderOk(List<int> h) {
  if (h.length < 0x150) return false;
  var x = 0;
  for (var i = 0x134; i <= 0x14c; i++) {
    x = (x - h[i] - 1) & 0xff;
  }
  return x == h[0x14d];
}

/// The GBA header: fixed value 0x96 at 0xB2 and the complement check over
/// 0xA0..0xBC stored at 0xBD.
bool _gbaHeaderOk(List<int> h) {
  if (h.length < 0xc0 || h[0xb2] != 0x96) return false;
  var chk = 0;
  for (var i = 0xa0; i <= 0xbc; i++) {
    chk = (chk - h[i]) & 0xff;
  }
  return ((chk - 0x19) & 0xff) == h[0xbd];
}

/// The DS header: CRC-16 of 0x000..0x15D at 0x15E, or the logo CRC 0xCF56
/// that every cartridge carries at 0x15C.
bool _ndsHeaderOk(List<int> h) {
  if (h.length < 0x160) return false;
  if (h[0x15c] == 0x56 && h[0x15d] == 0xcf) return true;
  return crc16Modbus(h.sublist(0, 0x15e)) == (h[0x15e] | h[0x15f] << 8);
}

/// CRC-16/MODBUS (reflected polynomial 0xA001, initial value 0xFFFF), the
/// checksum the DS header uses.
int crc16Modbus(List<int> bytes) {
  var crc = 0xffff;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1;
    }
  }
  return crc;
}

/// Whether the first 4 KB of [bytes] read as plain text: no NUL byte and
/// nearly every byte printable ASCII or whitespace.
bool _looksLikeText(List<int> bytes) {
  final n = bytes.length < 4096 ? bytes.length : 4096;
  var printable = 0;
  for (var i = 0; i < n; i++) {
    final b = bytes[i];
    if (b == 0) return false;
    if ((b >= 0x20 && b < 0x7f) || b == 0x09 || b == 0x0a || b == 0x0d) {
      printable++;
    }
  }
  return printable >= n * 0.95;
}
