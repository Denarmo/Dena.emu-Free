// SPDX-License-Identifier: GPL-3.0-or-later
// PICO-8 BBS cart browser: Featured / New / Search / Author, drawn as
// Brutalist tables. Spec: docs/specs/pico8-cart-browser.md,
// docs/specs/brutalist-ui.md (4.7)
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../library/library_scope.dart';
import '../shell/handheld.dart';
import '../ui/brutal/brutal.dart';
import 'bbs.dart';
import 'cart_download.dart';
import '../ui/dena_icons.dart';

/// One query's pages, loaded on demand.
class CartListController extends ChangeNotifier {
  CartListController(this.client, this.query);

  final BbsClient client;
  final BbsQuery query;

  final carts = <BbsCart>[];
  bool loading = false, hasMore = false, started = false;
  String? error;
  int _page = 0;

  /// Loads the first page once.
  void start() {
    if (started) return;
    started = true;
    _load();
  }

  void retry() {
    error = null;
    _load();
  }

  void more() {
    if (!loading && hasMore) _load();
  }

  Future<void> _load() async {
    loading = true;
    notifyListeners();
    try {
      final page = await client.list(query, page: _page + 1);
      _page++;
      final seen = {for (final c in carts) c.postId};
      carts.addAll(page.carts.where((c) => seen.add(c.postId)));
      hasMore = page.hasMore;
      error = null;
    } on BbsException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}

/// A title as a file-style name for display only: upper case, spaces to
/// underscores (`MOON_HOPPER`). The stored title never changes.
String fileStyleTitle(String title) =>
    title.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '_');

/// A row number as two digits: `01`.
String rowNumber(int n) => n.toString().padLeft(2, '0');

/// What the browser needs besides the library: the BBS and the credits file.
class CartBrowserDeps {
  const CartBrowserDeps({required this.client, required this.credits});

  final BbsClient client;
  final CartCredits credits;
}

class CartBrowserPage extends StatefulWidget {
  const CartBrowserPage({super.key, required this.deps});

  final CartBrowserDeps deps;

  @override
  State<CartBrowserPage> createState() => _CartBrowserPageState();
}

class _CartBrowserPageState extends State<CartBrowserPage> {
  static const tabs = [
    BrutalTabItem(label: 'FEATURED'),
    BrutalTabItem(label: 'NEW'),
    BrutalTabItem(label: 'SEARCH'),
    BrutalTabItem(label: 'AUTHOR'),
  ];

  int _index = 0;
  late final featured = CartListController(
    widget.deps.client,
    const FeaturedCarts(),
  )..addListener(_onLists);
  late final latest = CartListController(widget.deps.client, const NewCarts())
    ..addListener(_onLists);
  CartListController? search;
  final _searchText = TextEditingController();

  /// Holds focus across tab switches so L1 / R1 keep working.
  final _pageFocus = FocusNode(debugLabel: 'cart browser');

  /// The first focusable item of the visible tab (row, Retry or field).
  final _first = FocusNode(debugLabel: 'cart browser first');
  final _searchFirst = FocusNode(debugLabel: 'cart search first');

  @override
  void initState() {
    super.initState();
    featured.start();
  }

  @override
  void dispose() {
    featured.dispose();
    latest.dispose();
    search?.dispose();
    _searchText.dispose();
    _pageFocus.dispose();
    _first.dispose();
    _searchFirst.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == 1) latest.start();
    setState(() => _index = index);
    _pageFocus.requestFocus();
    _focusFirstSoon();
  }

  void _onLists() {
    if (!mounted) return;
    setState(() {});
    _focusFirstSoon();
  }

  /// Moves focus into the tab when nothing inside it has focus yet.
  void _focusFirstSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      final idle =
          primary == null || primary == _pageFocus || primary.context == null;
      if (idle && _first.context != null && _first.canRequestFocus) {
        _first.requestFocus();
      }
    });
  }

  void _go(int delta) => _select((_index + delta) % tabs.length);

  void _runSearch(String text) {
    final q = text.trim();
    if (q.isEmpty) return;
    search?.dispose();
    setState(() {
      search = CartListController(widget.deps.client, SearchCarts(q))
        ..addListener(_onLists)
        ..start();
    });
  }

  /// Authors of the carts loaded so far, alphabetical, with their counts.
  List<(int, String, int)> get _authors {
    final byId = <int, String>{};
    final counts = <int, Set<String>>{};
    for (final c in [...featured.carts, ...latest.carts]) {
      byId[c.authorId] = c.author;
      (counts[c.authorId] ??= {}).add(c.postId);
    }
    final list = [
      for (final e in byId.entries) (e.key, e.value, counts[e.key]!.length),
    ];
    list.sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final deps = widget.deps;
    final body = switch (_index) {
      0 => CartListView(controller: featured, deps: deps, firstFocus: _first),
      1 => CartListView(controller: latest, deps: deps, firstFocus: _first),
      2 => _SearchTab(
        field: _searchText,
        fieldFocus: _first,
        resultsFocus: _searchFirst,
        onSubmit: _runSearch,
        results: search,
        deps: deps,
      ),
      _ => _AuthorsTab(
        authors: _authors,
        loading: featured.loading || latest.loading,
        firstFocus: _first,
        deps: deps,
      ),
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.gameButtonLeft1): () =>
            _go(tabs.length - 1),
        const SingleActivator(LogicalKeyboardKey.gameButtonRight1): () =>
            _go(1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        skipTraversal: true,
        child: Scaffold(
          appBar: AppBar(title: const Text('PICO-8 BBS'), toolbarHeight: 48),
          body: _Page(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BrutalTabBar(
                  key: const Key('cart browser tabs'),
                  tabs: tabs,
                  selected: _index,
                  onSelected: _select,
                  iconAbove: false,
                ),
                const SizedBox(height: BrutalTokens.s3),
                Expanded(child: body),
              ],
            ),
          ),
          bottomNavigationBar: _hints(context),
        ),
      ),
    );
  }
}

/// Grid paper behind a padded page; the right and bottom padding leave room
/// for the tables' hard shadow.
class _Page extends StatelessWidget {
  const _Page({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final pad = t.density == BrutalDensity.handheld
        ? BrutalTokens.s2
        : BrutalTokens.s3;
    return BrutalGridPaper(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            pad,
            pad,
            pad + t.shadowOffsetLarge.dx,
            pad + t.shadowOffsetLarge.dy,
          ),
          child: child,
        ),
      ),
    );
  }
}

Widget? _hints(BuildContext context) => usesButtons(context)
    ? const BrutalHintBar(
        hints: [
          ([HintButton.a], 'Select'),
          ([HintButton.l1, HintButton.r1], 'Tabs'),
          ([HintButton.b], 'Back'),
        ],
      )
    : null;

/// Gives [node] to a table: when [node] itself is focused, focus moves on
/// to the table's first row (the kit's rows take no focus node of their own).
class FirstRowFocus extends StatefulWidget {
  const FirstRowFocus({super.key, required this.node, required this.child});

  final FocusNode node;
  final Widget child;

  @override
  State<FirstRowFocus> createState() => _FirstRowFocusState();
}

class _FirstRowFocusState extends State<FirstRowFocus> {
  @override
  void initState() {
    super.initState();
    widget.node.addListener(_moved);
  }

  @override
  void didUpdateWidget(FirstRowFocus old) {
    super.didUpdateWidget(old);
    if (old.node != widget.node) {
      old.node.removeListener(_moved);
      widget.node.addListener(_moved);
    }
  }

  @override
  void dispose() {
    widget.node.removeListener(_moved);
    super.dispose();
  }

  void _moved() {
    if (!widget.node.hasPrimaryFocus) return;
    for (final n in widget.node.traversalDescendants) {
      if (n.canRequestFocus) {
        n.requestFocus();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: widget.node, skipTraversal: true, child: widget.child);
}

/// The BBS results' columns.
const _cartColumns = [
  BrutalColumn('#', width: 32),
  BrutalColumn('CART', width: 46),
  BrutalColumn('TITLE', flex: 3),
  BrutalColumn('AUTHOR', flex: 2),
];

/// A list's table with loading, error, empty and "Load more" states.
class CartListView extends StatelessWidget {
  const CartListView({
    super.key,
    required this.controller,
    required this.deps,
    required this.firstFocus,
  });

  final CartListController controller;
  final CartBrowserDeps deps;
  final FocusNode firstFocus;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.carts.isEmpty) {
      if (c.loading || !c.started) {
        return const _Message(headline: 'LOADING.', text: 'asking the BBS ...');
      }
      if (c.error case final message?) {
        return _Message(
          headline: 'BBS ERROR.',
          text: message,
          failed: true,
          action: BrutalButton(
            focusNode: firstFocus,
            onPressed: c.retry,
            icon: DenaIcons.refresh,
            label: '[RETRY]',
          ),
        );
      }
      return const _Message(
        headline: 'NO CARTS FOUND.',
        text: 'nothing on the BBS matches',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: FirstRowFocus(
            node: firstFocus,
            child: BrutalTable(
              columns: _cartColumns,
              rowCount: c.carts.length,
              onRowPressed: (i) => showCartSheet(context, c.carts[i], deps),
              cellBuilder: (context, i, column, lit) => switch (column) {
                0 => Text(rowNumber(i + 1)),
                1 => BoxThumb(
                  aspect: 1,
                  child: CartThumb(cart: c.carts[i], client: deps.client),
                ),
                2 => Text(fileStyleTitle(c.carts[i].title)),
                _ => Text(c.carts[i].author),
              },
            ),
          ),
        ),
        if (c.hasMore || c.error != null)
          Padding(
            padding: const EdgeInsets.only(top: BrutalTokens.s3),
            child: Align(
              alignment: Alignment.centerLeft,
              child: c.loading
                  ? LogLine('loading more ...', key: const Key('loading more'))
                  : BrutalButton(
                      onPressed: c.error != null ? c.retry : c.more,
                      label: c.error != null ? '[RETRY]' : '[LOAD MORE]',
                    ),
            ),
          ),
        if (c.error case final message? when !c.loading)
          Padding(
            padding: const EdgeInsets.only(top: BrutalTokens.s1),
            child: LogLine(message, status: LogStatus.err),
          ),
      ],
    );
  }
}

/// An empty, loading or failed tab: a display headline, a log line and an
/// optional button (EmptyState's look; this one's button takes a focus node).
class _Message extends StatelessWidget {
  const _Message({
    required this.headline,
    required this.text,
    this.action,
    this.failed = false,
  });

  final String headline;
  final String text;
  final Widget? action;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final compact = t.density == BrutalDensity.handheld;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(BrutalTokens.s2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: compact ? t.displaySmall : t.display),
          const SizedBox(height: BrutalTokens.s2),
          Text(
            '> $text',
            style: t.body.copyWith(color: failed ? t.danger : t.mutedText),
          ),
          if (action != null) ...[
            const SizedBox(height: BrutalTokens.s4),
            action!,
          ],
        ],
      ),
    );
  }
}

/// A cart's BBS thumbnail (fetched from the BBS, never rehosted).
class CartThumb extends StatefulWidget {
  const CartThumb({super.key, required this.cart, required this.client});

  final BbsCart cart;
  final BbsClient client;

  @override
  State<CartThumb> createState() => _CartThumbState();
}

class _CartThumbState extends State<CartThumb> {
  late Future<Uint8List?> _bytes = widget.client.thumbnail(widget.cart);

  @override
  void didUpdateWidget(CartThumb old) {
    super.didUpdateWidget(old);
    if (old.cart != widget.cart || old.client != widget.client) {
      _bytes = widget.client.thumbnail(widget.cart);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final placeholder = ColoredBox(
      color: t.muted,
      child: Center(
        child: Icon(DenaIcons.cart, color: t.ink, size: BrutalTokens.iconSize),
      ),
    );
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snap) => switch (snap.data) {
        final bytes? => Image.memory(
          bytes,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.none,
          errorBuilder: (_, _, _) => placeholder,
        ),
        null => placeholder,
      },
    );
  }
}

class _SearchTab extends StatelessWidget {
  const _SearchTab({
    required this.field,
    required this.fieldFocus,
    required this.resultsFocus,
    required this.onSubmit,
    required this.results,
    required this.deps,
  });

  final TextEditingController field;
  final FocusNode fieldFocus, resultsFocus;
  final ValueChanged<String> onSubmit;
  final CartListController? results;
  final CartBrowserDeps deps;

  @override
  Widget build(BuildContext context) {
    final results = this.results;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CommandField(
          key: const Key('cart search'),
          controller: field,
          focusNode: fieldFocus,
          icon: DenaIcons.search,
          hint: 'search carts',
          onSubmitted: onSubmit,
        ),
        const SizedBox(height: BrutalTokens.s3),
        Expanded(
          child: results == null
              ? const _Message(
                  headline: 'SEARCH.',
                  text: 'search the BBS by title or tag',
                )
              : CartListView(
                  controller: results,
                  deps: deps,
                  firstFocus: resultsFocus,
                ),
        ),
      ],
    );
  }
}

class _AuthorsTab extends StatelessWidget {
  const _AuthorsTab({
    required this.authors,
    required this.loading,
    required this.firstFocus,
    required this.deps,
  });

  final List<(int, String, int)> authors;
  final bool loading;
  final FocusNode firstFocus;
  final CartBrowserDeps deps;

  @override
  Widget build(BuildContext context) {
    if (authors.isEmpty) {
      return loading
          ? const _Message(headline: 'LOADING.', text: 'asking the BBS ...')
          : const _Message(
              headline: 'NO AUTHORS YET.',
              text: 'authors of featured and new carts show here',
            );
    }
    return FirstRowFocus(
      node: firstFocus,
      child: BrutalTable(
        key: const Key('cart authors'),
        columns: const [
          BrutalColumn('#', width: 32),
          BrutalColumn('AUTHOR', flex: 3),
          BrutalColumn('CARTS', width: 72, numeric: true),
          BrutalColumn('', width: 36),
        ],
        rowCount: authors.length,
        onRowPressed: (i) {
          final (id, name, _) = authors[i];
          openAuthor(context, AuthorCarts(id, name), deps);
        },
        cellBuilder: (context, i, column, lit) => switch (column) {
          0 => Text(rowNumber(i + 1)),
          1 => Text(authors[i].$2),
          2 => Text('${authors[i].$3}'),
          _ => const Text('>'),
        },
      ),
    );
  }
}

/// Shows [query]'s carts on their own page; back returns.
Future<void> openAuthor(
  BuildContext context,
  AuthorCarts query,
  CartBrowserDeps deps,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => _AuthorPage(query: query, deps: deps),
  ),
);

class _AuthorPage extends StatefulWidget {
  const _AuthorPage({required this.query, required this.deps});

  final AuthorCarts query;
  final CartBrowserDeps deps;

  @override
  State<_AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<_AuthorPage> {
  late final controller = CartListController(widget.deps.client, widget.query)
    ..addListener(_changed)
    ..start();
  final _pageFocus = FocusNode(debugLabel: 'author page');
  final _first = FocusNode(debugLabel: 'author first');

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _first.context == null) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary == _pageFocus || primary.context == null) {
        _first.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    controller.dispose();
    _pageFocus.dispose();
    _first.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).maybePop(),
    },
    child: Focus(
      focusNode: _pageFocus,
      autofocus: true,
      skipTraversal: true,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          title: Text('CARTS BY ${widget.query.author}'),
        ),
        body: _Page(
          child: CartListView(
            controller: controller,
            deps: widget.deps,
            firstFocus: _first,
          ),
        ),
        bottomNavigationBar: _hints(context),
      ),
    ),
  );
}

/// The details sheet: label art, credit, license, BBS link and Download /
/// More by author / Copy link.
Future<void> showCartSheet(
  BuildContext context,
  BbsCart cart,
  CartBrowserDeps deps,
) => showBrutalSheet<void>(
  context: context,
  builder: (_) => BrutalSheet(
    title: fileStyleTitle(cart.title),
    child: CartSheet(cart: cart, deps: deps),
  ),
);

class CartSheet extends StatefulWidget {
  const CartSheet({super.key, required this.cart, required this.deps});

  final BbsCart cart;
  final CartBrowserDeps deps;

  @override
  State<CartSheet> createState() => _CartSheetState();
}

class _CartSheetState extends State<CartSheet> {
  bool? inLibrary;
  bool downloading = false;
  final _download = FocusNode(debugLabel: 'cart download');
  final _author = FocusNode(debugLabel: 'cart author');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (inLibrary == null) _check();
  }

  @override
  void dispose() {
    _download.dispose();
    _author.dispose();
    super.dispose();
  }

  bool get canDownload =>
      widget.cart.cartId != null && inLibrary == false && !downloading;

  Future<void> _check() async {
    final have = await cartInLibrary(
      LibraryScope.of(context).db,
      widget.deps.credits,
      widget.cart.postId,
    );
    if (!mounted) return;
    setState(() => inLibrary = have);
    // Something in the sheet always has focus: Download when it can run,
    // else More by author.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (canDownload ? _download : _author).requestFocus();
    });
  }

  Future<void> _start() async {
    final scope = LibraryScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cart = widget.cart;
    setState(() => downloading = true);
    String message;
    var ok = true;
    try {
      final result = await downloadCart(
        client: widget.deps.client,
        cart: cart,
        importer: scope.importer,
        credits: widget.deps.credits,
      );
      message = switch (result) {
        DownloadResult.added => 'Added ${cart.title} by ${cart.author}',
        DownloadResult.alreadyInLibrary => 'Already in your library',
      };
      if (mounted) setState(() => inLibrary = true);
    } on BbsException catch (e) {
      message = e.message;
      ok = false;
    }
    if (mounted) setState(() => downloading = false);
    messenger.showSnackBar(
      brutalToast(message, kind: ok ? ToastKind.ok : ToastKind.err),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    final t = BrutalTokens.of(context);
    final side = BrutalSheet.sideFor(context) == BrutalSheetSide.right;
    final art = t.density == BrutalDensity.handheld ? 72.0 : 96.0;
    final buttons = [
      BrutalButton(
        focusNode: _download,
        variant: BrutalButtonVariant.primary,
        expand: side,
        onPressed: canDownload ? _start : null,
        icon: inLibrary == true ? DenaIcons.check : DenaIcons.download,
        label: inLibrary == true ? '[IN LIBRARY]' : '[DOWNLOAD]',
      ),
      BrutalButton(
        focusNode: _author,
        expand: side,
        onPressed: () {
          final navigator = Navigator.of(context);
          navigator.pop();
          openAuthor(
            navigator.context,
            AuthorCarts(cart.authorId, cart.author),
            widget.deps,
          );
        },
        icon: DenaIcons.person,
        label: '[MORE BY AUTHOR]',
      ),
      BrutalButton(
        expand: side,
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          await Clipboard.setData(
            ClipboardData(text: cart.threadUrl.toString()),
          );
          messenger.showSnackBar(brutalToast('BBS link copied'));
        },
        icon: DenaIcons.link,
        label: '[COPY LINK]',
      ),
    ];
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        BrutalTokens.s4,
        BrutalTokens.s3,
        BrutalTokens.s4 + t.shadowOffset.dx,
        BrutalTokens.s4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: art,
                height: art,
                decoration: BoxDecoration(
                  border: Border.all(color: t.ink, width: BrutalTokens.border),
                ),
                child: CartThumb(cart: cart, client: widget.deps.client),
              ),
              const SizedBox(width: BrutalTokens.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fileStyleTitle(cart.title), style: t.title),
                    Text('by ${cart.author}', style: t.body),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: BrutalTokens.s3),
          // The listing has no license field (pico8-cart-browser.md).
          KeyValueStrip(
            entries: [('AUTHOR', cart.author), ('LICENSE', 'ON BBS PAGE')],
          ),
          const SizedBox(height: BrutalTokens.s2),
          // Shown in full (never cut off): the credit links back to the BBS.
          Text(
            cart.threadUrl.toString(),
            key: const Key('cart bbs link'),
            style: t.small.copyWith(color: t.ink),
          ),
          Text(
            "> license: set by the author, on the cart's BBS page",
            style: t.small.copyWith(color: t.mutedText),
          ),
          const SizedBox(height: BrutalTokens.s4),
          if (side)
            for (final (i, b) in buttons.indexed) ...[
              if (i > 0) const SizedBox(height: BrutalTokens.s3),
              Padding(
                // Room for the `<-` focus marker beside the button.
                padding: const EdgeInsets.only(right: BrutalTokens.s6 + 4),
                child: b,
              ),
            ]
          else
            Wrap(
              spacing: BrutalTokens.s3,
              runSpacing: BrutalTokens.s3,
              children: buttons,
            ),
          if (downloading) ...[
            const SizedBox(height: BrutalTokens.s3),
            LogLine('download ${cartFileStem(cart.title)}.p8.png ...'),
          ],
        ],
      ),
    );
  }
}
