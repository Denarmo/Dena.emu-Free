// SPDX-License-Identifier: GPL-3.0-or-later
// Touch screen for systems with one (DS): touches on the lower screen become
// the libretro pointer. Spec: docs/specs/ds.md (Screen and input)
import 'package:material_ui/material_ui.dart';

/// Maps a position in a game picture of [size] to libretro pointer
/// coordinates, or null when it is outside [touchArea] (a fraction of the
/// picture, e.g. the bottom half for stacked DS screens).
(int, int)? pointerFor(Offset pos, Size size, Rect touchArea) {
  final fx = pos.dx / size.width, fy = pos.dy / size.height;
  // Inclusive of the right and bottom edges, unlike Rect.contains.
  if (fx < touchArea.left || fx > touchArea.right) return null;
  if (fy < touchArea.top || fy > touchArea.bottom) return null;
  int scale(double f) => ((f.clamp(0.0, 1.0) * 2 - 1) * 0x7fff).round();
  return (scale(fx), scale(fy));
}

/// Wraps the game picture and reports pointer touches inside [touchArea].
class PointerArea extends StatefulWidget {
  const PointerArea({
    super.key,
    required this.child,
    required this.onPointer,
    this.touchArea = const Rect.fromLTRB(0, 0.5, 1, 1),
  });

  final Widget child;

  /// (x, y, pressed) in libretro pointer units.
  final void Function(int x, int y, bool pressed) onPointer;
  final Rect touchArea;

  @override
  State<PointerArea> createState() => _PointerAreaState();
}

class _PointerAreaState extends State<PointerArea> {
  int? _active;
  (int, int) _last = (0, 0);

  void _move(PointerEvent e, Size size, {required bool start}) {
    if (!start && e.pointer != _active) return;
    final p = pointerFor(e.localPosition, size, widget.touchArea);
    if (p == null) {
      if (!start) _end(e);
      return;
    }
    _active = e.pointer;
    _last = p;
    widget.onPointer(p.$1, p.$2, true);
  }

  void _end(PointerEvent e) {
    if (e.pointer != _active) return;
    _active = null;
    widget.onPointer(_last.$1, _last.$2, false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _move(e, box.biggest, start: true),
        onPointerMove: (e) => _move(e, box.biggest, start: false),
        onPointerUp: _end,
        onPointerCancel: _end,
        child: widget.child,
      ),
    );
  }
}
