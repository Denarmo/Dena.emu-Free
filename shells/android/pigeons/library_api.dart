// Pigeon definition for the library's Android file access (SAF).
// Spec: docs/specs/library.md (Import)
// Regenerate: dart run pigeon --input pigeons/library_api.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/library_api.g.dart',
    kotlinOut: 'android/src/main/kotlin/app/dena/dena_android/LibraryApi.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'app.dena.dena_android',
      errorClassName: 'LibraryFlutterError',
    ),
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
@HostApi()
abstract class LibraryHostApi {
  /// Opens the system picker for one or more files and copies each picked file
  /// into the app's cache. Returns the cached paths (empty if cancelled).
  @async
  List<String> pickFiles();

  /// Opens the system folder picker, walks the folder recursively and copies
  /// every file whose lower-cased name ends with one of [extensions] into the
  /// app's cache. Returns the cached paths (empty if cancelled).
  @async
  List<String> pickFolder(List<String> extensions);

  /// Whether the app may read shared storage directly (file-explorer.md):
  /// All files access from Android 11, READ_EXTERNAL_STORAGE before.
  bool hasStorageAccess();

  /// Asks for that access (the All files access settings page from Android
  /// 11, the permission dialog before) and returns whether it was granted.
  @async
  bool requestStorageAccess();

  /// Files shared to the app (share sheet / Quick Share) since the last call,
  /// already copied into the cache.
  List<String> takeSharedFiles();

  /// The SHA-1 of the newest `dena://play/<sha1>` link the app was opened
  /// with since the last call, or null (shortcuts.md).
  String? takeLaunchLink();

  /// Asks the launcher to pin a home-screen shortcut for the game. False when
  /// the launcher can't pin. [iconPath] is a PNG/JPEG cover, or null.
  bool pinShortcut(String sha1, String title, String? iconPath);

  /// The game started: make it the first recent-game shortcut.
  void reportPlayed(String sha1, String title, String? iconPath);

  /// The game was deleted: remove or disable its shortcuts.
  void removeShortcut(String sha1);

  /// Deletes the cache copies made by the calls above.
  void clearImportCache();

  /// Renders page 1 of the PDF at [pdfPath] to a PNG of [width]×[height]
  /// pixels at [outPng] (skin artwork, skins.md). Returns [outPng], or null if
  /// the PDF cannot be read.
  @async
  String? rasterizePdf(String pdfPath, int width, int height, String outPng);
}
