// SPDX-License-Identifier: GPL-3.0-or-later
// Cheat database browser: popular and searchable cheats for the running game.
// Spec: docs/specs/cheats.md (Cheat database)
import 'package:material_ui/material_ui.dart';

import '../library/database.dart';
import 'cheat_database.dart';
import 'cheats_sheet.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// The cheat database for the running game: a search field and tables of
/// popular and all cheats with a `[x]` column; a row press turns one on or off.
class CheatBrowserSheet extends StatefulWidget {
  const CheatBrowserSheet({
    super.key,
    required this.db,
    required this.game,
    required this.database,
    required this.apply,
    this.clock = DateTime.now,
  });

  /// The sheet's header.
  static const title = 'CHEATS.DB';

  final LibraryDatabase db;
  final Game game;
  final CheatDatabase database;
  final ApplyCheats apply;
  final DateTime Function() clock;

  @override
  State<CheatBrowserSheet> createState() => _CheatBrowserSheetState();
}

class _CheatBrowserSheetState extends State<CheatBrowserSheet> {
  late Future<CheatLookup> _lookup = widget.database.cheatsFor(widget.game);
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Cheat? _stored(List<Cheat> mine, DbCheat c) {
    for (final m in mine) {
      if (m.name == c.name && m.code == c.code) return m;
    }
    return null;
  }

  Future<void> _turnOn(DbCheat c) async {
    final mine = await widget.db.cheatsFor(widget.game.id);
    for (final x in [...(await _lookup).mastersOf(c), c]) {
      final have = _stored(mine, x);
      if (have == null) {
        await widget.db.addCheat(
          gameId: widget.game.id,
          name: x.name,
          code: x.code,
          format: x.format,
          createdAt: widget.clock(),
        );
      } else if (!have.enabled) {
        await widget.db.setCheatEnabled(have.id, true);
      }
    }
  }

  Future<void> _toggle(DbCheat c, bool on) async {
    if (on) {
      await _turnOn(c);
    } else {
      final have = _stored(await widget.db.cheatsFor(widget.game.id), c);
      if (have != null) await widget.db.deleteCheat(have.id);
    }
    await widget.apply(await enabledCheatCodes(widget.db, widget.game.id));
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3 + 4,
        BrutalTokens.s2,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommandField(
            controller: _search,
            icon: DenaIcons.search,
            hint: 'search cheats',
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          const SizedBox(height: BrutalTokens.s3),
          Flexible(
            child: FutureBuilder<CheatLookup>(
              future: _lookup,
              builder: (context, snap) {
                if (snap.hasError) return _error(t);
                final lookup = snap.data;
                if (lookup == null) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: BrutalTokens.s4),
                    child: LogLine('download cheats ...'),
                  );
                }
                if (lookup.cheats.isEmpty) {
                  return _message(
                    t,
                    'No cheats for this game in the database.',
                  );
                }
                return StreamBuilder<List<Cheat>>(
                  stream: widget.db.watchCheats(widget.game.id),
                  builder: (context, mineSnap) =>
                      _list(t, lookup, mineSnap.data ?? const []),
                );
              },
            ),
          ),
          const SizedBox(height: BrutalTokens.s2),
          Text(
            'Cheats from libretro-database (CC-BY-SA 4.0)',
            style: t.small.copyWith(color: t.mutedText),
          ),
        ],
      ),
    );
  }

  Widget _message(BrutalTokens t, String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: BrutalTokens.s4),
    child: Text(message, style: t.body),
  );

  Widget _error(BrutalTokens t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: BrutalTokens.s4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LogLine('download cheats', status: LogStatus.err),
        const SizedBox(height: BrutalTokens.s1),
        Text("Couldn't download cheats. Check your connection.", style: t.body),
        const SizedBox(height: BrutalTokens.s3),
        BrutalButton(
          autofocus: true,
          icon: DenaIcons.refresh,
          label: 'Retry',
          onPressed: () => setState(() {
            _lookup = widget.database.cheatsFor(widget.game);
          }),
        ),
      ],
    ),
  );

  Widget _list(BrutalTokens t, CheatLookup lookup, List<Cheat> mine) {
    final q = _query.toLowerCase();
    final popular = q.isEmpty ? lookup.popularCheats : const <DbCheat>[];
    final all = [
      for (final c in lookup.cheats)
        if (q.isEmpty || c.name.toLowerCase().contains(q)) c,
    ];
    return ListView(
      shrinkWrap: true,
      children: [
        if (popular.isNotEmpty) ...[
          _header(t, 'Popular'),
          _table(t, popular, mine, autofocus: true),
          const SizedBox(height: BrutalTokens.s3),
        ],
        _header(t, 'All cheats (${all.length})'),
        if (all.isEmpty)
          _message(t, 'No cheats match "$_query".')
        else
          _table(t, all, mine, autofocus: popular.isEmpty && q.isEmpty),
      ],
    );
  }

  Widget _header(BrutalTokens t, String label) => Padding(
    padding: const EdgeInsets.only(bottom: BrutalTokens.s1),
    child: Text(label, style: t.label),
  );

  Widget _table(
    BrutalTokens t,
    List<DbCheat> cheats,
    List<Cheat> mine, {
    bool autofocus = false,
  }) {
    bool on(DbCheat c) => _stored(mine, c)?.enabled ?? false;
    return Padding(
      padding: EdgeInsets.only(
        right: t.shadowOffsetLarge.dx,
        bottom: t.shadowOffsetLarge.dy,
      ),
      child: BrutalTable(
        shrinkWrap: true,
        columns: const [
          BrutalColumn('[x]', width: 44),
          BrutalColumn('Cheat', flex: 3),
          BrutalColumn('Fmt', width: 72),
        ],
        rowCount: cheats.length,
        autofocusRow: autofocus ? 0 : null,
        onRowPressed: (i) => _toggle(cheats[i], !on(cheats[i])),
        cellBuilder: (context, row, column, lit) {
          final c = cheats[row];
          return Text(switch (column) {
            0 => on(c) ? '[x]' : '[ ]',
            1 => c.name,
            _ => c.format,
          });
        },
      ),
    );
  }
}
