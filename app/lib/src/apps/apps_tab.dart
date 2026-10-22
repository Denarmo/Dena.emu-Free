// SPDX-License-Identifier: GPL-3.0-or-later
// Apps tab: one table of apps, the built-in ones pinned on top, then the
// device's launchable apps.
// Spec: docs/specs/apps-tab.md, brutalist-ui.md (4.8)
import 'package:material_ui/material_ui.dart';

import 'builtin_apps.dart';
import 'device_apps.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

class AppsTab extends StatefulWidget {
  const AppsTab({super.key, this.apps, this.builtIns});

  /// Defaults to [DeviceApps.platform]; tests pass a fake.
  final DeviceApps? apps;

  /// Defaults to [builtInApps].
  final List<BuiltInApp>? builtIns;

  @override
  State<AppsTab> createState() => _AppsTabState();
}

/// One row of the apps table.
typedef _AppRow = ({
  String name,
  String package,
  Widget Function(double side) icon,
  VoidCallback open,
});

class _AppsTabState extends State<AppsTab> {
  late final DeviceApps? source = widget.apps ?? DeviceApps.platform;
  List<DeviceApp>? installed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = source;
    if (s == null) {
      setState(() => installed = const []);
      return;
    }
    try {
      final list = await s.list();
      if (mounted) setState(() => installed = list);
    } on Object {
      if (mounted) setState(() => installed = const []);
    }
  }

  Future<void> _launch(DeviceApp app) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await source?.launch(app.package);
    } on Object {
      messenger.showSnackBar(
        brutalToast('Could not open ${app.label}', kind: ToastKind.err),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final builtIns = widget.builtIns ?? builtInApps();
    final list = installed;
    final rows = <_AppRow>[
      for (final b in builtIns)
        (
          name: b.label,
          package: b.route,
          icon: (side) => AppIconTile(
            side: side,
            child: Icon(b.icon, size: BrutalTokens.iconSize, color: t.ink),
          ),
          open: () => pushBuiltInApp(context, b),
        ),
      for (final a in list ?? const <DeviceApp>[])
        (
          name: a.label,
          package: a.package,
          icon: (side) => AppIconTile(
            side: side,
            child: a.icon == null
                ? Icon(
                    DenaIcons.appTile,
                    size: BrutalTokens.iconSize,
                    color: t.ink,
                  )
                : Image.memory(
                    a.icon!,
                    // Decoded small and drawn at whole multiples: a pixel
                    // tile, not a smooth launcher icon.
                    cacheWidth: 18,
                    cacheHeight: 18,
                    width: side >= 40 ? 36 : 18,
                    height: side >= 40 ? 36 : 18,
                    filterQuality: FilterQuality.none,
                    gaplessPlayback: true,
                  ),
          ),
          open: () => _launch(a),
        ),
    ];
    final status = switch (list) {
      null => const LogLine('listing installed apps ...'),
      [] => const LogLine('no apps to show'),
      _ => LogLine(
        '${builtIns.length} built-in // ${list.length} installed',
        status: LogStatus.ok,
      ),
    };
    final pad = t.density == BrutalDensity.handheld
        ? BrutalTokens.s2
        : BrutalTokens.s3;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PathBar(segments: ['apps', 'all']),
            const SizedBox(height: BrutalTokens.s2),
            if (rows.isEmpty)
              const EmptyState(headline: 'No apps.', message: 'no apps to show')
            else
              Flexible(
                child: _AppTable(rows: rows, pinned: builtIns.length),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: BrutalTokens.s2),
              child: status,
            ),
          ],
        ),
      ),
    );
  }
}

class _AppTable extends StatelessWidget {
  const _AppTable({required this.rows, required this.pinned});

  final List<_AppRow> rows;

  /// How many leading rows are built-in apps.
  final int pinned;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final package = box.maxWidth >= 380;
        final side = (t.rowHeight - 6).clamp(22.0, 42.0);
        final columns = [
          const BrutalColumn('Icon', width: 54),
          const BrutalColumn('Name', flex: 3),
          if (package) const BrutalColumn('Package', flex: 3),
          const BrutalColumn('', width: 76),
        ];
        // The table sizes to its rows when they fit, else scrolls.
        final rowsHeight =
            rows.length * (t.rowHeight + BrutalTokens.borderThin) +
            28 +
            2 * BrutalTokens.border;
        return SizedBox(
          height: rowsHeight < box.maxHeight ? rowsHeight : box.maxHeight,
          child: BrutalTable(
            columns: columns,
            rowCount: rows.length,
            autofocusRow: 0,
            onRowPressed: (i) => rows[i].open(),
            cellBuilder: (context, row, col, lit) {
              final r = rows[row];
              final fg = lit ? t.onFocus : t.ink;
              final last = columns.length - 1;
              if (col == 0) return r.icon(side);
              if (col == 1) return Text(BrutalTokens.fileName(r.name));
              if (col == last) return _OpenKey(color: fg);
              return Text(
                row < pinned ? 'BUILT-IN' : r.package,
                style: t.small.copyWith(color: lit ? t.onFocus : t.mutedText),
              );
            },
          ),
        );
      },
    );
  }
}

/// `[OPEN]`: the row's action, drawn as a key. The whole row opens the app
/// (tap, or A on the focused row), so this is not a separate focus stop.
class _OpenKey extends StatelessWidget {
  const _OpenKey({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s1,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: BrutalTokens.borderThin),
      ),
      child: Text('[OPEN]', style: t.label.copyWith(color: color)),
    );
  }
}

/// An app icon in a square bordered tile of [side] px.
class AppIconTile extends StatelessWidget {
  const AppIconTile({super.key, required this.side, required this.child});

  final double side;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border.all(
          color: const Color(0xFF000000),
          width: BrutalTokens.borderThin,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: child,
    );
  }
}
