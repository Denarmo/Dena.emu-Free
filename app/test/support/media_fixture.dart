// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:dena_emu/src/media/media_backend.dart';

MediaEntry track(
  String title, {
  String artist = 'Chip Ensemble',
  String album = 'Square Waves',
  int seconds = 200,
}) => MediaEntry(
  uri: 'content://media/external/audio/media/${title.hashCode.abs()}',
  title: title,
  artist: artist,
  album: album,
  folder: '',
  durationMs: seconds * 1000,
);

MediaEntry clip(String title, {String folder = 'Camera', int seconds = 95}) =>
    MediaEntry(
      uri: 'content://media/external/video/media/${title.hashCode.abs()}',
      title: title,
      artist: '',
      album: '',
      folder: folder,
      durationMs: seconds * 1000,
    );

/// In-memory [MediaBackend] that records calls.
class FakeMediaBackend implements MediaBackend {
  FakeMediaBackend({
    this.songs = const [],
    this.videos = const [],
    this.granted = true,
  });

  List<MediaEntry> songs;
  List<MediaEntry> videos;
  bool granted;
  final calls = <String>[];
  List<MediaEntry> queue = const [];
  MusicStatus music = MusicStatus(
    playing: false,
    index: -1,
    positionMs: 0,
    durationMs: 0,
    shuffle: false,
    repeat: 0,
  );
  VideoStatus video = VideoStatus(
    playing: false,
    ended: false,
    positionMs: 0,
    durationMs: 0,
    width: 1920,
    height: 1080,
  );
  int? openedAt;

  @override
  final MemoryResumeStore resume = MemoryResumeStore();

  MusicStatus _music({
    bool? playing,
    int? index,
    int? positionMs,
    bool? shuffle,
    int? repeat,
  }) {
    final i = index ?? music.index;
    return music = MusicStatus(
      playing: playing ?? music.playing,
      index: i,
      positionMs: positionMs ?? music.positionMs,
      durationMs: i >= 0 && i < queue.length ? queue[i].durationMs : 0,
      shuffle: shuffle ?? music.shuffle,
      repeat: repeat ?? music.repeat,
    );
  }

  @override
  Future<bool> requestAccess({required bool video}) async {
    calls.add('requestAccess($video)');
    return granted;
  }

  @override
  Future<List<MediaEntry>> list({required bool video}) async =>
      video ? videos : songs;

  @override
  Future<Uint8List?> thumbnail(String uri, int size) async => null;

  @override
  Future<void> playQueue(List<MediaEntry> queue, int index) async {
    calls.add('playQueue($index)');
    this.queue = queue;
    _music(playing: true, index: index, positionMs: 0);
  }

  @override
  Future<void> musicPlay() async {
    calls.add('play');
    _music(playing: true);
  }

  @override
  Future<void> musicPause() async {
    calls.add('pause');
    _music(playing: false);
  }

  @override
  Future<void> musicNext() async {
    calls.add('next');
    if (music.index + 1 < queue.length) _music(index: music.index + 1);
  }

  @override
  Future<void> musicPrevious() async {
    calls.add('previous');
    if (music.index > 0) _music(index: music.index - 1);
  }

  @override
  Future<void> musicSeek(int positionMs) async {
    calls.add('seek($positionMs)');
    _music(positionMs: positionMs);
  }

  @override
  Future<void> musicSkipTo(int index) async => _music(index: index);

  @override
  Future<void> setShuffle(bool on) async {
    calls.add('shuffle($on)');
    _music(shuffle: on);
  }

  @override
  Future<void> setRepeat(int mode) async {
    calls.add('repeat($mode)');
    _music(repeat: mode);
  }

  @override
  Future<MusicStatus> musicStatus() async => music;

  VideoStatus _video({bool? playing, int? positionMs, int? durationMs}) =>
      video = VideoStatus(
        playing: playing ?? video.playing,
        ended: false,
        positionMs: positionMs ?? video.positionMs,
        durationMs: durationMs ?? video.durationMs,
        width: video.width,
        height: video.height,
      );

  @override
  Future<int> videoOpen(String uri, int startMs) async {
    calls.add('videoOpen($startMs)');
    openedAt = startMs;
    final v = videos.firstWhere((v) => v.uri == uri, orElse: () => clip('x'));
    _video(playing: true, positionMs: startMs, durationMs: v.durationMs);
    return 7;
  }

  @override
  Future<void> videoPlay() async {
    calls.add('videoPlay');
    _video(playing: true);
  }

  @override
  Future<void> videoPause() async {
    calls.add('videoPause');
    _video(playing: false);
  }

  @override
  Future<void> videoSeek(int positionMs) async {
    calls.add('videoSeek($positionMs)');
    _video(positionMs: positionMs);
  }

  @override
  Future<VideoStatus> videoStatus() async => video;

  @override
  Future<int> videoClose() async {
    calls.add('videoClose');
    return video.positionMs;
  }
}
