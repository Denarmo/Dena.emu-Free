// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Files › Game folders on a PC. Spec: docs/specs/desktop-library.md
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';
import 'desktop_files.dart';
import 'game_folders.dart';

/// The Settings tile: how many folders are watched; opens [GameFoldersPage].
class GameFoldersTile extends StatelessWidget {
  const GameFoldersTile({super.key, required this.folders, this.files});

  final GameFolders folders;
  final DesktopGameFiles? files;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: folders,
    builder: (context, _) {
      final n = folders.all.length;
      return ListTile(
        leading: const Icon(DenaIcons.folder),
        title: const Text('Game folders'),
        subtitle: Text(
          n == 0
              ? 'Add folders with your games; new games show up by themselves'
              : n == 1
              ? '1 folder, watched for new games'
              : '$n folders, watched for new games',
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GameFoldersPage(folders: folders, files: files),
          ),
        ),
      );
    },
  );
}

/// Lists the watched folders as `FOLDERS.CFG`: add one, rescan all, hold
/// to remove one (brutalist-ui.md 4.9).
class GameFoldersPage extends StatefulWidget {
  const GameFoldersPage({super.key, required this.folders, this.files});

  final GameFolders folders;
  final DesktopGameFiles? files;

  @override
  State<GameFoldersPage> createState() => _GameFoldersPageState();
}

class _GameFoldersPageState extends State<GameFoldersPage> {
  /// The last action's result, shown as a log line.
  (String, LogStatus)? log;

  GameFolders get folders => widget.folders;

  void _say(String text, LogStatus status) {
    if (!mounted) return;
    setState(() => log = (text, status));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add() async {
    final String? dir;
    try {
      dir = await (widget.files ?? DesktopGameFiles()).pickDirectory();
    } on PlatformException catch (e) {
      _say('No folder dialog: ${e.message}', LogStatus.err);
      return;
    }
    if (dir == null) return;
    final s = await folders.add(dir);
    _say('${s.added} games added', LogStatus.ok);
  }

  Future<void> _scan() async {
    final s = await folders.scanAll();
    _say('${s.added} added, ${s.removed} no longer found', LogStatus.ok);
  }

  Future<void> _remove(String dir) async {
    final n = await folders.remove(dir);
    _say('Removed. $n games left the library; the files stay', LogStatus.ok);
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    Widget row(String dir, Widget trailing) => Container(
      constraints: BoxConstraints(minHeight: t.rowHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s3,
        vertical: BrutalTokens.s1,
      ),
      child: Row(
        children: [
          Icon(DenaIcons.folder, size: BrutalTokens.iconSize, color: t.ink),
          const SizedBox(width: BrutalTokens.s2),
          Expanded(child: Text(dir, style: t.row)),
          const SizedBox(width: BrutalTokens.s2),
          trailing,
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('GAME FOLDERS')),
      body: BrutalGridPaper(
        child: ListenableBuilder(
          listenable: folders,
          builder: (context, _) {
            final (logText, logStatus) =
                log ??
                (
                  folders.scanning ? 'scanning folders' : 'games stay where they are; new ones show up by themselves',
                  LogStatus.none,
                );
            return ListView(
              padding: const EdgeInsets.all(BrutalTokens.s4),
              children: [
                Wrap(
                  spacing: BrutalTokens.s2,
                  runSpacing: BrutalTokens.s2,
                  children: [
                    BrutalButton(
                      label: 'Add folder',
                      icon: DenaIcons.folderAdd,
                      variant: BrutalButtonVariant.primary,
                      autofocus: true,
                      onPressed: _add,
                    ),
                    BrutalButton(
                      label: folders.scanning ? 'Scanning…' : 'Scan again',
                      icon: DenaIcons.refresh,
                      onPressed: folders.scanning ? null : _scan,
                    ),
                  ],
                ),
                const SizedBox(height: BrutalTokens.s2),
                LogLine(logText, status: logStatus),
                const SizedBox(height: BrutalTokens.s4),
                CfgTable(
                  header: 'FOLDERS.CFG',
                  rows: [
                    for (final dir in folders.fixed)
                      row(
                        dir,
                        Text(
                          '[PORTABLE]',
                          style: t.label.copyWith(color: t.mutedText),
                        ),
                      ),
                    for (final dir in folders.folders)
                      row(
                        dir,
                        HoldToConfirm(
                          label: 'Hold to remove',
                          icon: DenaIcons.trash,
                          onConfirmed: () => _remove(dir),
                        ),
                      ),
                    if (folders.all.isEmpty)
                      row(
                        'no folders yet',
                        Text(
                          '[EMPTY]',
                          style: t.label.copyWith(color: t.mutedText),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
