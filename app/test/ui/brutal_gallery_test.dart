// Golden of the whole Brutalist kit, Paper and Ink, at every screen size
// and in touch and focus modes. Spec: docs/specs/brutalist-ui.md (3, 8)
import 'dart:io';

import 'package:dena_emu/src/app.dart' show denaTheme;
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:dena_emu/src/ui/dena_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/screen_matrix.dart';

const desktop = ScreenSize('1280x720', Size(1280, 720));

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await load(brutalMono, [
    for (final w in ['Medium', 'SemiBold', 'Bold'])
      'assets/fonts/ibm_plex_mono/IBMPlexMono-$w.ttf',
  ]);
  await load(brutalDisplay, [
    'assets/fonts/archivo_black/ArchivoBlack-Regular.ttf',
  ]);
  await load('DenaIcons', ['assets/fonts/dena_icons/DenaIcons.otf']);
}

class _Gallery extends StatelessWidget {
  const _Gallery();

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    Widget gap() => const SizedBox(width: 8, height: 8);
    return BrutalGridPaper(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            Text('DENA.EMU', style: t.display),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                BrutalButton(
                  label: 'Play',
                  icon: DenaIcons.play,
                  variant: BrutalButtonVariant.primary,
                  autofocus: true,
                  onPressed: () {},
                ),
                BrutalButton(label: 'Save', index: '1', onPressed: () {}),
                BrutalButton(
                  label: 'Dark',
                  variant: BrutalButtonVariant.dark,
                  onPressed: () {},
                ),
                const BrutalButton(label: 'Off', onPressed: null),
                HoldToConfirm(onConfirmed: () {}),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                CheckFilter(
                  label: 'all',
                  checked: true,
                  count: 12,
                  onPressed: () {},
                ),
                CheckFilter(
                  label: 'gba',
                  checked: false,
                  count: 4,
                  onPressed: () {},
                ),
                const Sticker('Paused'),
                const Sticker('Hack', small: true),
              ],
            ),
            BrutalTabBar(
              tabs: const [
                BrutalTabItem(label: 'Games', icon: DenaIcons.controller),
                BrutalTabItem(label: 'Carts', icon: DenaIcons.cart),
                BrutalTabItem(label: 'Settings', icon: DenaIcons.settings),
              ],
              selected: 0,
              onSelected: (_) {},
            ),
            const SizedBox(width: 300, child: CommandField(hint: 'search')),
            const PathBar(segments: ['sd', 'roms', 'gba']),
            SizedBox(
              width: 380,
              height: 4 * (t.rowHeight + 2) + 40,
              child: BrutalTable(
                columns: const [
                  BrutalColumn('', width: 44),
                  BrutalColumn('Title', flex: 3, sortable: true),
                  BrutalColumn('Sys', width: 50),
                  BrutalColumn('Done', width: 110),
                ],
                rowCount: 3,
                selectedRow: 1,
                sortColumn: 1,
                onSort: (_) {},
                onRowPressed: (_) {},
                cellBuilder: (context, row, col, lit) => switch (col) {
                  0 => const BoxThumb(),
                  1 => Text(['Aria Quest', 'Bolt Run', 'Cave Story'][row]),
                  2 => const Text('GBA'),
                  _ => ProgressCell(value: row / 3),
                },
              ),
            ),
            SizedBox(
              width: 340,
              child: CfgTable(
                header: 'video.cfg',
                rows: [
                  CfgRow(
                    label: 'Smooth',
                    control: CfgToggle(value: true, onChanged: (_) {}),
                  ),
                  CfgRow(
                    label: 'Scale',
                    control: CfgSegment<int>(
                      values: const [1, 2, 4],
                      selected: 2,
                      labelOf: (v) => '${v}X',
                      onChanged: (_) {},
                    ),
                  ),
                  CfgRow(
                    label: 'Volume',
                    control: BracketSlider(value: 0.5, onChanged: (_) {}),
                  ),
                  CfgRow(label: 'Shader', value: 'LCD', onOpen: () {}),
                ],
              ),
            ),
            const SizedBox(
              width: 300,
              child: KeyValueStrip(
                entries: [('File', 'bolt_run.gba'), ('Core', 'mGBA')],
              ),
            ),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LogLine('save state 2', status: LogStatus.ok),
                LogLine('load bios', status: LogStatus.err),
              ],
            ),
            const SizedBox(
              width: 320,
              child: BrutalPanel(
                header: 'empty',
                child: EmptyState(
                  headline: 'No roms found.',
                  message: 'add a folder to start',
                  action: 'Add folder',
                ),
              ),
            ),
            gap(),
            const SizedBox(
              width: 320,
              child: BrutalHintBar(
                hints: [
                  ([HintButton.a], 'OK'),
                  ([HintButton.b], 'Back'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  setUpAll(_loadFonts);

  for (final (name, tokens) in [
    ('paper', BrutalTokens.paper()),
    ('ink', BrutalTokens.ink()),
  ]) {
    testScreens('brutal gallery $name', (tester, screen, mode) async {
      final handheld =
          screen == handheld4x3 || screen == handheldSquare;
      await tester.pumpWidget(
        Handheld(
          enabled: handheld,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: denaTheme(tokens),
            home: const Scaffold(body: _Gallery()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile(goldenName('brutal_gallery_$name', screen, mode)),
      );
    }, sizes: const [...allScreenSizes, desktop]);
  }
}
