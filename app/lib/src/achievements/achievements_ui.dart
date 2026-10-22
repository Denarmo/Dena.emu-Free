// SPDX-License-Identifier: GPL-3.0-or-later
// RetroAchievements screens: settings, the game page list, the session list
// and the unlock toasts. Spec: docs/specs/achievements.md
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../library/database.dart';
import 'achievements_overlay.dart';
import 'retro_achievements.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Settings tab row: who is signed in, opening [RetroAchievementsPage].
class RetroAchievementsTile extends StatelessWidget {
  const RetroAchievementsTile({super.key, required this.ra});

  final RetroAchievements ra;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ra,
      builder: (context, _) {
        final a = ra.account;
        return CfgRow(
          label: 'RetroAchievements',
          value: a == null
              ? '[SIGN IN]'
              : (ra.hardcore ? '[HARDCORE]' : '[ON]'),
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RetroAchievementsPage(ra: ra),
            ),
          ),
        );
      },
    );
  }
}

/// Sign in or out, and the hardcore switch.
class RetroAchievementsPage extends StatefulWidget {
  const RetroAchievementsPage({super.key, required this.ra});

  final RetroAchievements ra;

  @override
  State<RetroAchievementsPage> createState() => _RetroAchievementsPageState();
}

class _RetroAchievementsPageState extends State<RetroAchievementsPage> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

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
    final err = await widget.ra.signIn(_user.text, _password.text);
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
    return Scaffold(
      appBar: AppBar(title: const Text('RETROACHIEVEMENTS')),
      body: BrutalGridPaper(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: widget.ra,
            builder: (context, _) {
              final a = widget.ra.account;
              return ListView(
                padding: const EdgeInsets.all(BrutalTokens.s3),
                children: [
                  if (a == null)
                    CfgTable(
                      header: 'ACCOUNT.CFG',
                      rows: [
                        const _Note(
                          'Use your retroachievements.org account. Dena.emu '
                          'keeps a sign-in token, not your password.',
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
                        _Actions(
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
                        Padding(
                          padding: const EdgeInsets.all(BrutalTokens.s3),
                          child: Row(
                            children: [
                              _Avatar(url: a.avatar),
                              const SizedBox(width: BrutalTokens.s3),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      a.name,
                                      style: t.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${a.score} hardcore points · '
                                      '${a.softcoreScore} softcore',
                                      style: t.small.copyWith(
                                        color: t.mutedText,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        _ValueRow('Status', '[ONLINE]', color: t.ok),
                        _Actions(
                          buttons: [
                            BrutalButton(
                              label: '[SIGN OUT]',
                              icon: DenaIcons.exit,
                              autofocus: true,
                              onPressed: widget.ra.signOut,
                            ),
                          ],
                        ),
                      ],
                    ),
                  const SizedBox(height: BrutalTokens.s4),
                  CfgTable(
                    header: 'PLAY.CFG',
                    rows: [
                      CfgRow(
                        label: 'Hardcore mode',
                        control: CfgToggle(
                          value: widget.ra.hardcore,
                          onChanged: (v) => widget.ra.hardcore = v,
                          semanticLabel: 'Hardcore mode',
                        ),
                      ),
                      const _Note(
                        'Earn hardcore points. Loading save states, rewind '
                        'and cheats are off, and games start from the '
                        'battery save.',
                      ),
                    ],
                  ),
                  if (RaOverlayScope.maybeOf(context) case final overlay?) ...[
                    const SizedBox(height: BrutalTokens.s4),
                    RaOverlaySettingsTable(settings: overlay),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final u = url;
    final fallback = Icon(DenaIcons.person, color: t.ink);
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: t.muted,
        border: Border.all(color: t.ink, width: BrutalTokens.borderThin),
      ),
      clipBehavior: Clip.hardEdge,
      child: u == null
          ? fallback
          : Image.network(
              u,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

/// An achievement badge; the locked art (or a lock) until unlocked.
class RaBadge extends StatelessWidget {
  const RaBadge({super.key, required this.achievement, this.size = 48});

  final RaAchievement achievement;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = achievement.unlocked
        ? achievement.badge
        : achievement.badgeLocked;
    final fallback = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        achievement.unlocked ? DenaIcons.trophy : DenaIcons.lock,
        color: scheme.onSurfaceVariant,
      ),
    );
    return ClipRect(
      child: url == null
          ? fallback
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class RaAchievementTile extends StatelessWidget {
  const RaAchievementTile({super.key, required this.achievement});

  final RaAchievement achievement;

  @override
  Widget build(BuildContext context) {
    final a = achievement;
    final scheme = Theme.of(context).colorScheme;
    final state = switch (a.unlock) {
      RaUnlock.hardcore => 'Unlocked in hardcore',
      RaUnlock.softcore => 'Unlocked',
      RaUnlock.locked => a.progress.isNotEmpty ? a.progress : null,
    };
    return ListTile(
      // Focusable for D-pad scrolling; nothing to open.
      onTap: () {},
      leading: RaBadge(achievement: a),
      title: Text(a.title),
      subtitle: Text(
        [a.description, ?state].join('\n'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: state != null,
      trailing: Text(
        '${a.points}',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: a.unlocked ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Unlocked first, in list order otherwise.
List<RaAchievement> _sorted(List<RaAchievement> list) => [
  ...list.where((a) => a.unlocked),
  ...list.where((a) => !a.unlocked),
];

/// The game page's list (opened from the game sheet).
class GameAchievementsPage extends StatefulWidget {
  const GameAchievementsPage({super.key, required this.ra, required this.game});

  final RetroAchievements ra;
  final Game game;

  @override
  State<GameAchievementsPage> createState() => _GameAchievementsPageState();
}

class _GameAchievementsPageState extends State<GameAchievementsPage> {
  late Future<RaGameInfo> _info = _fetch();

  Future<RaGameInfo> _fetch() =>
      widget.ra.fetchGame(widget.game.path, widget.game.system);

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.game.title.toUpperCase().replaceAll(' ', '_')),
      ),
      body: BrutalGridPaper(
        child: SafeArea(
          child: FutureBuilder<RaGameInfo>(
            future: _info,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(
                  child: LogLine('fetching achievements ...'),
                );
              }
              final err = snap.error;
              if (err != null) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(BrutalTokens.s6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          err is RaFetchError ? err.message : '$err',
                          textAlign: TextAlign.center,
                          style: t.body,
                        ),
                        if (err is! RaFetchError || !err.unknown) ...[
                          const SizedBox(height: BrutalTokens.s3),
                          BrutalButton(
                            autofocus: true,
                            variant: BrutalButtonVariant.primary,
                            onPressed: widget.ra.account == null
                                ? () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          RetroAchievementsPage(ra: widget.ra),
                                    ),
                                  )
                                : () => setState(() => _info = _fetch()),
                            label: widget.ra.account == null
                                ? '[SIGN IN]'
                                : '[TRY AGAIN]',
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }
              final info = snap.requireData;
              if (info.achievements.isEmpty) {
                return const Center(
                  child: EmptyState(
                    headline: 'NO ACHIEVEMENTS.',
                    message: 'This game has no achievements yet',
                  ),
                );
              }
              final list = _sorted(info.achievements);
              final total = info.achievements.length;
              return ListView(
                padding: const EdgeInsets.all(BrutalTokens.s3),
                children: [
                  BrutalPanel(
                    header: 'ACHIEVEMENTS.LOG',
                    large: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(BrutalTokens.s3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${info.unlocked} of $total unlocked',
                                style: t.title,
                              ),
                              Text(
                                '${info.pointsUnlocked} of ${info.points} '
                                'points'
                                '${widget.ra.hardcoreFor(widget.game.system) ? ' · Hardcore on' : ''}',
                                style: t.small.copyWith(color: t.mutedText),
                              ),
                              const SizedBox(height: BrutalTokens.s2),
                              LayoutBuilder(
                                builder: (context, box) => ProgressCell(
                                  value: total == 0 ? 0 : info.unlocked / total,
                                  width: box.maxWidth - 48,
                                  height: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final (i, a) in list.indexed)
                          _AchievementRow(achievement: a, autofocus: i == 0),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One achievement on the game page: square badge, title, description and
/// state, points on the right. Focusable for D-pad scrolling; nothing opens.
class _AchievementRow extends StatelessWidget {
  const _AchievementRow({required this.achievement, this.autofocus = false});

  final RaAchievement achievement;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final a = achievement;
    final state = switch (a.unlock) {
      RaUnlock.hardcore => '[x] Unlocked in hardcore',
      RaUnlock.softcore => '[x] Unlocked',
      RaUnlock.locked => a.progress.isNotEmpty ? '[ ] ${a.progress}' : null,
    };
    return BrutalPressable(
      onPressed: () {},
      autofocus: autofocus,
      semanticLabel: a.title,
      builder: (context, s) {
        final lit = s.highlighted;
        final fg = lit ? t.onFocus : t.ink;
        final dim = lit ? t.onFocus : t.mutedText;
        return Container(
          decoration: BoxDecoration(
            color: lit ? t.focus : t.panel,
            border: Border(
              top: BorderSide(
                color: lit ? const Color(0xFF000000) : t.ink,
                width: lit ? BrutalTokens.border : BrutalTokens.borderThin,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: BrutalTokens.s3,
            vertical: BrutalTokens.s2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RaSquareBadge(achievement: a),
              const SizedBox(width: BrutalTokens.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.title.toUpperCase(),
                      style: t.row.copyWith(color: fg),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      a.description,
                      style: t.small.copyWith(color: dim),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (state != null)
                      Text(
                        state,
                        style: t.small.copyWith(
                          color: lit
                              ? t.onFocus
                              : (a.unlocked ? t.ok : t.mutedText),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: BrutalTokens.s2),
              Text(
                '${a.points}',
                style: t.row.copyWith(color: a.unlocked || lit ? fg : dim),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A square badge with a hard border; the locked art (or a lock) until
/// unlocked.
class RaSquareBadge extends StatelessWidget {
  const RaSquareBadge({super.key, required this.achievement, this.size = 44});

  final double size;

  final RaAchievement achievement;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final a = achievement;
    final url = a.unlocked ? a.badge : a.badgeLocked;
    final fallback = Center(
      child: Icon(
        a.unlocked ? DenaIcons.trophy : DenaIcons.lock,
        size: BrutalTokens.iconSize,
        color: t.ink,
      ),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: t.muted,
        border: Border.all(
          color: const Color(0xFF000000),
          width: BrutalTokens.borderThin,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: url == null
          ? fallback
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

/// The running game's achievements (pause sheet): a progress header and a
/// table, unlocked first, with `[x]`, title, progress and points columns.
class SessionAchievementsSheet extends StatelessWidget {
  const SessionAchievementsSheet({super.key, required this.ra});

  final RetroAchievements ra;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final s = ra.session;
    final list = _sorted(ra.sessionAchievements());
    final unlocked = list.where((a) => a.unlocked).length;
    final subtitle = [
      s?.title ?? '',
      if (s?.hardcore ?? false) 'Hardcore',
    ].where((t) => t.isNotEmpty).join(' · ');
    return Padding(
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
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$unlocked of ${list.length} unlocked',
                      style: t.title,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: t.small.copyWith(color: t.mutedText),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: BrutalTokens.s2),
              ProgressCell(
                value: list.isEmpty ? 0 : unlocked / list.length,
                showPercent: true,
              ),
            ],
          ),
          const SizedBox(height: BrutalTokens.s3),
          if (list.isNotEmpty)
            Flexible(
              child: Padding(
                padding: EdgeInsets.only(
                  right: t.shadowOffsetLarge.dx,
                  bottom: t.shadowOffsetLarge.dy,
                ),
                child: BrutalTable(
                  columns: const [
                    BrutalColumn('[x]', width: 44),
                    BrutalColumn('Achievement', flex: 3),
                    BrutalColumn('Pts', width: 48, numeric: true),
                  ],
                  rowCount: list.length,
                  autofocusRow: 0,
                  // Rows only take focus to scroll; nothing to open.
                  onRowPressed: (_) {},
                  cellBuilder: (context, row, column, lit) {
                    final a = list[row];
                    return switch (column) {
                      0 => Text(a.unlocked ? '[x]' : '[ ]'),
                      1 => Text(
                        [
                          a.title,
                          if (!a.unlocked && a.progress.isNotEmpty) a.progress,
                        ].join('  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      _ => Text('${a.points}'),
                    };
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows [RetroAchievements.notices] one at a time at the top of the game
/// (or at [alignment], for [shown] each, desktop-sized when [large]).
class RaToastLayer extends StatefulWidget {
  const RaToastLayer({
    super.key,
    required this.notices,
    this.alignment = Alignment.topCenter,
    this.shown = const Duration(seconds: 4),
    this.large = false,
    this.onShow,
  });

  final Stream<RaNotice> notices;
  final Alignment alignment;
  final Duration shown;
  final bool large;

  /// Called as each toast appears (the desktop's unlock chime).
  final ValueChanged<RaNotice>? onShow;

  @override
  State<RaToastLayer> createState() => _RaToastLayerState();
}

class _RaToastLayerState extends State<RaToastLayer> {
  final _queue = <RaNotice>[];
  RaNotice? _showing;
  late final StreamSubscription<RaNotice> _sub = widget.notices.listen((n) {
    _queue.add(n);
    _next();
  });
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sub;
  }

  void _next() {
    if (_showing != null || _queue.isEmpty || !mounted) return;
    setState(() => _showing = _queue.removeAt(0));
    widget.onShow?.call(_showing!);
    _timer = Timer(widget.shown, () {
      if (!mounted) return;
      setState(() => _showing = null);
      _next();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = _showing;
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: widget.alignment,
          // Hard cut, no fade (brutalist-ui.md 2.4).
          child: AnimatedSwitcher(
            duration: Duration.zero,
            child: n == null
                ? const SizedBox.shrink()
                : Padding(
                    key: ObjectKey(n),
                    padding: EdgeInsets.all(
                      widget.large ? BrutalTokens.s6 : 12,
                    ),
                    child: RaToast(notice: n, large: widget.large),
                  ),
          ),
        ),
      ),
    );
  }
}

/// One toast: a black square sticker with yellow title and white mono text.
class RaToast extends StatelessWidget {
  const RaToast({super.key, required this.notice, this.large = false});

  final RaNotice notice;

  /// Desktop size: a bigger badge and wider box, for a monitor or a TV.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    const icon = BrutalTokens.iconSizeLarge;
    final (Widget leading, String title, String body) = switch (notice) {
      RaUnlockNotice(:final achievement, :final hardcore) => (
        RaSquareBadge(achievement: achievement, size: large ? 64 : 44),
        achievement.title,
        'Achievement unlocked · ${achievement.points} points'
            '${hardcore ? ' · Hardcore' : ''}',
      ),
      RaGameNotice(:final session) => (
        const Icon(DenaIcons.trophy, size: icon),
        session.title,
        session.total == 0
            ? 'No achievements yet'
            : '${session.unlocked} of ${session.total} achievements unlocked'
                  '${session.hardcore ? ' · Hardcore' : ''}',
      ),
      RaUnknownGameNotice() => (
        const Icon(DenaIcons.help, size: icon),
        'RetroAchievements',
        "This game file isn't recognised",
      ),
      RaMasteredNotice(:final title) => (
        const Icon(DenaIcons.premium, size: icon),
        title,
        'Every achievement unlocked!',
      ),
      RaOfflineNotice(:final offline) => (
        Icon(offline ? DenaIcons.cloudOff : DenaIcons.cloudDone, size: icon),
        'RetroAchievements',
        offline
            ? 'Offline: unlocks will be sent when the connection returns'
            : 'Back online: unlocks sent',
      ),
    };
    // The toast look: a black bar with white mono text on a hard shadow.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: large ? 520 : 420),
      child: Container(
        decoration: BoxDecoration(
          color: black,
          border: Border.all(color: white, width: BrutalTokens.borderThin),
          boxShadow: [
            BoxShadow(
              color: t.focus,
              offset: large ? t.shadowOffsetLarge : t.shadowOffset,
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(
          BrutalTokens.s2,
          BrutalTokens.s2,
          BrutalTokens.s4,
          BrutalTokens.s2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTheme(
              data: IconThemeData(color: t.focus),
              child: leading,
            ),
            const SizedBox(width: BrutalTokens.s3),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (large ? t.title : t.label).copyWith(color: t.focus),
                  ),
                  Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (large ? t.body : t.small).copyWith(color: white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
