// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md (Import)
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../shell/platform_features.dart';
import 'database.dart';
import 'import_rules.dart';

/// Outcome for one source file.
sealed class ImportOutcome {
  const ImportOutcome(this.source);
  final String source;
}

class Imported extends ImportOutcome {
  const Imported(super.source, this.gameId, this.title);
  final int gameId;
  final String title;
}

class Duplicate extends ImportOutcome {
  const Duplicate(super.source, {this.gameId});

  /// The library game it duplicates, when the importer knows it.
  final int? gameId;
}

class Rejected extends ImportOutcome {
  const Rejected(super.source, this.reason);
  final String reason;
}

/// A ROM ready to store: bytes are already unzipped.
class PreparedRom {
  PreparedRom({
    required this.system,
    required this.title,
    required this.fileName,
    required this.extension,
    required this.bytes,
  }) : sha1 = sha1Hex(bytes),
       crc32 = getCrc32(bytes).toRadixString(16).padLeft(8, '0');

  final GameSystem system;
  final String title;
  final String fileName;
  final String extension;
  final Uint8List bytes;
  final String sha1;
  final String crc32;
}

String sha1Hex(List<int> bytes) => sha1.convert(bytes).toString();

/// Disc images can be hundreds of megabytes: they are streamed (hashed while
/// copied) instead of read into memory (psx.md).
const streamedExtensions = {
  '.chd',
  '.pbp',
  '.iso',
  '.cso',
  '.cdi',
  // GameCube and Wii (gamecube-wii.md).
  '.gcm',
  '.rvz',
  '.wia',
  '.gcz',
  '.wbfs',
  '.ciso',
};

/// Copies [src] to [tmp] while hashing it; returns (sha1, crc32, size).
Future<(String, String, int)> _copyHashing(File src, File tmp) async {
  final digest = _DigestSink();
  final hasher = sha1.startChunkedConversion(digest);
  var crc = 0, size = 0;
  final out = tmp.openWrite();
  try {
    await for (final chunk in src.openRead()) {
      hasher.add(chunk);
      crc = getCrc32(chunk, crc);
      size += chunk.length;
      out.add(chunk);
    }
    await out.flush();
  } finally {
    await out.close();
  }
  hasher.close();
  return (digest.value.toString(), crc.toRadixString(16).padLeft(8, '0'), size);
}

/// Hashes [src] without copying it; returns (sha1, crc32, size).
Future<(String, String, int)> _hashOnly(File src) async {
  final digest = _DigestSink();
  final hasher = sha1.startChunkedConversion(digest);
  var crc = 0, size = 0;
  await for (final chunk in src.openRead()) {
    hasher.add(chunk);
    crc = getCrc32(chunk, crc);
    size += chunk.length;
  }
  hasher.close();
  return (digest.value.toString(), crc.toRadixString(16).padLeft(8, '0'), size);
}

/// The first [romHeadLength] bytes of [file], for the content check.
Future<List<int>> _readHead(File file) =>
    file.openRead(0, romHeadLength).fold<List<int>>([], (a, b) => a..addAll(b));

/// Hashes a `.cue`/`.gdi` [sheet] together with its first [track]: the sheet
/// alone is a few lines that differ little between games. The CRC-32 is the
/// track's own, which is what the Redump DATs list (box-art.md).
Future<(String, String, int)> _hashSheet(File sheet, File? track) async {
  final digest = _DigestSink();
  final hasher = sha1.startChunkedConversion(digest);
  var crc = 0, size = 0;
  final text = await sheet.readAsBytes();
  hasher.add(text);
  size += text.length;
  if (track != null && await track.exists()) {
    await for (final chunk in track.openRead()) {
      hasher.add(chunk);
      crc = getCrc32(chunk, crc);
      size += chunk.length;
    }
  } else {
    crc = getCrc32(text);
  }
  hasher.close();
  return (digest.value.toString(), crc.toRadixString(16).padLeft(8, '0'), size);
}

/// Sheets read beyond this are not cue or GDI sheets.
const _maxSheetBytes = 64 * 1024;

/// The first track file of the `.cue` or `.gdi` [sheet], beside it; null
/// when the sheet can't be read or names none.
Future<File?> firstTrackOf(File sheet) async {
  try {
    if (await sheet.length() > _maxSheetBytes) return null;
    final text = String.fromCharCodes(await sheet.readAsBytes());
    final gdi = p.extension(sheet.path).toLowerCase() == '.gdi';
    final name = firstTrackFile(text, gdi: gdi);
    if (name == null) return null;
    return File(p.join(p.dirname(sheet.path), name));
  } on FileSystemException {
    return null;
  }
}

Future<List<int>> _head(File file, int length) async {
  try {
    return await file
        .openRead(0, length)
        .fold<List<int>>([], (a, b) => a..addAll(b));
  } on FileSystemException {
    return const [];
  }
}

/// Whether the `.chd` [file] holds a GD-ROM (a Dreamcast disc): its metadata
/// has a `CHGD` (or the older `CHGT`) track entry, where CD images have
/// `CHT2`/`CHTR` (MAME's CHD format, versions 3 to 5).
Future<bool> isGdRomChd(File file) async =>
    (await _chdHasTag(file, const {'CHGD', 'CHGT'}));

/// Whether the `.chd` [file] holds a DVD (`chdman createdvd`): its metadata
/// has a `DVD ` entry (ps2.md, Library). PS2 DVDs and PSP UMDs are made
/// this way; CD images never are.
Future<bool> isDvdChd(File file) => _chdHasTag(file, const {'DVD '});

/// Whether one of the `.chd` [file]'s metadata entries carries a tag of
/// [tags].
Future<bool> _chdHasTag(File file, Set<String> tags) async {
  RandomAccessFile? f;
  try {
    f = await file.open();
    final head = await f.read(56);
    if (head.length < 56 ||
        String.fromCharCodes(head.sublist(0, 8)) != 'MComprHD') {
      return false;
    }
    final bytes = ByteData.sublistView(head);
    final version = bytes.getUint32(12);
    final metaAt = version >= 5
        ? 48
        : version >= 3
        ? 36
        : -1;
    if (metaAt < 0) return false;
    var offset = bytes.getUint64(metaAt);
    final length = await f.length();
    // A broken chain could loop; real discs have one entry per track.
    for (var i = 0; i < 256 && offset != 0 && offset + 16 <= length; i++) {
      await f.setPosition(offset);
      final entry = await f.read(16);
      if (entry.length < 16) return false;
      final tag = String.fromCharCodes(entry.sublist(0, 4));
      if (tags.contains(tag)) return true;
      offset = ByteData.sublistView(entry).getUint64(8);
    }
    return false;
  } on FileSystemException {
    return false;
  } finally {
    await f?.close();
  }
}

/// What a disc image in place is (dreamcast-saturn.md, ps2.md, Library):
/// its own bytes first (a GD-ROM or DVD `.chd`, a cue sheet's Saturn,
/// Dreamcast or PS2 track, an `.iso` or `.cso` whose `SYSTEM.CNF` boots a
/// PS2 game), then the folder it lies in (`Saturn/`, `Dreamcast/`, `PS1/`,
/// `PS2/`). A `.cue` that says none of these is a PlayStation disc. GameCube
/// and Wii images by their header (gamecube-wii.md, Library); a `.dol` or
/// `.elf` by its folder (`Wii/`, else GameCube). Null for other files, for a
/// `.cue` whose track is missing and for a PSP image.
Future<GameSystem?> sniffDisc(File file) async {
  final ext = p.extension(file.path).toLowerCase();
  switch (ext) {
    case '.iso':
      final nintendo = nintendoDiscFromHeader(
        await _head(file, 0x8000 + 0x20),
        'iso',
      );
      if (nintendo != null) return nintendo;
      return await _isoSystem(file, (at) => at * 2048) == GameSystem.ps2
          ? GameSystem.ps2
          : null;
    case '.gcm' || '.ciso' || '.gcz' || '.wia' || '.rvz' || '.wbfs':
      return nintendoDiscFromHeader(
        await _head(file, 0x8000 + 0x20),
        ext.substring(1),
      );
    case '.dol' || '.elf':
      return homebrewSystemFromFolders(file.path);
    case '.chd':
      if (await isGdRomChd(file)) return GameSystem.dreamcast;
      final folder = systemFromFolders(file.path);
      if (await isDvdChd(file)) {
        return folder == GameSystem.psp ? GameSystem.psp : GameSystem.ps2;
      }
      return folder;
    case '.cue':
      final track = await firstTrackOf(file);
      if (track == null || !await track.exists()) return null;
      return _sniffCue(file, track);
    case '.cso':
      return await _csoIsPs2(file) ? GameSystem.ps2 : null;
    default:
      return null;
  }
}

/// Folders that never make a `.cue` theirs: no PSP, GameCube or Wii game is a
/// cue sheet (gamecube-wii.md, Library).
const _notCueSystems = {GameSystem.psp, GameSystem.gamecube, GameSystem.wii};

/// [GameSystem.ps2] when the cue sheet's first [track] (whose first bytes
/// are [head]) is a PS2 CD; null otherwise.
Future<GameSystem?> _ps2Track(File track, List<int> head) async {
  final raw = rawSectorDataOffset(head);
  final system = await _isoSystem(
    track,
    raw == null ? (lba) => lba * 2048 : (lba) => lba * 2352 + raw,
    stride: raw == null ? 2048 : 2352,
  );
  return system == GameSystem.ps2 ? system : null;
}

/// [discSystemFromIso] over [file], whose sector `lba` has its 2048 data
/// bytes at [dataAt]`(lba)`, sectors [stride] bytes apart.
Future<GameSystem?> _isoSystem(
  File file,
  int Function(int lba) dataAt, {
  int stride = 2048,
}) async {
  RandomAccessFile? f;
  try {
    final raf = f = await file.open();
    return await discSystemFromIso((lba, count) async {
      final out = <int>[];
      for (var i = 0; i < count; i++) {
        await raf.setPosition(dataAt(lba + i));
        final sector = await raf.read(2048);
        out.addAll(sector);
        if (sector.length < 2048) break;
      }
      return out;
    });
  } on FileSystemException {
    return null;
  } finally {
    await f?.close();
  }
}

/// Whether the CSO (compressed ISO) [file] holds a PS2 disc rather than a
/// PSP UMD (ps2.md, Library). CSO: `CISO`, header size, the uncompressed
/// size (u64), block size, version and index shift, then one u32 offset per
/// block, the top bit set for a block stored without compression; the
/// others are raw deflate.
Future<bool> _csoIsPs2(File file) async {
  RandomAccessFile? f;
  try {
    final raf = f = await file.open();
    final head = await raf.read(0x18);
    if (head.length < 0x18 || String.fromCharCodes(head, 0, 4) != 'CISO') {
      return false;
    }
    final h = ByteData.sublistView(Uint8List.fromList(head));
    final total = h.getUint64(8, Endian.little);
    final blockSize = h.getUint32(16, Endian.little);
    final shift = head[0x15];
    if (blockSize < 2048 || blockSize % 2048 != 0 || shift > 16) return false;
    final blocks = (total + blockSize - 1) ~/ blockSize;
    final cache = <int, List<int>>{};
    Future<List<int>> block(int n) async {
      if (n >= blocks) return const [];
      if (cache[n] case final b?) return b;
      await raf.setPosition(0x18 + n * 4);
      final idx = ByteData.sublistView(Uint8List.fromList(await raf.read(8)));
      final a = idx.getUint32(0, Endian.little);
      final b = idx.getUint32(4, Endian.little);
      final start = (a & 0x7fffffff) << shift;
      final end = (b & 0x7fffffff) << shift;
      if (end <= start || end - start > blockSize + 1024) return const [];
      await raf.setPosition(start);
      final data = await raf.read(end - start);
      final List<int> out;
      if (a & 0x80000000 != 0) {
        out = data;
      } else {
        try {
          out = ZLibCodec(raw: true).decode(data);
        } on FormatException {
          return const [];
        }
      }
      return cache[n] = out;
    }

    return await discSystemFromIso((lba, count) async {
          final out = <int>[];
          for (var i = 0; i < count; i++) {
            final at = (lba + i) * 2048;
            final b = await block(at ~/ blockSize);
            final off = at % blockSize;
            if (b.length < off + 2048) break;
            out.addAll(b.sublist(off, off + 2048));
          }
          return out;
        }) ==
        GameSystem.ps2;
  } on FileSystemException {
    return false;
  } finally {
    await f?.close();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Reads [file] and applies the import rules. Returns a [PreparedRom] or a
/// [Rejected] reason. Pure apart from reading the file, so it can run in an
/// isolate.
Future<Object> prepare(File file) async {
  final name = p.basename(file.path);
  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } on FileSystemException catch (e) {
    return Rejected(
      name,
      'Could not read the file (${e.osError?.message ?? e.message})',
    );
  }
  if (p.extension(name).toLowerCase() == '.zip') {
    // ZipDecoder accepts some garbage as an empty archive, so check the
    // local-file-header signature first.
    final isZip =
        bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
    if (!isZip) return Rejected(name, 'The zip file is damaged');
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object {
      return Rejected(name, 'The zip file is damaged');
    }
    final entries = {
      for (final f in archive.files)
        if (f.isFile) f.name: f,
    };
    switch (chooseZipEntry(entries.keys.toList())) {
      case ZipNoGame():
        final track = entries.keys.any(
          (e) => p.extension(e).toLowerCase() == '.bin',
        );
        return Rejected(
          name,
          track
              ? 'The zip has no game file in it: a disc needs its .cue in '
                    'the zip beside the .bin files'
              : 'The zip has no game file in it',
        );
      case ZipAmbiguous(:final entries):
        return Rejected(
          name,
          'The zip has several games in it (${entries.length})',
        );
      case ZipPick(:final entryName, :final system):
        final data = entries[entryName]!.content;
        final inner = p.basename(entryName);
        if (!romContentLooksValid(system, inner, data, data.length)) {
          return Rejected(name, 'Not a supported game file');
        }
        return PreparedRom(
          system: system,
          title: cleanTitle(inner),
          fileName: name,
          extension: p.extension(inner).toLowerCase(),
          bytes: Uint8List.fromList(data),
        );
    }
  }
  final header = bytes.length >= 0x104 ? bytes.sublist(0, 0x104) : bytes;
  final system = detectSystem(
    name,
    header: header,
    disc: homebrewSystemFromFolders(file.path),
  );
  if (system == null) {
    if (p.extension(name).toLowerCase() == '.bin' &&
        (rawSectorDataOffset(header) != null ||
            discSystemFromHeader(header) != null)) {
      return Rejected(name, "This is one track of a disc: add the game's .cue");
    }
    return Rejected(name, 'Not a supported game file');
  }
  if (!system.playable) {
    return Rejected(name, "${system.shortName} games aren't supported yet");
  }
  if (!romContentLooksValid(system, name, bytes, bytes.length)) {
    return Rejected(name, 'Not a supported game file');
  }
  return PreparedRom(
    system: system,
    title: cleanTitle(name),
    fileName: name,
    extension: p.extension(name).toLowerCase(),
    bytes: bytes,
  );
}

/// Imports files into [db], copying ROMs to `<gamesDir>/<system>/<sha1><ext>`.
/// Each file is independent: a failure rejects that file and the batch goes on.
class Importer {
  Importer(this.db, this.gamesDir, {this.desktop});

  final LibraryDatabase db;
  final Directory gamesDir;

  /// Whether this is the Windows or SteamOS app, where the desktop-only
  /// systems play (dreamcast-saturn.md); [keepsUserRoms]'s test when null.
  final bool? desktop;

  bool get _desktop => desktop ?? keepsUserRoms;

  /// Why a game of [system] can't be added here, or null when it can.
  String? _unplayable(GameSystem system) {
    if (system.playableOn(desktop: _desktop)) return null;
    if (system.playable) {
      return '${system.shortName} games play on the Windows and SteamOS '
          'versions';
    }
    return "${system.shortName} games aren't supported yet";
  }

  Stream<ImportOutcome> importAll(List<File> files) async* {
    for (final f in files) {
      yield* Stream.fromIterable(await importEach(f));
    }
  }

  /// Every outcome of adding [file]: one, or one per disc for a zip holding
  /// several `.cue`/`.gdi` sheets. [inPlace] adds an unzipped file where it
  /// lies ([importInPlace]).
  Future<List<ImportOutcome>> importEach(
    File file, {
    bool inPlace = false,
  }) async {
    if (p.extension(file.path).toLowerCase() == '.zip') {
      if (await _importZippedDiscs(file) case final outcomes?) return outcomes;
    }
    return [inPlace ? await importInPlace(file) : await importOne(file)];
  }

  Future<ImportOutcome> importOne(File file) async {
    final name = p.basename(file.path);
    final ext = p.extension(name).toLowerCase();
    if (streamedExtensions.contains(ext)) return _importStreamed(file, ext);
    if (ext == '.cue' || ext == '.gdi') return _importCueSet(file);
    if (ext == '.zip') {
      if (await _importZippedDiscs(file) case final outcomes?) {
        return outcomes.firstWhere(
          (o) => o is Imported,
          orElse: () => outcomes.first,
        );
      }
    }
    final prepared = await prepare(file);
    if (prepared is Rejected) return prepared;
    final rom = prepared as PreparedRom;
    if (_unplayable(rom.system) case final why?) {
      return Rejected(rom.fileName, why);
    }
    final dest = File(
      p.join(gamesDir.path, rom.system.id, '${rom.sha1}${rom.extension}'),
    );
    try {
      await dest.parent.create(recursive: true);
      if (!await dest.exists()) await dest.writeAsBytes(rom.bytes, flush: true);
    } on FileSystemException {
      return Rejected(rom.fileName, 'Not enough space to store the game');
    }
    final id = await db.addGame(
      system: rom.system.id,
      title: rom.title,
      fileName: rom.fileName,
      path: dest.path,
      sha1: rom.sha1,
      size: rom.bytes.length,
      crc32: rom.crc32,
    );
    if (id == null) return Duplicate(rom.fileName);
    return Imported(rom.fileName, id, rom.title);
  }
}

/// Adds a game file where it lies, without a copy: the handheld's own
/// `Roms/<system>` folders (sd-card.md, Card library). Zips still go through
/// [Importer.importOne], since cores read the extracted ROM.
extension InPlaceImport on Importer {
  Future<ImportOutcome> importInPlace(File file) async {
    final name = p.basename(file.path);
    if (p.extension(name).toLowerCase() == '.zip') return importOne(file);
    final List<int> header;
    final int length;
    try {
      header = await _readHead(file);
      length = await file.length();
    } on FileSystemException catch (e) {
      return Rejected(
        name,
        'Could not read the file (${e.osError?.message ?? e.message})',
      );
    }
    final system = detectSystem(
      name,
      header: header,
      disc: await sniffDisc(file),
    );
    if (system == null) return Rejected(name, 'Not a supported game file');
    if (_unplayable(system) case final why?) return Rejected(name, why);
    if (!romContentLooksValid(system, name, header, length)) {
      return Rejected(name, 'Not a supported game file');
    }
    final ext = p.extension(name).toLowerCase();
    final String sha, crc;
    final int size;
    try {
      (sha, crc, size) = ext == '.cue' || ext == '.gdi'
          ? await _hashSheet(file, await firstTrackOf(file))
          : await _hashOnly(file);
    } on FileSystemException catch (e) {
      return Rejected(
        name,
        'Could not read the file (${e.osError?.message ?? e.message})',
      );
    }
    final id = await db.addGame(
      system: system.id,
      title: cleanTitle(name),
      fileName: name,
      path: file.path,
      sha1: sha,
      size: size,
      crc32: crc,
    );
    if (id == null) return Duplicate(name);
    return Imported(name, id, cleanTitle(name));
  }
}

extension on Importer {
  /// Copies a `.cue` or `.gdi` sheet and every track it names into
  /// `<gamesDir>/<system>/<sha1>/`, keeping their names so the core finds
  /// the tracks beside the sheet (psx.md, Import). A cue disc is sniffed like
  /// an in-place one and is a PlayStation game unless its tracks or folder
  /// say otherwise; a `.gdi` is a Dreamcast disc. A sheet unpacked from a
  /// zip names the zip as its [source] and [move]s its tracks instead of
  /// copying them.
  Future<ImportOutcome> _importCueSet(
    File file, {
    String? source,
    bool move = false,
  }) async {
    final name = p.basename(file.path);
    final from = source ?? name;
    final gdi = p.extension(name).toLowerCase() == '.gdi';
    final String sheet;
    try {
      if (await file.length() > _maxSheetBytes) {
        return Rejected(from, 'Not a supported game file');
      }
      sheet = String.fromCharCodes(await file.readAsBytes());
    } on FileSystemException catch (e) {
      return Rejected(
        from,
        'Could not read the file (${e.osError?.message ?? e.message})',
      );
    }
    final names = sheetTrackFiles(sheet, gdi: gdi);
    if (names.isEmpty || !names.every(isSafeTrackName)) {
      return Rejected(from, 'Not a supported game file');
    }
    final tracks = <String, File>{};
    for (final n in names) {
      final track = await _findTrack(file.parent, n);
      if (track == null) {
        return Rejected(
          from,
          source != null
              ? _missingFromZip(n, gdi: gdi)
              : 'The disc is missing $n: add the ${gdi ? '.gdi' : '.cue'} '
                    'from the folder that holds its track files',
        );
      }
      tracks[n] = track;
    }
    final first = tracks[names.first]!;
    final system = gdi
        ? detectSystem(name)
        : detectSystem(name, disc: await _sniffCue(file, first));
    if (system == null) return Rejected(from, 'Not a supported game file');
    if (_unplayable(system) case final why?) return Rejected(from, why);
    final String sha, crc;
    final int size;
    try {
      if (!discTrackLooksValid(await _readHead(first))) {
        return Rejected(from, 'Not a supported game file');
      }
      (sha, crc, size) = await _hashSheet(file, first);
    } on FileSystemException catch (e) {
      return Rejected(
        from,
        'Could not read the file (${e.osError?.message ?? e.message})',
      );
    }
    final dir = Directory(p.join(gamesDir.path, system.id));
    final dest = Directory(p.join(dir.path, sha));
    if (!await dest.exists()) {
      final tmp = Directory(
        p.join(dir.path, '.import-${DateTime.now().microsecondsSinceEpoch}'),
      );
      try {
        await tmp.create(recursive: true);
        await file.copy(p.join(tmp.path, name));
        for (final MapEntry(key: n, value: track) in tracks.entries) {
          final out = File(p.joinAll([tmp.path, ...n.split(RegExp(r'[/\\]'))]));
          await out.parent.create(recursive: true);
          await (move ? track.rename(out.path) : track.copy(out.path));
        }
        await tmp.rename(dest.path);
      } on FileSystemException {
        if (await tmp.exists()) await tmp.delete(recursive: true);
        return Rejected(from, 'Not enough space to store the game');
      }
    }
    final id = await db.addGame(
      system: system.id,
      title: cleanTitle(name),
      fileName: name,
      path: p.join(dest.path, name),
      sha1: sha,
      size: size,
      crc32: crc,
    );
    if (id == null) {
      return Duplicate(from, gameId: (await db.gameBySha1(sha))?.id);
    }
    return Imported(from, id, cleanTitle(name));
  }

  /// Adds the disc sets of the zip [file]: every `.cue` or `.gdi` sheet in
  /// it, with the track files it names, is unpacked and added like a picked
  /// sheet ([_importCueSet], psx.md, Import), one game per sheet. Null when
  /// the zip holds no sheet, so it is a zip of one cartridge or disc image.
  Future<List<ImportOutcome>?> _importZippedDiscs(File file) async {
    final name = p.basename(file.path);
    final _ZipListing listing;
    try {
      final l = _listZip(file.path);
      if (l == null) return null;
      listing = l;
    } on FileSystemException catch (e) {
      return [
        Rejected(
          name,
          'Could not read the file (${e.osError?.message ?? e.message})',
        ),
      ];
    } on Object {
      return [Rejected(name, 'The zip file is damaged')];
    }
    final byLower = {for (final e in listing.crcs.keys) e.toLowerCase(): e};
    final known = await db.allGames();
    final outcomes = <ImportOutcome>[];
    final wanted = <String>{};
    final sheets = <String>[];
    for (final MapEntry(key: entry, value: text) in listing.sheets.entries) {
      final gdi = p.extension(entry).toLowerCase() == '.gdi';
      final names = sheetTrackFiles(text, gdi: gdi);
      if (names.isEmpty || !names.every(isSafeTrackName)) {
        outcomes.add(Rejected(name, 'Not a supported game file'));
        continue;
      }
      final folder = p.posix.dirname(entry);
      final entries = <String>[];
      String? missing;
      for (final n in names) {
        final path = p.posix.normalize(
          p.posix.join(folder, n.replaceAll(r'\', '/')),
        );
        final found = listing.crcs.containsKey(path)
            ? path
            : byLower[path.toLowerCase()];
        if (found == null) {
          missing = n;
          break;
        }
        entries.add(found);
      }
      if (missing != null) {
        outcomes.add(Rejected(name, _missingFromZip(missing, gdi: gdi)));
        continue;
      }
      // A zip the library already has is not unpacked again: the game keeps
      // the sheet's name and its first track's CRC-32, which the zip lists.
      final crc = listing.crcs[entries.first];
      final sheetName = p.posix.basename(entry);
      final crcHex = crc?.toRadixString(16).padLeft(8, '0');
      final have = known
          .where((g) => g.fileName == sheetName && g.crc32 == crcHex)
          .firstOrNull;
      if (crc != null && have != null) {
        outcomes.add(Duplicate(name, gameId: have.id));
        continue;
      }
      sheets.add(entry);
      wanted
        ..add(entry)
        ..addAll(entries);
    }
    if (sheets.isEmpty) return outcomes;
    final tmp = Directory(
      p.join(gamesDir.path, '.unzip-${DateTime.now().microsecondsSinceEpoch}'),
    );
    try {
      await tmp.create(recursive: true);
      final failed = await _unzipApart(file.path, wanted, tmp.path);
      if (failed != null) {
        return [
          ...outcomes,
          for (final _ in sheets)
            Rejected(
              name,
              failed == 'space'
                  ? 'Not enough space to store the game'
                  : 'The zip file is damaged',
            ),
        ];
      }
      for (final entry in sheets) {
        outcomes.add(
          await _importCueSet(
            File(p.joinAll([tmp.path, ...p.posix.split(entry)])),
            source: name,
            move: true,
          ),
        );
      }
      return outcomes;
    } on FileSystemException {
      return [
        ...outcomes,
        Rejected(name, 'Not enough space to store the game'),
      ];
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  Future<ImportOutcome> _importStreamed(File file, String ext) async {
    final name = p.basename(file.path);
    final system = detectSystem(name, disc: await sniffDisc(file));
    if (system == null) return Rejected(name, 'Not a supported game file');
    if (_unplayable(system) case final why?) return Rejected(name, why);
    try {
      final head = await _readHead(file);
      if (!romContentLooksValid(system, name, head, await file.length())) {
        return Rejected(name, 'Not a supported game file');
      }
    } on FileSystemException catch (e) {
      return Rejected(
        name,
        'Could not read the file (${e.osError?.message ?? e.message})',
      );
    }
    final dir = Directory(p.join(gamesDir.path, system.id));
    final tmp = File(
      p.join(dir.path, '.import-${DateTime.now().microsecondsSinceEpoch}$ext'),
    );
    final String sha, crc;
    final int size;
    try {
      await dir.create(recursive: true);
      (sha, crc, size) = await _copyHashing(file, tmp);
    } on FileSystemException catch (e) {
      if (await tmp.exists()) await tmp.delete();
      final reading = e.path == file.path;
      return Rejected(
        name,
        reading
            ? 'Could not read the file (${e.osError?.message ?? e.message})'
            : 'Not enough space to store the game',
      );
    }
    final dest = File(p.join(dir.path, '$sha$ext'));
    if (await dest.exists()) {
      await tmp.delete();
    } else {
      await tmp.rename(dest.path);
    }
    final id = await db.addGame(
      system: system.id,
      title: cleanTitle(name),
      fileName: name,
      path: dest.path,
      sha1: sha,
      size: size,
      crc32: crc,
    );
    if (id == null) return Duplicate(name);
    return Imported(name, id, cleanTitle(name));
  }
}

/// Why a zipped disc can't be added: its sheet names [track], which the zip
/// doesn't hold.
String _missingFromZip(String track, {required bool gdi}) =>
    'The zip is missing $track, which its ${gdi ? '.gdi' : '.cue'} names: '
    'zip the sheet together with all of its track files';

/// A zip's file entries and their CRC-32s, and the text of its disc sheets.
class _ZipListing {
  _ZipListing(this.crcs, this.sheets);
  final Map<String, int?> crcs;
  final Map<String, String> sheets;
}

/// Lists the zip at [path] without unpacking its entries, or null when it
/// holds no `.cue` or `.gdi` sheet. Throws on a damaged zip.
_ZipListing? _listZip(String path) {
  final input = InputFileStream(path);
  try {
    if (input.length < 4 || input.readUint32() != 0x04034b50) {
      throw const FormatException('not a zip');
    }
    input.reset();
    final archive = ZipDecoder().decodeStream(input);
    final crcs = <String, int?>{};
    final sheets = <String, String>{};
    for (final f in archive.files) {
      if (!f.isFile || isIgnoredZipEntry(f.name)) continue;
      final entry = p.posix.normalize(f.name.replaceAll(r'\', '/'));
      crcs[entry] = f.crc32;
      if (isDiscSheet(entry) && f.size <= _maxSheetBytes) {
        sheets[entry] = String.fromCharCodes(f.readBytes() ?? const []);
      }
    }
    return sheets.isEmpty ? null : _ZipListing(crcs, sheets);
  } finally {
    input.closeSync();
  }
}

/// [_unzip] in its own isolate, away from this method's unsendable state.
Future<String?> _unzipApart(String zipPath, Set<String> wanted, String out) =>
    Isolate.run(() => _unzip(zipPath, wanted, out));

/// Unpacks the [wanted] entries of the zip at [zipPath] into [outDir],
/// keeping their folders. Runs in an isolate: discs are hundreds of
/// megabytes. Returns null, `'space'` when a file can't be written or
/// `'damaged'` when the zip can't be read.
String? _unzip(String zipPath, Set<String> wanted, String outDir) {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      return 'damaged';
    }
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final entry = p.posix.normalize(f.name.replaceAll(r'\', '/'));
      if (!wanted.contains(entry) || !isSafeTrackName(entry)) continue;
      final dest = File(p.joinAll([outDir, ...p.posix.split(entry)]));
      try {
        dest.parent.createSync(recursive: true);
      } on FileSystemException {
        return 'space';
      }
      final out = OutputFileStream(dest.path);
      try {
        f.writeContent(out);
      } on FileSystemException {
        return 'space';
      } on Object {
        return 'damaged';
      } finally {
        out.closeSync();
      }
    }
    return null;
  } finally {
    input.closeSync();
  }
}

/// The track [name] of a cue sheet in [dir]: that exact path, else a file
/// whose name matches ignoring case (sheets are often written on Windows).
Future<File?> _findTrack(Directory dir, String name) async {
  final parts = name.split(RegExp(r'[/\\]'));
  final exact = File(p.joinAll([dir.path, ...parts]));
  if (await exact.exists()) return exact;
  final folder = Directory(
    p.joinAll([dir.path, ...parts.take(parts.length - 1)]),
  );
  try {
    await for (final e in folder.list(followLinks: false)) {
      if (e is File &&
          p.basename(e.path).toLowerCase() == parts.last.toLowerCase()) {
        return e;
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// What the `.cue` [sheet] whose first track is [track] holds (see
/// [sniffDisc]).
Future<GameSystem?> _sniffCue(File sheet, File track) async {
  final head = await _head(track, 0x20);
  final folder = systemFromFolders(sheet.path);
  return discSystemFromHeader(head) ??
      await _ps2Track(track, head) ??
      (_notCueSystems.contains(folder) ? null : folder) ??
      GameSystem.psx;
}

/// [paths] without the track files that a `.cue` among them names: picking
/// a disc's folder or its sheet with its tracks adds the game once instead
/// of refusing every `.bin` (psx.md, Import).
Future<List<String>> withoutCueTracks(List<String> paths) async {
  final tracks = <String>{};
  for (final path in paths) {
    if (p.extension(path).toLowerCase() != '.cue') continue;
    try {
      final f = File(path);
      if (await f.length() > _maxSheetBytes) continue;
      for (final n in cueTrackFiles(
        String.fromCharCodes(await f.readAsBytes()),
      )) {
        final parts = n.split(RegExp(r'[/\\]'));
        tracks.add(
          p.normalize(p.joinAll([p.dirname(path), ...parts])).toLowerCase(),
        );
      }
    } on FileSystemException {
      continue;
    }
  }
  if (tracks.isEmpty) return paths;
  return [
    for (final path in paths)
      if (!tracks.contains(p.normalize(path).toLowerCase())) path,
  ];
}

/// Whether deleting a game keeps a ROM that lies outside the app's data
/// folder: on a PC those are the user's own files in their game folders
/// (desktop-library.md). Tests drive the Android UI, so it is false there.
bool get keepsUserRoms =>
    !hasAndroidShell && shellProfile == ShellProfile.desktop;

/// Removes a deleted game's files: the ROM copy and, under [dataDir], its
/// battery save and every save state (game-session.md, save-states.md).
/// With [keepUserRom] (default [keepsUserRoms]) a ROM outside [dataDir]
/// stays on disk.
Future<void> deleteGameFiles(
  Game game, {
  String? dataDir,
  bool? keepUserRom,
}) async {
  final rom = File(game.path);
  final keep =
      (keepUserRom ?? keepsUserRoms) &&
      (dataDir == null || !p.isWithin(dataDir, rom.path));
  if (!keep) {
    // A copied cue or GDI sheet lies in its own `<sha1>/` folder with its
    // tracks.
    final set = rom.parent;
    if (isDiscSheet(rom.path) && p.basename(set.path) == game.sha1) {
      if (await set.exists()) await set.delete(recursive: true);
    } else if (await rom.exists()) {
      await rom.delete();
    }
  }
  if (dataDir == null) return;
  final srm = File(p.join(dataDir, 'saves', '${game.sha1}.srm'));
  if (await srm.exists()) await srm.delete();
  final states = Directory(p.join(dataDir, 'states', game.sha1));
  if (await states.exists()) await states.delete(recursive: true);
}
