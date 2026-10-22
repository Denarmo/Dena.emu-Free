// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/media-players.md, brutalist-ui.md (4.8)
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/media/media_backend.dart';
import 'package:dena_emu/src/media/media_kit.dart';
import 'package:dena_emu/src/media/music_screen.dart';
import 'package:dena_emu/src/media/video_screen.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/media_fixture.dart';
import '../support/screen_matrix.dart';

Widget app(Widget home) => DenaApp(home: home);

/// Unmounts the screens so their periodic timers (music polling, video
/// position) are cancelled before the test ends.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

/// Lets the fake backend's futures complete and the screen rebuild.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Puts the focus on the seek bar, as moving the D-pad onto it would.
Future<void> focusSeekBar(WidgetTester tester) async {
  final inner = find
      .descendant(of: find.byType(MediaSeekBar), matching: find.byType(Builder))
      .first;
  Focus.of(tester.element(inner)).requestFocus();
  await tester.pump();
}

bool focusIn<T extends Widget>() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<T>() !=
    null;

void useFocusMode() {
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  addTearDown(
    () => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic,
  );
}

final _songs = [
  track('Blip Blop Overture'),
  track('Cave Echoes', seconds: 245),
  track('Dungeon Loop', album: 'Low Bits', artist: 'Noise Channel'),
  track('Moonlight March', seconds: 312),
  track('Pixel Rain', album: 'Low Bits', artist: 'Noise Channel'),
];

final _clips = [
  clip('Beach Day', folder: 'Camera'),
  clip('Birthday Cake', folder: 'Camera', seconds: 42),
  clip('Big Buck Bunny', folder: 'Movies', seconds: 596),
  clip('Sunset Timelapse', folder: 'Camera', seconds: 30),
];

/// A backend with [_songs] and [_clips] and the second song playing.
Future<FakeMediaBackend> playing() async {
  final fake = FakeMediaBackend(songs: _songs, videos: _clips);
  await MusicController.of(fake).play(_songs, 1);
  await fake.musicSeek(83000);
  await fake.setRepeat(2);
  fake.calls.clear();
  return fake;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // VideoPlayerPage toggles the system UI; answer those calls so the
    // unawaited futures do not surface as missing-plugin errors.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });

  test('formatDuration renders m:ss and h:mm:ss', () {
    expect(formatDuration(0), '0:00');
    expect(formatDuration(65000), '1:05');
    expect(formatDuration(3725000), '1:02:05');
  });

  test('resumePoint forgets the start and the last 5 seconds', () {
    expect(resumePoint(3000, 100000), isNull);
    expect(resumePoint(50000, 100000), 50000);
    expect(resumePoint(97000, 100000), isNull);
  });

  testWidgets('songs table shows titles and plays the tapped track', (
    tester,
  ) async {
    final fake = FakeMediaBackend(
      songs: [track('First'), track('Second'), track('Third')],
    );
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    expect(find.byType(BrutalTable), findsOneWidget);
    expect(find.text('FIRST'), findsOneWidget);
    expect(find.text('SECOND'), findsOneWidget);
    expect(find.text('THIRD'), findsOneWidget);
    await tester.tap(find.text('SECOND'));
    await tester.pump();
    expect(fake.calls, contains('playQueue(1)'));
    await finish(tester);
  });

  testWidgets('refused access offers to allow access', (tester) async {
    final fake = FakeMediaBackend(granted: false);
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    expect(find.text('[ALLOW ACCESS]'), findsOneWidget);
    await tester.tap(find.text('[ALLOW ACCESS]'));
    await settle(tester);
    expect(fake.calls.where((c) => c == 'requestAccess(false)'), hasLength(2));
    await finish(tester);
  });

  testWidgets('empty music library says so', (tester) async {
    final fake = FakeMediaBackend();
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    expect(find.text('> No music found on this device.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Albums tab groups tracks by album', (tester) async {
    final fake = FakeMediaBackend(
      songs: [
        track('A'),
        track('B'),
        track('C', album: 'Other Album'),
      ],
    );
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    await tester.tap(find.text('ALBUMS'));
    await tester.pump();
    expect(find.text('SQUARE WAVES'), findsOneWidget);
    expect(find.text('OTHER ALBUM'), findsOneWidget);
    // Groups sort by name: OTHER ALBUM first.
    expect(find.text('C'), findsOneWidget);
    expect(find.text('A'), findsNothing);
    await tester.tap(find.text('SQUARE WAVES'));
    await tester.pump();
    expect(find.text('A'), findsOneWidget);
    expect(find.text('C'), findsNothing);
    await finish(tester);
  });

  testWidgets('L1 / R1 switch categories and a track stays focused', (
    tester,
  ) async {
    useFocusMode();
    final fake = FakeMediaBackend(songs: _songs);
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    expect(focusIn<BrutalTable>(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
    await settle(tester);
    expect(find.text('SQUARE WAVES'), findsOneWidget);
    expect(focusIn<BrutalTable>(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
    await settle(tester);
    expect(find.text('PIXEL_RAIN'), findsOneWidget);
    expect(focusIn<BrutalTable>(), isTrue);
    // X plays / pauses wherever the focus is.
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
    await settle(tester);
    expect(fake.calls, contains('play'));
    await finish(tester);
  });

  testWidgets('music seek bar steps with left / right on a pad', (
    tester,
  ) async {
    useFocusMode();
    final fake = await playing();
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    // 800x600: library and now playing side by side.
    expect(find.byType(NowPlaying), findsOneWidget);
    await focusSeekBar(tester);
    // Cave Echoes is 245 s; one step is 1/20 of it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(fake.calls, contains('seek(${83000 + 12250})'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(fake.calls.last, 'seek(83000)');
    // Held: key repeats keep stepping.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(fake.calls.last, 'seek(${83000 - 2 * 12250})');
    await finish(tester);
  });

  testWidgets('music seek bar seeks where it is tapped', (tester) async {
    final fake = await playing();
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    final bar = find.descendant(
      of: find.byType(MediaSeekBar),
      matching: find.byType(ProgressCell),
    );
    await tester.tapAt(tester.getCenter(bar));
    await settle(tester);
    final seek = fake.calls.lastWhere((c) => c.startsWith('seek('));
    final ms = int.parse(seek.substring(5, seek.length - 1));
    expect(ms, closeTo(245000 / 2, 245000 * 0.05));
    await finish(tester);
  });

  testWidgets('portrait: mini player opens now playing, back closes it', (
    tester,
  ) async {
    tester.view.physicalSize = phone.size * phone.pixelRatio;
    tester.view.devicePixelRatio = phone.pixelRatio;
    addTearDown(tester.view.reset);
    final fake = await playing();
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    expect(find.byType(NowPlaying), findsNothing);
    await tester.tap(find.byTooltip('Now playing'));
    await settle(tester);
    expect(find.byType(NowPlaying), findsOneWidget);
    await tester.tap(find.byTooltip('Next'));
    await settle(tester);
    expect(fake.calls, contains('next'));
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);
    expect(find.byType(NowPlaying), findsNothing);
    expect(find.byType(BrutalTable), findsOneWidget);
    await finish(tester);
  });

  testWidgets('videos table shows titles and folder filters', (tester) async {
    final fake = FakeMediaBackend(
      videos: [
        clip('Beach', folder: 'Camera'),
        clip('Cartoon', folder: 'Movies'),
      ],
    );
    await tester.pumpWidget(app(VideoScreen(backend: fake)));
    await settle(tester);
    expect(find.text('BEACH'), findsOneWidget);
    expect(find.text('CARTOON'), findsOneWidget);
    expect(find.text('[x]ALL(2)'), findsOneWidget);
    expect(find.text('[ ]CAMERA(1)'), findsOneWidget);
    expect(find.text('[ ]MOVIES(1)'), findsOneWidget);
    await tester.tap(find.text('[ ]MOVIES(1)'));
    await tester.pump();
    expect(find.text('BEACH'), findsNothing);
    expect(find.text('CARTOON'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('video player opens, seeks and resumes', (tester) async {
    final fake = FakeMediaBackend();
    final video = clip('Beach');
    Widget page() => app(
      VideoPlayerPage(
        video: video,
        backend: fake,
        textureBuilder: (_) => const ColoredBox(color: Colors.blue),
      ),
    );

    await tester.pumpWidget(page());
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls, contains('videoOpen(0)'));

    // The overlay's GestureDetector also listens for double taps, so a single
    // tap only resolves after the double-tap timeout (~300 ms).
    await tester.tap(find.byTooltip('Forward 10 seconds'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(fake.calls.any((c) => c.startsWith('videoSeek(')), isTrue);

    await finish(tester);

    fake.resume.positions[video.uri] = 30000;
    await tester.pumpWidget(page());
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls, contains('videoOpen(30000)'));
    await finish(tester);
  });

  testWidgets('video seek bar steps with left / right on a pad', (
    tester,
  ) async {
    useFocusMode();
    final fake = FakeMediaBackend(videos: _clips);
    await tester.pumpWidget(
      app(
        VideoPlayerPage(
          video: _clips[2],
          backend: fake,
          textureBuilder: (_) => const ColoredBox(color: Colors.blue),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await focusSeekBar(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    // Big Buck Bunny is 596 s; one step is 1/20 of it.
    expect(fake.calls.last, 'videoSeek(29800)');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls.last, 'videoSeek(0)');
    await finish(tester);
  });

  testWidgets('hidden video controls: right skips 10 s', (tester) async {
    final fake = FakeMediaBackend(videos: _clips);
    await tester.pumpWidget(
      app(
        VideoPlayerPage(
          video: _clips[2],
          backend: fake,
          textureBuilder: (_) => const ColoredBox(color: Colors.blue),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Controls hide 3 s after showing while playing.
    await tester.pump(const Duration(seconds: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls, contains('videoSeek(10000)'));
    await finish(tester);
  });

  // ---- goldens (spec 7: phone, 640x480, 720x720; touch and focus) --------

  testScreens('music library', (tester, screen, mode) async {
    final fake = await playing();
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('music_library', screen, mode)),
    );
    await finish(tester);
  });

  testScreens('music albums and now playing', (tester, screen, mode) async {
    final fake = await playing();
    await tester.pumpWidget(app(MusicScreen(backend: fake)));
    await settle(tester);
    if (screen == phone) {
      await tester.tap(find.byTooltip('Now playing'));
    } else {
      await tester.tap(find.text('ALBUMS'));
    }
    await settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('music_now_playing', screen, mode)),
    );
    await finish(tester);
  });

  testScreens('video list', (tester, screen, mode) async {
    final fake = FakeMediaBackend(videos: _clips);
    fake.resume.positions[_clips[2].uri] = 300000;
    await tester.pumpWidget(app(VideoScreen(backend: fake)));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('video_list', screen, mode)),
    );
    await finish(tester);
  });

  testScreens('video player', (tester, screen, mode) async {
    final fake = FakeMediaBackend(videos: _clips);
    fake.resume.positions[_clips[2].uri] = 300000;
    await tester.pumpWidget(
      app(
        VideoPlayerPage(
          video: _clips[2],
          backend: fake,
          textureBuilder: (_) => const ColoredBox(color: Color(0xFF1B3A5C)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await fake.videoPause();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('video_player', screen, mode)),
    );
    await finish(tester);
  });
}
