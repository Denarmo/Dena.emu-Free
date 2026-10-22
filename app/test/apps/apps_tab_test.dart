import 'package:dena_emu/src/apps/apps_tab.dart';
import 'package:dena_emu/src/apps/builtin_apps.dart';
import 'package:dena_emu/src/apps/device_apps.dart';
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/screen_matrix.dart';

import 'package:dena_emu/src/ui/dena_icons.dart';

class _FakeApps implements DeviceApps {
  final launched = <String>[];

  @override
  Future<List<DeviceApp>> list() async => const [
    DeviceApp(package: 'a.browser', label: 'Browser'),
    DeviceApp(package: 'a.camera', label: 'Camera'),
    DeviceApp(package: 'a.files', label: 'Files'),
  ];

  @override
  Future<void> launch(String package) async => launched.add(package);

  @override
  Future<bool> isHome() async => false;

  @override
  Future<void> requestHome() async {}
}

final _builtIns = [
  BuiltInApp(
    id: 'demo',
    label: 'Demo',
    icon: DenaIcons.playCircle,
    builder: (_) => const Scaffold(body: Text('demo screen')),
  ),
];

void main() {
  testScreens('apps tab', (tester, screen, mode) async {
    final fake = _FakeApps();
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: AppsTab(apps: fake, builtIns: _builtIns),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // One table: the built-in app pinned on top, then the installed ones.
    expect(find.byType(BrutalTable), findsOneWidget);
    expect(find.text('BUILT-IN'), findsOneWidget);
    expect(find.text('[OPEN]'), findsNWidgets(4));
    expect(find.byType(AppIconTile), findsNWidgets(4));
    final demo = tester.getTopLeft(find.text('DEMO')).dy;
    expect(demo, lessThan(tester.getTopLeft(find.text('BROWSER')).dy));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('apps_tab', screen, mode)),
    );
    await tester.tap(find.text('CAMERA'));
    await tester.pump();
    expect(fake.launched, ['a.camera']);
    await tester.tap(find.text('DEMO'));
    await tester.pumpAndSettle();
    expect(find.text('demo screen'), findsOneWidget);
  });

  test('registry resolves apps/builtin/<id>', () {
    registerBuiltInApp(_builtIns.first);
    expect(builtInAppRoute('demo'), 'apps/builtin/demo');
    expect(builtInAppById('demo')?.label, 'Demo');
    expect(
      builtInAppRouteFor(const RouteSettings(name: 'apps/builtin/demo')),
      isNotNull,
    );
    expect(builtInAppRouteFor(const RouteSettings(name: 'x')), isNull);
  });

  testWidgets('the D-pad starts on the first row and A opens it', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final fake = _FakeApps();
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: AppsTab(apps: fake, builtIns: _builtIns),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await dpad(tester, LogicalKeyboardKey.arrowDown);
    await dpad(tester, LogicalKeyboardKey.arrowDown);
    await dpad(tester, LogicalKeyboardKey.enter);
    expect(fake.launched, ['a.camera']);
  });
}
