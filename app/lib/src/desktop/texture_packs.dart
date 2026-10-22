// SPDX-License-Identifier: GPL-3.0-or-later
// HD texture packs on Windows and SteamOS: the user drops community packs
// into Textures/<system>, the app links each core's own pack folder there
// before the game starts and turns the core's texture replacement on.
// Spec: docs/specs/texture-packs.md
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import '../shell/host_library.dart';
import '../shell/platform_features.dart';
import '../ui/brutal/brutal.dart';

/// The systems whose desktop cores replace textures, with the folder name
/// under Textures and the label shown in Settings.
const texturePackSystems = {
  'n64': 'N64',
  'psx': 'PS1',
  'psp': 'PSP',
  'dreamcast': 'DREAMCAST',
};

/// Where each core looks for packs, under the system (Bios) folder; the
/// app links it to `Textures/<system>`. PS1 is per game
/// ([TexturePacks.coreFolder]).
const _coreFolders = {
  'n64': ['Mupen64plus', 'hires_texture'], // GLideN64
  'psp': ['PSP', 'TEXTURES'], // PPSSPP, memory stick = system folder
  'dreamcast': ['dc', 'textures'], // Flycast
};

/// Sends the choice for the next game to the host library.
typedef TexturePackSink = void Function(bool on);

/// Opens a folder in the system file manager.
typedef FolderOpener = Future<void> Function(String path);

/// The game a pack belongs to: enough of the library's `Game`.
typedef PackGame = ({String sha1, String system, String path});

/// The Textures folder, the per-game choices (`texture_packs.json` in the
/// data folder) and the links into the cores' folders.
class TexturePacks extends ChangeNotifier {
  TexturePacks({
    required this.root,
    required this.biosDir,
    this.file,
    this.sink,
    FolderOpener? opener,
    Map<String, bool>? games,
  }) : _games = {...?games},
       _opener = opener ?? openFolder;

  /// Reads [file]; a missing or damaged file means no per-game choices.
  factory TexturePacks.load({
    required Directory root,
    required Directory biosDir,
    required File file,
    TexturePackSink? sink,
    FolderOpener? opener,
  }) {
    final games = <String, bool>{};
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map && j['games'] is Map) {
          for (final MapEntry(:key, :value) in (j['games'] as Map).entries) {
            if (key is String && value is bool) games[key] = value;
          }
        }
      }
    } on Object {
      // No choices; the next change rewrites the file.
    }
    return TexturePacks(
      root: root,
      biosDir: biosDir,
      file: file,
      sink: sink,
      opener: opener,
      games: games,
    );
  }

  /// `<storage root>/Textures`.
  final Directory root;

  /// The system folder the cores get (`<storage root>/Bios`).
  final Directory biosDir;
  final File? file;
  final TexturePackSink? sink;
  final FolderOpener _opener;
  final Map<String, bool> _games;

  /// Whether [system] has packs on the desktop.
  static bool supports(String system) => texturePackSystems.containsKey(system);

  /// `Textures/<system>`.
  Directory systemFolder(String system) => Directory(p.join(root.path, system));

  /// Where [game]'s pack goes: the system folder, or for PS1 the folder
  /// named after the disc file (Beetle PSX looks packs up by file name).
  Directory gameFolder(PackGame game) {
    final dir = systemFolder(game.system);
    if (game.system != 'psx') return dir;
    final base = p.basenameWithoutExtension(game.path);
    // Packs often ship as `<disc>-texture-replacements`; either name works.
    final shipped = Directory(p.join(dir.path, '$base-texture-replacements'));
    return shipped.existsSync() ? shipped : Directory(p.join(dir.path, base));
  }

  /// The core's own pack folder for [game], which links to [gameFolder].
  String coreFolder(PackGame game) {
    if (game.system == 'psx') {
      final base = p.basenameWithoutExtension(game.path);
      return p.join(biosDir.path, '$base-texture-replacements');
    }
    return p.joinAll([biosDir.path, ..._coreFolders[game.system]!]);
  }

  /// Creates `Textures/<system>` for every system, so Open folder has
  /// somewhere to go.
  void ensureFolders() {
    for (final s in texturePackSystems.keys) {
      try {
        systemFolder(s).createSync(recursive: true);
      } on FileSystemException catch (e) {
        debugPrint('Textures folder not created: $e');
      }
    }
  }

  /// How many packs (entries) `Textures/<system>` holds.
  int packCount(String system) {
    try {
      return systemFolder(system).listSync().length;
    } on FileSystemException {
      return 0;
    }
  }

  /// Whether [dir] holds at least one file, at any depth.
  /// Stops at the first file: packs hold tens of thousands.
  static bool hasFiles(Directory dir) {
    try {
      if (!dir.existsSync()) return false;
      final pending = [dir];
      while (pending.isNotEmpty) {
        for (final e in pending.removeLast().listSync(followLinks: false)) {
          if (e is File) return true;
          if (e is Directory) pending.add(e);
        }
      }
    } on FileSystemException {
      // Unreadable: treated as empty.
    }
    return false;
  }

  /// The player's choice for [sha1], or null for the default.
  bool? choiceFor(String sha1) => _games[sha1];

  /// On unless the player turned it off, once the game's folder has files
  /// (packs are off until a folder has files).
  bool enabledFor(PackGame game) {
    if (!supports(game.system)) return false;
    return _games[game.sha1] ?? hasFiles(gameFolder(game));
  }

  /// Saves the per-game toggle.
  void setGame(String sha1, bool on) {
    if (_games[sha1] == on) return;
    _games[sha1] = on;
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'games': _games}));
    } on Object catch (e) {
      debugPrint('Texture pack choices not saved: $e');
    }
  }

  /// Before [game] starts: links the core's folder when packs are on and
  /// tells the host. Returns whether packs are on.
  bool prepare(PackGame game) {
    var on = enabledFor(game);
    if (on) {
      final error = linkFolder(coreFolder(game), gameFolder(game).path);
      if (error != null) {
        debugPrint('Texture pack not linked: $error');
        on = false;
      }
    }
    sink?.call(on);
    return on;
  }

  /// After a game: the next one starts with packs off unless it has some.
  void reset() => sink?.call(false);

  /// Opens `Textures/<system>` (or [game]'s PS1 folder), creating it first.
  Future<void> open(String system, {PackGame? game}) async {
    final dir = game == null ? systemFolder(system) : gameFolder(game);
    try {
      await dir.create(recursive: true);
      await _opener(dir.path);
    } on Object catch (e) {
      debugPrint('Textures folder not opened: $e');
    }
  }
}

/// Makes [linkPath] point at [target] (a junction on Windows, a symlink on
/// Linux). A link elsewhere is replaced; an empty real folder is swapped for
/// the link; a real folder with files in it is left alone, so packs put
/// there by hand still load. Returns an error message, or null.
String? linkFolder(String linkPath, String target) {
  try {
    final abs = p.absolute(target);
    Directory(abs).createSync(recursive: true);
    final link = Link(linkPath);
    if (FileSystemEntity.isLinkSync(linkPath)) {
      if (p.equals(link.targetSync(), abs)) return null;
      link.deleteSync();
    } else if (FileSystemEntity.isDirectorySync(linkPath)) {
      final dir = Directory(linkPath);
      if (dir.listSync().isNotEmpty) return null;
      dir.deleteSync();
    } else if (FileSystemEntity.isFileSync(linkPath)) {
      return 'a file is in the way: $linkPath';
    }
    Directory(p.dirname(linkPath)).createSync(recursive: true);
    link.createSync(abs);
    return null;
  } on FileSystemException catch (e) {
    return e.toString();
  }
}

/// Explorer on Windows, the desktop's file manager (xdg-open, through the
/// portal in the Flatpak) on Linux.
Future<void> openFolder(String path) async {
  if (Platform.isWindows) {
    await Process.start('explorer.exe', [path], runInShell: false);
  } else {
    await Process.start('xdg-open', [path]);
  }
}

/// dena_desktop_set_texture_packs of the host library; null off the desktop
/// or with a library that predates texture packs.
TexturePackSink? openTexturePackSink() {
  if (shellProfile != ShellProfile.desktop) return null;
  final lib = openHostLibrary();
  if (lib == null) return null;
  try {
    final set = lib.lookupFunction<Void Function(Int32), void Function(int)>(
      'dena_desktop_set_texture_packs',
    );
    return (on) => set(on ? 1 : 0);
  } on ArgumentError {
    return null;
  }
}

/// Gives Settings, the game menu and the session the texture packs; absent
/// off the desktop.
class TexturePacksScope extends InheritedNotifier<TexturePacks> {
  const TexturePacksScope({
    super.key,
    required TexturePacks packs,
    required super.child,
  }) : super(notifier: packs);

  static TexturePacks? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TexturePacksScope>()?.notifier;
}

/// `TEXTURE PACKS ....... 3 >` in VIDEO.CFG.
class TexturePacksTile extends StatelessWidget {
  const TexturePacksTile({super.key, required this.packs});

  final TexturePacks packs;

  @override
  Widget build(BuildContext context) {
    final n = texturePackSystems.keys.fold(0, (a, s) => a + packs.packCount(s));
    return CfgRow(
      label: 'Texture packs',
      value: n == 0 ? 'none' : '$n',
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => TexturePacksPage(packs: packs)),
      ),
    );
  }
}

/// One row per system: how many packs, and OPEN FOLDER.
class TexturePacksPage extends StatefulWidget {
  const TexturePacksPage({super.key, required this.packs});

  final TexturePacks packs;

  @override
  State<TexturePacksPage> createState() => _TexturePacksPageState();
}

class _TexturePacksPageState extends State<TexturePacksPage> {
  @override
  void initState() {
    super.initState();
    widget.packs.ensureFolders();
  }

  @override
  Widget build(BuildContext context) {
    final packs = widget.packs;
    final systems = texturePackSystems.entries.toList();
    return Shortcuts(
      shortcuts: arrowsMoveFocus,
      child: CfgPage(
        title: 'Texture packs',
        path: const ['settings', 'video.cfg', 'textures'],
        sections: [
          CfgTable(
            header: 'TEXTURES.CFG',
            rows: [
              for (final (i, MapEntry(key: system, value: label))
                  in systems.indexed)
                CfgRow(
                  label: label,
                  control: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_count(packs.packCount(system))),
                      const SizedBox(width: BrutalTokens.s3),
                      BrutalButton(
                        label: 'OPEN FOLDER',
                        autofocus: i == 0,
                        onPressed: () async {
                          await packs.open(system);
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
          LogLine('Folder: ${packs.root.path}'),
          const LogLine(
            'Drop each pack as it ships: N64 packs (a folder or .hts file '
            'named after the game) in n64, PSP packs (a folder named after the '
            'game ID, ULUS10041) in psp, Dreamcast packs (a folder named after '
            'the game ID) in dreamcast, PS1 packs in psx, named after the '
            'disc file without its extension.',
          ),
          const LogLine(
            'A game with a pack uses it from its next start. Turn it off for '
            'one game in the game\'s menu (Textures). PS1 replacement is '
            'experimental and may crash some games.',
          ),
        ],
      ),
    );
  }

  static String _count(int n) => switch (n) {
    0 => 'EMPTY',
    1 => '1 PACK',
    _ => '$n PACKS',
  };
}
