// SPDX-License-Identifier: GPL-3.0-or-later
// The settings page layout: a path bar over CfgTable sections on grid paper.
// Spec: docs/specs/brutalist-ui.md (4.6)
import 'package:material_ui/material_ui.dart';

import '../ui/brutal/brutal.dart';
import 'handheld.dart';

/// Lays out settings [sections] (usually [CfgTable]s) under a [PathBar]
/// showing [path] (`settings > video.cfg > shaders`; none when empty, as on
/// the settings tab, whose header bar shows it). From [twoColumnsAt]
/// logical pixels wide the sections flow into two columns (desktop).
class CfgSections extends StatelessWidget {
  const CfgSections({
    super.key,
    required this.path,
    required this.sections,
    this.twoColumnsAt = 840,
  });

  final List<String> path;
  final List<Widget> sections;
  final double twoColumnsAt;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    // Room for the hard shadow on the right and below.
    final pad = EdgeInsets.fromLTRB(
      BrutalTokens.s3,
      BrutalTokens.s2,
      BrutalTokens.s3 + t.shadowOffsetLarge.dx,
      BrutalTokens.s6,
    );
    const gap = SizedBox(height: BrutalTokens.s4);
    return LayoutBuilder(
      builder: (context, box) {
        final two = box.maxWidth >= twoColumnsAt && sections.length > 1;
        Widget column(Iterable<Widget> items) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, s) in items.indexed) ...[if (i > 0) gap, s],
          ],
        );
        return ListView(
          padding: pad,
          children: [
            if (path.isNotEmpty) ...[
              PathBar(segments: path),
              const SizedBox(height: BrutalTokens.s3),
            ],
            if (!two)
              column(sections)
            else
              // Reading order stays top to bottom, left column first, so
              // the D-pad walks one column and then the next.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: column([
                      for (var i = 0; i < sections.length; i += 2) sections[i],
                    ]),
                  ),
                  const SizedBox(width: BrutalTokens.s4 + 6),
                  Expanded(
                    child: column([
                      for (var i = 1; i < sections.length; i += 2) sections[i],
                    ]),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// A settings sub-page: app bar, grid paper, a [CfgSections] body and, on
/// button devices, the hint bar.
class CfgPage extends StatelessWidget {
  const CfgPage({
    super.key,
    required this.title,
    required this.path,
    required this.sections,
    this.hints = const [
      ([HintButton.a], 'Select'),
      ([HintButton.b], 'Back'),
    ],
  });

  final String title;
  final List<String> path;
  final List<Widget> sections;
  final List<ButtonHint> hints;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: BrutalGridPaper(
      child: SafeArea(
        top: false,
        child: CfgSections(path: path, sections: sections),
      ),
    ),
    bottomNavigationBar: usesButtons(context) ? HintBar(hints: hints) : null,
  );
}

/// Gives the first focusable control inside [child] the focus once it is
/// built, unless something on the page already has it. For kit controls
/// without an `autofocus` of their own (CfgSegment).
class AutofocusFirst extends StatefulWidget {
  const AutofocusFirst({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<AutofocusFirst> createState() => _AutofocusFirstState();
}

class _AutofocusFirstState extends State<AutofocusFirst> {
  final _node = FocusNode(
    debugLabel: 'AutofocusFirst',
    skipTraversal: true,
    canRequestFocus: false,
  );

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The same rule as `autofocus`: only when the scope has no focus yet.
      if (FocusScope.of(context).focusedChild != null) return;
      _node.traversalDescendants.firstOrNull?.requestFocus();
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _node, child: widget.child);
}
