// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Shaders: each system's default shader and resolution.
// Spec: docs/specs/shaders.md (App), docs/specs/brutalist-ui.md (4.6)
import 'package:material_ui/material_ui.dart';

import '../session/cheat_codes.dart' show systemLabel;
import '../session/session_screen.dart' show coreLibraries, desktopOnlySystems;
import '../shell/cfg_page.dart';
import '../shell/handheld.dart';
import '../ui/brutal/brutal.dart';
import 'shader_catalog.dart';
import 'shader_sheet.dart';
import 'shader_store.dart';

class ShaderSettingsPage extends StatefulWidget {
  const ShaderSettingsPage({super.key, required this.store});

  final ShaderStore store;

  @override
  State<ShaderSettingsPage> createState() => _ShaderSettingsPageState();
}

class _ShaderSettingsPageState extends State<ShaderSettingsPage> {
  Future<void> _open(String system) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ShaderSheet(store: widget.store, system: system),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final handheld = Handheld.of(context);
    return CfgPage(
      title: 'Shaders',
      path: const ['settings', 'video.cfg', 'shaders'],
      hints: const [
        ([HintButton.a], 'Open'),
        ([HintButton.b], 'Back'),
      ],
      sections: [
        CfgTable(
          header: 'SHADERS.CFG',
          rows: [
            for (final (i, system)
                in coreLibraries.keys
                    .where(
                      (s) =>
                          desktopResolution || !desktopOnlySystems.contains(s),
                    )
                    .indexed)
              CfgRow(
                autofocus: i == 0,
                label: systemLabel(system),
                value: [
                  shaderName(
                    widget.store.systemDefault(system),
                    desktop: widget.store.desktop,
                  ),
                  if (widget.store.systemUpscale(system) > 1 && !handheld)
                    '${widget.store.systemUpscale(system)}x',
                  if (widget.store.systemWidescreen(system)) '16:9',
                ].join(' · '),
                onOpen: () => _open(system),
              ),
          ],
        ),
      ],
    );
  }
}
