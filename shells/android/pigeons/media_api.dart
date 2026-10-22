// Pigeon definition for the music and video players (MediaStore + Media3).
// Spec: docs/specs/media-players.md
// Regenerate: dart run pigeon --input pigeons/media_api.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/media_api.g.dart',
    kotlinOut: 'android/src/main/kotlin/app/dena/dena_android/MediaApi.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'app.dena.dena_android',
      errorClassName: 'MediaFlutterError',
    ),
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
/// One MediaStore audio or video file.
class MediaEntry {
  MediaEntry({
    required this.uri,
    required this.title,
    required this.artist,
    required this.album,
    required this.folder,
    required this.durationMs,
  });
  String uri;
  String title;
  String artist;
  String album;

  /// Bucket (folder) name; videos are grouped by it.
  String folder;
  int durationMs;
}

class MusicStatus {
  MusicStatus({
    required this.playing,
    required this.index,
    required this.positionMs,
    required this.durationMs,
    required this.shuffle,
    required this.repeat,
  });
  bool playing;

  /// Index into the queue last passed to playQueue, or -1 with no queue.
  int index;
  int positionMs;
  int durationMs;
  bool shuffle;

  /// 0 off, 1 one, 2 all (Media3 repeat modes).
  int repeat;
}

class VideoStatus {
  VideoStatus({
    required this.playing,
    required this.ended,
    required this.positionMs,
    required this.durationMs,
    required this.width,
    required this.height,
  });
  bool playing;
  bool ended;
  int positionMs;
  int durationMs;
  int width;
  int height;
}

@HostApi()
abstract class MediaHostApi {
  /// Asks for READ_MEDIA_AUDIO / READ_MEDIA_VIDEO (READ_EXTERNAL_STORAGE
  /// before Android 13). True when granted.
  @async
  bool requestAccess(bool video);

  /// Every audio (or video) file in MediaStore, sorted by title.
  @async
  List<MediaEntry> list(bool video);

  /// A JPEG thumbnail (album art / video frame) of at most [size] px, or null.
  @async
  Uint8List? thumbnail(String uri, int size);

  /// Replaces the background music queue and plays [index].
  void playQueue(List<MediaEntry> queue, int index);
  void musicPlay();
  void musicPause();
  void musicNext();
  void musicPrevious();
  void musicSeek(int positionMs);
  void musicSkipTo(int index);
  void setShuffle(bool on);
  void setRepeat(int mode);
  MusicStatus musicStatus();

  /// Opens [uri] into a new Flutter texture at [startMs] and plays it.
  /// Returns the texture id.
  int videoOpen(String uri, int startMs);
  void videoPlay();
  void videoPause();
  void videoSeek(int positionMs);
  VideoStatus videoStatus();

  /// Releases the player and texture; returns the last position.
  int videoClose();
}
