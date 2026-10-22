// SPDX-License-Identifier: GPL-3.0-or-later
// Save-state slots: files and the slot picker sheet.
// Spec: docs/specs/save-states.md
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../ui/brutal/brutal.dart';

/// One save-state slot of a game: the quick slot or slots 1–9.
class StateSlot {
  StateSlot({
    required this.id,
    required this.label,
    required this.statePath,
    required this.pngPath,
    this.savedAt,
  });

  /// `quick` or `slot<N>`.
  final String id;
  final String label;
  final String statePath;
  final String pngPath;

  /// When the slot was written, or null when it is empty.
  final DateTime? savedAt;

  bool get isEmpty => savedAt == null;
}

/// The quick slot and slots 1–9 under `states/<sha1>/` of [dataDir].
List<StateSlot> listSlots(String dataDir, String sha1) {
  final dir = p.posix.join(dataDir, 'states', sha1);
  StateSlot slot(String id, String label) {
    final state = p.posix.join(dir, '$id.state');
    final f = File(state);
    return StateSlot(
      id: id,
      label: label,
      statePath: state,
      pngPath: p.posix.join(dir, '$id.png'),
      savedAt: f.existsSync() ? f.lastModifiedSync() : null,
    );
  }

  return [
    slot('quick', 'Quick'),
    for (var n = 1; n <= 9; n++) slot('slot$n', 'Slot $n'),
  ];
}

/// A slot's age in the file-listing style: `NEW` under a minute, then `-2M`,
/// `-5H`, `-3D`; `---` when empty.
String formatSlotAge(StateSlot slot, DateTime now) {
  final saved = slot.savedAt;
  if (saved == null) return '---';
  final d = now.difference(saved);
  if (d.inMinutes < 1) return 'NEW';
  if (d.inHours < 1) return '-${d.inMinutes}M';
  if (d.inDays < 1) return '-${d.inHours}H';
  return '-${d.inDays}D';
}

/// The slot's short name: `QUICK`, `SLOT1`.
String slotName(StateSlot slot) => slot.id.toUpperCase();

enum SlotMode { save, load }

/// Grid of slot cards; pops with the picked [StateSlot]. In [SlotMode.load]
/// empty slots are disabled. [initial] (a slot id) takes focus first when it
/// can be picked. B (Back) closes without picking.
class SlotSheet extends StatelessWidget {
  const SlotSheet({
    super.key,
    required this.mode,
    required this.slots,
    required this.aspectRatio,
    this.initial,
    this.clock = DateTime.now,
  });

  final SlotMode mode;
  final List<StateSlot> slots;

  /// The game's picture aspect ratio, for the thumbnails.
  final double aspectRatio;
  final String? initial;
  final DateTime Function() clock;

  /// The sheet's header: `SAVE.STATE` or `LOAD.STATE`.
  static String titleFor(SlotMode mode) =>
      mode == SlotMode.save ? 'SAVE.STATE' : 'LOAD.STATE';

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final width = t.density == BrutalDensity.phone
        ? MediaQuery.sizeOf(context).width
        : 460.0;
    final columns = width >= 900 ? 5 : (width >= 560 ? 4 : 2);
    bool enabled(StateSlot s) => mode == SlotMode.save || !s.isEmpty;
    final wanted = slots.indexWhere((s) => s.id == initial && enabled(s));
    final first = wanted >= 0 ? wanted : slots.indexWhere(enabled);
    final now = clock();
    return GridView.count(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3 + 4,
        BrutalTokens.s3 + 4,
      ),
      crossAxisCount: columns,
      mainAxisSpacing: BrutalTokens.s3,
      crossAxisSpacing: BrutalTokens.s3,
      childAspectRatio: aspectRatio * 0.8,
      children: [
        for (final (i, s) in slots.indexed)
          SlotCard(
            slot: s,
            now: now,
            autofocus: i == first,
            onPressed: enabled(s) ? () => Navigator.of(context).pop(s) : null,
          ),
      ],
    );
  }
}

/// A slot card: the thumbnail (hatched when empty) over a `SLOT2 -2M` label.
/// The label turns yellow when [selected] or focused; focus also draws a
/// blue outline.
class SlotCard extends StatelessWidget {
  const SlotCard({
    super.key,
    required this.slot,
    required this.now,
    required this.onPressed,
    this.selected = false,
    this.autofocus = false,
    this.focusNode,
  });

  final StateSlot slot;
  final DateTime now;
  final VoidCallback? onPressed;
  final bool selected;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPressable(
      onPressed: onPressed,
      autofocus: autofocus,
      focusNode: focusNode,
      selected: selected,
      semanticLabel: '${slot.label} ${formatSlotAge(slot, now)}',
      builder: (context, s) {
        final lit = selected || s.highlighted;
        final card = BrutalShadowBox(
          pressed: s.pressed,
          offset: t.shadowOffset,
          color: t.shadow,
          child: Container(
            decoration: BoxDecoration(
              color: t.panel,
              border: Border.all(color: t.ink, width: BrutalTokens.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: SlotThumb(slot: slot)),
                Container(height: BrutalTokens.borderThin, color: t.ink),
                Container(
                  color: lit && s.enabled ? t.focus : t.panel,
                  padding: const EdgeInsets.symmetric(
                    horizontal: BrutalTokens.s1 + 2,
                    vertical: 2,
                  ),
                  child: Text(
                    '${slotName(slot)} ${formatSlotAge(slot, now)}',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: t.label.copyWith(
                      color: !s.enabled
                          ? t.mutedText
                          : (lit ? t.onFocus : t.ink),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        if (!s.focused) return card;
        // Focus never relies on colour alone: a blue outline around it.
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(color: t.primary, width: BrutalTokens.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(BrutalTokens.border),
            child: card,
          ),
        );
      },
    );
  }
}

/// A slot's saved picture, or hatching when there is none.
class SlotThumb extends StatelessWidget {
  const SlotThumb({super.key, required this.slot});

  final StateSlot slot;

  @override
  Widget build(BuildContext context) {
    final png = File(slot.pngPath);
    if (!slot.isEmpty && png.existsSync()) {
      return Image.memory(
        png.readAsBytesSync(),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
        gaplessPlayback: true,
      );
    }
    final t = BrutalTokens.of(context);
    return CustomPaint(
      painter: HatchPainter(t.muted),
      child: const SizedBox.expand(),
    );
  }
}

/// Diagonal hatching for an empty slot.
class HatchPainter extends CustomPainter {
  const HatchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3;
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width; x += 10) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(HatchPainter old) => old.color != color;
}
