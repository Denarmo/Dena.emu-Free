// Pigeon definition for the game-session lifecycle API (not the hot path:
// input and frames never cross this channel). Spec: docs/specs/game-session.md
// Regenerate: dart run pigeon --input pigeons/game_api.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/game_api.g.dart',
    kotlinOut: 'android/src/main/kotlin/app/dena/dena_android/GameApi.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'app.dena.dena_android',
      errorClassName: 'GameApiError',
    ),
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
/// How a session started (game-session.md, Lifecycle).
enum StartOutcome { fresh, resumed, badState }

class StartResult {
  StartResult({this.outcome, this.error});

  /// Null when the start failed; see [error].
  StartOutcome? outcome;
  String? error;
}

@HostApi()
abstract class GameHostApi {
  /// Loads [coreLibrary] with [romPath]. Loads the battery save from [srmPath]
  /// and resumes from [statePath] when those files exist.
  StartResult start(
    String coreLibrary,
    String romPath,
    String srmPath,
    String statePath,
  );

  /// Stops frames and audio and writes the battery save and auto-save state.
  void pause();

  void resume();

  /// Fast-forward: 1 is normal speed, up to 8.
  void setSpeed(int speed);

  /// Audio buffer target in ms (20-80), applied at the next start (performance.md).
  void setAudioLatency(int ms);

  /// Rewind (docs/specs/rewind.md): capture states; L2 held rewinds.
  void configureRewind(bool enabled, bool l2Hold);

  /// The game picture's aspect (width / height) for an external display
  /// (external-display.md).
  void setDisplayAspect(double aspect);

  /// Gamepad sticks drive the game's analog input instead of the D-pad.
  void setAnalogMode(bool on);

  /// Plays backwards while on (pause-menu tile, session overlay).
  void setRewinding(bool on);

  /// Writes the battery save and auto-save state without pausing.
  void saveNow();

  /// Writes a save state to [statePath] and the current frame to [pngPath].
  /// Returns an error message, or null on success (save-states.md).
  String? saveState(String statePath, String pngPath);

  /// Loads the save state at [statePath]. Returns an error message, or null.
  String? loadState(String statePath);

  /// Replaces the active cheats; each entry is one cheat's codes joined by
  /// '+' (cheats.md).
  void setCheats(List<String> codes);

  /// While on, the next gamepad or keyboard press reports
  /// [GameEventsApi.onGamepadUsed] once and turns this off (skins.md,
  /// last input wins).
  void setTouchMode(bool on);

  /// Draws the game through the bundled shader [id] (shaders.md); "" is Off.
  /// May be called before [start]. Returns an error message, or null.
  String? setShader(String id);

  /// Internal resolution for the next [start] (shaders.md, Upscale): 0 keeps
  /// the core's default, 2-4 (2-8 on the desktop, desktop-resolution.md)
  /// multiply the native size where the core can.
  void setUpscale(int factor);

  /// The core's 16:9 widescreen hack for the next [start]
  /// (desktop-resolution.md); cores without one ignore it.
  void setWidescreen(bool on);

  /// Saves the current frame to Pictures/Dena.emu as `<name>.png`
  /// (pause-menu.md). Returns an error message, or null.
  @async
  String? captureScreenshot(String name);

  /// Saves, then unloads the core.
  void stop();
}

/// Session events from the Android shell (gamepads.md). Main thread.
@FlutterApi()
abstract class GameEventsApi {
  /// Start + Select on a controller: open the pause menu.
  void onMenuRequested();

  /// Device names per port (four entries, empty for a free port).
  void onPlayersChanged(List<String> names);

  /// A controller or keyboard was used while touch mode was on: hide the skin.
  void onGamepadUsed();

  /// The game picture moved to the external display [name], or back to the
  /// phone when null (external-display.md).
  void onExternalDisplayChanged(String? name);

  /// The controller on [port] (0-3) disconnected; the game should pause.
  void onControllerDisconnected(int port, String name);
}
