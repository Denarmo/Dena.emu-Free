// SPDX-License-Identifier: GPL-3.0-or-later
// Brutalist surfaces: graph paper, panels, stickers, log lines, key-value
// strips and empty states.
// Spec: docs/specs/brutalist-ui.md (3)
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'button.dart';
import 'tokens.dart';

/// `GridPaper` in the spec (renamed: Flutter has its own). The screen
/// background: [BrutalTokens.ground] with an 8 px grid, every
/// 4th line darker. The grid is recorded once per size and colour and
/// replayed, so it costs one picture draw per frame (cheap on the H700).
class BrutalGridPaper extends StatelessWidget {
  const BrutalGridPaper({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return CustomPaint(
      painter: _GridPainter(t.ground, t.gridLine, t.gridLineMajor),
      isComplex: true,
      willChange: false,
      child: child ?? const SizedBox.expand(),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.ground, this.line, this.major);

  final Color ground, line, major;

  static final _cache = <(Size, Color, Color, Color), ui.Picture>{};

  @override
  void paint(Canvas canvas, Size size) {
    final key = (size, ground, line, major);
    final picture = _cache[key] ??= _record(size);
    // Bound the cache: sizes change on rotation and resizing.
    if (_cache.length > 8) _cache.remove(_cache.keys.first);
    canvas.drawPicture(picture);
  }

  ui.Picture _record(Size size) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Offset.zero & size, Paint()..color = ground);
    final thin = Paint()..color = line;
    final thick = Paint()..color = major;
    const cell = BrutalTokens.gridCell;
    for (var i = 0; i * cell <= size.width; i++) {
      c.drawRect(
        Rect.fromLTWH(i * cell, 0, BrutalTokens.hairline, size.height),
        i % 4 == 0 ? thick : thin,
      );
    }
    for (var j = 0; j * cell <= size.height; j++) {
      c.drawRect(
        Rect.fromLTWH(0, j * cell, size.width, BrutalTokens.hairline),
        j % 4 == 0 ? thick : thin,
      );
    }
    return rec.endRecording();
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.ground != ground || old.line != line || old.major != major;
}

/// A box with the panel fill, a 3 px ink border and a hard shadow. An
/// optional [header] draws an inverted strip on top (`VIDEO.CFG`).
class BrutalPanel extends StatelessWidget {
  const BrutalPanel({
    super.key,
    required this.child,
    this.header,
    this.headerTrailing,
    this.large = false,
    this.padding = EdgeInsets.zero,
    this.fill,
    this.shadowed = true,
  });

  final Widget child;
  final String? header;
  final Widget? headerTrailing;

  /// The 6 px shadow of tables and dialogs.
  final bool large;
  final EdgeInsetsGeometry padding;
  final Color? fill;
  final bool shadowed;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final offset = large ? t.shadowOffsetLarge : t.shadowOffset;
    return Padding(
      padding: EdgeInsets.only(
        right: shadowed ? offset.dx : 0,
        bottom: shadowed ? offset.dy : 0,
      ),
      child: DecoratedBox(
        decoration: t.panelDecoration(
          fill: fill,
          large: large,
          shadowed: shadowed,
        ),
        child: Padding(
          padding: const EdgeInsets.all(BrutalTokens.border),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (header != null) BrutalHeaderStrip(header!, trailing: headerTrailing),
              Flexible(
                fit: FlexFit.loose,
                child: Padding(padding: padding, child: child),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The inverted header row of panels and tables.
class BrutalHeaderStrip extends StatelessWidget {
  const BrutalHeaderStrip(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      color: t.headerBar,
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s3,
        vertical: BrutalTokens.s1 + 2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: t.label.copyWith(color: t.onHeaderBar),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A rotated yellow block with a border and shadow and Archivo Black text
/// (`PAUSED`, `NEW`, `HACK`).
class Sticker extends StatelessWidget {
  const Sticker(this.text, {super.key, this.small = false, this.angle = -4});

  final String text;
  final bool small;

  /// Degrees; negative leans left.
  final double angle;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final style = (small ? t.small : t.displaySmall).copyWith(
      fontFamily: brutalDisplay,
      color: t.onFocus,
      fontSize: small ? 11 : null,
    );
    return Transform.rotate(
      angle: angle * math.pi / 180,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: small ? BrutalTokens.s1 + 2 : BrutalTokens.s3,
          vertical: small ? 1 : BrutalTokens.s1,
        ),
        decoration: BoxDecoration(
          color: t.focus,
          border: Border.all(
            color: const Color(0xFF000000),
            width: small ? BrutalTokens.borderThin : BrutalTokens.border,
          ),
          boxShadow: [
            BoxShadow(
              color: t.shadow,
              offset: small ? const Offset(2, 2) : t.shadowOffset,
            ),
          ],
        ),
        child: Text(text.toUpperCase(), style: style),
      ),
    );
  }
}

/// How a [LogLine] ends.
enum LogStatus { none, ok, err }

/// One `small` mono line where an action happens: `> save state 2 ... ok`.
class LogLine extends StatelessWidget {
  const LogLine(this.text, {super.key, this.status = LogStatus.none});

  final String text;
  final LogStatus status;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Text.rich(
      TextSpan(
        style: t.small.copyWith(color: t.mutedText),
        children: [
          TextSpan(text: '> $text'),
          if (status != LogStatus.none) ...[
            const TextSpan(text: ' ... '),
            TextSpan(
              text: status.name,
              style: TextStyle(
                color: status == LogStatus.ok ? t.ok : t.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The `FILE / SESSION / CORE` meta table: black key column, panel values.
class KeyValueStrip extends StatelessWidget {
  const KeyValueStrip({super.key, required this.entries, this.keyWidth});

  final List<(String, String)> entries;

  /// Null fits the longest key.
  final double? keyWidth;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.panel,
        border: Border.all(color: t.ink, width: BrutalTokens.border),
      ),
      child: Table(
        columnWidths: {
          0: keyWidth == null
              ? const IntrinsicColumnWidth()
              : FixedColumnWidth(keyWidth!),
          1: const FlexColumnWidth(),
        },
        border: TableBorder(
          horizontalInside: BorderSide(
            color: t.ink,
            width: BrutalTokens.borderThin,
          ),
        ),
        children: [
          for (final (k, v) in entries)
            TableRow(
              children: [
                Container(
                  color: t.headerBar,
                  padding: const EdgeInsets.symmetric(
                    horizontal: BrutalTokens.s2,
                    vertical: BrutalTokens.s1,
                  ),
                  child: Text(
                    k.toUpperCase(),
                    style: t.label.copyWith(color: t.onHeaderBar),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BrutalTokens.s2,
                    vertical: BrutalTokens.s1,
                  ),
                  child: Text(
                    v,
                    style: t.row,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The empty screen: an Archivo Black headline, a mono explanation and one
/// primary button (`NO ROMS FOUND.` / `> add a folder to start`).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.headline,
    required this.message,
    this.action,
    this.onAction,
    this.icon,
    this.autofocus = false,
  });

  final String headline;
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final IconData? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final compact = t.density == BrutalDensity.handheld;
    return Padding(
      padding: const EdgeInsets.all(BrutalTokens.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            headline.toUpperCase(),
            style: compact ? t.displaySmall : t.display,
          ),
          const SizedBox(height: BrutalTokens.s2),
          Text('> $message', style: t.body.copyWith(color: t.mutedText)),
          if (action != null) ...[
            const SizedBox(height: BrutalTokens.s4),
            BrutalButton(
              label: '[${action!.toUpperCase()}]',
              icon: icon,
              variant: BrutalButtonVariant.primary,
              onPressed: onAction,
              autofocus: autofocus,
            ),
          ],
        ],
      ),
    );
  }
}
