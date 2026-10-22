// SPDX-License-Identifier: GPL-3.0-or-later
// Skins tab: built-in and imported skins per system, import and delete.
// Spec: docs/specs/skins.md (8b), docs/specs/brutalist-ui.md (4.6, list chrome)
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../library/import_rules.dart';
import '../library/library_scope.dart';
import '../session/cheat_codes.dart' show systemLabel;
import '../shell/handheld.dart' show arrowsMoveFocus;
import 'deltaskin.dart';
import 'skin_store.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

final _systems = [
  for (final s in GameSystem.values)
    if (s.playable && !s.desktopOnly) s.id,
];

class SkinsTab extends StatefulWidget {
  const SkinsTab({super.key});

  @override
  State<SkinsTab> createState() => _SkinsTabState();
}

class _SkinsTabState extends State<SkinsTab> {
  List<InstalledSkin> installed = [];
  Map<String, String?> active = {};
  bool loaded = false;

  SkinStore? get store => LibraryScope.of(context).skins;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!loaded) _reload();
  }

  Future<void> _reload() async {
    final s = store;
    if (s == null) return;
    final list = await s.list();
    final ids = await s.activeIds();
    final known = {for (final i in list) i.skin.identifier};
    final act = <String, String?>{
      for (final sys in _systems)
        sys: known.contains(ids[sys]) ? ids[sys] : null,
    };
    if (!mounted) return;
    setState(() {
      installed = list;
      active = act;
      loaded = true;
    });
  }

  Future<void> _import() async {
    final scope = LibraryScope.of(context);
    final s = store;
    if (s == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final paths = await scope.files.pickFiles();
    var added = 0;
    String? error;
    for (final path in paths) {
      if (!path.toLowerCase().endsWith('.deltaskin')) {
        error = 'Only .deltaskin files can be imported here';
        continue;
      }
      try {
        final skin = await s.install(File(path));
        added++;
        // A newly imported skin becomes active for its systems.
        for (final sys in skinSystems(skin.skin.gameType)) {
          await s.setActive(sys, skin.skin.identifier);
        }
      } on SkinFormatException catch (e) {
        error = e.message;
      }
    }
    await scope.files.clearCache();
    await _reload();
    if (added > 0 || error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error ?? (added == 1 ? 'Skin imported' : '$added skins imported'),
          ),
        ),
      );
    }
  }

  Future<void> _choose(String system, String? id) async {
    await store?.setActive(system, id);
    await _reload();
  }

  Future<void> _delete(InstalledSkin s) async {
    await store?.delete(s);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s2,
        BrutalTokens.s3 + t.shadowOffsetLarge.dx,
        BrutalTokens.s6,
      ),
      children: [
        const PathBar(segments: ['settings', 'input.cfg', 'skins']),
        const SizedBox(height: BrutalTokens.s3),
        Row(
          children: [
            const Expanded(
              child: LogLine(
                '> touch controls appear when you play without a controller.',
              ),
            ),
            const SizedBox(width: BrutalTokens.s2),
            BrutalButton(
              icon: DenaIcons.document,
              label: 'Import skin',
              onPressed: store == null ? null : _import,
            ),
          ],
        ),
        for (final sys in _systems) ...[
          const SizedBox(height: BrutalTokens.s4),
          Shortcuts(
            shortcuts: arrowsMoveFocus,
            child: CfgTable(
              header: '${sys.toUpperCase()}.SKIN  ${systemLabel(sys)}',
              rows: [
                _SkinRow(
                  name: 'Built-in',
                  active: active[sys] == null,
                  // Built-in can only be turned on; another skin turns it off.
                  onToggle: (on) => on ? _choose(sys, null) : null,
                ),
                for (final s in installed.where(
                  (s) => skinSystems(s.skin.gameType).contains(sys),
                ))
                  _SkinRow(
                    name: s.skin.name,
                    note: s.bundled ? 'console style' : null,
                    active: active[sys] == s.skin.identifier,
                    // Off goes back to Built-in.
                    onToggle: (on) =>
                        _choose(sys, on ? s.skin.identifier : null),
                    onDelete: s.bundled ? null : () => _delete(s),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// One skin of a system: its name, `[ON]` when it is the active one, and a
/// hold-to-delete key for imported skins.
class _SkinRow extends StatelessWidget {
  const _SkinRow({
    required this.name,
    required this.active,
    required this.onToggle,
    this.note,
    this.onDelete,
  });

  final String name;
  final String? note;
  final bool active;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      constraints: BoxConstraints(minHeight: t.rowHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s3,
        vertical: BrutalTokens.s1,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: t.label.copyWith(color: t.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (note != null)
                  Text(note!, style: t.small.copyWith(color: t.mutedText)),
              ],
            ),
          ),
          if (onDelete case final delete?) ...[
            HoldToConfirm(label: 'HOLD DEL', onConfirmed: delete),
            const SizedBox(width: BrutalTokens.s2 + 4),
          ],
          CfgToggle(value: active, semanticLabel: name, onChanged: onToggle),
        ],
      ),
    );
  }
}
