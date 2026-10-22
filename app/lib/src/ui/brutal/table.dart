// SPDX-License-Identifier: GPL-3.0-or-later
// The dense Brutalist table, its progress cell and the box-art thumbnail.
// Spec: docs/specs/brutalist-ui.md (3: BrutalTable, ProgressCell, BoxThumb)
import 'package:material_ui/material_ui.dart';

import 'pressable.dart';
import 'tokens.dart';

/// A [BrutalTable] column.
@immutable
class BrutalColumn {
  const BrutalColumn(
    this.label, {
    this.width,
    this.flex = 1,
    this.numeric = false,
    this.sortable = false,
  });

  final String label;

  /// Fixed width; null takes a [flex] share of what is left.
  final double? width;
  final int flex;

  /// Right-aligned.
  final bool numeric;

  /// The header cycles the sort when tapped or activated.
  final bool sortable;
}

/// Builds the cell of [row] in [column]; [lit] is true for the focused or
/// selected row (draw text in [BrutalTokens.onFocus]).
typedef BrutalCellBuilder =
    Widget Function(BuildContext context, int row, int column, bool lit);

/// A dense table: black header row with sortable columns (`TITLE ↓`), thin
/// row dividers, mono cells. The focused or selected row is yellow with 3 px
/// black rules above and below, and its leading cell turns into a blue `->`.
/// Rows are built lazily, so big libraries stay cheap.
class BrutalTable extends StatelessWidget {
  const BrutalTable({
    super.key,
    required this.columns,
    required this.rowCount,
    required this.cellBuilder,
    this.selectedRow,
    this.onRowPressed,
    this.onRowLongPress,
    this.sortColumn,
    this.sortAscending = true,
    this.onSort,
    this.shrinkWrap = false,
    this.controller,
    this.autofocusRow,
  });

  final List<BrutalColumn> columns;
  final int rowCount;
  final BrutalCellBuilder cellBuilder;
  final int? selectedRow;
  final ValueChanged<int>? onRowPressed;
  final ValueChanged<int>? onRowLongPress;
  final int? sortColumn;
  final bool sortAscending;
  final ValueChanged<int>? onSort;

  /// Size to the rows instead of filling and scrolling.
  final bool shrinkWrap;
  final ScrollController? controller;
  final int? autofocusRow;

  /// The leading marker cell's width.
  static const double markerWidth = 30;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final list = ListView.builder(
      controller: controller,
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.zero,
      itemCount: rowCount,
      itemExtent: t.rowHeight + BrutalTokens.borderThin,
      itemBuilder: (context, i) => _Row(
        table: this,
        index: i,
        selected: i == selectedRow,
      ),
    );
    return DecoratedBox(
      decoration: t.panelDecoration(large: true),
      child: Padding(
        padding: const EdgeInsets.all(BrutalTokens.border),
        child: Column(
          mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(table: this),
            if (shrinkWrap) list else Expanded(child: list),
          ],
        ),
      ),
    );
  }

  /// Lays out [cells] in the columns' widths after the marker cell.
  Widget layout(BuildContext context, Widget marker, List<Widget> cells) {
    return Row(
      children: [
        SizedBox(width: markerWidth, child: marker),
        for (final (i, c) in columns.indexed)
          if (c.width != null)
            SizedBox(width: c.width, child: _cell(c, cells[i]))
          else
            Expanded(flex: c.flex, child: _cell(c, cells[i])),
      ],
    );
  }

  Widget _cell(BrutalColumn c, Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: BrutalTokens.s1 + 2),
    child: Align(
      alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.table});

  final BrutalTable table;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final style = t.label.copyWith(color: t.onHeaderBar);
    return Container(
      color: t.headerBar,
      height: t.density == BrutalDensity.handheld ? 22 : 28,
      child: table.layout(context, const SizedBox(), [
        for (final (i, c) in table.columns.indexed)
          _HeaderCell(
            label:
                c.label.toUpperCase() +
                (i == table.sortColumn
                    ? (table.sortAscending ? ' ↓' : ' ↑')
                    : ''),
            style: style,
            onPressed: c.sortable && table.onSort != null
                ? () => table.onSort!(i)
                : null,
          ),
      ]),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, required this.style, this.onPressed});

  final String label;
  final TextStyle style;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, style: style, maxLines: 1, overflow: TextOverflow.clip);
    if (onPressed == null) return text;
    final t = BrutalTokens.of(context);
    return BrutalPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, s) => Container(
        color: s.highlighted ? t.focus : null,
        child: s.highlighted
            ? Text(label, style: style.copyWith(color: t.onFocus), maxLines: 1)
            : text,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.table, required this.index, required this.selected});

  final BrutalTable table;
  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPressable(
      onPressed: table.onRowPressed == null
          ? null
          : () => table.onRowPressed!(index),
      onLongPress: table.onRowLongPress == null
          ? null
          : () => table.onRowLongPress!(index),
      autofocus: index == table.autofocusRow,
      selected: selected,
      builder: (context, s) {
        final lit = selected || s.highlighted;
        final cells = [
          for (var c = 0; c < table.columns.length; c++)
            DefaultTextStyle.merge(
              style: t.row.copyWith(color: lit ? t.onFocus : t.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: table.cellBuilder(context, index, c, lit),
            ),
        ];
        final marker = lit
            ? Container(
                color: t.primary,
                alignment: Alignment.center,
                child: Text('->', style: t.label.copyWith(color: t.onPrimary)),
              )
            : const SizedBox();
        return Container(
          decoration: BoxDecoration(
            color: lit ? t.focus : t.panel,
            border: lit
                ? Border.symmetric(
                    horizontal: BorderSide(
                      color: const Color(0xFF000000),
                      width: BrutalTokens.border,
                    ),
                  )
                : Border(
                    bottom: BorderSide(
                      color: t.ink,
                      width: BrutalTokens.borderThin,
                    ),
                  ),
          ),
          child: table.layout(context, marker, cells),
        );
      },
    );
  }
}

/// A hard progress bar: ink border, ink fill for the done part, no rounding,
/// optional `%` text after it.
class ProgressCell extends StatelessWidget {
  const ProgressCell({
    super.key,
    required this.value,
    this.showPercent = true,
    this.width = 64,
    this.height = 10,
    this.color,
  });

  /// 0 to 1.
  final double value;
  final bool showPercent;
  final double width;
  final double height;

  /// Ink by default; pass onFocus on a lit row.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final ink = color ?? DefaultTextStyle.of(context).style.color ?? t.ink;
    final v = value.clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            border: Border.all(color: ink, width: BrutalTokens.borderThin),
          ),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: v,
            heightFactor: 1,
            child: ColoredBox(color: ink),
          ),
        ),
        if (showPercent) ...[
          const SizedBox(width: BrutalTokens.s1),
          Text('${(v * 100).round()}%', style: t.small.copyWith(color: ink)),
        ],
      ],
    );
  }
}

/// Tiny box art in a table cell, keeping the console box's [aspect]
/// (width / height) inside 34x40 (phone, desktop) or 26x30 (handheld), with
/// a black border. [child] is the art; null draws an empty muted box.
class BoxThumb extends StatelessWidget {
  const BoxThumb({super.key, this.child, this.aspect = 34 / 40});

  final Widget? child;
  final double aspect;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final (w, full) = t.density == BrutalDensity.handheld
        ? (26.0, 30.0)
        : (34.0, 40.0);
    return LayoutBuilder(
      builder: (context, box) {
        // A row shorter than the box (handheld 28 px) shrinks it to fit.
        final h = box.maxHeight < full ? box.maxHeight : full;
        final fitW = aspect >= w / h ? w : h * aspect;
        final fitH = aspect >= w / h ? w / aspect : h;
        return SizedBox(
          width: w,
          height: h,
          child: Center(
            child: Container(
              width: fitW,
              height: fitH,
              decoration: BoxDecoration(
                color: t.muted,
                border: Border.all(
                  color: const Color(0xFF000000),
                  width: BrutalTokens.borderThin,
                ),
              ),
              clipBehavior: Clip.hardEdge,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
