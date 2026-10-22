// SPDX-License-Identifier: GPL-3.0-or-later
// Cheats sheet: list, toggle, add and delete a game's cheats.
// Spec: docs/specs/cheats.md
import 'package:material_ui/material_ui.dart';

import '../library/database.dart';
import 'cheat_browser.dart';
import 'cheat_codes.dart';
import 'cheat_database.dart';
import 'pause_sheets.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Sends the enabled cheats (in core form) to the running core.
typedef ApplyCheats = Future<void> Function(List<String> codes);

/// The enabled cheats of [gameId] in the form the core wants.
Future<List<String>> enabledCheatCodes(LibraryDatabase db, int gameId) async =>
    [
      for (final c in await db.cheatsFor(gameId))
        if (c.enabled) coreCode(c.code),
    ];

/// The game's cheats as CHEATS.CFG: one row per cheat with an `[ON]`/`[OFF]`
/// key and a hold-to-delete, `[+] ADD CODE` and the database browser.
class CheatsSheet extends StatelessWidget {
  const CheatsSheet({
    super.key,
    required this.db,
    required this.game,
    required this.apply,
    this.database,
    this.clock = DateTime.now,
  });

  /// The sheet's header.
  static const title = 'CHEATS';

  final LibraryDatabase db;
  final Game game;
  final ApplyCheats apply;

  /// The cheat database to browse; no **Browse** button when null or when the
  /// system has no database cheats.
  final CheatDatabase? database;
  final DateTime Function() clock;

  Future<void> _changed() async => apply(await enabledCheatCodes(db, game.id));

  Future<void> _add(BuildContext context) async {
    final added = await showBrutalDialog<ParsedCheat>(
      context: context,
      builder: (_) => _AddCheatDialog(system: game.system, onSave: _save),
    );
    if (added != null) await _changed();
  }

  Future<void> _browse(BuildContext context) => showSessionSheet<void>(
    context: context,
    title: CheatBrowserSheet.title,
    builder: (_) => CheatBrowserSheet(
      db: db,
      game: game,
      database: database!,
      apply: apply,
      clock: clock,
    ),
  );

  Future<void> _save(String name, ParsedCheat cheat) => db.addCheat(
    gameId: game.id,
    name: name,
    code: cheat.stored,
    format: cheat.format,
    createdAt: clock(),
  );

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3 + 4,
        BrutalTokens.s3,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: BrutalTokens.s2,
            runSpacing: BrutalTokens.s2,
            children: [
              BrutalButton(
                icon: DenaIcons.add,
                label: 'Add code',
                variant: BrutalButtonVariant.primary,
                onPressed: () => _add(context),
              ),
              if (database != null && cheatDbSystems.containsKey(game.system))
                BrutalButton(
                  icon: DenaIcons.globe,
                  label: 'Browse',
                  onPressed: () => _browse(context),
                ),
            ],
          ),
          const SizedBox(height: BrutalTokens.s3),
          Flexible(
            child: StreamBuilder<List<Cheat>>(
              stream: db.watchCheats(game.id),
              builder: (context, snap) {
                final cheats = snap.data ?? const <Cheat>[];
                if (cheats.isEmpty) {
                  return BrutalPanel(
                    header: 'CHEATS.CFG',
                    padding: const EdgeInsets.all(BrutalTokens.s3),
                    child: Text(
                      'No cheats yet. Add a Game Genie, Action Replay, '
                      'GameShark or raw code.',
                      style: t.body,
                    ),
                  );
                }
                return SingleChildScrollView(
                  child: CfgTable(
                    header: 'CHEATS.CFG',
                    rows: [
                      for (final (i, c) in cheats.indexed)
                        _CheatRow(
                          cheat: c,
                          autofocus: i == 0,
                          onToggle: (on) async {
                            await db.setCheatEnabled(c.id, on);
                            await _changed();
                          },
                          onDelete: () async {
                            await db.deleteCheat(c.id);
                            await _changed();
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CheatRow extends StatelessWidget {
  const _CheatRow({
    required this.cheat,
    required this.autofocus,
    required this.onToggle,
    required this.onDelete,
  });

  final Cheat cheat;
  final bool autofocus;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final lines = cheat.code.split('\n');
    final summary = lines.length == 1
        ? lines.first
        : '${lines.first} (+${lines.length - 1})';
    return Container(
      constraints: BoxConstraints(minHeight: t.rowHeight),
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s1,
        BrutalTokens.s2,
        BrutalTokens.s1,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  cheat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.row,
                ),
                Text(
                  '${cheat.format} // $summary',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.small.copyWith(color: t.mutedText),
                ),
              ],
            ),
          ),
          const SizedBox(width: BrutalTokens.s2),
          CfgToggle(
            value: cheat.enabled,
            autofocus: autofocus,
            semanticLabel: cheat.name,
            onChanged: onToggle,
          ),
          const SizedBox(width: BrutalTokens.s2),
          Tooltip(
            message: 'Delete ${cheat.name}',
            child: HoldToConfirm(
              label: 'Del',
              icon: DenaIcons.trash,
              onConfirmed: onDelete,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddCheatDialog extends StatefulWidget {
  const _AddCheatDialog({required this.system, required this.onSave});

  final String system;
  final Future<void> Function(String name, ParsedCheat cheat) onSave;

  @override
  State<_AddCheatDialog> createState() => _AddCheatDialogState();
}

class _AddCheatDialogState extends State<_AddCheatDialog> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final parsed = parseCheat(widget.system, _code.text);
    if (parsed == null) {
      setState(
        () => _error =
            "This doesn't look like a ${systemLabel(widget.system)} code",
      );
      return;
    }
    final name = _name.text.trim().isEmpty
        ? parsed.lines.first
        : _name.text.trim();
    await widget.onSave(name, parsed);
    if (mounted) Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return BrutalDialog(
      title: 'ADD CODE',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: BrutalTokens.s2),
          TextField(
            controller: _code,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'Code',
              helperText: 'One code per line',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        BrutalDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        BrutalDialogAction(label: 'Add', primary: true, onPressed: _submit),
      ],
    );
  }
}
