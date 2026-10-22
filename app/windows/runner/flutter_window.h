#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/texture_registrar.h>

#include <memory>
#include <set>

#include "dena/desktop_loader.h"
#include "win32_window.h"
#include "window_mode.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Marks the window of the running instance; a second launch sends it the
  // game file as WM_COPYDATA with kOpenFileMessage (docs/specs/open-with.md).
  static constexpr wchar_t kInstanceProp[] = L"DenaEmu.Instance";
  static constexpr ULONG_PTR kOpenFileMessage = 0x44454E41;  // "DENA"

  // A key message from the message loop: true when a game took it, so it
  // must not reach Flutter (docs/specs/desktop-shell.md, Keyboard).
  bool HandleGameKey(const MSG& msg);

  // F11 or Alt+Enter toggles fullscreen, also during a game.
  bool HandleWindowKey(const MSG& msg) {
    return window_mode_ && window_mode_->HandleKey(msg);
  }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Loads dena_host.dll beside the executable and connects it: the game
  // texture, the GameHostApi channels and the events back to Dart.
  void StartDenaHost();
  void StopDenaHost();
  // The "dena/window" channel (docs/specs/controller-mode.md, Window).
  void StartWindowChannel();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The desktop host library (games); empty when it is not installed.
  dena::DesktopHost dena_;
  flutter::TextureRegistrar* registrar_ = nullptr;
  std::unique_ptr<flutter::TextureVariant> game_texture_;
  int64_t game_texture_id_ = -1;
  FlutterDesktopGpuSurfaceDescriptor surface_ = {};  // raster thread
  std::set<int> taken_keys_;
  // Sleep and wake messages on Modern Standby PCs too (deck-presets.md).
  HPOWERNOTIFY sleep_notify_ = nullptr;

  std::unique_ptr<WindowMode> window_mode_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
