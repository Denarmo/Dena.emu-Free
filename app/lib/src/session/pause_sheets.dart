// SPDX-License-Identifier: GPL-3.0-or-later
// The pause menu's sub-sheets in the Brutalist kit: the sheet frame every
// in-game sheet opens in, CONTROLLERS and GAME.CFG.
// Spec: docs/specs/pause-menu.md, brutalist-ui.md (4.5)
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../shell/handheld.dart';
import '../turbo/turbo.dart';
import '../ui/brutal/brutal.dart';

/// Opens an in-game sheet titled [title] (`CHEATS.CFG`): at the bottom on
/// phones, a right-hand side panel on handhelds and desktops, appearing in
/// one frame. [dim] false keeps the game behind it undimmed (the shader
/// preview). On pad devices it ends in an `[A] OK [B] BACK` hint bar.
Future<T?> showSessionSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  bool dim = true,
}) {
  // Narrow windows get the bottom sheet whatever the device.
  final side = MediaQuery.sizeOf(context).width < 600
      ? BrutalSheetSide.bottom
      : BrutalSheet.sideFor(context);
  final handheld = BrutalTokens.of(context).density == BrutalDensity.handheld;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: dim ? BrutalTokens.scrim : Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) {
      final size = MediaQuery.sizeOf(context);
      final bottom = side == BrutalSheetSide.bottom;
      Widget content = builder(context);
      if (usesButtons(context)) {
        content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(child: content),
            const BrutalHintBar(
              hints: [
                ([HintButton.a], 'OK'),
                ([HintButton.b], 'Back'),
              ],
            ),
          ],
        );
      }
      final sheet = BrutalSheet(
        title: title,
        side: side,
        width: math.max(
          300,
          math.min(size.width * (handheld ? 0.5 : 0.42), 460),
        ),
        child: content,
      );
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Align(
          alignment: bottom ? Alignment.bottomCenter : Alignment.centerRight,
          child: bottom
              ? ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.height * 0.85),
                  child: sheet,
                )
              : SizedBox(height: double.infinity, child: sheet),
        ),
      );
    },
  );
}

/// The players and their devices as a table; a free port shows `---`.
class ControllersSheet extends StatelessWidget {
  const ControllersSheet({super.key, required this.players});

  /// Device name per port; empty for a free port.
  final List<String> players;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(BrutalTokens.s3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: BrutalTable(
              shrinkWrap: true,
              columns: const [
                BrutalColumn('PORT', width: 64),
                BrutalColumn('DEVICE'),
              ],
              rowCount: players.length,
              autofocusRow: 0,
              onRowPressed: (_) => Navigator.of(context).pop(),
              cellBuilder: (context, row, column, lit) {
                final name = players[row];
                final style = t.row.copyWith(
                  color: lit
                      ? t.onFocus
                      : (name.isEmpty && column == 1 ? t.mutedText : t.ink),
                );
                return Text(
                  column == 0 ? 'P${row + 1}' : (name.isEmpty ? '---' : name),
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),
          const SizedBox(height: BrutalTokens.s3),
          const LogLine('press a button on a controller to join'),
        ],
      ),
    );
  }
}

/// One pause action moved into GAME.CFG when the stack runs out of room.
typedef GameCfgEntry = ({String label, String? value});

/// GAME.CFG: the pause actions that did not fit the stack (handheld) and
/// this game's turbo setup. Pops with the index of the entry picked.
class GameCfgSheet extends StatefulWidget {
  const GameCfgSheet({
    super.key,
    this.entries = const [],
    this.turbo,
    this.onTurbo,
  });

  final List<GameCfgEntry> entries;

  /// This game's turbo setup (turbo.md); no TURBO.CFG when null.
  final TurboConfig? turbo;
  final ValueChanged<TurboConfig>? onTurbo;

  /// Whether the sheet has anything to show.
  static bool hasContent(List<GameCfgEntry> entries, TurboConfig? turbo) =>
      entries.isNotEmpty || turbo != null;

  @override
  State<GameCfgSheet> createState() => _GameCfgSheetState();
}

class _GameCfgSheetState extends State<GameCfgSheet> {
  late TurboConfig? turbo = widget.turbo;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3 + 6,
        BrutalTokens.s4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.entries.isNotEmpty)
            CfgTable(
              header: 'GAME.CFG',
              rows: [
                for (final (i, e) in widget.entries.indexed)
                  CfgRow(
                    label: e.label,
                    value: e.value,
                    autofocus: i == 0,
                    onOpen: () => Navigator.of(context).pop(i),
                  ),
              ],
            ),
          if (turbo case final c?) ...[
            if (widget.entries.isNotEmpty)
              const SizedBox(height: BrutalTokens.s4),
            BrutalPanel(
              header: 'TURBO.CFG',
              padding: const EdgeInsets.all(BrutalTokens.s3),
              child: TurboEditor(
                value: c,
                onChanged: (v) {
                  setState(() => turbo = v);
                  widget.onTurbo?.call(v);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
