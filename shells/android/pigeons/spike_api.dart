// Pigeon definition for the latency-spike lifecycle API (not the hot path:
// input and frames never cross this channel). Spec: docs/specs/latency-spike.md
// Regenerate: dart run pigeon --input pigeons/spike_api.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/spike_api.g.dart',
    kotlinOut: 'android/src/main/kotlin/app/dena/dena_android/SpikeApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.dena.dena_android'),
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
@HostApi()
abstract class SpikeHostApi {
  /// Starts mGBA on [romPath], or on the bundled latency test ROM when null.
  /// Returns an error message, or null on success.
  String? start(String? romPath);

  /// Stops the core and releases the surface.
  void stop();

  /// Creates a Flutter texture backed by a native surface and routes the
  /// emulator's frames into it. Returns the texture id.
  int attachTexture(int width, int height);

  /// Detaches and releases the texture created by [attachTexture].
  void detachTexture();

  /// Latest metrics as JSON (see the spec's Software metrics section).
  String metrics();

  /// Pixel of the last core frame as 0xRRGGBB, or -1 when out of range.
  int pixel(int x, int y);

  /// Test hook: sends a key event through the Activity's dispatchKeyEvent,
  /// i.e. the same path a real gamepad takes inside the app.
  void debugDispatchKey(int keyCode, bool down);
}
