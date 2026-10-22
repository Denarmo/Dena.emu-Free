// SPDX-License-Identifier: GPL-3.0-or-later
// The ROM page of one game: its DAT check, scraped files and conversion.
// Spec: docs/specs/rom-manager.md (5)
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../library/database.dart';
import '../net/browser.dart' show openInBrowser;
import '../shell/network.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';
import 'convert.dart';
import 'models.dart';
import 'rom_manager.dart';
import 'scraper.dart';

/// Opens [game]'s ROM page.
Future<void> openRomPage(BuildContext context, Game game) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => RomPage(game: game)));

/// `VERIFIED // Game Name (USA)`: one line for INSPECT and the game menu.
String verifySummary(VerifyResult? r) =>
    r == null ? 'UNCHECKED' : r.status.label;

/// Status, match and actions for one game. Every control takes focus in
/// order, so the page works with a D-pad alone.
class RomPage extends StatefulWidget {
  const RomPage({super.key, required this.game});

  final Game game;

  @override
  State<RomPage> createState() => _RomPageState();
}

class _RomPageState extends State<RomPage> {
  bool _verifying = false, _scraping = false;
  String? _verifyError, _scrapeMessage;
  bool _scrapeFailed = false;

  Future<void> _verify(RomManager m) async {
    setState(() {
      _verifying = true;
      _verifyError = null;
    });
    try {
      await m.verifier.verify(widget.game, download: true);
    } on Object catch (e) {
      _verifyError = 'check failed: $e';
    }
    if (mounted) setState(() => _verifying = false);
  }

  Future<void> _scrape(RomManager m) async {
    setState(() {
      _scraping = true;
      _scrapeMessage = null;
    });
    final out = await m.scraper.scrape(widget.game);
    if (!mounted) return;
    setState(() {
      _scraping = false;
      final (message, failed) = switch (out) {
        ScrapeDone(:final files) => (
          'got ${files.files.length} file(s)',
          false,
        ),
        ScrapeMiss() => ('no source knows this game', true),
        ScrapeFailed(:final message) => (message, true),
      };
      _scrapeMessage = message;
      _scrapeFailed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = RomManagerScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('ROM CHECK')),
      body: BrutalGridPaper(
        child: SafeArea(
          child: m == null
              ? const SizedBox.shrink()
              : ListenableBuilder(
                  listenable: m.changes,
                  builder: (context, _) => ListView(
                    padding: const EdgeInsets.all(BrutalTokens.s3),
                    children: [
                      _datTable(context, m),
                      const SizedBox(height: BrutalTokens.s4),
                      _scrapeTable(context, m),
                      if (m.conversions case final q?) ...[
                        const SizedBox(height: BrutalTokens.s4),
                        _convertTable(context, q),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _datTable(BuildContext context, RomManager m) {
    final t = BrutalTokens.of(context);
    final g = widget.game;
    final r = m.resultFor(g);
    final stale = r != null && m.verifier.isStale(g);
    final online = NetworkScope.of(context);
    final color = switch (r?.status) {
      VerifyStatus.verified => t.ok,
      VerifyStatus.badDump || VerifyStatus.modified => t.danger,
      _ => null,
    };
    return CfgTable(
      header: 'DAT.CHK',
      rows: [
        RomValueRow(
          'Status',
          '[${verifySummary(r)}${stale ? ' · OLD DAT' : ''}]',
          color: color,
        ),
        RomValueRow('Match', r?.name ?? '--'),
        RomValueRow('Source', r?.source ?? '--'),
        RomValueRow('File', g.fileName),
        RomValueRow('SHA-1', g.sha1),
        RomValueRow('CRC32', g.crc32.toUpperCase()),
        if (r?.status == VerifyStatus.unverifiable)
          const RomNote(
            'DATs list the raw disc tracks, so a compressed file can only be '
            'checked before it is converted.',
          ),
        if (r?.status == VerifyStatus.modified)
          const RomNote(
            'The file name names a game in the DAT but the data differs: a '
            'hack, a patched or trimmed copy, or a bad dump.',
          ),
        RomActions(
          log: _verifying
              ? const LogLine('checking')
              : _verifyError == null
              ? null
              : LogLine(_verifyError!, status: LogStatus.err),
          buttons: [
            BrutalButton(
              label: _verifying ? '[CHECKING…]' : '[VERIFY]',
              icon: DenaIcons.check,
              variant: BrutalButtonVariant.primary,
              autofocus: true,
              // Without a DAT the check downloads one first.
              onPressed:
                  _verifying || (!online && m.dats.info(g.system) == null)
                  ? null
                  : () => _verify(m),
            ),
          ],
        ),
      ],
    );
  }

  Widget _scrapeTable(BuildContext context, RomManager m) {
    final g = widget.game;
    final files = m.scraper.filesFor(g);
    final info = files.info;
    final online = NetworkScope.of(context);
    final desktop = m.conversions != null;
    final have = [
      for (final k in ScrapeKind.values)
        if (files.files.containsKey(k)) k.label,
    ];
    return CfgTable(
      header: 'SCRAPE.CFG',
      rows: [
        RomValueRow('Files', have.isEmpty ? '--' : have.join(' ')),
        if (info != null) ...[
          if (info.title case final title?) RomValueRow('Title', title),
          if (info.year case final year?) RomValueRow('Year', '$year'),
          if (info.developer case final dev?) RomValueRow('Developer', dev),
          if (info.publisher case final pub?) RomValueRow('Publisher', pub),
          if (info.genre case final genre?) RomValueRow('Genre', genre),
          RomValueRow('From', info.source.toUpperCase()),
          if (info.description case final d?) RomNote(d),
        ],
        // A PC opens a manual or video snap in the system's viewer.
        if (desktop)
          for (final k in const [ScrapeKind.manual, ScrapeKind.video])
            if (files.files[k] case final File f)
              CfgRow(
                label: k == ScrapeKind.manual ? 'Manual' : 'Video snap',
                value: 'open',
                onOpen: () => openInBrowser(Uri.file(f.path)),
              ),
        RomActions(
          log: _scraping
              ? const LogLine('scraping')
              : _scrapeMessage == null
              ? null
              : LogLine(
                  _scrapeMessage!,
                  status: _scrapeFailed ? LogStatus.err : LogStatus.ok,
                ),
          buttons: [
            BrutalButton(
              label: _scraping ? '[SCRAPING…]' : '[SCRAPE]',
              icon: DenaIcons.download,
              onPressed: _scraping || !online ? null : () => _scrape(m),
            ),
          ],
        ),
      ],
    );
  }

  Widget _convertTable(BuildContext context, ConversionQueue q) {
    final g = widget.game;
    final plan = planFor(g);
    final job = q.jobs.where((j) => j.game.id == g.id).lastOrNull;
    final active =
        job != null &&
        const {
          JobState.queued,
          JobState.running,
          JobState.verifying,
        }.contains(job.state);
    final problem = active ? null : q.problemFor(g);
    return CfgTable(
      header: 'CONVERT.CFG',
      rows: [
        RomValueRow(
          'Target',
          plan == null ? 'nothing to convert' : plan.format.name.toUpperCase(),
        ),
        if (job != null) RomValueRow('Job', jobLabel(job)),
        if (job != null && active) RomProgress(job.progress),
        if (plan != null)
          const RomNote(
            'Written next to the original and checked before the library '
            'uses it. The original is deleted afterwards unless KEEP '
            'ORIGINALS is on in Settings > ROM manager.',
          ),
        RomActions(
          log: problem == null || plan == null
              ? null
              : LogLine(problem.toLowerCase(), status: LogStatus.err),
          buttons: [
            if (active)
              BrutalButton(
                label: '[CANCEL]',
                icon: DenaIcons.close,
                onPressed: () => q.cancel(job),
              )
            else
              BrutalButton(
                label: '[CONVERT]',
                icon: DenaIcons.disc,
                onPressed: problem == null ? () => q.enqueue(g) : null,
              ),
          ],
        ),
      ],
    );
  }
}

/// `RUNNING 45%`, `DONE saved 312 MB`, `FAILED verification failed`.
String jobLabel(ConversionJob j) {
  final state = switch (j.state) {
    JobState.queued => 'QUEUED',
    JobState.running => 'CONVERTING ${(j.progress * 100).round()}%',
    JobState.verifying => 'VERIFYING ${(j.progress * 100).round()}%',
    JobState.done => 'DONE',
    JobState.failed => 'FAILED',
    JobState.cancelled => 'CANCELLED',
  };
  return j.message == null || j.state == JobState.running
      ? state
      : '$state · ${j.message}';
}

/// `KEY ........ value`: a read-only [CfgTable] row.
class RomValueRow extends StatelessWidget {
  const RomValueRow(this.label, this.value, {super.key, this.color});

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

/// A muted explanation inside a [CfgTable].
class RomNote extends StatelessWidget {
  const RomNote(this.text, {super.key});

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

/// A hard progress bar: ink fill on the panel, square ends.
class RomProgress extends StatelessWidget {
  const RomProgress(this.value, {super.key});

  final double value;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s3,
        vertical: BrutalTokens.s2,
      ),
      child: Container(
        height: 14,
        decoration: BoxDecoration(
          color: t.panel,
          border: Border.all(color: t.ink, width: BrutalTokens.borderThin),
        ),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0, 1),
          heightFactor: 1,
          child: ColoredBox(color: t.ink),
        ),
      ),
    );
  }
}

/// The action buttons at the foot of a [CfgTable], with an optional log line.
class RomActions extends StatelessWidget {
  const RomActions({super.key, required this.buttons, this.log});

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
