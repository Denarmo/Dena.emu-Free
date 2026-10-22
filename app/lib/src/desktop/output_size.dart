// SPDX-License-Identifier: GPL-3.0-or-later
// Reports the game picture's size in physical pixels to the desktop host, so
// shader stacks draw at the screen's own resolution (4K on a 4K screen).
// Spec: docs/specs/shader-stacks.md (Platform)
import 'package:material_ui/material_ui.dart';

import '../shell/host_library.dart';

/// Takes the picture's width and height in physical pixels.
typedef OutputSizeSink = void Function(int width, int height);

/// Lays out [child] as given and sends its size (times the device pixel
/// ratio) to [sink] whenever it changes.
class DesktopOutputSize extends StatefulWidget {
  const DesktopOutputSize({super.key, required this.child, this.sink});

  final Widget child;

  /// [setDesktopOutputSize] when null.
  final OutputSizeSink? sink;

  @override
  State<DesktopOutputSize> createState() => _DesktopOutputSizeState();
}

class _DesktopOutputSizeState extends State<DesktopOutputSize> {
  (int, int)? _sent;

  void _report(Size logical, double ratio) {
    if (!logical.isFinite) return;
    final size = (
      (logical.width * ratio).round(),
      (logical.height * ratio).round(),
    );
    if (size == _sent || size.$1 <= 0 || size.$2 <= 0) return;
    _sent = size;
    (widget.sink ?? setDesktopOutputSize)(size.$1, size.$2);
  }

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _report(constraints.biggest, ratio);
        return widget.child;
      },
    );
  }
}
