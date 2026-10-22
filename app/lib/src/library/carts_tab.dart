// SPDX-License-Identifier: GPL-3.0-or-later
// PICO-8 carts: imported carts, the Dena Explore launcher cart and, once
// permitted, the BBS browser, as a Brutalist table. Spec: docs/specs/pico8.md
// (Carts tab), docs/specs/pico8-cart-browser.md,
// docs/specs/pico8-launcher-cart.md, docs/specs/brutalist-ui.md (4.7)
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../carts/bbs.dart';
import '../carts/cart_browser.dart';
import '../carts/cart_download.dart';
import 'database.dart';
import 'games_tab.dart';
import 'library_scope.dart';
import '../shell/app_dirs.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Browsing and downloading BBS carts, in the browser page and in the
/// launcher cart. On since 2026-10-17 (user decision after checking that
/// Lexaloffle requires no permission; CLAUDE.md §4 rules apply).
const pico8BrowserEnabled = true;

/// The browser's BBS client and credits file in the app.
Future<CartBrowserDeps> defaultBrowserDeps() async => CartBrowserDeps(
  client: HttpBbsClient(),
  credits: CartCredits((await appDataDir()).path),
);

class CartsTab extends StatefulWidget {
  const CartsTab({
    super.key,
    required this.onPlay,
    this.onExplore,
    this.browserEnabled = pico8BrowserEnabled,
    this.browserDeps = defaultBrowserDeps,
  });

  final PlayGame onPlay;

  /// Opens the Dena Explore launcher cart; no button or row when null.
  final Future<void> Function(BuildContext context)? onExplore;

  /// Tests force the browser on; the app uses [pico8BrowserEnabled].
  final bool browserEnabled;
  final Future<CartBrowserDeps> Function() browserDeps;

  @override
  State<CartsTab> createState() => _CartsTabState();
}

class _CartsTabState extends State<CartsTab> {
  LibraryDatabase? _db;
  late Stream<List<Game>> _carts;
  Future<CartBrowserDeps>? _deps;

  /// Credits of downloaded carts by SHA-1 (author; license on the BBS page).
  Map<String, CartCredit> _credits = const {};
  String _creditsSeen = '';
  String _cartsSeen = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final db = LibraryScope.of(context).db;
    if (db != _db) {
      _db = db;
      _carts = db.watchGames(system: 'pico8');
    }
  }

  Future<CartBrowserDeps> _browserDeps() =>
      _deps ??= widget.browserDeps().catchError((Object e) {
        _deps = null;
        throw e;
      });

  Future<void> _loadCredits() async {
    try {
      final map = await (await _browserDeps()).credits.load();
      final seen = map.keys.join(',');
      if (!mounted || seen == _creditsSeen) return;
      setState(() {
        _creditsSeen = seen;
        _credits = Map.of(map);
      });
    } on Object {
      // No data folder (tests) or no credits file: authors stay unknown.
    }
  }

  Future<void> _browse(BuildContext context) async {
    final navigator = Navigator.of(context);
    final deps = await _browserDeps();
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => CartBrowserPage(deps: deps)),
    );
    await _loadCredits();
  }

  Future<void> _addCarts(BuildContext context) async {
    final scope = LibraryScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final paths = await scope.files.pickFiles();
    if (paths.isEmpty) return;
    final summary = await importPaths(scope, paths);
    messenger.showSnackBar(
      brutalToast(
        [
          '${summary.added} added',
          if (summary.duplicates > 0)
            '${summary.duplicates} already in library',
          if (summary.rejected.isNotEmpty)
            '${summary.rejected.length} not imported',
        ].join(', '),
        kind: summary.rejected.isEmpty ? ToastKind.ok : ToastKind.info,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: StreamBuilder<List<Game>>(
          stream: _carts,
          builder: (context, snap) {
            final carts = snap.data ?? const <Game>[];
            final seen = carts.map((g) => g.sha1).join(',');
            if (snap.hasData && seen != _cartsSeen) {
              _cartsSeen = seen;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _loadCredits(),
              );
            }
            return _CartsBody(
              carts: carts,
              loaded: snap.hasData,
              credits: _credits,
              onPlay: widget.onPlay,
              onExplore: widget.onExplore,
              browserEnabled: widget.browserEnabled,
              onBrowse: () => _browse(context),
              onAdd: () => _addCarts(context),
            );
          },
        ),
      ),
    );
  }
}

class _CartsBody extends StatelessWidget {
  const _CartsBody({
    required this.carts,
    required this.loaded,
    required this.credits,
    required this.onPlay,
    required this.onExplore,
    required this.browserEnabled,
    required this.onBrowse,
    required this.onAdd,
  });

  final List<Game> carts;
  final bool loaded;
  final Map<String, CartCredit> credits;
  final PlayGame onPlay;
  final Future<void> Function(BuildContext context)? onExplore;
  final bool browserEnabled;
  final VoidCallback onBrowse, onAdd;

  /// The explore row's offset: row `00` is Dena Explore when it is there.
  int get _first => onExplore == null ? 0 : 1;

  Game? _cartAt(int row) => row < _first ? null : carts[row - _first];

  void _details(BuildContext context, int row) {
    final game = _cartAt(row);
    if (game != null) showGameSheet(context, game, onPlay);
  }

  /// The focused row, found through the tag on its first cell.
  static int? focusedRow() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx is! Element) return null;
    int? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget case CartRowTag(:final index)) {
        found = index;
        return;
      }
      e.visitChildren(visit);
    }

    ctx.visitChildren(visit);
    return found;
  }

  List<BrutalColumn> _columns(BrutalTokens t) {
    final phone = t.density == BrutalDensity.phone;
    return [
      const BrutalColumn('#', width: 32),
      const BrutalColumn('CART', width: 46),
      const BrutalColumn('TITLE', flex: 3),
      BrutalColumn('AUTHOR', flex: phone ? 2 : 3),
      BrutalColumn('LICENSE', width: phone ? 72 : 96),
      const BrutalColumn('FAV', width: 40),
    ];
  }

  Widget _cell(BuildContext context, int row, int column, bool lit) {
    final t = BrutalTokens.of(context);
    final ink = lit ? t.onFocus : t.ink;
    final game = _cartAt(row);
    final credit = game == null ? null : credits[game.sha1];
    return switch (column) {
      0 => CartRowTag(index: row, child: Text(rowNumber(row))),
      1 => BoxThumb(
        aspect: 1,
        child: game == null
            ? ColoredBox(
                color: t.focus,
                child: Icon(
                  DenaIcons.compass,
                  size: BrutalTokens.iconSize,
                  color: t.onFocus,
                ),
              )
            : GameCover(
                game: game,
                placeholder: Icon(
                  DenaIcons.cart,
                  size: BrutalTokens.iconSize,
                  color: t.ink,
                ),
              ),
      ),
      2 => Text(fileStyleTitle(game?.title ?? 'Dena Explore')),
      3 => Text(game == null ? 'DENA.EMU' : credit?.author ?? '-'),
      // Downloaded carts carry their author's license on the BBS page
      // (pico8-cart-browser.md); the launcher is our own GPL cart.
      4 => Text(
        game == null
            ? 'GPL-3.0'
            : credit == null
            ? '-'
            : 'SEE BBS',
      ),
      _ =>
        game?.favorite ?? false
            ? Semantics(
                label: 'Favourite',
                child: Icon(
                  DenaIcons.star,
                  size: BrutalTokens.iconSize,
                  color: ink,
                ),
              )
            : const SizedBox(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final explore = onExplore;
    final rows = _first + carts.length;
    const pad = BrutalTokens.s2;
    final buttons = [
      if (explore != null)
        BrutalButton(
          // First in the tab: focus lands here after L1 / R1, with or
          // without carts below.
          autofocus: true,
          variant: BrutalButtonVariant.primary,
          icon: DenaIcons.compass,
          label: '[LAUNCH EXPLORE]',
          onPressed: () => explore(context),
        ),
      if (browserEnabled)
        BrutalButton(
          autofocus: explore == null,
          icon: DenaIcons.globe,
          label: '[BROWSE BBS]',
          onPressed: onBrowse,
        ),
      BrutalButton(
        autofocus: explore == null && !browserEnabled && rows == 0,
        icon: DenaIcons.add,
        label: '[ADD CARTS]',
        onPressed: onAdd,
      ),
    ];
    return BrutalGridPaper(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          pad,
          pad,
          pad + t.shadowOffsetLarge.dx,
          pad + t.shadowOffsetLarge.dy,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: BrutalTokens.s3,
              runSpacing: BrutalTokens.s3,
              children: buttons,
            ),
            const SizedBox(height: BrutalTokens.s2),
            LogLine(
              browserEnabled
                  ? (explore != null
                        ? 'explore: browse, download and play carts'
                        : 'bbs carts are credited to their authors')
                  : 'cart browser off: add .p8 and .p8.png carts you have '
                        'downloaded',
            ),
            const SizedBox(height: BrutalTokens.s3),
            Expanded(
              child: loaded && rows == 0
                  ? const Align(
                      alignment: Alignment.topLeft,
                      child: EmptyState(
                        headline: 'NO CARTS YET.',
                        message: 'add .p8 or .p8.png carts to start',
                      ),
                    )
                  : CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.gameButtonY,
                        ): () =>
                            _focusedDetails(context),
                        const SingleActivator(
                          LogicalKeyboardKey.contextMenu,
                        ): () =>
                            _focusedDetails(context),
                      },
                      child: BrutalTable(
                        key: const Key('carts table'),
                        columns: _columns(t),
                        rowCount: rows,
                        autofocusRow: explore == null && !browserEnabled
                            ? 0
                            : null,
                        onRowPressed: (row) {
                          final game = _cartAt(row);
                          if (game == null) {
                            explore?.call(context);
                          } else {
                            onPlay(context, game);
                          }
                        },
                        onRowLongPress: (row) => _details(context, row),
                        cellBuilder: _cell,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _focusedDetails(BuildContext context) {
    final row = focusedRow();
    if (row != null) _details(context, row);
  }
}

/// Marks a carts-table row's first cell with its index, so Y can find the
/// focused row.
class CartRowTag extends StatelessWidget {
  const CartRowTag({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
