// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/media-players.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dena_android/dena_android.dart';
import 'package:flutter/foundation.dart';

import '../shell/app_dirs.dart';

export 'package:dena_android/dena_android.dart'
    show MediaEntry, MusicStatus, VideoStatus;

/// Device media access and playback, backed by MediaStore + Media3 on
/// Android. Tests and screenshots swap in a fake via [MediaBackend.instance].
abstract class MediaBackend {
  static MediaBackend instance = AndroidMediaBackend();

  Future<bool> requestAccess({required bool video});
  Future<List<MediaEntry>> list({required bool video});
  Future<Uint8List?> thumbnail(String uri, int size);

  Future<void> playQueue(List<MediaEntry> queue, int index);
  Future<void> musicPlay();
  Future<void> musicPause();
  Future<void> musicNext();
  Future<void> musicPrevious();
  Future<void> musicSeek(int positionMs);
  Future<void> musicSkipTo(int index);
  Future<void> setShuffle(bool on);
  Future<void> setRepeat(int mode);
  Future<MusicStatus> musicStatus();

  Future<int> videoOpen(String uri, int startMs);
  Future<void> videoPlay();
  Future<void> videoPause();
  Future<void> videoSeek(int positionMs);
  Future<VideoStatus> videoStatus();
  Future<int> videoClose();

  /// Where video resume positions are kept.
  ResumeStore get resume;
}

class AndroidMediaBackend implements MediaBackend {
  AndroidMediaBackend([MediaHostApi? api]) : _api = api ?? MediaHostApi();

  final MediaHostApi _api;

  @override
  late final ResumeStore resume = FileResumeStore();

  @override
  Future<bool> requestAccess({required bool video}) =>
      _api.requestAccess(video);
  @override
  Future<List<MediaEntry>> list({required bool video}) => _api.list(video);
  @override
  Future<Uint8List?> thumbnail(String uri, int size) =>
      _api.thumbnail(uri, size);
  @override
  Future<void> playQueue(List<MediaEntry> queue, int index) =>
      _api.playQueue(queue, index);
  @override
  Future<void> musicPlay() => _api.musicPlay();
  @override
  Future<void> musicPause() => _api.musicPause();
  @override
  Future<void> musicNext() => _api.musicNext();
  @override
  Future<void> musicPrevious() => _api.musicPrevious();
  @override
  Future<void> musicSeek(int positionMs) => _api.musicSeek(positionMs);
  @override
  Future<void> musicSkipTo(int index) => _api.musicSkipTo(index);
  @override
  Future<void> setShuffle(bool on) => _api.setShuffle(on);
  @override
  Future<void> setRepeat(int mode) => _api.setRepeat(mode);
  @override
  Future<MusicStatus> musicStatus() => _api.musicStatus();
  @override
  Future<int> videoOpen(String uri, int startMs) =>
      _api.videoOpen(uri, startMs);
  @override
  Future<void> videoPlay() => _api.videoPlay();
  @override
  Future<void> videoPause() => _api.videoPause();
  @override
  Future<void> videoSeek(int positionMs) => _api.videoSeek(positionMs);
  @override
  Future<VideoStatus> videoStatus() => _api.videoStatus();
  @override
  Future<int> videoClose() => _api.videoClose();
}

/// Last watched position per video URI.
abstract class ResumeStore {
  Future<int> positionOf(String uri);
  Future<void> save(String uri, int positionMs, int durationMs);
}

/// Positions under 5 s, or within 5 s of the end, are forgotten: the video
/// starts over next time.
int? resumePoint(int positionMs, int durationMs) {
  if (positionMs < 5000) return null;
  if (durationMs > 0 && positionMs > durationMs - 5000) return null;
  return positionMs;
}

class MemoryResumeStore implements ResumeStore {
  final positions = <String, int>{};

  @override
  Future<int> positionOf(String uri) async => positions[uri] ?? 0;

  @override
  Future<void> save(String uri, int positionMs, int durationMs) async {
    final p = resumePoint(positionMs, durationMs);
    if (p == null) {
      positions.remove(uri);
    } else {
      positions[uri] = p;
    }
  }
}

/// JSON map in the app support directory (`video_resume.json`).
class FileResumeStore extends MemoryResumeStore {
  FileResumeStore([this._dir]);

  final Directory? _dir;
  Future<File>? _file;

  Future<File> _open() => _file ??= () async {
    final dir = _dir ?? await appDataDir();
    final f = File('${dir.path}/video_resume.json');
    try {
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      positions.addAll(map.map((k, v) => MapEntry(k, (v as num).toInt())));
    } catch (_) {}
    return f;
  }();

  @override
  Future<int> positionOf(String uri) async {
    await _open();
    return super.positionOf(uri);
  }

  @override
  Future<void> save(String uri, int positionMs, int durationMs) async {
    final f = await _open();
    await super.save(uri, positionMs, durationMs);
    await f.writeAsString(jsonEncode(positions));
  }
}

/// `m:ss`, or `h:mm:ss` from an hour.
String formatDuration(int ms) {
  final s = (ms ~/ 1000).clamp(0, 1 << 31);
  final h = s ~/ 3600, m = (s ~/ 60) % 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// Cached thumbnails, keyed by URI.
class ThumbnailCache {
  ThumbnailCache(this.backend);

  final MediaBackend backend;
  final _cache = <String, Future<Uint8List?>>{};

  Future<Uint8List?> of(String uri, {int size = 256}) =>
      _cache[uri] ??= backend.thumbnail(uri, size).catchError((_) => null);
}

/// Music queue and status shared by every Music screen: playback outlives
/// the screen (it runs in the background service).
class MusicController extends ChangeNotifier {
  MusicController(this.backend);

  static MusicController? _shared;
  static MusicController of(MediaBackend backend) {
    if (_shared?.backend != backend) _shared = MusicController(backend);
    return _shared!;
  }

  final MediaBackend backend;
  List<MediaEntry> queue = const [];
  MusicStatus status = MusicStatus(
    playing: false,
    index: -1,
    positionMs: 0,
    durationMs: 0,
    shuffle: false,
    repeat: 0,
  );
  Timer? _timer;
  int _listeners = 0;

  MediaEntry? get current => status.index >= 0 && status.index < queue.length
      ? queue[status.index]
      : null;

  /// Polls the player while a screen is showing it.
  void attach() {
    if (_listeners++ == 0) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => refresh(),
      );
      refresh();
    }
  }

  void detach() {
    if (--_listeners == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> refresh() async {
    try {
      status = await backend.musicStatus();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _then(Future<void> f) async {
    await f;
    await refresh();
  }

  Future<void> play(List<MediaEntry> tracks, int index) {
    queue = List.unmodifiable(tracks);
    status = MusicStatus(
      playing: true,
      index: index,
      positionMs: 0,
      durationMs: tracks[index].durationMs,
      shuffle: status.shuffle,
      repeat: status.repeat,
    );
    notifyListeners();
    return _then(backend.playQueue(tracks, index));
  }

  Future<void> toggle() =>
      _then(status.playing ? backend.musicPause() : backend.musicPlay());
  Future<void> next() => _then(backend.musicNext());
  Future<void> previous() => _then(backend.musicPrevious());
  Future<void> seek(int ms) => _then(backend.musicSeek(ms));
  Future<void> toggleShuffle() => _then(backend.setShuffle(!status.shuffle));

  /// Off → all → one → off.
  Future<void> cycleRepeat() =>
      _then(backend.setRepeat(const [2, 0, 1][status.repeat.clamp(0, 2)]));
}
