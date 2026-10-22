// SPDX-License-Identifier: GPL-3.0-or-later
// In-app file explorer for Add games / Add a folder. Spec:
// docs/specs/file-explorer.md
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../shell/app_dirs.dart';
import '../shell/handheld.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';
import 'library_scope.dart';

/// A place the explorer starts from: the games card, a USB drive, shared
/// storage.
class ExplorerRoot {
  const ExplorerRoot(this.label, this.path, this.icon, {this.start});

  final String label;
  final String path;
  final IconData icon;

  /// The folder to open first inside [path] (the card's `Roms`), if any.
  final String? start;

  @override
  bool operator ==(Object other) =>
      other is ExplorerRoot && other.label == label && other.path == path;

  @override
  int get hashCode => Object.hash(label, path);
}

/// Mount points of removable or extra storage in a `/proc/mounts` text:
/// USB drives, a second card slot, NVMe. Leaves out the system, boot
/// partitions and [exclude] (the games card, listed on its own).
List<({String device, String dir})> removableMounts(
  String mounts, {
  String? exclude,
}) {
  final out = <({String device, String dir})>[];
  for (final line in const LineSplitter().convert(mounts)) {
    final f = line.split(' ');
    if (f.length < 2) continue;
    final dev = f[0];
    final dir = _unescape(f[1]);
    if (!(dev.startsWith('/dev/sd') ||
        dev.startsWith('/dev/mmcblk') ||
        dev.startsWith('/dev/nvme'))) {
      continue;
    }
    if (dir == '/' || dir.startsWith('/boot')) continue;
    if (exclude != null &&
        (dir == exclude ||
            p.isWithin(dir, exclude) ||
            p.isWithin(exclude, dir))) {
      continue;
    }
    if (!out.any((m) => m.dir == dir)) out.add((device: dev, dir: dir));
  }
  return out;
}

/// `/proc/mounts` writes spaces and tabs in paths as octal escapes.
String _unescape(String s) => s.replaceAllMapped(
  RegExp(r'\\([0-7]{3})'),
  (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
);

/// The roots on this device ([handheld] true on the Linux card, else the
/// Android fallback). [env], [mounts] and [storage] stand in for the real
/// environment, `/proc/mounts` and `/storage` in tests.
Future<List<ExplorerRoot>> explorerRoots({
  required bool handheld,
  Map<String, String>? env,
  String? mounts,
  Directory? storage,
}) async {
  final roots = <ExplorerRoot>[];
  if (handheld) {
    final card = (env ?? Platform.environment)['DENA_CARD'];
    if (card != null && card.isNotEmpty) {
      final roms = p.join(card, 'Roms');
      roots.add(
        ExplorerRoot(
          'Games card',
          card,
          DenaIcons.sdCard,
          start: await Directory(roms).exists() ? roms : null,
        ),
      );
    }
    String text;
    try {
      text = mounts ?? await File('/proc/mounts').readAsString();
    } on FileSystemException {
      text = '';
    }
    final extra = removableMounts(
      text,
      exclude: card == null || card.isEmpty ? null : card,
    );
    final usbCount = extra.where((m) => m.device.startsWith('/dev/sd')).length;
    var usbIndex = 0;
    for (final m in extra) {
      final usb = m.device.startsWith('/dev/sd');
      if (usb) usbIndex++;
      roots.add(
        ExplorerRoot(
          usb
              ? (usbCount == 1 ? 'USB drive' : 'USB drive $usbIndex')
              : p.basename(m.dir),
          m.dir,
          usb ? DenaIcons.usb : DenaIcons.sdCard,
        ),
      );
    }
    return roots;
  }
  final base = storage ?? Directory('/storage');
  final shared = p.join(base.path, 'emulated', '0');
  if (await Directory(shared).exists()) {
    roots.add(ExplorerRoot('Internal storage', shared, DenaIcons.folder));
  }
  try {
    await for (final e in base.list()) {
      final name = p.basename(e.path);
      if (e is! Directory || name == 'emulated' || name == 'self') continue;
      roots.add(ExplorerRoot(name, e.path, DenaIcons.sdCard));
    }
  } on FileSystemException {
    // No /storage listing without permission; shared storage is enough.
  }
  return roots;
}

/// Whether [name] ends with one of [extensions] (lower-cased, with dot).
bool matchesExtension(String name, List<String> extensions) {
  final lower = name.toLowerCase();
  return extensions.any(lower.endsWith);
}

/// One row of a folder listing.
class ExplorerEntry {
  const ExplorerEntry(
    this.path, {
    required this.isFolder,
    this.size,
    this.modified,
  });

  final String path;
  final bool isFolder;

  /// Bytes; null for folders or when the file can't be read.
  final int? size;
  final DateTime? modified;

  String get name => p.basename(path);

  /// The TYPE column: `DIR`, or the extension in capitals (`GBA`).
  String get type {
    if (isFolder) return 'DIR';
    final ext = p.extension(path);
    return ext.isEmpty ? '-' : ext.substring(1).toUpperCase();
  }
}

/// `812 B`, `4.0K`, `12.3M`, `1.20G`: short enough for a table column.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}G';
}

/// `2026-10-18`: the MODIFIED column.
String formatDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The folders and (matching, unless [allFiles]) files directly in [dir],
/// folders first, by name. Hidden entries are left out. Throws
/// [FileSystemException] when [dir] can't be read.
Future<List<ExplorerEntry>> listFolder(
  Directory dir,
  List<String> extensions, {
  bool allFiles = false,
}) async {
  final folders = <ExplorerEntry>[];
  final files = <ExplorerEntry>[];
  await for (final e in dir.list(followLinks: true)) {
    final name = p.basename(e.path);
    if (name.startsWith('.')) continue;
    if (e is Directory) {
      folders.add(ExplorerEntry(e.path, isFolder: true));
    } else if (e is File && (allFiles || matchesExtension(name, extensions))) {
      FileStat? stat;
      try {
        stat = await e.stat();
      } on FileSystemException {
        stat = null;
      }
      files.add(
        ExplorerEntry(
          e.path,
          isFolder: false,
          size: stat?.size,
          modified: stat?.modified,
        ),
      );
    }
  }
  int byName(ExplorerEntry a, ExplorerEntry b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return [...folders..sort(byName), ...files..sort(byName)];
}

/// Every file under [dir] whose name matches [extensions], down to
/// [maxDepth] folder levels and at most [limit] files. Unreadable folders
/// are skipped.
Future<List<String>> collectGames(
  Directory dir,
  List<String> extensions, {
  int maxDepth = 8,
  int limit = 5000,
}) async {
  final out = <String>[];
  Future<void> walk(Directory d, int depth) async {
    if (depth > maxDepth || out.length >= limit) return;
    final List<FileSystemEntity> children;
    try {
      children = await d.list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final e in children) {
      if (out.length >= limit) return;
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        await walk(e, depth + 1);
      } else if (e is File && matchesExtension(name, extensions)) {
        out.add(e.path);
      }
    }
  }

  await walk(dir, 0);
  return out;
}

/// Remembers the last folder the explorer had open, in `<data>/explorer.json`.
class ExplorerMemory {
  ExplorerMemory(this.file);

  final File file;

  /// The app's own memory file in the data folder.
  static Future<ExplorerMemory> load() async =>
      ExplorerMemory(File(p.join((await appDataDir()).path, 'explorer.json')));

  Future<String?> last() async {
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map && json['last'] is String
          ? json['last'] as String
          : null;
    } on Object {
      return null;
    }
  }

  Future<void> remember(String path) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'last': path}));
    } on FileSystemException catch (e) {
      debugPrint('Explorer: could not save last folder: $e');
    }
  }
}

/// Opens a picker and returns the paths to import (library.md, Import).
typedef GamePicker = Future<List<String>> Function(
  BuildContext context, {
  required bool folder,
  required List<String> extensions,
});

/// Add games / Add a folder. With [StorageAccess] granted (Android, asked
/// for here once per run) [explorer], the in-app file explorer; else the
/// system picker of [files] when it has one, and [explorer] when there is
/// none or it fails to start.
Future<List<String>> pickGamePaths(
  BuildContext context,
  GameFileSource files, {
  required bool folder,
  GamePicker explorer = pickWithExplorer,
}) async {
  if (files case final StorageAccess storage) {
    if (await _storageAccess(context, storage)) {
      if (!context.mounted) return const [];
      return explorer(context, folder: folder, extensions: importExtensions);
    }
  }
  if (!context.mounted) return const [];
  if (files.hasPicker) {
    try {
      return folder
          ? await files.pickFolder(importExtensions)
          : await files.pickFiles();
    } on PlatformException catch (e) {
      // No system picker (e.g. no DocumentsUI): use the in-app explorer.
      debugPrint('System picker unavailable: $e');
    }
  }
  if (!context.mounted) return const [];
  return explorer(context, folder: folder, extensions: importExtensions);
}

/// Sources whose user chose the system picker over storage access this run.
final _pickerChosen = Expando<bool>();

/// Whether [storage] can be browsed: granted already, or granted now after
/// the FILE ACCESS dialog. Asks once per run; a refusal keeps the picker.
Future<bool> _storageAccess(BuildContext context, StorageAccess storage) async {
  try {
    if (await storage.hasStorageAccess()) return true;
    if (_pickerChosen[storage] ?? false) return false;
    if (!context.mounted) return false;
    final allow = await showBrutalDialog<bool>(
      context: context,
      builder: (context) => BrutalDialog(
        title: 'FILE ACCESS',
        body: const Text(
          'To browse your game folders, Dena.emu needs All files access. '
          'Turn on "Allow access" on the next screen, then go back. '
          'Games you add are copied into the library; nothing else is read.',
        ),
        actions: [
          BrutalDialogAction(
            label: 'SYSTEM PICKER',
            onPressed: () => Navigator.pop(context, false),
          ),
          BrutalDialogAction(
            label: 'ALLOW',
            primary: true,
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (allow ?? false) {
      if (await storage.requestStorageAccess()) return true;
    }
    _pickerChosen[storage] = true;
    return false;
  } on PlatformException catch (e) {
    debugPrint('Storage access unavailable: $e');
    return false;
  }
}

/// Opens the explorer and returns the paths to import: the checked files
/// ([folder] false) or every matching file under the chosen folder. Empty
/// when the user backs out.
Future<List<String>> pickWithExplorer(
  BuildContext context, {
  required bool folder,
  required List<String> extensions,
  List<ExplorerRoot>? roots,
  ExplorerMemory? memory,
}) async {
  final handheld = Handheld.of(context);
  final navigator = Navigator.of(context);
  final found =
      roots ?? await explorerRoots(handheld: handheld || !Platform.isAndroid);
  var mem = memory;
  if (mem == null) {
    try {
      mem = await ExplorerMemory.load();
    } on Object catch (e) {
      debugPrint('Explorer: no data folder to remember the last folder: $e');
    }
  }
  final result = await navigator.push<List<String>>(
    MaterialPageRoute(
      builder: (_) => FileExplorerPage(
        roots: found,
        folderMode: folder,
        extensions: extensions,
        memory: mem,
      ),
    ),
  );
  return result ?? const [];
}

/// The explorer screen. Pops with the paths to import.
class FileExplorerPage extends StatefulWidget {
  const FileExplorerPage({
    super.key,
    required this.roots,
    required this.folderMode,
    required this.extensions,
    this.memory,
  });

  final List<ExplorerRoot> roots;

  /// Add a folder (true) or Add games (false).
  final bool folderMode;
  final List<String> extensions;
  final ExplorerMemory? memory;

  @override
  State<FileExplorerPage> createState() => _FileExplorerPageState();
}

class _FileExplorerPageState extends State<FileExplorerPage> {
  /// The open folder; null shows the list of roots.
  String? dir;
  ExplorerRoot? root;
  List<ExplorerEntry> entries = const [];
  bool loading = true;
  bool unreadable = false;
  bool allFiles = false;
  bool collecting = false;
  final checked = <String>{};

  /// Bumped on every folder change so the list starts at the top again,
  /// with its first row focused (a fresh focus scope lets it autofocus).
  int generation = 0;

  /// The last action and how it went, shown as a log line.
  (String, LogStatus)? log;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final last = await widget.memory?.last();
    if (last != null) {
      for (final r in widget.roots) {
        if ((last == r.path || p.isWithin(r.path, last)) &&
            await Directory(last).exists()) {
          return _open(r, last, remember: false);
        }
      }
    }
    if (widget.roots.length == 1) {
      final r = widget.roots.single;
      return _open(r, r.start ?? r.path, remember: false);
    }
    _showRoots();
  }

  void _showRoots() {
    if (!mounted) return;
    setState(() {
      dir = null;
      root = null;
      entries = const [];
      loading = false;
      unreadable = false;
      generation++;
    });
  }

  Future<void> _open(
    ExplorerRoot r,
    String path, {
    bool remember = true,
  }) async {
    setState(() {
      loading = true;
      root = r;
      dir = path;
    });
    List<ExplorerEntry> list;
    var failed = false;
    try {
      list = await listFolder(
        Directory(path),
        widget.extensions,
        allFiles: allFiles,
      );
    } on FileSystemException {
      list = const [];
      failed = true;
    }
    if (!mounted || dir != path) return;
    setState(() {
      entries = list;
      unreadable = failed;
      loading = false;
      generation++;
      log = ('open ${p.basename(path)}', failed ? LogStatus.err : LogStatus.ok);
    });
    if (remember && !failed) await widget.memory?.remember(path);
  }

  /// Whether B goes up a level instead of closing the explorer.
  bool get canGoUp {
    final d = dir;
    final r = root;
    if (d == null || r == null) return false;
    return d != r.path || widget.roots.length > 1;
  }

  void _up() {
    final d = dir;
    final r = root;
    if (d == null || r == null) return;
    if (d == r.path) {
      _showRoots();
    } else {
      _open(r, p.dirname(d));
    }
  }

  void _toggleFilter() {
    setState(() => allFiles = !allFiles);
    log = (allFiles ? 'show all files' : 'show games only', LogStatus.none);
    if (root case final r? when dir != null) _open(r, dir!, remember: false);
  }

  void _toggleAll() {
    final files = [
      for (final e in entries)
        if (!e.isFolder) e.path,
    ];
    if (files.isEmpty) return;
    setState(() {
      if (files.every(checked.contains)) {
        checked.removeAll(files);
      } else {
        checked.addAll(files);
      }
    });
  }

  Future<void> _confirm() async {
    if (widget.folderMode) {
      final d = dir;
      if (d == null || collecting) return;
      setState(() {
        collecting = true;
        log = ('find games in ${p.basename(d)}', LogStatus.none);
      });
      final games = await collectGames(Directory(d), widget.extensions);
      await widget.memory?.remember(d);
      if (mounted) Navigator.of(context).pop(games);
    } else {
      if (checked.isEmpty) return;
      if (dir case final d?) await widget.memory?.remember(d);
      if (mounted) Navigator.of(context).pop(checked.toList());
    }
  }

  void _activate(ExplorerEntry e) {
    if (e.isFolder) {
      _open(root!, e.path);
    } else if (!widget.folderMode) {
      setState(() {
        final on = checked.add(e.path);
        if (!on) checked.remove(e.path);
        log = ('${on ? 'check' : 'uncheck'} ${e.name}', LogStatus.ok);
      });
    }
  }

  String get _title => widget.folderMode ? 'ADD A FOLDER' : 'ADD GAMES';

  String get _confirmLabel => widget.folderMode
      ? (collecting ? 'Finding games…' : 'Use this folder')
      : checked.length == 1
      ? 'Add 1 game'
      : 'Add ${checked.length} games';

  bool get _canConfirm =>
      widget.folderMode ? dir != null && !collecting : checked.isNotEmpty;

  /// `/mnt > card > Roms > gba`, or `/storage` on the list of roots.
  List<String> get _segments {
    final d = dir;
    if (d == null) return const ['storage'];
    final parts = p.split(d).where((s) => s != p.separator && s.isNotEmpty);
    return parts.isEmpty ? [d] : parts.toList();
  }

  (String, LogStatus) get _log {
    if (log case final l?) return l;
    if (!widget.folderMode) {
      return checked.isEmpty
          ? ('press A on a game to check it', LogStatus.none)
          : ('${checked.length} checked', LogStatus.none);
    }
    return dir == null
        ? ('choose storage', LogStatus.none)
        : ('use this folder to add every game under it', LogStatus.none);
  }

  @override
  Widget build(BuildContext context) {
    final handheld = Handheld.of(context);
    final (logText, logStatus) = _log;
    final files = entries.where((e) => !e.isFolder);
    final allChecked =
        files.isNotEmpty && files.every((e) => checked.contains(e.path));
    return PopScope(
      canPop: !canGoUp,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.gameButtonStart): _confirm,
          const SingleActivator(LogicalKeyboardKey.gameButtonSelect): _confirm,
          const SingleActivator(LogicalKeyboardKey.gameButtonY): _toggleFilter,
          if (!widget.folderMode)
            const SingleActivator(LogicalKeyboardKey.gameButtonX): _toggleAll,
        },
        // Holds focus when the folder has nothing focusable, so B and Start
        // still reach the shortcuts above.
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(title: Text(_title)),
            body: BrutalGridPaper(
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.all(
                    handheld ? BrutalTokens.s2 : BrutalTokens.s3,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PathBar(segments: _segments, hint: root?.label),
                      const SizedBox(height: BrutalTokens.s2),
                      Expanded(child: _body()),
                      const SizedBox(height: BrutalTokens.s1),
                      LogLine(logText, status: logStatus),
                      if (!handheld || dir != null) ...[
                        const SizedBox(height: BrutalTokens.s2),
                        Wrap(
                          spacing: BrutalTokens.s2,
                          runSpacing: BrutalTokens.s2,
                          alignment: WrapAlignment.end,
                          children: [
                            if (canGoUp)
                              BrutalButton(
                                label: 'Up',
                                icon: DenaIcons.expandLess,
                                onPressed: _up,
                              ),
                            if (dir != null)
                              BrutalButton(
                                label: 'All files',
                                icon: DenaIcons.list,
                                value: allFiles ? '[ON]' : '[OFF]',
                                onPressed: _toggleFilter,
                              ),
                            if (!widget.folderMode && files.isNotEmpty)
                              BrutalButton(
                                label: allChecked
                                    ? 'Select none'
                                    : 'Select all',
                                icon: DenaIcons.radioOn,
                                onPressed: _toggleAll,
                              ),
                            BrutalButton(
                              label: _confirmLabel,
                              icon: widget.folderMode
                                  ? DenaIcons.folderAdd
                                  : DenaIcons.fileAdd,
                              variant: BrutalButtonVariant.primary,
                              onPressed: _canConfirm ? _confirm : null,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            bottomNavigationBar: usesButtons(context)
                ? BrutalHintBar(
                    hints: [
                      (
                        [HintButton.a],
                        widget.folderMode ? 'Open' : 'Open/Check',
                      ),
                      ([HintButton.b], canGoUp ? 'Up' : 'Close'),
                      if (!widget.folderMode && dir != null)
                        ([HintButton.x], 'All'),
                      if (dir != null)
                        ([HintButton.y], allFiles ? 'Games only' : 'All files'),
                      if (_canConfirm)
                        (
                          [HintButton.start],
                          widget.folderMode ? 'Use folder' : 'Add',
                        ),
                    ],
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (loading) {
      return Align(
        alignment: Alignment.topLeft,
        child: LogLine('reading ${dir == null ? 'storage' : p.basename(dir!)}'),
      );
    }
    if (dir == null) {
      if (widget.roots.isEmpty) {
        return const Align(
          alignment: Alignment.topLeft,
          child: EmptyState(
            headline: 'No storage.',
            message: 'no card or drive to browse',
          ),
        );
      }
      return FocusScope(
        key: ValueKey(generation),
        child: BrutalTable(
          columns: const [
            BrutalColumn('Storage', flex: 2),
            BrutalColumn('Path', flex: 3),
          ],
          rowCount: widget.roots.length,
          autofocusRow: 0,
          onRowPressed: (i) {
            final r = widget.roots[i];
            _open(r, r.start ?? r.path);
          },
          cellBuilder: (context, i, c, lit) {
            final r = widget.roots[i];
            return c == 0
                ? _NameCell(icon: r.icon, name: r.label, lit: lit)
                : Text(r.path);
          },
        ),
      );
    }
    if (unreadable || entries.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: EmptyState(
          headline: unreadable
              ? "Can't open."
              : allFiles
              ? 'Empty folder.'
              : 'No games here.',
          message: unreadable
              ? 'this folder is locked or gone'
              : allFiles
              ? 'nothing in this folder'
              : 'no games in this folder; Y shows every file',
          action: canGoUp ? 'Up' : null,
          icon: DenaIcons.expandLess,
          onAction: canGoUp ? _up : null,
          autofocus: true,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 560;
        final checks = !widget.folderMode;
        return FocusScope(
          key: ValueKey(generation),
          child: BrutalTable(
            columns: [
              if (checks) const BrutalColumn('', width: 40),
              const BrutalColumn('Name', flex: 3),
              const BrutalColumn('Size', width: 76, numeric: true),
              if (wide) const BrutalColumn('Modified', width: 108),
              const BrutalColumn('Type', width: 56),
            ],
            rowCount: entries.length,
            autofocusRow: 0,
            onRowPressed: (i) {
              final e = entries[i];
              if (e.isFolder || !widget.folderMode) _activate(e);
            },
            cellBuilder: (context, i, c, lit) {
              final e = entries[i];
              final col = checks ? c : c + 1;
              final muted = TextStyle(
                color: lit ? null : BrutalTokens.of(context).mutedText,
              );
              return switch (col) {
                0 => Text(
                  e.isFolder
                      ? ''
                      : checked.contains(e.path)
                      ? '[x]'
                      : '[ ]',
                ),
                1 => _NameCell(
                  icon: e.isFolder ? DenaIcons.folder : DenaIcons.cartOutline,
                  name: e.isFolder ? '${e.name}/' : e.name,
                  lit: lit,
                ),
                2 => Text(
                  e.size == null ? '-' : formatSize(e.size!),
                  style: muted,
                ),
                3 when wide => Text(
                  e.modified == null ? '-' : formatDay(e.modified!),
                  style: muted,
                ),
                _ => Text(e.type, style: muted),
              };
            },
          ),
        );
      },
    );
  }
}

/// A table cell with a 9x9 icon before the name.
class _NameCell extends StatelessWidget {
  const _NameCell({required this.icon, required this.name, required this.lit});

  final IconData icon;
  final String name;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Row(
      children: [
        Icon(icon, size: BrutalTokens.iconSize, color: lit ? t.onFocus : t.ink),
        const SizedBox(width: BrutalTokens.s2),
        Expanded(
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
