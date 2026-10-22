// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > LIBRARY.CFG > ROM manager, and Settings > ACCOUNTS.CFG >
// ScreenScraper.
// Spec: docs/specs/rom-manager.md (5)
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../library/library_scope.dart';
import '../shell/network.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';
import 'convert.dart';
import 'dat_store.dart';
import 'models.dart';
import 'rom_manager.dart';
import 'rom_page.dart';
import 'screenscraper.dart';

/// The LIBRARY.CFG row that opens the ROM manager.
class RomManagerTile extends StatelessWidget {
  const RomManagerTile({super.key, required this.manager});

  final RomManager manager;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: manager.dats,
    builder: (context, _) {
      final n = manager.dats.installed.length;
      return CfgRow(
        label: 'ROM manager',
        value: n == 0 ? 'no DATs' : '$n DAT${n == 1 ? '' : 's'}',
        onOpen: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const RomManagerPage())),
      );
    },
  );
}

/// DATs, batch check, scraping sources and conversion jobs.
class RomManagerPage extends StatefulWidget {
  const RomManagerPage({super.key});

  @override
  State<RomManagerPage> createState() => _RomManagerPageState();
}

class _RomManagerPageState extends State<RomManagerPage> {
  String? _datError, _ovgdbError;
  bool _ovgdbBusy = false;

  Future<void> _get(RomManager m, String system, {bool latest = false}) async {
    setState(() => _datError = null);
    try {
      await m.dats.download(system, latest: latest);
    } on Object catch (e) {
      if (mounted) setState(() => _datError = '$e');
    }
  }

  Future<void> _import(RomManager m) async {
    final files = LibraryScope.of(context).files;
    setState(() => _datError = null);
    try {
      final picked = await files.pickFiles();
      for (final path in picked) {
        await m.dats.importFile(File(path));
      }
    } on Object catch (e) {
      if (mounted) setState(() => _datError = '$e');
    } finally {
      await files.clearCache();
    }
  }

  Future<void> _getOpenVgdb(RomManager m) async {
    setState(() {
      _ovgdbBusy = true;
      _ovgdbError = null;
    });
    try {
      await m.openVgdb!.download();
    } on Object catch (e) {
      _ovgdbError = '$e';
    }
    if (mounted) setState(() => _ovgdbBusy = false);
  }

  @override
  Widget build(BuildContext context) {
    final m = RomManagerScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('ROM MANAGER')),
      body: BrutalGridPaper(
        child: SafeArea(
          child: m == null
              ? const SizedBox.shrink()
              : ListenableBuilder(
                  listenable: m.changes,
                  builder: (context, _) => ListView(
                    padding: const EdgeInsets.all(BrutalTokens.s3),
                    children: [
                      _dats(context, m),
                      const SizedBox(height: BrutalTokens.s4),
                      _scrape(context, m),
                      if (m.conversions case final q?) ...[
                        const SizedBox(height: BrutalTokens.s4),
                        _convert(context, m, q),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _dats(BuildContext context, RomManager m) {
    final online = NetworkScope.of(context);
    final v = m.verifier;
    final db = LibraryScope.of(context).db;
    return CfgTable(
      header: 'DATS.CFG',
      rows: [
        const RomNote(
          'No-Intro (cartridges) and Redump (discs) lists of good dumps, '
          'from libretro-database (CC-BY-SA-4.0). GET downloads one, '
          'UPDATE takes the newest. IMPORT DAT reads your own from '
          'datomatic.no-intro.org or redump.org.',
        ),
        for (final (i, system) in datSystems.keys.indexed)
          _DatRow(
            system: system,
            info: m.dats.info(system),
            busy: m.dats.busy(system),
            online: online,
            autofocus: i == 0,
            onGet: (latest) => _get(m, system, latest: latest),
          ),
        RomActions(
          log: v.running
              ? LogLine('checking ${v.done}/${v.total}')
              : _datError == null
              ? null
              : LogLine(_datError!, status: LogStatus.err),
          buttons: [
            BrutalButton(
              label: '[IMPORT DAT]',
              icon: DenaIcons.fileAdd,
              onPressed: () => _import(m),
            ),
            if (v.running)
              BrutalButton(
                label: '[STOP]',
                icon: DenaIcons.close,
                onPressed: v.cancel,
              )
            else
              BrutalButton(
                label: '[VERIFY ALL]',
                icon: DenaIcons.check,
                variant: BrutalButtonVariant.primary,
                onPressed: () async =>
                    v.verifyAll(await db.allGames(), download: online),
              ),
          ],
        ),
      ],
    );
  }

  Widget _scrape(BuildContext context, RomManager m) {
    final online = NetworkScope.of(context);
    final s = m.scraper;
    final ovgdb = m.openVgdb;
    final a = m.account;
    final db = LibraryScope.of(context).db;
    return CfgTable(
      header: 'SCRAPE.CFG',
      rows: [
        if (ovgdb != null)
          RomValueRow(
            'OpenVGDB',
            _ovgdbBusy
                ? '[DOWNLOADING…]'
                : ovgdb.installed
                ? '[INSTALLED]'
                : '[NOT INSTALLED]',
          ),
        if (a != null)
          RomValueRow(
            'ScreenScraper',
            !a.available
                ? 'no key in this build'
                : a.signedIn
                ? '[${a.user}]'
                : 'sign in under ACCOUNTS',
          ),
        for (final k in ScrapeKind.values)
          CfgRow(
            label: 'Fetch ${k.label.toLowerCase()}',
            control: CfgToggle(
              value: m.settings.kinds.contains(k),
              onChanged: (on) => m.settings.setKind(k, on),
              semanticLabel: 'Fetch ${k.label.toLowerCase()}',
            ),
          ),
        const RomNote(
          'Scraping runs when you ask: SCRAPE on a game, or SCRAPE MISSING '
          'here. ScreenScraper is used first when signed in, OpenVGDB fills '
          'the gaps. Files stay in the app data folder under scrape/.',
        ),
        RomActions(
          log: s.running
              ? LogLine('scraping ${s.done}/${s.total}')
              : s.problem != null
              ? LogLine(s.problem!, status: LogStatus.err)
              : _ovgdbError == null
              ? null
              : LogLine(_ovgdbError!, status: LogStatus.err),
          buttons: [
            if (ovgdb != null)
              BrutalButton(
                label: ovgdb.installed ? '[UPDATE OPENVGDB]' : '[GET OPENVGDB]',
                icon: DenaIcons.download,
                onPressed: _ovgdbBusy || !online ? null : () => _getOpenVgdb(m),
              ),
            if (s.running)
              BrutalButton(
                label: '[STOP]',
                icon: DenaIcons.close,
                onPressed: s.cancel,
              )
            else
              BrutalButton(
                label: '[SCRAPE MISSING]',
                icon: DenaIcons.image,
                variant: BrutalButtonVariant.primary,
                onPressed: online
                    ? () async => s.scrapeAll(await db.allGames())
                    : null,
              ),
          ],
        ),
      ],
    );
  }

  Widget _convert(BuildContext context, RomManager m, ConversionQueue q) {
    final db = LibraryScope.of(context).db;
    final tools = q.tools;
    return CfgTable(
      header: 'CONVERT.CFG',
      rows: [
        RomValueRow('chdman', tools.find('chdman') ?? 'not found'),
        RomValueRow('DolphinTool', tools.find('dolphintool') ?? 'not found'),
        const RomNote(
          'CHD for disc images (.cue, .gdi, PSP .iso), RVZ for GameCube and '
          'Wii. Put chdman (from MAME) or DolphinTool (from Dolphin) in the '
          'tools folder next to Dena.emu or on PATH. Nothing converts on its '
          'own.',
        ),
        CfgRow(
          label: 'Keep originals',
          control: CfgToggle(
            value: m.settings.keepOriginals,
            onChanged: (v) => m.settings.keepOriginals = v,
            semanticLabel: 'Keep originals',
          ),
        ),
        for (final j in q.jobs) ...[
          RomValueRow(j.game.fileName, jobLabel(j)),
          if (j.state == JobState.running || j.state == JobState.verifying)
            RomProgress(j.progress),
        ],
        RomActions(
          buttons: [
            BrutalButton(
              label: '[CONVERT ALL]',
              icon: DenaIcons.disc,
              variant: BrutalButtonVariant.primary,
              onPressed: () async {
                final games = await db.allGames();
                var queued = 0;
                for (final g in games) {
                  if (q.problemFor(g) == null && q.enqueue(g) != null) {
                    queued++;
                  }
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    brutalToast(
                      queued == 0
                          ? 'nothing to convert'
                          : 'queued $queued conversion(s)',
                      kind: queued == 0 ? ToastKind.info : ToastKind.ok,
                    ),
                  );
                }
              },
            ),
            if (q.jobs.any(
              (j) => const {
                JobState.done,
                JobState.failed,
                JobState.cancelled,
              }.contains(j.state),
            ))
              BrutalButton(
                label: '[CLEAR FINISHED]',
                icon: DenaIcons.trash,
                onPressed: q.clearFinished,
              ),
          ],
        ),
      ],
    );
  }
}

/// One system's DAT: name and version, or GET.
class _DatRow extends StatelessWidget {
  const _DatRow({
    required this.system,
    required this.info,
    required this.busy,
    required this.online,
    required this.autofocus,
    required this.onGet,
  });

  final String system;
  final DatInfo? info;
  final bool busy, online, autofocus;
  final ValueChanged<bool> onGet;

  @override
  Widget build(BuildContext context) {
    final i = info;
    final label = system.toUpperCase();
    if (busy) return RomValueRow(label, '[DOWNLOADING…]');
    return CfgRow(
      label: label,
      autofocus: autofocus,
      value: i == null
          ? (online ? 'get' : 'none')
          : '${i.version ?? i.name} · ${i.games} games${online ? ' · update' : ''}',
      // GET takes the pinned DAT; UPDATE the newest one.
      onOpen: online ? () => onGet(i != null) : null,
    );
  }
}

/// The ACCOUNTS.CFG row for ScreenScraper.
class ScreenScraperTile extends StatelessWidget {
  const ScreenScraperTile({super.key, required this.account});

  final ScreenScraperAccount account;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) => CfgRow(
      label: 'ScreenScraper',
      value: !account.available
          ? 'no key in this build'
          : account.signedIn
          ? '[ON]'
          : '[SIGN IN]',
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ScreenScraperPage(account: account),
        ),
      ),
    ),
  );
}

/// Sign in to ScreenScraper with the user's own account.
class ScreenScraperPage extends StatefulWidget {
  const ScreenScraperPage({super.key, required this.account});

  final ScreenScraperAccount account;

  @override
  State<ScreenScraperPage> createState() => _ScreenScraperPageState();
}

class _ScreenScraperPageState extends State<ScreenScraperPage> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.account.signedIn) unawaited(widget.account.refresh());
  }

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_user.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your username and password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.account.signIn(_user.text.trim(), _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final a = widget.account;
    return Scaffold(
      appBar: AppBar(title: const Text('SCREENSCRAPER')),
      body: BrutalGridPaper(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: a,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(BrutalTokens.s3),
              children: [
                if (!a.available)
                  const CfgTable(
                    header: 'ACCOUNT.CFG',
                    rows: [
                      RomValueRow('Status', '[NO KEY]'),
                      RomNote(
                        'This build has no ScreenScraper developer key, so '
                        'scraping uses OpenVGDB only. Builds made with '
                        'DENA_SCREENSCRAPER_DEVID and '
                        'DENA_SCREENSCRAPER_DEVPASSWORD can sign in.',
                      ),
                    ],
                  )
                else if (!a.signedIn)
                  CfgTable(
                    header: 'ACCOUNT.CFG',
                    rows: [
                      const RomNote(
                        'Use your own screenscraper.fr account; its quota is '
                        "yours. ScreenScraper has no sign-in tokens, so the "
                        'password is kept in the app data folder and sent '
                        'only to screenscraper.fr.',
                      ),
                      AutofillGroup(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: BrutalTokens.s3,
                            vertical: BrutalTokens.s2,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: _user,
                                enabled: !_busy,
                                autofocus: true,
                                autofillHints: const [AutofillHints.username],
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'USERNAME',
                                ),
                              ),
                              const SizedBox(height: BrutalTokens.s3),
                              TextField(
                                controller: _password,
                                enabled: !_busy,
                                obscureText: true,
                                autofillHints: const [AutofillHints.password],
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _signIn(),
                                decoration: const InputDecoration(
                                  labelText: 'PASSWORD',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      RomActions(
                        log: _busy
                            ? const LogLine('signing in')
                            : _error == null
                            ? null
                            : LogLine(_error!, status: LogStatus.err),
                        buttons: [
                          BrutalButton(
                            label: _busy ? '[SIGNING IN…]' : '[SIGN IN]',
                            icon: DenaIcons.enter,
                            variant: BrutalButtonVariant.primary,
                            onPressed: _busy ? null : _signIn,
                          ),
                        ],
                      ),
                    ],
                  )
                else
                  CfgTable(
                    header: 'ACCOUNT.CFG',
                    rows: [
                      RomValueRow('User', a.user ?? '--'),
                      RomValueRow('Status', '[ONLINE]', color: t.ok),
                      if (a.info case final i?) ...[
                        RomValueRow('Level', '${i.level}'),
                        RomValueRow(
                          'Today',
                          '${i.requestsToday} / ${i.maxRequestsPerDay}',
                        ),
                      ],
                      RomActions(
                        buttons: [
                          BrutalButton(
                            label: '[SIGN OUT]',
                            icon: DenaIcons.exit,
                            autofocus: true,
                            onPressed: a.signOut,
                          ),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
