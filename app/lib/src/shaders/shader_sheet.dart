// SPDX-License-Identifier: GPL-3.0-or-later
// Shader picker: Off and every bundled shader, saved per game or per system.
// Spec: docs/specs/shaders.md (App), shader-stacks.md (App)
import 'package:material_ui/material_ui.dart';

import '../session/cheat_codes.dart' show systemLabel;
import '../shell/handheld.dart';
import '../ui/brutal/brutal.dart';
import 'shader_catalog.dart';
import 'shader_store.dart';

/// Applies [id] to the running game ("" = Off); false when it failed to load.
typedef ApplyShader = Future<bool> Function(String id);

/// The rows' note for [s]: its description, with the pass count of a stack.
String shaderNote(ShaderInfo s) =>
    s.passes > 1 ? '${s.passes} passes · ${s.description}' : s.description;

class ShaderSheet extends StatefulWidget {
  const ShaderSheet({
    super.key,
    required this.store,
    required this.system,
    this.gameSha1,
    this.current,
    this.onApply,
    this.embedded = false,
  });

  final ShaderStore store;
  final String system;

  /// The paused game; null on Settings, where only the system default is set.
  final String? gameSha1;

  /// The shader showing now (it may differ from the saved one after a load
  /// failure); read from [store] when null.
  final String? current;

  /// Previews a pick behind the sheet; none on Settings.
  final ApplyShader? onApply;

  /// Shown inside an in-game sheet (showSessionSheet), which draws the
  /// title, height and hint bar; false draws its own (Settings).
  final bool embedded;

  @override
  State<ShaderSheet> createState() => _ShaderSheetState();
}

class _ShaderSheetState extends State<ShaderSheet> {
  late String selected =
      widget.current ??
      (widget.gameSha1 == null
          ? widget.store.systemDefault(widget.system)
          : widget.store.resolve(widget.system, widget.gameSha1!));

  /// Saving for this game only (true) or for every game of the system.
  late bool gameScope =
      widget.gameSha1 != null && widget.store.hasGameOverride(widget.gameSha1!);

  late int upscale = widget.gameSha1 == null
      ? widget.store.systemUpscale(widget.system)
      : widget.store.resolveUpscale(widget.system, widget.gameSha1!);
  late final int _upscaleAtOpen = upscale;

  late bool wide = widget.gameSha1 == null
      ? widget.store.systemWidescreen(widget.system)
      : widget.store.resolveWidescreen(widget.system, widget.gameSha1!);
  late final bool _wideAtOpen = wide;

  /// Saved like the resolution (desktop-resolution.md, Widescreen).
  void _pickWide(bool on) {
    setState(() => wide = on);
    final sha1 = widget.gameSha1;
    if (gameScope && sha1 != null) {
      widget.store.setGameWidescreen(sha1, on);
    } else {
      widget.store.setSystemWidescreen(widget.system, on);
      if (sha1 != null) widget.store.clearGameWidescreen(sha1);
    }
  }

  /// Saved with the same scope as the shader; the core reads it at start.
  void _pickUpscale(int factor) {
    setState(() => upscale = factor);
    final sha1 = widget.gameSha1;
    if (gameScope && sha1 != null) {
      widget.store.setGameUpscale(sha1, factor);
    } else {
      widget.store.setSystemUpscale(widget.system, factor);
      if (sha1 != null) widget.store.clearGameUpscale(sha1);
    }
  }

  Future<void> _pick(String id) async {
    setState(() => selected = id);
    final ok = await widget.onApply?.call(id) ?? true;
    if (!mounted) return;
    if (!ok) {
      // The session fell back to Off; the saved choice stays as it was.
      setState(() => selected = '');
      return;
    }
    final sha1 = widget.gameSha1;
    if (gameScope && sha1 != null) {
      widget.store.setGame(sha1, id);
    } else {
      widget.store.setSystem(widget.system, id);
      // So the game shows what was picked: drop its own choice.
      if (sha1 != null) widget.store.clearGame(sha1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final label = systemLabel(widget.system);
    final entries = shadersFor(widget.system, desktop: widget.store.desktop);
    final handheld = Handheld.of(context);
    final rows = [
      (id: '', name: 'Off', description: 'The plain picture', suggested: false),
      for (final e in entries)
        (
          id: e.shader.id,
          name: e.shader.name,
          description: shaderNote(e.shader),
          suggested: e.suggested,
        ),
    ];
    final selectedRow = rows.indexWhere((r) => r.id == selected);
    final sheet = Padding(
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3 + 6,
        BrutalTokens.s2,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.embedded) ...[
            Text(switch ((widget.gameSha1 == null, handheld)) {
              (true, false) => '$label shader and resolution',
              (true, true) => '$label shader',
              (false, false) => 'Shader and resolution',
              (false, true) => 'Shader',
            }, style: t.title),
            const SizedBox(height: BrutalTokens.s2),
          ],
          if (widget.gameSha1 != null) ...[
            Row(
              children: [
                SizedBox(width: 72, child: Text('Save', style: t.label)),
                Expanded(
                  child: CfgSegment<bool>(
                    values: const [true, false],
                    selected: gameScope,
                    labelOf: (v) => v ? 'This game' : 'All $label games',
                    onChanged: (v) => setState(() => gameScope = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: BrutalTokens.s2),
          ],
          // The launcher draws at native resolution: handheld GPUs have
          // no headroom for more (handheld-session.md).
          if (!handheld) ...[
            _ResolutionRow(
              system: widget.system,
              label: label,
              desktop: widget.store.desktop,
              factor: upscale,
              restartNote: widget.gameSha1 != null && upscale != _upscaleAtOpen,
              onChanged: _pickUpscale,
            ),
            const SizedBox(height: BrutalTokens.s2),
          ],
          if (hasWidescreen(widget.system, desktop: widget.store.desktop)) ...[
            _WidescreenRow(
              on: wide,
              restartNote: widget.gameSha1 != null && wide != _wideAtOpen,
              onChanged: _pickWide,
            ),
            const SizedBox(height: BrutalTokens.s2),
          ],
          Flexible(
            child: Padding(
              padding: EdgeInsets.only(
                right: t.shadowOffsetLarge.dx,
                bottom: t.shadowOffsetLarge.dy,
              ),
              child: BrutalTable(
                columns: const [
                  BrutalColumn('[x]', width: 44),
                  BrutalColumn('Shader', flex: 2),
                  BrutalColumn('Note', flex: 3),
                ],
                rowCount: rows.length,
                selectedRow: selectedRow < 0 ? null : selectedRow,
                // The current shader takes focus first, so A on open keeps it.
                autofocusRow: selectedRow < 0 ? 0 : selectedRow,
                onRowPressed: (i) => _pick(rows[i].id),
                cellBuilder: (context, row, column, lit) {
                  final r = rows[row];
                  return switch (column) {
                    0 => Text(r.id == selected ? '[x]' : '[ ]'),
                    1 => Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    _ => Row(
                      children: [
                        if (r.suggested) ...[
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Sticker(
                                'Suggested',
                                small: true,
                                angle: 0,
                              ),
                            ),
                          ),
                          const SizedBox(width: BrutalTokens.s1),
                        ],
                        Expanded(
                          flex: 2,
                          child: Text(
                            r.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: lit ? null : TextStyle(color: t.mutedText),
                          ),
                        ),
                      ],
                    ),
                  };
                },
              ),
            ),
          ),
        ],
      ),
    );
    if (widget.embedded) return sheet;
    // The game stays visible above the sheet for the preview.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.62;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight.clamp(260, 640)),
      child: SafeArea(
        child: !usesButtons(context)
            ? sheet
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: sheet),
                  const BrutalHintBar(
                    hints: [
                      ([HintButton.a], 'Select'),
                      ([HintButton.b], 'Back'),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Internal resolution (shaders.md, Upscale; desktop-resolution.md): Auto
/// (the core's default) and the factors the system's core can do (2x-4x on
/// phones, up to 8x on the desktop), with a note saying what the limit is,
/// that the system is upscaled by the filter, that it renders true
/// resolution on a GPU renderer with a requirement (DS), or that a factor
/// above 4x needs a strong GPU.
class _ResolutionRow extends StatelessWidget {
  const _ResolutionRow({
    required this.system,
    required this.label,
    required this.desktop,
    required this.factor,
    required this.restartNote,
    required this.onChanged,
  });

  final String system;
  final String label;
  final bool desktop;
  final int factor;
  final bool restartNote;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final factors = upscaleFactors(system, desktop: desktop);
    final max = maxUpscale(system, desktop: desktop);
    final requirement = upscaleRequirement(system, desktop: desktop);
    final String? note = max < 2
        ? '$label draws at its native resolution only'
        : restartNote
        ? 'The new resolution applies the next time the game starts'
        : max < 4
        ? '$label renders at 2x at most'
        : filterUpscale(system, desktop: desktop)
        ? 'Smoothed with the xBRZ pixel-art filter'
        : requirement != null
        ? 'True 3D resolution, needs $requirement'
        : factor > 4
        ? 'Above 4x needs a strong graphics card'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(width: 72, child: Text('Res', style: t.label)),
            Expanded(
              child: CfgSegment<int>(
                values: [0, ...factors],
                selected: factor,
                labelOf: (f) => f == 0 ? 'Auto' : '${f}x',
                onChanged: onChanged,
              ),
            ),
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: BrutalTokens.s1),
            child: Text(
              note,
              style: t.small.copyWith(color: t.mutedText),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// `WIDE [OFF] [16:9]` (desktop-resolution.md, Widescreen): the core's
/// widescreen hack, read when the game loads.
class _WidescreenRow extends StatelessWidget {
  const _WidescreenRow({
    required this.on,
    required this.restartNote,
    required this.onChanged,
  });

  final bool on;
  final bool restartNote;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(width: 72, child: Text('Wide', style: t.label)),
            Expanded(
              child: CfgSegment<bool>(
                values: const [false, true],
                selected: on,
                labelOf: (v) => v ? '16:9' : 'Off',
                onChanged: onChanged,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: BrutalTokens.s1),
          child: Text(
            restartNote
                ? 'Widescreen applies the next time the game starts'
                : 'Widescreen hack: 3D games only, 2D art stretches',
            style: t.small.copyWith(color: t.mutedText),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
