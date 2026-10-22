// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/media-players.md (Video), brutalist-ui.md (4.8)
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'media_backend.dart';
import 'media_kit.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Route name of the video player.
const videoRoute = 'apps/video';

/// Device videos in a table, filtered by folder; opens [VideoPlayerPage].
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, this.backend});

  final MediaBackend? backend;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

enum _Load { loading, denied, ready }

class _VideoScreenState extends State<VideoScreen> {
  late final MediaBackend backend = widget.backend ?? MediaBackend.instance;
  late final ThumbnailCache thumbs = ThumbnailCache(backend);
  _Load load = _Load.loading;
  List<MediaEntry> videos = const [];
  Map<String, int> resume = const {};
  int category = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => load = _Load.loading);
    if (!await backend.requestAccess(video: true)) {
      if (mounted) setState(() => load = _Load.denied);
      return;
    }
    final list = await backend.list(video: true);
    await _readResume(list);
    if (!mounted) return;
    setState(() {
      videos = list;
      load = _Load.ready;
    });
  }

  Future<void> _readResume(List<MediaEntry> list) async {
    final map = <String, int>{};
    for (final v in list) {
      final p = await backend.resume.positionOf(v.uri);
      if (p > 0) map[v.uri] = p;
    }
    resume = map;
  }

  List<String> get folders {
    final f = {
      for (final v in videos)
        if (v.folder.isNotEmpty) v.folder,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return f;
  }

  Future<void> _open(MediaEntry v) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(video: v, backend: backend),
      ),
    );
    await _readResume(videos);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final names = folders;
    // ALL, then one filter per folder.
    final count = names.length + 1;
    final cat = category.clamp(0, count - 1);
    final shown = cat == 0
        ? videos
        : videos.where((v) => v.folder == names[cat - 1]).toList();
    final Widget body = switch (load) {
      _Load.loading => const MediaLoading('videos'),
      _Load.denied => MediaMessage(
        headline: 'No access.',
        text: 'Dena.emu needs access to your videos to play them.',
        action: 'Allow access',
        onAction: _load,
      ),
      _Load.ready when videos.isEmpty => const MediaMessage(
        headline: 'No videos.',
        text: 'No videos found on this device.',
      ),
      _Load.ready => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FocusTraversalGroup(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < count; i++) ...[
                    if (i > 0) const SizedBox(width: BrutalTokens.s1),
                    CheckFilter(
                      label: i == 0 ? 'All' : names[i - 1],
                      count: i == 0
                          ? videos.length
                          : videos
                                .where((v) => v.folder == names[i - 1])
                                .length,
                      checked: i == cat,
                      onPressed: () => setState(() => category = i),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: BrutalTokens.s2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: BrutalTokens.s3),
              child: _VideoTable(
                // A new table per folder, so its first row takes focus when
                // the focused row goes away (L1 / R1).
                key: ValueKey('videos-$cat'),
                videos: shown,
                resume: resume,
                thumbs: thumbs,
                onOpen: _open,
              ),
            ),
          ),
        ],
      ),
    };
    return CallbackShortcuts(
      bindings: categoryKeys(count, cat, (i) => setState(() => category = i)),
      child: MediaScaffold(
        title: 'Video',
        autofocusBack: load == _Load.ready && videos.isEmpty,
        child: body,
      ),
    );
  }
}

/// The video list: THUMB, TITLE, FOLDER (when there is room) and TIME with
/// the resume progress under it.
class _VideoTable extends StatelessWidget {
  const _VideoTable({
    super.key,
    required this.videos,
    required this.resume,
    required this.thumbs,
    required this.onOpen,
  });

  final List<MediaEntry> videos;
  final Map<String, int> resume;
  final ThumbnailCache thumbs;
  final ValueChanged<MediaEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final folder = box.maxWidth >= 480;
        final cols = <(String, BrutalColumn)>[
          ('thumb', const BrutalColumn('Thumb', width: 76)),
          ('title', const BrutalColumn('Title', flex: 3)),
          if (folder) ('folder', const BrutalColumn('Folder', flex: 2)),
          ('time', const BrutalColumn('Time', width: 84, numeric: true)),
        ];
        final h = (t.rowHeight - 12).clamp(16.0, 36.0);
        return BrutalTable(
          columns: [for (final c in cols) c.$2],
          rowCount: videos.length,
          autofocusRow: 0,
          onRowPressed: (i) => onOpen(videos[i]),
          cellBuilder: (context, row, col, lit) {
            final v = videos[row];
            switch (cols[col].$1) {
              case 'thumb':
                return MediaThumb(
                  future: thumbs.of(v.uri, size: 320),
                  icon: DenaIcons.film,
                  width: (h * 16 / 9).roundToDouble(),
                  height: h,
                );
              case 'title':
                return Text(
                  BrutalTokens.fileName(v.title),
                  key: ValueKey('video-${v.uri}'),
                );
              case 'folder':
                return Text(
                  v.folder.toUpperCase(),
                  style: TextStyle(color: lit ? t.onFocus : t.mutedText),
                );
              default:
                final at = resume[v.uri] ?? 0;
                final time = Text(formatDuration(v.durationMs));
                if (at <= 0 || v.durationMs <= 0) return time;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    time,
                    const SizedBox(height: 2),
                    ProgressCell(
                      value: at / v.durationMs,
                      showPercent: false,
                      width: 56,
                      height: 6,
                      color: lit ? t.onFocus : t.ink,
                    ),
                  ],
                );
            }
          },
        );
      },
    );
  }
}

/// Full-screen playback with auto-hiding Brutalist controls. D-pad: left /
/// right skip 10 s, A plays / pauses, B leaves and remembers the position.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.video,
    required this.backend,
    this.textureBuilder,
  });

  final MediaEntry video;
  final MediaBackend backend;

  /// Draws the frame; tests and screenshots replace the real [Texture].
  final Widget Function(int textureId)? textureBuilder;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  MediaBackend get backend => widget.backend;
  int? texture;
  VideoStatus status = VideoStatus(
    playing: false,
    ended: false,
    positionMs: 0,
    durationMs: 0,
    width: 0,
    height: 0,
  );
  Timer? _poll;
  Timer? _hide;
  bool controls = true;
  bool _closed = false;
  final _focus = FocusNode(debugLabel: 'video');

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _open();
  }

  Future<void> _open() async {
    final start = await backend.resume.positionOf(widget.video.uri);
    final id = await backend.videoOpen(widget.video.uri, start);
    if (!mounted) {
      await backend.videoClose();
      return;
    }
    setState(() => texture = id);
    _poll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refresh(),
    );
    _refresh();
    _showControls();
  }

  Future<void> _refresh() async {
    try {
      final s = await backend.videoStatus();
      if (!mounted) return;
      setState(() => status = s);
      if (s.ended) setState(() => controls = true);
    } catch (_) {}
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    _hide?.cancel();
    final duration = status.durationMs;
    final pos = await backend.videoClose();
    await backend.resume.save(widget.video.uri, pos, duration);
  }

  @override
  void dispose() {
    _close();
    _focus.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _showControls() {
    setState(() => controls = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && status.playing) setState(() => controls = false);
    });
  }

  Future<void> _toggle() async {
    _showControls();
    await (status.playing ? backend.videoPause() : backend.videoPlay());
    await _refresh();
  }

  Future<void> _skip(int deltaMs) async {
    _showControls();
    final max = status.durationMs > 0 ? status.durationMs : 1 << 31;
    await backend.videoSeek((status.positionMs + deltaMs).clamp(0, max));
    await _refresh();
  }

  Future<void> _seek(int ms) async {
    _showControls();
    await backend.videoSeek(ms);
    await _refresh();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    // Hidden controls: the D-pad drives playback directly.
    if (!controls || k == LogicalKeyboardKey.mediaPlayPause) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        _skip(-10000);
      } else if (k == LogicalKeyboardKey.arrowRight) {
        _skip(10000);
      } else if (k == LogicalKeyboardKey.gameButtonA ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.space ||
          k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.mediaPlayPause) {
        _toggle();
      } else if (k == LogicalKeyboardKey.gameButtonB ||
          k == LogicalKeyboardKey.escape ||
          k == LogicalKeyboardKey.goBack) {
        return KeyEventResult.ignored;
      } else {
        _showControls();
      }
      return KeyEventResult.handled;
    }
    _showControls();
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final id = texture;
    final aspect = status.width > 0 && status.height > 0
        ? status.width / status.height
        : 16 / 9;
    final frame = id == null
        ? const SizedBox()
        : (widget.textureBuilder?.call(id) ?? Texture(textureId: id));
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _key,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              controls ? setState(() => controls = false) : _showControls(),
          onDoubleTapDown: (d) => _skip(
            d.localPosition.dx < MediaQuery.sizeOf(context).width / 2
                ? -10000
                : 10000,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(aspectRatio: aspect, child: frame),
              ),
              // Shown and hidden in one frame (no fades).
              IgnorePointer(
                ignoring: !controls,
                child: Opacity(opacity: controls ? 1 : 0, child: _overlay()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overlay() {
    final t = BrutalTokens.of(context);
    final playing = status.playing;
    final pad = t.density == BrutalDensity.handheld
        ? BrutalTokens.s2
        : BrutalTokens.s3;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BrutalPanel(
              padding: const EdgeInsets.all(BrutalTokens.s1),
              child: Row(
                children: [
                  MediaKey(
                    icon: DenaIcons.arrowBack,
                    tooltip: 'Back',
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const SizedBox(width: BrutalTokens.s2),
                  Expanded(
                    child: Text(
                      BrutalTokens.fileName(widget.video.title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.title,
                    ),
                  ),
                  Text(
                    status.ended
                        ? '[END]'
                        : playing
                        ? '[PLAY]'
                        : '[PAUSE]',
                    style: t.label,
                  ),
                  const SizedBox(width: BrutalTokens.s2),
                ],
              ),
            ),
            const Spacer(),
            FocusTraversalGroup(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  MediaKey(
                    icon: DenaIcons.rewind10,
                    tooltip: 'Back 10 seconds',
                    onPressed: () => _skip(-10000),
                  ),
                  const SizedBox(width: BrutalTokens.s6),
                  MediaKey(
                    icon: status.ended
                        ? DenaIcons.replay
                        : playing
                        ? DenaIcons.pause
                        : DenaIcons.play,
                    tooltip: playing ? 'Pause' : 'Play',
                    size: 64,
                    primary: true,
                    autofocus: true,
                    onPressed: _toggle,
                  ),
                  const SizedBox(width: BrutalTokens.s6),
                  MediaKey(
                    icon: DenaIcons.forward10,
                    tooltip: 'Forward 10 seconds',
                    onPressed: () => _skip(10000),
                  ),
                ],
              ),
            ),
            const Spacer(),
            BrutalPanel(
              padding: const EdgeInsets.all(BrutalTokens.s1),
              child: MediaSeekBar(
                positionMs: status.positionMs,
                durationMs: status.durationMs,
                onSeek: _seek,
                format: formatDuration,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
