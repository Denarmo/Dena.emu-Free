// SPDX-License-Identifier: GPL-3.0-or-later
// The Brutalist shell chrome: the DENA.EMU/ wordmark block and the three
// navigation arrangements (tabs under the wordmark on phones, a left rail on
// handhelds, a yellow header bar on desktops and tablets).
// Spec: docs/specs/brutalist-ui.md (4.1, 4.12, 5)
import 'package:material_ui/material_ui.dart';

import '../library/database.dart';
import '../library/library_scope.dart';
import '../ui/brutal/brutal.dart';
import 'handheld.dart';

/// Where the shell puts its navigation.
enum ShellNav {
  /// Phones: a row of four tabs under the wordmark.
  tabs,

  /// Handhelds: wordmark and tabs stacked in a left rail.
  rail,

  /// Desktop, TV layout, tablets and foldables: a yellow header bar.
  header;

  /// The arrangement for [context]: handhelds use the rail, anything from
  /// 600 px wide the header bar, phones the tabs.
  static ShellNav of(BuildContext context) {
    if (Handheld.of(context)) return rail;
    return MediaQuery.sizeOf(context).width >= 600 ? header : tabs;
  }
}

/// One navigation destination of the shell.
typedef ShellDestination = ({
  IconData icon,
  IconData selectedIcon,
  String label,
});

/// The `DENA.EMU/` wordmark, the current [path] and the library stat line
/// (`12 ROMS // 4.1 GB`). [compact] (handheld rail) drops the stat column
/// and uses the smaller display size; [bare] draws no panel, for the yellow
/// header bar that already is one.
class DenaWordmark extends StatelessWidget {
  const DenaWordmark({
    super.key,
    required this.path,
    this.compact = false,
    this.bare = false,
  });

  final String path;
  final bool compact;
  final bool bare;

  static const text = 'DENA.EMU/';

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final mark = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        maxLines: 1,
        style: (compact ? t.displaySmall : t.display).copyWith(
          color: t.onFocus,
        ),
      ),
    );
    final Widget content = compact
        ? mark
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 3, child: mark),
              const SizedBox(width: BrutalTokens.s3),
              Flexible(
                flex: 2,
                child: _StatLines(path: path, color: t.onFocus),
              ),
            ],
          );
    if (bare) return content;
    return BrutalPanel(
      fill: t.focus,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? BrutalTokens.s3 : BrutalTokens.s4,
        vertical: compact ? BrutalTokens.s2 : BrutalTokens.s3,
      ),
      child: content,
    );
  }
}

/// The right-hand side of the wordmark: the path and the library size.
class _StatLines extends StatelessWidget {
  const _StatLines({required this.path, required this.color});

  final String path;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final style = t.small.copyWith(color: color, fontWeight: FontWeight.w600);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(path, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        LibraryStat(style: style),
      ],
    );
  }
}

/// `12 ROMS // 4.1 GB`, live from the library.
class LibraryStat extends StatefulWidget {
  const LibraryStat({super.key, this.style});

  final TextStyle? style;

  @override
  State<LibraryStat> createState() => _LibraryStatState();
}

class _LibraryStatState extends State<LibraryStat> {
  Stream<List<Game>>? _games;
  LibraryDatabase? _db;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final db = context.dependOnInheritedWidgetOfExactType<LibraryScope>()?.db;
    if (db != _db) {
      _db = db;
      _games = db?.watchGames();
    }
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    if (games == null) return const SizedBox.shrink();
    return StreamBuilder<List<Game>>(
      stream: games,
      builder: (context, snap) {
        final list = snap.data;
        if (list == null) return const SizedBox.shrink();
        final bytes = list.fold<int>(0, (sum, g) => sum + g.size);
        return Text(
          libraryStatLine(list.length, bytes),
          style: widget.style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// `12 ROMS // 4.1 GB` for [count] games of [bytes] in total.
String libraryStatLine(int count, int bytes) =>
    '$count ${count == 1 ? 'ROM' : 'ROMS'} // ${formatBytes(bytes)}';

/// Bytes as `512 KB`, `38 MB`, `4.1 GB` (decimal units, one decimal from
/// GB up).
String formatBytes(int bytes) {
  const kb = 1000, mb = kb * 1000, gb = mb * 1000;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

/// The tab path shown beside the wordmark: `/games`, `/settings`.
String shellPath(String label) => '/${label.toLowerCase()}';

/// Phone navigation: the wordmark, then the tabs in one row.
class ShellTopTabs extends StatelessWidget {
  const ShellTopTabs({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelected,
  });

  final List<ShellDestination> destinations;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s2,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DenaWordmark(path: shellPath(destinations[selected].label)),
          const SizedBox(height: BrutalTokens.s2),
          BrutalTabBar(
            tabs: _items(destinations, selected),
            selected: selected,
            onSelected: onSelected,
          ),
        ],
      ),
    );
  }
}

/// Handheld navigation: wordmark and tabs stacked in a left rail. The
/// library adds its filters below through its own layout (4.2).
class ShellRail extends StatelessWidget {
  const ShellRail({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelected,
  });

  final List<ShellDestination> destinations;
  final int selected;
  final ValueChanged<int> onSelected;

  static const width = 168.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BrutalTokens.s2,
          BrutalTokens.s2,
          BrutalTokens.s1,
          BrutalTokens.s2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DenaWordmark(
              path: shellPath(destinations[selected].label),
              compact: true,
            ),
            const SizedBox(height: BrutalTokens.s2),
            BrutalTabBar(
              tabs: _items(destinations, selected),
              selected: selected,
              onSelected: onSelected,
              axis: Axis.vertical,
              iconAbove: false,
            ),
          ],
        ),
      ),
    );
  }
}

/// Desktop, TV and tablet navigation: one yellow bar with the wordmark,
/// the tabs inline and the path and library size at the right.
class ShellHeaderBar extends StatelessWidget {
  const ShellHeaderBar({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelected,
  });

  final List<ShellDestination> destinations;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final items = _items(destinations, selected);
    final stat = t.small.copyWith(
      color: t.onFocus,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s2,
      ),
      child: BrutalPanel(
        fill: t.focus,
        padding: const EdgeInsets.symmetric(
          horizontal: BrutalTokens.s4,
          vertical: BrutalTokens.s2,
        ),
        child: Row(
          children: [
            Flexible(
              flex: 2,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  DenaWordmark.text,
                  maxLines: 1,
                  style: t.displaySmall.copyWith(color: t.onFocus),
                ),
              ),
            ),
            const SizedBox(width: BrutalTokens.s4),
            FocusTraversalGroup(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, item) in items.indexed) ...[
                    if (i > 0) const SizedBox(width: BrutalTokens.s2),
                    BrutalTab(
                      item: item,
                      selected: i == selected,
                      vertical: false,
                      onPressed: () => onSelected(i),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: BrutalTokens.s4),
            Expanded(
              flex: 2,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    shellPath(destinations[selected].label),
                    style: stat,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  LibraryStat(style: stat),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<BrutalTabItem> _items(List<ShellDestination> destinations, int selected) =>
    [
      for (final (i, d) in destinations.indexed)
        BrutalTabItem(
          label: d.label,
          icon: i == selected ? d.selectedIcon : d.icon,
        ),
    ];
