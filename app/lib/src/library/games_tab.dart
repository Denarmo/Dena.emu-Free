// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md (Screens, D-pad and focus),
// docs/specs/brutalist-ui.md (4.2)
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../romtools/rom_manager.dart';
import '../romtools/rom_page.dart';
import '../session/session_screen.dart' show coreLibraries;
import '../shell/handheld.dart';
import '../ui/app_theme.dart';
import '../ui/brutal/brutal.dart';
import '../ui/onscreen_keyboard.dart';
import '../ui/system_palette.dart';
import 'box_art.dart' show BoxArtCache;
import 'card_files.dart';
import 'database.dart';
import 'desktop_files.dart';
import 'file_explorer.dart';
import 'foil.dart';
import 'game_box.dart';
import 'game_box_menu.dart';
import 'game_folders.dart';
import 'import_rules.dart';
import 'launch_animation.dart';
import 'library_scope.dart';
import 'romhacks.dart';
import 'stash_view.dart';
import '../ui/dena_icons.dart';

/// Stands in for the ROM manager's results where there is none.
final _noChanges = Listenable.merge(const []);

/// Called when the user chooses Play on a game.
typedef PlayGame = void Function(BuildContext context, Game game);

class GamesTab extends StatefulWidget {
  const GamesTab({super.key, required this.onPlay});

  final PlayGame onPlay;

  @override
  State<GamesTab> createState() => _GamesTabState();
}

class _GamesTabState extends State<GamesTab> {
  String? system;

  /// The DAT.CHK filter (rom-manager.md 5); null shows every game.
  DatFilter? datFilter;
  String query = '';
  TableSort sort = TableSort.title;
  bool ascending = true;
  final search = TextEditingController();
  bool _checkedShares = false;
  LibraryView _viewLocal = LibraryView.table;

  LibraryDatabase? _db;
  Stream<List<Game>>? _all;

  /// The games on screen, in order.
  List<Game> _shown = const [];

  /// Every game in the library, for the DAT.CHK counts.
  List<Game> _allGames = const [];

  /// The focused game (INSPECT panel, handheld preview) and the shuffle's
  /// pick (lit on touch, where focus is hidden).
  int? _focusedId, _selectedId;

  final _tableScroll = ScrollController();
  final _gridScroll = ScrollController();
  final _random = math.Random();

  /// Table rows on screen: their focus nodes and BOX cells, by row.
  final _rowNodes = <int, FocusNode>{};
  final _rowContexts = <int, BuildContext>{};

  /// Grid cards' focus nodes, by game id.
  final _gridNodes = <int, FocusNode>{};

  /// The saved view (theme.json `library`), or a session-only one without
  /// it.
  LibraryView _viewOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ThemeScope>()
          ?.notifier
          ?.library ??
      _viewLocal;

  void _setView(LibraryView view) => setState(() {
    final s = context.getInheritedWidgetOfExactType<ThemeScope>()?.notifier;
    if (s != null) {
      s.library = view;
    } else {
      _viewLocal = view;
    }
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_checkedShares) {
      _checkedShares = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _importShared());
    }
  }

  @override
  void dispose() {
    search.dispose();
    _tableScroll.dispose();
    _gridScroll.dispose();
    for (final n in _gridNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _importShared() async {
    final scope = LibraryScope.of(context);
    final paths = await scope.files.takeSharedFiles();
    if (paths.isNotEmpty && mounted) await _runImport(paths);
  }

  Future<void> _addGames({required bool folder}) async {
    final scope = LibraryScope.of(context);
    // On a PC a folder is watched, not imported once (desktop-library.md).
    if (folder && scope.folders != null) {
      if (scope.files case final DesktopGameFiles files) {
        return _addWatchedFolder(scope.folders!, files);
      }
    }
    final paths = await pickGamePaths(context, scope.files, folder: folder);
    if (paths.isNotEmpty && mounted) await _runImport(paths);
  }

  Future<void> _addWatchedFolder(
    GameFolders folders,
    DesktopGameFiles files,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final String? dir;
    try {
      dir = await files.pickDirectory();
    } on PlatformException catch (e) {
      debugPrint('Folder dialog unavailable: $e');
      if (mounted) {
        final paths = await pickGamePaths(
          context,
          const CardGameFiles(),
          folder: true,
        );
        if (paths.isNotEmpty && mounted) await _runImport(paths);
      }
      return;
    }
    if (dir == null || !mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Looking for games…'),
        duration: Duration(days: 1),
      ),
    );
    final scan = await folders.add(dir);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            [
              '${scan.added} added',
              if (scan.skipped > 0) '${scan.skipped} already in library',
              if (scan.rejected.isNotEmpty) '${scan.rejected.length} not games',
              'the folder is watched for new games',
            ].join(', '),
          ),
        ),
      );
  }

  Future<void> _runImport(List<String> paths) async {
    final messenger = ScaffoldMessenger.of(context);
    final scope = LibraryScope.of(context);
    final progress = ValueNotifier('Importing 0 of ${paths.length}');
    messenger.showSnackBar(
      SnackBar(
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (_, v, _) => Text(v),
        ),
        duration: const Duration(days: 1),
      ),
    );
    final summary = await importPaths(
      scope,
      paths,
      onProgress: (d, t) => progress.value = 'Importing $d of $t',
    );
    messenger.hideCurrentSnackBar();
    final parts = [
      '${summary.added} added',
      if (summary.duplicates > 0) '${summary.duplicates} already in library',
      if (summary.rejected.isNotEmpty)
        '${summary.rejected.length} not imported',
    ];
    messenger.showSnackBar(
      SnackBar(
        content: Text(parts.join(', ')),
        action: summary.rejected.isEmpty
            ? null
            : SnackBarAction(
                label: 'Details',
                onPressed: () => _showRejected(summary),
              ),
      ),
    );
  }

  void _showRejected(ImportSummary summary) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          for (final r in summary.rejected)
            ListTile(title: Text(r.source), subtitle: Text(r.reason)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = LibraryScope.of(context).db;
    if (!identical(db, _db)) {
      _db = db;
      _all = db.watchGames(sort: LibrarySort.title);
    }
    final rom = RomManagerScope.of(context);
    return Scaffold(
      body: BrutalGridPaper(
        child: SafeArea(
          child: ListenableBuilder(
            // Check results change the DAT filter and INSPECT.
            listenable: rom?.results ?? _noChanges,
            builder: (context, _) => StreamBuilder<List<Game>>(
              stream: _all,
              builder: (context, snap) {
                final all = snap.data ?? const <Game>[];
                if (snap.hasData && all.isEmpty) {
                  return _EmptyLibrary(onAdd: _addGames);
                }
                final counts = <String, int>{};
                for (final g in all) {
                  counts[g.system] = (counts[g.system] ?? 0) + 1;
                }
                final key = searchKey(query);
                final games = sortGames(
                  [
                    for (final g in all)
                      if ((system == null || g.system == system) &&
                          (key.isEmpty || g.searchTitle.contains(key)) &&
                          (datFilter == null ||
                              rom == null ||
                              datFilter!.matches(rom.resultFor(g))))
                        g,
                  ],
                  sort,
                  ascending: ascending,
                );
                _shown = games;
                _allGames = all;
                return CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.gameButtonX):
                        _shuffle,
                    const SingleActivator(LogicalKeyboardKey.gameButtonSelect):
                        _nextSort,
                    const SingleActivator(LogicalKeyboardKey.gameButtonY):
                        _zoomFocused,
                    const SingleActivator(LogicalKeyboardKey.contextMenu):
                        _zoomFocused,
                  },
                  child: LayoutBuilder(
                    builder: (context, box) =>
                        _layout(context, box, games, all.length, counts),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Phone (and anything narrow): controls stacked above the table.
  /// Handheld and desktop: a filter column beside it; wide desktops add the
  /// INSPECT panel (brutalist-ui.md 4.2, 5).
  Widget _layout(
    BuildContext context,
    BoxConstraints box,
    List<Game> games,
    int total,
    Map<String, int> counts,
  ) {
    final t = BrutalTokens.of(context);
    final handheld = t.density == BrutalDensity.handheld;
    final focused =
        games.where((g) => g.id == (_focusedId ?? _selectedId)).firstOrNull ??
        games.firstOrNull;
    final view = _viewOf(context);
    final listing = Expanded(child: _listing(context, games, view));
    final footer = _Footer(
      rows: games.length,
      sort: sort,
      ascending: ascending,
      view: view,
      onView: _setView,
    );
    final path = PathBar(
      segments: [
        'games',
        system == null
            ? 'all ($total)'
            : '${_shortName(system!)} (${games.length})'.toLowerCase(),
      ],
      hint: handheld ? 'L/R TABS' : null,
    );
    if (box.maxWidth < 540 || t.density == BrutalDensity.phone) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          BrutalTokens.s3,
          BrutalTokens.s2,
          BrutalTokens.s3,
          BrutalTokens.s2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _searchField()),
                const SizedBox(width: BrutalTokens.s2),
                _shuffleButton(),
                const SizedBox(width: BrutalTokens.s2),
                _AddButton(onAdd: _addGames),
              ],
            ),
            const SizedBox(height: BrutalTokens.s2),
            _filters(counts, total),
            if (query.isEmpty && system == null && !handheld)
              _Resume(games: games, onPlay: widget.onPlay),
            const SizedBox(height: BrutalTokens.s2),
            listing,
            const SizedBox(height: BrutalTokens.s1),
            footer,
          ],
        ),
      );
    }
    final inspect = !handheld && box.maxWidth >= 1000;
    final side = SizedBox(
      width: handheld ? 176 : 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchField(),
          const SizedBox(height: BrutalTokens.s2),
          Flexible(
            child: BrutalPanel(
              header: 'FILTER.SYS',
              headerTrailing: handheld ? null : const _HeaderHint('[SEL] SORT'),
              padding: const EdgeInsets.all(BrutalTokens.s2),
              child: SingleChildScrollView(child: _filters(counts, total)),
            ),
          ),
          const SizedBox(height: BrutalTokens.s2),
          _shuffleButton(expand: true),
          const SizedBox(height: BrutalTokens.s2),
          _AddButton(onAdd: _addGames, expand: true),
          if (handheld && focused != null) ...[
            const SizedBox(height: BrutalTokens.s2),
            Expanded(child: _Preview(game: focused)),
          ] else
            const Spacer(),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.all(handheld ? BrutalTokens.s2 : BrutalTokens.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          side,
          SizedBox(width: handheld ? BrutalTokens.s2 : BrutalTokens.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                path,
                const SizedBox(height: BrutalTokens.s1),
                listing,
                const SizedBox(height: BrutalTokens.s1),
                footer,
              ],
            ),
          ),
          if (inspect && focused != null) ...[
            const SizedBox(width: BrutalTokens.s4),
            SizedBox(
              width: 320,
              child: _Inspect(
                game: focused,
                index: games.indexOf(focused),
                onPlay: () => widget.onPlay(context, focused),
                onInfo: () => showGameSheet(context, focused, widget.onPlay),
                onRom: RomManagerScope.of(context) == null
                    ? null
                    : () => openRomPage(context, focused),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _searchField() => CommandField(
    controller: search,
    hint: 'search',
    icon: DenaIcons.search,
    onChanged: (v) => setState(() => query = v),
  );

  Widget _shuffleButton({bool expand = false}) => BrutalButton(
    label: 'SHUFFLE',
    icon: DenaIcons.shuffle,
    variant: BrutalButtonVariant.primary,
    expand: expand,
    onPressed: _shuffle,
    // Holding it tips the whole library out as the stash (stash_view.dart).
    onLongPress: () => _setView(LibraryView.stash),
  );

  Widget _filters(Map<String, int> counts, int total) {
    final systems = counts.keys.toList()..sort(_systemOrder);
    return Wrap(
      spacing: BrutalTokens.s1,
      runSpacing: BrutalTokens.s1,
      children: [
        CheckFilter(
          label: 'All',
          count: total,
          checked: system == null,
          onPressed: () => _filter(null),
        ),
        for (final id in systems)
          CheckFilter(
            label: _shortName(id),
            count: counts[id],
            checked: system == id,
            onPressed: () => _filter(id),
          ),
        // DAT.CHK (rom-manager.md 5), once any game has been checked.
        if (RomManagerScope.of(context) case final rom?
            when rom.results.all.isNotEmpty)
          for (final f in DatFilter.values)
            CheckFilter(
              label: f.label,
              count: _allGames.where((g) => f.matches(rom.resultFor(g))).length,
              checked: datFilter == f,
              onPressed: () => setState(() {
                datFilter = datFilter == f ? null : f;
                _selectedId = null;
              }),
            ),
      ],
    );
  }

  void _filter(String? id) => setState(() {
    system = id;
    _selectedId = null;
  });

  Widget _listing(BuildContext context, List<Game> games, LibraryView view) {
    if (games.isEmpty) {
      final t = BrutalTokens.of(context);
      return BrutalPanel(
        padding: const EdgeInsets.all(BrutalTokens.s4),
        child: Text('> no games match', style: t.body),
      );
    }
    return switch (view) {
      LibraryView.table => _table(context, games),
      LibraryView.grid => _grid(context, games),
      LibraryView.stash => StashView(
        games: games,
        onPlay: (g) => widget.onPlay(context, g),
        onDetails: (g) => showGameSheet(context, g, widget.onPlay),
      ),
    };
  }

  Widget _table(BuildContext context, List<Game> games) {
    final t = BrutalTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) => _sizedTable(
        context,
        games,
        // The marker column, the borders and the drop shadow.
        _columnsFor(t.density, box.maxWidth - t.shadowOffsetLarge.dx - 36),
      ),
    );
  }

  Widget _sizedTable(
    BuildContext context,
    List<Game> games,
    List<_ColumnSpec> columns,
  ) {
    final t = BrutalTokens.of(context);
    final most = games.fold(0, (m, g) => math.max(m, g.playSeconds));
    final selected = _selectedId == null
        ? null
        : games.indexWhere((g) => g.id == _selectedId);
    final sortColumn = columns.indexWhere((c) => c.sort == sort);
    return Padding(
      padding: EdgeInsets.only(
        right: t.shadowOffsetLarge.dx,
        bottom: t.shadowOffsetLarge.dy,
      ),
      child: BrutalTable(
        controller: _tableScroll,
        columns: [for (final c in columns) c.column],
        rowCount: games.length,
        autofocusRow: 0,
        selectedRow: selected == null || selected < 0 ? null : selected,
        sortColumn: sortColumn < 0 ? null : sortColumn,
        sortAscending: ascending,
        onSort: (i) => _sortBy(columns[i].sort!),
        onRowPressed: (i) => widget.onPlay(context, games[i]),
        onRowLongPress: (i) => _zoom(games[i], i),
        cellBuilder: (context, row, column, lit) =>
            _cell(context, games[row], row, columns[column].id, lit, most),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    Game game,
    int row,
    _Col column,
    bool lit,
    int most,
  ) {
    final t = BrutalTokens.of(context);
    final ink = lit ? t.onFocus : t.ink;
    switch (column) {
      case _Col.number:
        return Text(game.favorite ? '★' : (row + 1).toString().padLeft(2, '0'));
      case _Col.box:
        return _RowProbe(
          key: ValueKey(game.id),
          onAttach: (node, ctx) {
            _rowNodes[row] = node;
            _rowContexts[row] = ctx;
          },
          onDetach: (node) {
            if (identical(_rowNodes[row], node)) {
              _rowNodes.remove(row);
              _rowContexts.remove(row);
            }
          },
          onFocus: () {
            if (_focusedId != game.id) setState(() => _focusedId = game.id);
          },
          child: GameBoxThumb(game: game),
        );
      case _Col.title:
        return Row(
          children: [
            Flexible(
              child: Text(
                BrutalTokens.fileName(game.title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isRomhack(game)) ...[
              const SizedBox(width: BrutalTokens.s1),
              const HackBadge(),
            ],
          ],
        );
      case _Col.system:
        final scheme = Theme.of(context).colorScheme;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The one place a system keeps its colour (brutalist-ui.md 2.1).
            Container(
              width: 6,
              height: 6,
              color: systemScheme(game.system, scheme).primary,
            ),
            const SizedBox(width: BrutalTokens.s1),
            Flexible(child: Text(_shortName(game.system).toUpperCase())),
          ],
        );
      case _Col.year:
        final year = gameYear(game);
        return Text(year == null ? '--' : '$year');
      case _Col.progress:
        if (game.playSeconds <= 0 || most <= 0) return const SizedBox();
        return ProgressCell(
          value: game.playSeconds / most,
          showPercent: false,
          width: t.density == BrutalDensity.desktop ? 72 : 40,
          color: ink,
        );
      case _Col.played:
        return Text(playTime(game.playSeconds));
      case _Col.last:
        return Text(lastPlayed(game.lastPlayedAt, DateTime.now()));
    }
  }

  Widget _grid(BuildContext context, List<Game> games) {
    final handheld = BrutalTokens.of(context).density == BrutalDensity.handheld;
    return GridView.builder(
      controller: _gridScroll,
      padding: const EdgeInsets.only(bottom: BrutalTokens.s4),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: handheld ? 130 : 170,
        childAspectRatio: 0.72,
        mainAxisSpacing: BrutalTokens.s2,
        crossAxisSpacing: BrutalTokens.s2,
      ),
      itemCount: games.length,
      itemBuilder: (context, i) => GameCard(
        key: ValueKey(games[i].id),
        game: games[i],
        autofocus: i == 0,
        focusNode: _gridNode(games[i].id),
        selected: games[i].id == _selectedId,
        onPlay: () => widget.onPlay(context, games[i]),
        onDetails: (from) =>
            showGameSheet(context, games[i], widget.onPlay, from: from),
      ),
    );
  }

  FocusNode _gridNode(int id) => _gridNodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'game $id')
      ..addListener(() {
        final node = _gridNodes[id];
        if (node != null && node.hasFocus && _focusedId != id && mounted) {
          setState(() => _focusedId = id);
        }
      }),
  );

  void _sortBy(TableSort key) => setState(() {
    if (key == sort) {
      ascending = !ascending;
    } else {
      sort = key;
      ascending = key.ascendingFirst;
    }
  });

  /// Select on a pad: the next sort key, in its natural direction.
  void _nextSort() => setState(() {
    sort = TableSort.values[(sort.index + 1) % TableSort.values.length];
    ascending = sort.ascendingFirst;
  });

  /// Picks a random game on screen, scrolls to it and focuses it.
  void _shuffle() {
    final games = _shown;
    if (games.isEmpty) return;
    var i = _random.nextInt(games.length);
    if (games.length > 1 && games[i].id == (_focusedId ?? _selectedId)) {
      i = (i + 1) % games.length;
    }
    final game = games[i];
    setState(() {
      _selectedId = game.id;
      _focusedId = game.id;
    });
    final view = _viewOf(context);
    if (view == LibraryView.stash) return;
    final scroll = view == LibraryView.table ? _tableScroll : _gridScroll;
    if (scroll.hasClients) {
      final p = scroll.position;
      final target = view == LibraryView.table
          ? i * (BrutalTokens.of(context).rowHeight + BrutalTokens.borderThin)
          : p.maxScrollExtent * i / math.max(1, games.length - 1);
      scroll.jumpTo(target.clamp(p.minScrollExtent, p.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = view == LibraryView.table
          ? _rowNodes[i]
          : _gridNodes[game.id];
      if (node == null || node.context == null) return;
      node.requestFocus();
      Scrollable.ensureVisible(node.context!);
    });
  }

  /// Y or the menu key: the focused game's box zoom (game_box_menu.dart).
  void _zoomFocused() {
    final games = _shown;
    for (final MapEntry(key: i, value: node) in _rowNodes.entries) {
      if (node.hasFocus && i < games.length) return _zoom(games[i], i);
    }
  }

  void _zoom(Game game, int row) {
    final ctx = _rowContexts[row];
    final box = ctx != null && ctx.mounted ? ctx.findRenderObject() : null;
    showGameSheet(
      context,
      game,
      widget.onPlay,
      from: box is RenderBox && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null,
    );
  }
}

/// A table column of the Games tab.
enum _Col { number, box, title, system, year, progress, played, last }

typedef _ColumnSpec = ({_Col id, BrutalColumn column, TableSort? sort});

/// The columns per device (brutalist-ui.md 4.2): phone `# BOX TITLE SYS YR
/// %`, handheld `# BOX TITLE SYS YR`, desktop adds
/// PLAYED and LAST.
List<_ColumnSpec> _columnsFor(BrutalDensity density, double width) {
  _ColumnSpec c(
    _Col id,
    String label, {
    double? width,
    int flex = 1,
    bool numeric = false,
    TableSort? sort,
  }) => (
    id: id,
    column: BrutalColumn(
      label,
      width: width,
      flex: flex,
      numeric: numeric,
      sortable: sort != null,
    ),
    sort: sort,
  );
  final all = switch (density) {
    BrutalDensity.phone => [
      c(_Col.number, '#', width: 34),
      c(_Col.box, 'BOX', width: 48),
      c(_Col.title, 'TITLE', sort: TableSort.title),
      c(_Col.system, 'SYS', width: 60, sort: TableSort.system),
      c(_Col.year, 'YR', width: 44, sort: TableSort.year),
      c(_Col.progress, '%', width: 56, sort: TableSort.playTime),
    ],
    BrutalDensity.handheld => [
      c(_Col.number, '#', width: 30),
      c(_Col.box, 'BOX', width: 38),
      c(_Col.title, 'TITLE', sort: TableSort.title),
      c(_Col.system, 'SYS', width: 56, sort: TableSort.system),
      c(_Col.year, 'YR', width: 48, sort: TableSort.year),
    ],
    BrutalDensity.desktop => [
      c(_Col.number, '#', width: 40),
      c(_Col.box, 'BOX', width: 50),
      c(_Col.title, 'TITLE', flex: 3, sort: TableSort.title),
      c(_Col.system, 'SYS', width: 72, sort: TableSort.system),
      c(_Col.year, 'YR', width: 60, sort: TableSort.year),
      c(_Col.progress, '%', width: 92),
      c(
        _Col.played,
        'PLAYED',
        width: 92,
        numeric: true,
        sort: TableSort.playTime,
      ),
      c(
        _Col.last,
        'LAST',
        width: 92,
        numeric: true,
        sort: TableSort.lastPlayed,
      ),
    ],
  };
  // Narrow windows drop the least useful columns first so TITLE keeps room.
  const minTitle = 120.0;
  final columns = [...all];
  for (final drop in [_Col.last, _Col.played, _Col.progress, _Col.year]) {
    final fixed = columns.fold(0.0, (w, c) => w + (c.column.width ?? 0));
    if (width - fixed >= minTitle) break;
    columns.removeWhere((c) => c.id == drop);
  }
  return columns;
}

/// How the library table is ordered (brutalist-ui.md 4.2).
enum TableSort {
  title('TITLE', true),
  system('SYS', true),
  year('YEAR', true),
  lastPlayed('LAST', false),
  playTime('PLAYED', false);

  const TableSort(this.label, this.ascendingFirst);

  /// Shown in the footer: `SORT=TITLE ASC`.
  final String label;

  /// Whether picking this key starts ascending (A to Z, oldest year) or
  /// descending (most recent, most played).
  final bool ascendingFirst;
}

/// [games] ordered by [sort]; unknown values (no year, never played) stay
/// last either way, ties fall back to the title.
List<Game> sortGames(
  List<Game> games,
  TableSort sort, {
  bool ascending = true,
}) {
  int byTitle(Game a, Game b) => a.searchTitle.compareTo(b.searchTitle);
  int nullsLast<T extends Comparable<Object>>(T? a, T? b) {
    if (a == null || b == null) {
      return a == null && b == null ? 0 : (a == null ? 1 : -1);
    }
    return ascending ? a.compareTo(b) : b.compareTo(a);
  }

  final out = [...games];
  out.sort((a, b) {
    final c = switch (sort) {
      TableSort.title => ascending ? byTitle(a, b) : byTitle(b, a),
      TableSort.system =>
        ascending
            ? _index(a.system).compareTo(_index(b.system))
            : _index(b.system).compareTo(_index(a.system)),
      TableSort.year => nullsLast(gameYear(a), gameYear(b)),
      TableSort.lastPlayed => nullsLast(a.lastPlayedAt, b.lastPlayedAt),
      TableSort.playTime => nullsLast(
        a.playSeconds > 0 ? a.playSeconds : null,
        b.playSeconds > 0 ? b.playSeconds : null,
      ),
    };
    return c != 0 ? c : byTitle(a, b);
  });
  return out;
}

/// The release year a file or title names, like `Quest (1994) (USA).sfc`
/// (TOSEC style), or null. The library stores no year of its own.
int? gameYear(Game game) {
  final re = RegExp(r'[(\[]((?:19[7-9]|20[0-4])\d)[)\]-]');
  final m = re.firstMatch(game.fileName) ?? re.firstMatch(game.title);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Whether [game] is a romhack by its name (romhacks.md): a known hack or a
/// `(Hack)` style tag.
bool isRomhack(Game game) =>
    looksLikeHack(game.fileName) ||
    looksLikeHack(game.title) ||
    romhackFor(game.system, game.fileName) != null;

/// Play time as `14h 20m`; `--` when never played.
String playTime(int seconds) {
  if (seconds <= 0) return '--';
  final m = seconds ~/ 60;
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

/// When a game was last played, relative to [now]: `today`, `1d`, `12d`,
/// `3mo`, `2y`; `--` when never.
String lastPlayed(DateTime? at, DateTime now) {
  if (at == null) return '--';
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  if (days <= 0) return 'today';
  if (days < 60) return '${days}d';
  if (days < 730) return '${days ~/ 30}mo';
  return '${days ~/ 365}y';
}

int _systemOrder(String a, String b) => _index(a).compareTo(_index(b));
int _index(String id) {
  final i = GameSystem.values.indexWhere((s) => s.id == id);
  return i < 0 ? 99 : i;
}

String _shortName(String id) =>
    GameSystem.values
        .where((s) => s.id == id)
        .map((s) => s.shortName)
        .firstOrNull ??
    id;

/// The emulator core that runs [system], as `MGBA`, or `--`.
String _coreName(String system) {
  final lib = coreLibraries[system];
  if (lib == null) return '--';
  return lib
      .replaceFirst(RegExp(r'^lib'), '')
      .replaceFirst('_libretro.so', '')
      .toUpperCase();
}

String _fileSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

/// Tells the table which focus node and context a row has, and when the row
/// takes focus. Sits in the row's BOX cell, so `Focus.of` is the row.
class _RowProbe extends StatefulWidget {
  const _RowProbe({
    super.key,
    required this.onAttach,
    required this.onDetach,
    required this.onFocus,
    required this.child,
  });

  final void Function(FocusNode node, BuildContext context) onAttach;
  final void Function(FocusNode node) onDetach;
  final VoidCallback onFocus;
  final Widget child;

  @override
  State<_RowProbe> createState() => _RowProbeState();
}

class _RowProbeState extends State<_RowProbe> {
  FocusNode? _node;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final node = Focus.maybeOf(context);
    if (node != _node) {
      _node?.removeListener(_changed);
      _node = node?..addListener(_changed);
    }
  }

  void _changed() {
    if (_node?.hasFocus ?? false) widget.onFocus();
  }

  @override
  void dispose() {
    if (_node case final node?) {
      node.removeListener(_changed);
      widget.onDetach(node);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_node case final node?) widget.onAttach(node, context);
    return widget.child;
  }
}

/// `12 ROWS // SORT=TITLE ASC` and the view switch `[LIST] [GRID] [STASH]`.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.rows,
    required this.sort,
    required this.ascending,
    required this.view,
    required this.onView,
  });

  final int rows;
  final TableSort sort;
  final bool ascending;
  final LibraryView view;
  final ValueChanged<LibraryView> onView;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final style = t.small.copyWith(color: t.ink, fontWeight: FontWeight.w600);
    return Row(
      children: [
        Expanded(
          child: Text(
            '$rows ROWS // SORT=${sort.label} ${ascending ? 'ASC' : 'DESC'}',
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final (v, label) in const [
          (LibraryView.table, 'LIST'),
          (LibraryView.grid, 'GRID'),
          (LibraryView.stash, 'STASH'),
        ])
          BrutalPressable(
            onPressed: () => onView(v),
            selected: v == view,
            semanticLabel: '$label view',
            builder: (context, s) {
              final lit = v == view || s.highlighted;
              return Container(
                margin: const EdgeInsets.only(left: BrutalTokens.s1),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                color: lit ? t.focus : null,
                child: Text(
                  '[$label]',
                  style: style.copyWith(color: lit ? t.onFocus : t.ink),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _HeaderHint extends StatelessWidget {
  const _HeaderHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Text(text, style: t.small.copyWith(color: t.onHeaderBar));
  }
}

/// The handheld rail's look at the focused game's box.
class _Preview extends StatelessWidget {
  const _Preview({required this.game});

  final Game game;

  @override
  Widget build(BuildContext context) {
    return BrutalPanel(
      padding: const EdgeInsets.all(BrutalTokens.s2),
      child: GameBox(
        key: ValueKey(game.id),
        game: game,
        alignment: Alignment.center,
      ),
    );
  }
}

/// Desktop: the focused game's box, facts, PLAY / INFO and last session.
class _Inspect extends StatelessWidget {
  const _Inspect({
    required this.game,
    required this.index,
    required this.onPlay,
    required this.onInfo,
    this.onRom,
  });

  final Game game;
  final int index;
  final VoidCallback onPlay, onInfo;

  /// Opens the ROM page; null without a ROM manager.
  final VoidCallback? onRom;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final year = gameYear(game);
    final last = game.lastPlayedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return BrutalPanel(
      large: true,
      header: 'INSPECT // ${(index + 1).toString().padLeft(2, '0')}',
      headerTrailing: const _HeaderHint('[Y] ZOOM'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(BrutalTokens.s4),
              child: GameBox(
                key: ValueKey(game.id),
                game: game,
                alignment: Alignment.center,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: t.ink, width: BrutalTokens.border),
              ),
            ),
            padding: const EdgeInsets.all(BrutalTokens.s3),
            child: Text(
              BrutalTokens.fileName(game.title),
              style: t.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          KeyValueStrip(
            entries: [
              ('SYS', _shortName(game.system).toUpperCase()),
              ('YEAR', year == null ? '--' : '$year'),
              ('PLAYED', playTime(game.playSeconds)),
              ('LAST', lastPlayed(last, DateTime.now())),
              ('SIZE', _fileSize(game.size)),
              ('CORE', _coreName(game.system)),
              if (RomManagerScope.of(context) case final rom?)
                ('DAT', verifySummary(rom.resultFor(game))),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(BrutalTokens.s3),
            child: Row(
              children: [
                Expanded(
                  child: BrutalButton(
                    label: 'PLAY [A]',
                    icon: DenaIcons.play,
                    variant: BrutalButtonVariant.primary,
                    expand: true,
                    onPressed: onPlay,
                  ),
                ),
                const SizedBox(width: BrutalTokens.s3),
                Expanded(
                  child: BrutalButton(
                    label: 'INFO [Y]',
                    icon: DenaIcons.info,
                    expand: true,
                    onPressed: onInfo,
                  ),
                ),
              ],
            ),
          ),
          if (onRom != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BrutalTokens.s3,
                0,
                BrutalTokens.s3,
                BrutalTokens.s3,
              ),
              child: BrutalButton(
                label: 'ROM CHECK',
                icon: DenaIcons.check,
                expand: true,
                onPressed: onRom,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              BrutalTokens.s3,
              0,
              BrutalTokens.s3,
              BrutalTokens.s3,
            ),
            child: LogLine(
              last == null
                  ? 'last_played never'
                  : 'last_played ${last.year}-${two(last.month)}-'
                        '${two(last.day)} ${two(last.hour)}:${two(last.minute)}',
            ),
          ),
        ],
      ),
    );
  }
}

/// One game in the grid, drawn as its console's real box (game_box.dart).
/// A / Enter plays; Y / long-press opens the box zoom. Focused, the box gets
/// a yellow 3 px frame and a `->` plate under it (brutalist-ui.md 4.2).
class GameCard extends StatefulWidget {
  const GameCard({
    super.key,
    required this.game,
    required this.onPlay,
    required this.onDetails,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
  });

  final Game game;
  final VoidCallback onPlay;

  /// Opens the details, given where the box stands on screen.
  final ValueChanged<Rect?> onDetails;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Lit without focus (the shuffle's pick on touch).
  final bool selected;

  @override
  State<GameCard> createState() => GameCardState();
}

class GameCardState extends State<GameCard> {
  final _stage = GlobalKey();

  /// Whether the card draws its focus frame.
  bool lit = false;

  void _details() {
    final box = _stage.currentContext?.findRenderObject();
    widget.onDetails(
      box is RenderBox && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final t = BrutalTokens.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.gameButtonY): _details,
        const SingleActivator(LogicalKeyboardKey.contextMenu): _details,
      },
      child: BrutalPressable(
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        onPressed: widget.onPlay,
        onLongPress: _details,
        semanticLabel: game.title,
        selected: widget.selected,
        builder: (context, s) {
          lit = s.highlighted || widget.selected;
          final onPlate = lit ? t.onFocus : t.ink;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(BrutalTokens.s1),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: lit ? t.focus : Colors.transparent,
                      width: BrutalTokens.border,
                    ),
                  ),
                  child: Stack(
                    key: _stage,
                    fit: StackFit.expand,
                    children: [
                      GameBox(game: game),
                      if (game.favorite)
                        const Positioned(
                          top: 0,
                          left: 0,
                          child: Sticker('★', small: true),
                        ),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: BrutalTokens.s1 + 2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: lit ? t.focus : t.panel,
                  border: Border.all(
                    color: t.ink,
                    width: BrutalTokens.borderThin,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${lit ? '-> ' : ''}${BrutalTokens.fileName(game.title)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.label.copyWith(color: onPlate),
                    ),
                    Text(
                      _shortName(game.system).toUpperCase(),
                      maxLines: 1,
                      style: t.small.copyWith(color: onPlate),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A short tag on a cover or title: a romhack's base-game cover, a favourite.
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: t.focus,
        border: Border.all(
          color: const Color(0xFF000000),
          width: BrutalTokens.borderThin,
        ),
      ),
      child: Text(
        text,
        style: t.small.copyWith(
          color: t.onFocus,
          fontWeight: FontWeight.w700,
          fontSize: 9,
          height: 1.2,
        ),
      ),
    );
  }
}

/// Cover stand-in: a muted panel with the system's short name in mono.
class SystemPlaceholder extends StatelessWidget {
  const SystemPlaceholder({super.key, required this.system});

  final String system;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return ColoredBox(
      color: t.muted,
      child: LayoutBuilder(
        builder: (context, box) {
          final side = box.biggest.shortestSide;
          return Center(
            child: Padding(
              padding: EdgeInsets.all(side * 0.1),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _shortName(system).toUpperCase(),
                  style: t.title.copyWith(color: t.ink),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A game's cover from [LibraryScope.art], or [placeholder] while loading or
/// when there is none.
class GameCover extends StatefulWidget {
  const GameCover({
    super.key,
    required this.game,
    required this.placeholder,
    this.onAspect,
  });

  final Game game;
  final Widget placeholder;

  /// Told the cover image's width / height once it has loaded.
  final ValueChanged<double>? onAspect;

  @override
  State<GameCover> createState() => _GameCoverState();
}

class _GameCoverState extends State<GameCover> {
  File? file;
  bool hack = false;
  String? loadedKey;
  BoxArtCache? _art;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final art = LibraryScope.of(context).art;
    if (art != _art) {
      // A cover changed on disk redraws the card.
      _art?.revision.removeListener(_load);
      art?.revision.addListener(_load);
      _art = art;
    }
    _load();
  }

  @override
  void dispose() {
    _art?.revision.removeListener(_load);
    super.dispose();
  }

  @override
  void didUpdateWidget(GameCover old) {
    super.didUpdateWidget(old);
    _load();
  }

  void _load() {
    final art = _art;
    final key =
        '${widget.game.sha1}|${widget.game.customArtPath}|'
        '${art?.revision.value}';
    if (key == loadedKey) return;
    loadedKey = key;
    if (art == null) return;
    art.coverFor(widget.game).then((f) async {
      final standIn = f != null && await art.isHackStandIn(widget.game);
      if (mounted && loadedKey == key) {
        setState(() {
          file = f;
          hack = standIn;
        });
        if (f != null) _measure(f, key);
      }
    });
  }

  void _measure(File f, String key) {
    final onAspect = widget.onAspect;
    if (onAspect == null) return;
    final stream = FileImage(f).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final w = info.image.width, h = info.image.height;
      info.dispose();
      if (mounted && loadedKey == key && h > 0) onAspect(w / h);
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    // The launch animation starts from here (launch-animation.md).
    return LaunchOrigin(game: widget.game, child: _cover());
  }

  Widget _cover() {
    final f = file;
    if (f == null) return widget.placeholder;
    final cover = FoilOverlay(
      child: Image.file(
        f,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.placeholder,
      ),
    );
    if (!hack) return cover;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        cover,
        const Positioned(left: 4, bottom: 4, child: HackBadge()),
      ],
    );
  }
}

/// Marks a base game's cover, or a table title, as a romhack (box-art.md):
/// a hard yellow `HACK` tag.
class HackBadge extends StatelessWidget {
  const HackBadge({super.key});

  @override
  Widget build(BuildContext context) =>
      Semantics(label: 'Romhack, base game cover', child: const _Tag('HACK'));
}

/// Phone: a blue RESUME button for the last game played, when there is one.
class _Resume extends StatelessWidget {
  const _Resume({required this.games, required this.onPlay});

  final List<Game> games;
  final PlayGame onPlay;

  @override
  Widget build(BuildContext context) {
    Game? last;
    for (final g in games) {
      final at = g.lastPlayedAt;
      if (at != null && (last == null || at.isAfter(last.lastPlayedAt!))) {
        last = g;
      }
    }
    if (last == null) return const SizedBox.shrink();
    final game = last;
    return Padding(
      padding: const EdgeInsets.only(top: BrutalTokens.s2),
      child: BrutalButton(
        label: 'RESUME ${BrutalTokens.fileName(game.title)}',
        icon: DenaIcons.play,
        value: '->',
        variant: BrutalButtonVariant.primary,
        expand: true,
        onPressed: () => onPlay(context, game),
      ),
    );
  }
}

/// `+ ADD`: Add games or Add a folder.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.onAdd, this.expand = false});

  final Future<void> Function({required bool folder}) onAdd;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(DenaIcons.fileAdd),
          onPressed: () => onAdd(folder: false),
          child: const Text('Add games'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(DenaIcons.folderAdd),
          onPressed: () => onAdd(folder: true),
          child: const Text('Add a folder'),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Add games',
        child: BrutalButton(
          label: 'ADD',
          icon: DenaIcons.add,
          expand: expand,
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
    );
  }
}

/// The first-run screen: `NO ROMS FOUND.` and `[ADD FOLDER]`, with single
/// files as the second way in.
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onAdd});

  final Future<void> Function({required bool folder}) onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EmptyState(
                headline: 'No roms found.',
                message:
                    'add a folder to start. dena.emu does not include games.',
                action: 'Add folder',
                icon: DenaIcons.folderAdd,
                autofocus: true,
                onAction: () => onAdd(folder: true),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: BrutalTokens.s4,
                ),
                child: BrutalButton(
                  label: '[ADD FILES]',
                  icon: DenaIcons.fileAdd,
                  onPressed: () => onAdd(folder: false),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Details: the game's box zooms toward the viewer with its options
/// (game_box_menu.dart). [from] is the box's place on screen, if known.
Future<void> showGameSheet(
  BuildContext context,
  Game game,
  PlayGame onPlay, {
  Rect? from,
}) => showGameBoxMenu(context, game, onPlay, from: from);

/// Asks for a new title; null when cancelled.
Future<String?> askGameName(BuildContext context, String current) {
  // Handhelds and controller mode type on the D-pad keyboard
  // (handheld-ui.md, controller-mode.md).
  if (usesButtons(context)) {
    return showOnScreenKeyboard(
      context,
      title: 'Rename',
      initial: current,
      accept: (t) => t.trim().isNotEmpty,
    );
  }
  final c = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Rename'),
      content: TextField(controller: c, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, c.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
