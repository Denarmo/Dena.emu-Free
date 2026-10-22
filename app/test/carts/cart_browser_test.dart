import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/carts/bbs.dart';
import 'package:dena_emu/src/carts/cart_browser.dart';
import 'package:dena_emu/src/carts/cart_download.dart';
import 'package:dena_emu/src/library/carts_tab.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';
import 'fake_bbs.dart';

class _Rig {
  _Rig(this.db, this.dir, this.client)
    : deps = CartBrowserDeps(client: client, credits: CartCredits(dir.path));

  final LibraryDatabase db;
  final Directory dir;
  final FakeBbsClient client;
  final CartBrowserDeps deps;

  /// [screen] picks handheld density for the 640x480 and 720x720 sizes.
  Widget app(Widget home, {ScreenSize? screen}) => Handheld(
    enabled: screen == handheld4x3 || screen == handheldSquare,
    child: LibraryScope(
      db: db,
      importer: Importer(db, Directory('${dir.path}/games')),
      files: FakeFiles(),
      child: DenaApp(home: home),
    ),
  );
}

/// The real fonts, so goldens show the Brutalist type.
Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
      );
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

Future<_Rig> _rig(
  WidgetTester tester, {
  String? failWith,
  int carts = 0,
}) async {
  final db = await seededDb([]);
  for (var i = 0; i < carts; i++) {
    await db.addGame(
      system: 'pico8',
      title: 'Cart ${i + 1}',
      fileName: 'cart${i + 1}.p8',
      path: '/nowhere/cart$i.p8',
      sha1: 'cart$i',
      size: 1,
      crc32: '0',
      addedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
    );
  }
  final dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('dena_bbs_test'),
  ))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  return _Rig(db, dir, FakeBbsClient()..failWith = failWith);
}

/// Lets real file and database work finish: each await in a chain of I/O
/// needs its own turn of the real event loop.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Runs real I/O turns until [finder] matches (download chains many awaits).
Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester, _Rig rig) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(Duration.zero);
  await tester.runAsync(rig.db.close);
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _settle(tester);
}

int _tab(WidgetTester tester) => tester
    .widget<BrutalTabBar>(find.byKey(const Key('cart browser tabs')))
    .selected;

void main() {
  setUpAll(_loadFonts);

  testScreens('featured carts', (tester, screen, mode) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(
      rig.app(CartBrowserPage(deps: rig.deps), screen: screen),
    );
    await _settle(tester);
    expect(find.text('MOON_HOPPER'), findsOneWidget);
    expect(find.text('04'), findsOneWidget);
    expect(find.text('05'), findsNothing);
    expect(find.text('ada'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(CartBrowserPage),
      matchesGoldenFile(goldenName('cart_browser_featured', screen, mode)),
    );
    await _finish(tester, rig);
  });

  testScreens('cart sheet', (tester, screen, mode) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(
      rig.app(CartBrowserPage(deps: rig.deps), screen: screen),
    );
    await _settle(tester);
    await tester.tap(find.text('MOON_HOPPER'));
    await _settle(tester);
    expect(find.byType(CartSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Navigator),
      matchesGoldenFile(goldenName('cart_sheet', screen, mode)),
    );
    await _finish(tester, rig);
  });

  testScreens('offline error', (tester, screen, mode) async {
    final rig = await _rig(tester, failWith: 'No connection to the BBS.');
    await tester.pumpWidget(
      rig.app(CartBrowserPage(deps: rig.deps), screen: screen),
    );
    await _settle(tester);
    expect(find.text('> No connection to the BBS.'), findsOneWidget);
    expect(find.text('[RETRY]'), findsOneWidget);
    await expectLater(
      find.byType(CartBrowserPage),
      matchesGoldenFile(goldenName('cart_browser_error', screen, mode)),
    );
    // Retry (focused, so A / Enter works) reloads.
    rig.client.failWith = null;
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text('MOON_HOPPER'), findsOneWidget);
    expect(find.text('ada'), findsNWidgets(2));
    await _finish(tester, rig);
  });

  testScreens('every tab renders', (tester, screen, mode) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(rig.app(CartBrowserPage(deps: rig.deps)));
    await _settle(tester);
    for (final name in ['NEW', 'SEARCH', 'AUTHOR', 'FEATURED']) {
      await tester.tap(find.text(name));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: name);
    }
    await _finish(tester, rig);
  });

  testScreens('L1 / R1 cycle the tabs', (tester, screen, mode) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(rig.app(CartBrowserPage(deps: rig.deps)));
    await _settle(tester);
    expect(_tab(tester), 0);
    for (final expected in [1, 2, 3, 0]) {
      await _key(tester, LogicalKeyboardKey.gameButtonRight1);
      expect(_tab(tester), expected);
    }
    await _key(tester, LogicalKeyboardKey.gameButtonLeft1);
    expect(_tab(tester), 3);
    expect(
      rig.client.requests.map((r) => r.$1),
      containsAll([const FeaturedCarts(), const NewCarts()]),
    );
    await _finish(tester, rig);
  }, sizes: const [handheld4x3]);

  testScreens(
    'D-pad selects a cart and B / Escape go back',
    (tester, screen, mode) async {
      final rig = await _rig(tester);
      await tester.pumpWidget(
        rig.app(
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CartBrowserPage(deps: rig.deps),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      // The first card has focus once the list loads.
      await _key(tester, LogicalKeyboardKey.enter);
      expect(find.byType(CartSheet), findsOneWidget);
      expect(find.text('[DOWNLOAD]'), findsOneWidget);
      // Download takes focus once the library check is done.
      final download = tester.widget<BrutalButton>(
        find.ancestor(
          of: find.text('[DOWNLOAD]'),
          matching: find.byType(BrutalButton),
        ),
      );
      expect(download.focusNode!.hasPrimaryFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(CartSheet), findsNothing);
      await _key(tester, LogicalKeyboardKey.gameButtonB);
      expect(find.byType(CartBrowserPage), findsNothing);
      await _finish(tester, rig);
    },
    sizes: const [handheld4x3],
    modes: const [InputMode.focus],
  );

  testScreens('search runs on submit', (tester, screen, mode) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(rig.app(CartBrowserPage(deps: rig.deps)));
    await _settle(tester);
    await tester.tap(find.text('SEARCH'));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('cart search')), 'cave');
    await _settle(tester);
    expect(rig.client.requests.whereType<(SearchCarts, int)>(), isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(find.text("TOM_&_JERRY'S_CAVE"), findsOneWidget);
    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsNothing);
    await _finish(tester, rig);
  }, sizes: const [phone]);

  testScreens('authors tab opens an author', (tester, screen, mode) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(rig.app(CartBrowserPage(deps: rig.deps)));
    await _settle(tester);
    await tester.tap(find.text('AUTHOR').first);
    await _settle(tester);
    expect(find.text('>'), findsNWidgets(3)); // ada, bo"b, cy
    await tester.tap(find.text('ada'));
    await _settle(tester);
    expect(find.text('CARTS BY ada'), findsOneWidget);
    expect(find.text('ada'), findsNWidgets(2));
    expect(find.text('02'), findsOneWidget);
    expect(find.text('03'), findsNothing);
    expect(rig.client.requests.last.$1, const AuthorCarts(11, 'ada'));
    await _finish(tester, rig);
  }, sizes: const [phone]);

  testScreens('download imports and credits the cart', (
    tester,
    screen,
    mode,
  ) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(rig.app(CartBrowserPage(deps: rig.deps)));
    await _settle(tester);
    await tester.tap(find.text('MOON_HOPPER'));
    await _settle(tester);
    // The sheet credits the author and links the BBS page.
    expect(find.text('by ada'), findsOneWidget);
    expect(find.textContaining('/bbs/?tid=501'), findsOneWidget);
    expect(find.text('LICENSE'), findsOneWidget);
    await tester.tap(find.text('[DOWNLOAD]'));
    await _until(tester, find.text('[IN LIBRARY]'));
    expect(find.text('OK > Added Moon Hopper by ada'), findsOneWidget);
    expect(find.text('[IN LIBRARY]'), findsOneWidget);
    final games = (await tester.runAsync(() => rig.db.watchGames().first))!;
    expect(games.single.system, 'pico8');
    final credits = (await tester.runAsync(rig.deps.credits.load))!;
    expect(credits.values.single.author, 'ada');
    expect(credits.values.single.threadId, 501);
    expect(File('${rig.dir.path}/carts/credits.json').existsSync(), isTrue);

    // Reopening the cart shows it is already there.
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);
    await tester.tap(find.text('MOON_HOPPER'));
    await _settle(tester);
    expect(find.text('[IN LIBRARY]'), findsOneWidget);
    expect(rig.client.downloads, ['1001']);
    await _finish(tester, rig);
  }, sizes: const [phone]);

  testScreens('a cart without a file id cannot be downloaded', (
    tester,
    screen,
    mode,
  ) async {
    final rig = await _rig(tester);
    await tester.pumpWidget(rig.app(CartBrowserPage(deps: rig.deps)));
    await _settle(tester);
    await tester.tap(find.text('NO_ART'));
    await _settle(tester);
    final button = tester.widget<BrutalButton>(
      find.ancestor(
        of: find.text('[DOWNLOAD]'),
        matching: find.byType(BrutalButton),
      ),
    );
    expect(button.onPressed, isNull);
    await _finish(tester, rig);
  }, sizes: const [phone]);

  group('Carts tab', () {
    testScreens('flag off: no browser', (tester, screen, mode) async {
      final rig = await _rig(tester);
      await tester.pumpWidget(
        rig.app(CartsTab(onPlay: (_, _) {}, browserEnabled: false)),
      );
      await _settle(tester);
      expect(find.text('[BROWSE BBS]'), findsNothing);
      expect(
        find.text(
          '> cart browser off: add .p8 and .p8.png carts you have downloaded',
        ),
        findsOneWidget,
      );
      await _finish(tester, rig);
    }, sizes: const [phone]);

    test('the browser is on by default', () {
      expect(pico8BrowserEnabled, isTrue);
    });

    testScreens('the Dena Explore card opens the launcher', (
      tester,
      screen,
      mode,
    ) async {
      final rig = await _rig(tester);
      var opened = 0;
      await tester.pumpWidget(
        rig.app(CartsTab(onPlay: (_, _) {}, onExplore: (_) async => opened++)),
      );
      await _settle(tester);
      // The button above the table and the pinned row 00 both launch it.
      expect(find.text('[LAUNCH EXPLORE]'), findsOneWidget);
      expect(find.text('00'), findsOneWidget);
      expect(find.text('DENA_EXPLORE'), findsOneWidget);
      await tester.tap(find.text('[LAUNCH EXPLORE]'));
      await tester.pump();
      expect(opened, 1);
      await tester.tap(find.text('DENA_EXPLORE'));
      await tester.pump();
      expect(opened, 2);
      await tester.pumpWidget(rig.app(CartsTab(onPlay: (_, _) {})));
      await _settle(tester);
      expect(find.text('[LAUNCH EXPLORE]'), findsNothing);
      expect(find.text('DENA_EXPLORE'), findsNothing);
      await _finish(tester, rig);
    });

    testScreens('flag forced on opens the browser', (
      tester,
      screen,
      mode,
    ) async {
      final rig = await _rig(tester);
      await tester.pumpWidget(
        rig.app(
          CartsTab(
            onPlay: (_, _) {},
            browserEnabled: true,
            browserDeps: () async => rig.deps,
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('[BROWSE BBS]'));
      await _settle(tester);
      expect(find.byType(CartBrowserPage), findsOneWidget);
      await _finish(tester, rig);
    }, sizes: const [phone]);
    testScreens('carts table', (tester, screen, mode) async {
      final rig = await _rig(tester, carts: 3);
      final games = (await tester.runAsync(() => rig.db.watchGames().first))!;
      await tester.runAsync(() async {
        await rig.db.setFavorite(games.first.id, true);
        await rig.deps.credits.put(
          games.last.sha1,
          const CartCredit(
            postId: '1001',
            threadId: 501,
            title: 'Cart 3',
            author: 'ada',
            authorId: 11,
            cartId: 'cart3',
          ),
        );
      });
      await tester.pumpWidget(
        rig.app(
          CartsTab(
            onPlay: (_, _) {},
            onExplore: (_) async {},
            browserDeps: () async => rig.deps,
          ),
          screen: screen,
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      for (final header in ['#', 'CART', 'TITLE', 'AUTHOR', 'LICENSE', 'FAV']) {
        expect(find.text(header), findsOneWidget, reason: header);
      }
      expect(find.text('00'), findsOneWidget);
      expect(find.text('CART_3'), findsOneWidget);
      expect(find.text('ada'), findsOneWidget);
      expect(find.text('SEE BBS'), findsOneWidget);
      expect(find.text('GPL-3.0'), findsOneWidget);
      await expectLater(
        find.byType(CartsTab),
        matchesGoldenFile(goldenName('carts_tab', screen, mode)),
      );
      await _finish(tester, rig);
    });

    testScreens('no carts and no network: empty state', (
      tester,
      screen,
      mode,
    ) async {
      final rig = await _rig(tester);
      await tester.pumpWidget(
        rig.app(
          CartsTab(onPlay: (_, _) {}, browserEnabled: false),
          screen: screen,
        ),
      );
      await _settle(tester);
      expect(find.text('NO CARTS YET.'), findsOneWidget);
      expect(find.text('[ADD CARTS]'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, rig);
    });

    testScreens(
      'the focused row stays visible and A plays it',
      (tester, screen, mode) async {
        final rig = await _rig(tester, carts: 30);
        final played = <String>[];
        await tester.pumpWidget(
          rig.app(
            CartsTab(
              onPlay: (_, game) => played.add(game.title),
              onExplore: (_) async {},
              browserDeps: () async => rig.deps,
            ),
            screen: screen,
          ),
        );
        await _settle(tester);
        final table = find.byKey(const Key('carts table'));
        // Focus starts on LAUNCH EXPLORE; down enters the table at row 00.
        for (var i = 0; i < 25; i++) {
          await _key(tester, LogicalKeyboardKey.arrowDown);
        }
        final focused = FocusManager.instance.primaryFocus!.context!;
        final row = tester.getRect(
          find.byElementPredicate((e) => e == focused),
        );
        final view = tester.getRect(table);
        expect(row.top, greaterThanOrEqualTo(view.top));
        expect(row.bottom, lessThanOrEqualTo(view.bottom));
        Finder inRow(Pattern p) => find.descendant(
          of: find.byElementPredicate((e) => e == focused),
          matching: find.textContaining(p),
        );
        final number = int.parse(
          tester.widget<Text>(inRow(RegExp(r'^\d\d$'))).data!,
        );
        expect(number, greaterThan(10));
        final title = tester.widget<Text>(inRow(RegExp(r'^CART_'))).data!;
        await _key(tester, LogicalKeyboardKey.gameButtonA);
        expect(played.map(fileStyleTitle), [title]);
        await _finish(tester, rig);
      },
      sizes: const [handheld4x3],
      modes: const [InputMode.focus],
    );
  });
}
