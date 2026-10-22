// Renders the music and video players (media-players.md) with real fonts (Roboto + Material Icons from the
// Flutter SDK) for sharing progress. Not part of CI:
//   flutter test tool/media_screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/media_fixture.dart';

import 'package:dena_emu/src/media/media_backend.dart';
import 'package:dena_emu/src/media/music_screen.dart';
import 'package:dena_emu/src/media/video_screen.dart';
import 'package:dena_emu/src/app.dart' show denaTheme;
import 'package:dena_emu/src/ui/brutal/tokens.dart' show BrutalTokens;

Future<void> loadFont(String family, List<String> files) async {
  final fonts =
      '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter'}'
      '/bin/cache/artifacts/material_fonts';
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(
      Future.value(ByteData.sublistView(File('$fonts/$f').readAsBytesSync())),
    );
  }
  await loader.load();
}

/// Loads a font bundled with the app (assets/fonts/...).
Future<void> loadAppFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(
      Future.value(
        ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync()),
      ),
    );
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    await loadAppFont('Roboto', [
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
        'roboto/Roboto-$w.ttf',
    ]);
    await loadFont('MaterialIcons', ['MaterialIcons-Regular.otf']);
    await loadAppFont('IBM Plex Mono', [
      for (final w in ['Medium', 'SemiBold', 'Bold'])
        'ibm_plex_mono/IBMPlexMono-$w.ttf',
    ]);
    await loadAppFont('Archivo Black', [
      'archivo_black/ArchivoBlack-Regular.ttf',
    ]);
    await loadAppFont('DenaIcons', ['dena_icons/DenaIcons.otf']);
  });

  Future<void> shoot(
    WidgetTester tester,
    Widget app,
    String name, {
    Size size = const Size(412, 915),
    double ratio = 2.625,
    Future<void> Function()? before,
  }) async {
    // flutter_test draws shadows as black outlines unless this is off.
    debugDisableShadows = false;
    tester.view.physicalSize = size * ratio;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await before?.call();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/$name.png'),
    );
    debugDisableShadows = true; // the test binding checks it is restored
  }

  // ---- Music and video players (media-players.md) ----
  final songs = [
    track(
      'Morning Circuit',
      artist: 'Chip Ensemble',
      album: 'Square Waves',
      seconds: 214,
    ),
    track('Neon Rain', artist: 'Lumen', album: 'Night Drive', seconds: 251),
    track(
      'Overworld Theme',
      artist: 'Chip Ensemble',
      album: 'Square Waves',
      seconds: 187,
    ),
    track('Pulse Width', artist: 'Lumen', album: 'Night Drive', seconds: 233),
    track(
      'Save Point',
      artist: 'Kira Vale',
      album: 'Checkpoints',
      seconds: 176,
    ),
    track(
      'Starfield Drift',
      artist: 'Kira Vale',
      album: 'Checkpoints',
      seconds: 302,
    ),
    track(
      'Title Screen',
      artist: 'Chip Ensemble',
      album: 'Square Waves',
      seconds: 145,
    ),
    track('Warp Zone', artist: 'Lumen', album: 'Night Drive', seconds: 198),
  ];
  final clips = [
    clip('Beach day', folder: 'Camera', seconds: 74),
    clip('Birthday cake', folder: 'Camera', seconds: 212),
    clip('Speedrun attempt 14', folder: 'Recordings', seconds: 1834),
    clip('Boss fight no damage', folder: 'Recordings', seconds: 642),
    clip('Concert encore', folder: 'Camera', seconds: 389),
    clip('Trailer', folder: 'Downloads', seconds: 131),
  ];
  Widget media(Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: denaTheme(BrutalTokens.ink()),
    home: home,
  );
  Future<FakeMediaBackend> playing() async {
    final fake = FakeMediaBackend(songs: songs, videos: clips);
    await MusicController.of(fake).play(songs, 1);
    await fake.musicSeek(83000);
    await fake.setRepeat(2);
    return fake;
  }

  for (final (label, size, ratio) in [
    ('phone', const Size(412, 915), 2.625),
    ('640x480', const Size(640, 480), 1.0),
  ]) {
    testWidgets('music library, $label', (tester) async {
      final fake = await playing();
      await shoot(
        tester,
        media(MusicScreen(backend: fake)),
        'music_library_$label',
        size: size,
        ratio: ratio,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('music albums + now playing, $label', (tester) async {
      final fake = await playing();
      await shoot(
        tester,
        media(MusicScreen(backend: fake)),
        'music_now_playing_$label',
        size: size,
        ratio: ratio,
        before: () async {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
          if (label == 'phone') {
            await tester.tap(find.byTooltip('Now playing'));
          } else {
            await tester.tap(find.text('ALBUMS'));
          }
          await tester.pump();
        },
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('video browser, $label', (tester) async {
      final fake = FakeMediaBackend(videos: clips);
      fake.resume.positions[clips[2].uri] = 700000;
      await shoot(
        tester,
        media(VideoScreen(backend: fake)),
        'video_browser_$label',
        size: size,
        ratio: ratio,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('video playback, $label', (tester) async {
      final fake = FakeMediaBackend(videos: clips);
      fake.resume.positions[clips[2].uri] = 700000;
      await fake.videoOpen(clips[2].uri, 700000);
      await fake.videoPause();
      await shoot(
        tester,
        media(
          VideoPlayerPage(
            video: clips[2],
            backend: fake,
            textureBuilder: (_) => const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF1B3A5C),
                    Color(0xFF6A2C70),
                    Color(0xFFE08E45),
                  ],
                ),
              ),
            ),
          ),
        ),
        'video_playback_$label',
        size: size == const Size(412, 915) ? const Size(915, 412) : size,
        ratio: ratio,
        before: () async {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
          await fake.videoPause();
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  }
}
