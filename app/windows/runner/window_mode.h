// Borderless fullscreen and the remembered window position for the
// "dena/window" channel (docs/specs/controller-mode.md, Window).
#ifndef RUNNER_WINDOW_MODE_H_
#define RUNNER_WINDOW_MODE_H_

#include <windows.h>

#include <string>

class WindowMode {
 public:
  explicit WindowMode(HWND window) : window_(window) {}

  bool fullscreen() const { return fullscreen_; }
  // Borderless, covering the monitor the window is on (no mode switch).
  void SetFullscreen(bool on);
  void Toggle() { SetFullscreen(!fullscreen_); }

  // F11 or Alt+Enter, from the message loop: toggles and returns true.
  bool HandleKey(const MSG& msg);

  // Moves the window to the place saved in |path| (UTF-8) if that is still
  // on a monitor, and saves it there when the window closes.
  void Restore(const std::string& path);
  void Save() const;

 private:
  WINDOWPLACEMENT NormalPlacement() const;

  HWND window_;
  bool fullscreen_ = false;
  WINDOWPLACEMENT before_{sizeof(WINDOWPLACEMENT)};
  std::wstring path_;
};

#endif  // RUNNER_WINDOW_MODE_H_
