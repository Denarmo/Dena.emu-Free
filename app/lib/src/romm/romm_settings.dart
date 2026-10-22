// SPDX-License-Identifier: GPL-3.0-or-later
// Settings and library browser for a RomM server. Free tier.
// Spec: docs/specs/romm.md
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../library/importer.dart';
import '../library/library_scope.dart';
import 'romm_client.dart';
import 'romm_controller.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Provides the app's [RommController].
class RommScope extends InheritedNotifier<RommController> {
  const RommScope({
    super.key,
    required RommController romm,
    required super.child,
  }) : super(notifier: romm);

  static RommController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RommScope>()?.notifier;

  static RommController? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<RommScope>()?.notifier;
}

/// Feeds app lifecycle into [romm] (auto-sync on pause and resume).
class RommHost extends StatefulWidget {
  const RommHost({super.key, required this.romm, required this.child});

  final RommController romm;
  final Widget child;

  @override
  State<RommHost> createState() => _RommHostState();
}

class _RommHostState extends State<RommHost> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: widget.romm.appResumed,
      onPause: widget.romm.appPaused,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RommScope(romm: widget.romm, child: widget.child);
}

String rommStatus(RommController r) {
  if (!r.connected) return 'Use your own RomM server for games and saves. Free';
  if (r.syncing) return 'Syncing saves…';
  if (r.problem != null) return r.problem!;
  final last = r.lastSync;
  if (last == null) return '${r.username} on ${r.server}';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${r.username} on ${r.server}. Synced ${two(last.hour)}:${two(last.minute)}';
}

/// One word for the settings row and the STATUS cell.
String rommState(RommController r) {
  if (!r.connected) return 'OFF';
  if (r.syncing) return 'SYNCING';
  if (r.problem != null) return 'ERROR';
  return 'ONLINE';
}

/// The RomM row in Settings.
class RommSection extends StatelessWidget {
  const RommSection({super.key});

  @override
  Widget build(BuildContext context) {
    final r = RommScope.of(context);
    if (r == null) return const SizedBox.shrink();
    return CfgRow(
      label: 'RomM server',
      value: '[${rommState(r)}]',
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RommPage(romm: r)),
      ),
    );
  }
}

class RommPage extends StatefulWidget {
  const RommPage({super.key, required this.romm});

  final RommController romm;

  @override
  State<RommPage> createState() => _RommPageState();
}

class _RommPageState extends State<RommPage> {
  late final _server = TextEditingController(text: widget.romm.server ?? '');
  late final _user = TextEditingController(text: widget.romm.username ?? '');
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.romm.connect(
      _server.text,
      _user.text.trim(),
      _password.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) _password.clear();
  }

  Future<void> _syncNow(RommController r) async {
    final rep = await r.syncNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r.problem ??
              (rep.changedNothing
                  ? 'Everything is up to date'
                  : 'Sent ${rep.uploaded}, received ${rep.downloaded}'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ROMM SERVER')),
    body: BrutalGridPaper(
      child: SafeArea(
        child: ListenableBuilder(
          listenable: widget.romm,
          builder: (context, _) {
            final r = widget.romm;
            return ListView(
              padding: const EdgeInsets.all(BrutalTokens.s3),
              children: [r.connected ? _connected(context, r) : _form(context)],
            );
          },
        ),
      ),
    ),
  );

  Widget _form(BuildContext context) => CfgTable(
    header: 'ROMM.CFG',
    rows: [
      const _Note(
        'Connect to a RomM server you run yourself to download its games and '
        'keep saves and states in step across devices.',
      ),
      _Field(
        child: TextField(
          key: const Key('romm-server'),
          controller: _server,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'SERVER ADDRESS',
            hintText: 'http://192.168.1.10:8080',
          ),
        ),
      ),
      _Field(
        child: TextField(
          key: const Key('romm-user'),
          controller: _user,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'USERNAME'),
        ),
      ),
      _Field(
        child: TextField(
          key: const Key('romm-password'),
          controller: _password,
          obscureText: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'PASSWORD'),
          onSubmitted: (_) => _connect(),
        ),
      ),
      _Actions(
        log: _busy
            ? const LogLine('connecting')
            : _error == null
            ? null
            : LogLine(_error!, status: LogStatus.err),
        buttons: [
          BrutalButton(
            label: _busy ? '[CONNECTING…]' : '[CONNECT]',
            icon: DenaIcons.server,
            variant: BrutalButtonVariant.primary,
            onPressed: _busy ? null : _connect,
          ),
        ],
      ),
    ],
  );

  Widget _connected(BuildContext context, RommController r) {
    final t = BrutalTokens.of(context);
    final state = rommState(r);
    return CfgTable(
      header: 'ROMM.CFG',
      rows: [
        _ValueRow('User', r.username ?? ''),
        _ValueRow('Server', r.server ?? ''),
        _ValueRow(
          'Status',
          '[$state]',
          color: switch (state) {
            'ONLINE' => t.ok,
            'ERROR' => t.danger,
            _ => null,
          },
        ),
        CfgRow(
          label: 'Browse the server',
          value: 'DOWNLOAD',
          autofocus: true,
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => RommPlatformsPage(romm: r)),
          ),
        ),
        CfgRow(
          label: 'Sync automatically',
          control: CfgToggle(
            key: const Key('romm-auto'),
            value: r.autoSync,
            onChanged: r.setAutoSync,
            semanticLabel: 'Sync automatically',
          ),
        ),
        const _Note('After each game and when the app opens or closes.'),
        _Actions(
          log: LogLine(
            r.syncing ? 'syncing saves' : rommStatus(r),
            status: r.syncing
                ? LogStatus.none
                : r.problem != null
                ? LogStatus.err
                : r.lastSync != null
                ? LogStatus.ok
                : LogStatus.none,
          ),
          buttons: [
            BrutalButton(
              label: '[SYNC NOW]',
              icon: DenaIcons.sync,
              variant: BrutalButtonVariant.primary,
              onPressed: r.syncing ? null : () => _syncNow(r),
            ),
            BrutalButton(
              label: '[DISCONNECT]',
              icon: DenaIcons.exit,
              onPressed: r.disconnect,
            ),
          ],
        ),
      ],
    );
  }
}

class RommPlatformsPage extends StatefulWidget {
  const RommPlatformsPage({super.key, required this.romm});

  final RommController romm;

  @override
  State<RommPlatformsPage> createState() => _RommPlatformsPageState();
}

class _RommPlatformsPageState extends State<RommPlatformsPage> {
  late Future<List<RommPlatform>> _list = widget.romm.client.platforms();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ROMM LIBRARY')),
    body: BrutalGridPaper(
      child: SafeArea(
        child: FutureBuilder<List<RommPlatform>>(
          future: _list,
          builder: (context, snap) {
            if (snap.hasError) {
              return _ErrorRetry(
                message: '${snap.error}',
                onRetry: () =>
                    setState(() => _list = widget.romm.client.platforms()),
              );
            }
            final list = snap.data;
            if (list == null) return const _Loading('loading systems');
            final shown = list.where((p) => p.romCount > 0).toList();
            if (shown.isEmpty) {
              return const Center(
                child: EmptyState(
                  headline: 'NO GAMES.',
                  message: 'This server has no games yet',
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(BrutalTokens.s3),
              child: BrutalTable(
                columns: const [
                  BrutalColumn('SYSTEM', flex: 3),
                  BrutalColumn('GAMES', width: 80, numeric: true),
                ],
                rowCount: shown.length,
                autofocusRow: 0,
                cellBuilder: (context, i, c, lit) => Text(
                  c == 0 ? _fileStyle(shown[i].name) : '${shown[i].romCount}',
                ),
                onRowPressed: (i) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        RommRomsPage(romm: widget.romm, platform: shown[i]),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class RommRomsPage extends StatefulWidget {
  const RommRomsPage({super.key, required this.romm, required this.platform});

  final RommController romm;
  final RommPlatform platform;

  @override
  State<RommRomsPage> createState() => _RommRomsPageState();
}

class _RommRomsPageState extends State<RommRomsPage> {
  late Future<List<RommRom>> _list = _load();
  Set<String> _local = {};
  String _query = '';

  Future<List<RommRom>> _load() async {
    final db = LibraryScope.of(context).db;
    _local = {for (final g in await db.allGames()) g.sha1};
    return widget.romm.client.roms(platformId: widget.platform.id);
  }

  Future<void> _download(RommRom rom) async {
    final messenger = ScaffoldMessenger.of(context);
    String text;
    try {
      final db = LibraryScope.of(context).db;
      final out = await widget.romm.download(rom);
      text = switch (out) {
        Imported(:final title) => 'Added $title',
        Duplicate() => '${rom.name} is already in your library',
        Rejected(:final reason) => '${rom.name}: $reason',
      };
      if (out is Imported) {
        final g = await db.gameById(out.gameId);
        if (g != null) _local.add(g.sha1);
      }
    } on RommException catch (e) {
      text = 'Download failed: $e';
    }
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _cover(RommRom rom) => BoxThumb(
    child: rom.coverPath == null
        ? null
        : Image.network(
            widget.romm.client.asset(rom.coverPath!).toString(),
            headers: widget.romm.client.authHeader,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_fileStyle(widget.platform.name))),
    body: BrutalGridPaper(
      child: SafeArea(
        child: FutureBuilder<List<RommRom>>(
          future: _list,
          builder: (context, snap) {
            if (snap.hasError) {
              return _ErrorRetry(
                message: '${snap.error}',
                onRetry: () => setState(() => _list = _load()),
              );
            }
            final all = snap.data;
            if (all == null) return const _Loading('loading games');
            final q = _query.toLowerCase();
            final roms = q.isEmpty
                ? all
                : all.where((r) => r.name.toLowerCase().contains(q)).toList();
            final compact =
                BrutalTokens.of(context).density == BrutalDensity.phone &&
                MediaQuery.sizeOf(context).width < 480;
            return Padding(
              padding: const EdgeInsets.all(BrutalTokens.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    // Search acts as you type; Done on the on-screen
                    // keyboard just closes it.
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(DenaIcons.search),
                      hintText: 'SEARCH',
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: BrutalTokens.s3),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: widget.romm,
                      builder: (context, _) => BrutalTable(
                        columns: [
                          const BrutalColumn('', width: 46),
                          const BrutalColumn('TITLE', flex: 3),
                          if (!compact)
                            const BrutalColumn('SIZE', width: 86, numeric: true),
                          const BrutalColumn('GET', width: 86, numeric: true),
                        ],
                        rowCount: roms.length,
                        cellBuilder: (context, i, c, lit) {
                          final rom = roms[i];
                          final column = compact && c >= 2 ? c + 1 : c;
                          return switch (column) {
                            0 => _cover(rom),
                            1 => Text(_fileStyle(rom.name)),
                            2 => Text(_size(rom.size)),
                            _ => _state(rom, lit),
                          };
                        },
                        onRowPressed: (i) {
                          final rom = roms[i];
                          final busy = widget.romm.downloads.containsKey(
                            rom.id,
                          );
                          if (busy || widget.romm.has(rom, _local)) return;
                          _download(rom);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _state(RommRom rom, bool lit) {
    final t = BrutalTokens.of(context);
    if (widget.romm.downloads.containsKey(rom.id)) {
      final progress = widget.romm.downloads[rom.id];
      if (progress == null) return const Text('[....]');
      return ProgressCell(
        value: progress,
        width: 40,
        color: lit ? t.onFocus : t.ink,
      );
    }
    if (widget.romm.has(rom, _local)) {
      return const Text('[OK]', semanticsLabel: 'In your library');
    }
    return const Text('[GET]', semanticsLabel: 'Download');
  }
}

/// [name] as a table shows titles: upper case, spaces as underscores.
String _fileStyle(String name) => name.toUpperCase().replaceAll(' ', '_');

String _size(int bytes) {
  if (bytes <= 0) return '';
  const mb = 1024 * 1024;
  if (bytes < mb) return '${(bytes / 1024).ceil()} KB';
  if (bytes < 1024 * mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
}

class _Loading extends StatelessWidget {
  const _Loading(this.what);

  final String what;

  @override
  Widget build(BuildContext context) => Center(child: LogLine('$what ...'));
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(BrutalTokens.s6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LogLine(message, status: LogStatus.err),
          const SizedBox(height: BrutalTokens.s3),
          BrutalButton(
            label: '[TRY AGAIN]',
            icon: DenaIcons.sync,
            autofocus: true,
            onPressed: onRetry,
          ),
        ],
      ),
    ),
  );
}

/// A `KEY ........ value` row whose value is text, cut short to fit.
class _ValueRow extends StatelessWidget {
  const _ValueRow(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      constraints: BoxConstraints(minHeight: t.rowHeight),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: BrutalTokens.s3),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Text(label.toUpperCase(), style: t.label),
            const SizedBox(width: BrutalTokens.s2),
            Expanded(
              child: Text(
                '.' * 80,
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                style: t.small.copyWith(color: t.ink.withValues(alpha: 0.4)),
              ),
            ),
            const SizedBox(width: BrutalTokens.s2),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.62),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.row.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Explanation inside a [CfgTable], in `small` muted mono.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s3,
        vertical: BrutalTokens.s2,
      ),
      child: Text(text, style: t.small.copyWith(color: t.mutedText)),
    );
  }
}

/// A text field inside a [CfgTable].
class _Field extends StatelessWidget {
  const _Field({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: BrutalTokens.s3,
      vertical: BrutalTokens.s2,
    ),
    child: child,
  );
}

/// The action buttons at the foot of a [CfgTable], with an optional log line.
class _Actions extends StatelessWidget {
  const _Actions({required this.buttons, this.log});

  final List<Widget> buttons;
  final Widget? log;

  @override
  Widget build(BuildContext context) {
    // Pad devices draw a `<-` marker beside the focused button: leave room.
    final gap = BrutalTokens.of(context).padMarkers
        ? BrutalTokens.s8 + BrutalTokens.s1
        : BrutalTokens.s3;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        gap,
        BrutalTokens.s3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (log != null) ...[log!, const SizedBox(height: BrutalTokens.s3)],
          Wrap(
            spacing: gap,
            runSpacing: BrutalTokens.s3,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: buttons,
          ),
        ],
      ),
    );
  }
}
