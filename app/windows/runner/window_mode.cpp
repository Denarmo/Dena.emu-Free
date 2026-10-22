#include "window_mode.h"

#include <cstdio>

namespace {

std::wstring Wide(const std::string& utf8) {
  const int n = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  std::wstring out(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1) {
    ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), n);
  }
  return out;
}

}  // namespace

void WindowMode::SetFullscreen(bool on) {
  if (on == fullscreen_) return;
  const LONG_PTR style = ::GetWindowLongPtr(window_, GWL_STYLE);
  if (on) {
    MONITORINFO monitor = {sizeof(monitor)};
    if (!::GetWindowPlacement(window_, &before_) ||
        !::GetMonitorInfo(
            ::MonitorFromWindow(window_, MONITOR_DEFAULTTOPRIMARY), &monitor)) {
      return;
    }
    ::SetWindowLongPtr(window_, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
    const RECT& r = monitor.rcMonitor;
    ::SetWindowPos(window_, HWND_TOP, r.left, r.top, r.right - r.left,
                   r.bottom - r.top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    ::SetWindowLongPtr(window_, GWL_STYLE, style | WS_OVERLAPPEDWINDOW);
    ::SetWindowPlacement(window_, &before_);
    ::SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                       SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
  fullscreen_ = on;
}

bool WindowMode::HandleKey(const MSG& msg) {
  if (msg.message != WM_KEYDOWN && msg.message != WM_SYSKEYDOWN) return false;
  if ((msg.lParam & (1 << 30)) != 0) {
    // Auto-repeat of a toggle key: swallow it, never toggle twice.
    return msg.wParam == VK_F11 ||
           (msg.message == WM_SYSKEYDOWN && msg.wParam == VK_RETURN);
  }
  // Alt+Enter arrives as WM_SYSKEYDOWN (Alt held).
  const bool alt_enter =
      msg.message == WM_SYSKEYDOWN && msg.wParam == VK_RETURN;
  if (msg.wParam != VK_F11 && !alt_enter) return false;
  Toggle();
  return true;
}

WINDOWPLACEMENT WindowMode::NormalPlacement() const {
  WINDOWPLACEMENT p = {sizeof(p)};
  if (fullscreen_) return before_;
  ::GetWindowPlacement(window_, &p);
  return p;
}

void WindowMode::Restore(const std::string& path) {
  path_ = Wide(path);
  FILE* f = _wfopen(path_.c_str(), L"rb");
  if (!f) return;
  long x = 0, y = 0, w = 0, h = 0;
  const int n = std::fscanf(f, "%ld %ld %ld %ld", &x, &y, &w, &h);
  std::fclose(f);
  if (n != 4 || w < 320 || h < 240) return;
  RECT r = {x, y, x + w, y + h};
  // A monitor that is gone (or moved) keeps the default position.
  if (!::MonitorFromRect(&r, MONITOR_DEFAULTTONULL)) return;
  WINDOWPLACEMENT p = {sizeof(p)};
  ::GetWindowPlacement(window_, &p);
  p.rcNormalPosition = r;
  // Still hidden until the first frame: keep it hidden.
  p.showCmd = ::IsWindowVisible(window_) ? SW_SHOWNORMAL : SW_HIDE;
  ::SetWindowPlacement(window_, &p);
}

void WindowMode::Save() const {
  if (path_.empty()) return;
  const WINDOWPLACEMENT p = NormalPlacement();
  const RECT& r = p.rcNormalPosition;
  FILE* f = _wfopen(path_.c_str(), L"wb");
  if (!f) return;
  std::fprintf(f, "%ld %ld %ld %ld\n", r.left, r.top, r.right - r.left,
               r.bottom - r.top);
  std::fclose(f);
}
