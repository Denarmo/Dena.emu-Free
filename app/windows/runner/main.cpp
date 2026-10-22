#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// One instance (docs/specs/open-with.md): a second launch hands its game
// file to the running window and exits.
constexpr wchar_t kInstanceMutex[] = L"Local\\io.github.denarmo.DenaEmu";

// The first argument that is not a flag: the game file to open, if any.
const wchar_t* GameArgument(int argc, wchar_t** argv) {
  for (int i = 1; i < argc; i++) {
    if (argv[i][0] != L'-') return argv[i];
  }
  return nullptr;
}

// The running instance's window: the one carrying FlutterWindow's property.
BOOL CALLBACK FindInstance(HWND hwnd, LPARAM found) {
  if (::GetPropW(hwnd, FlutterWindow::kInstanceProp) == nullptr) return TRUE;
  *reinterpret_cast<HWND*>(found) = hwnd;
  return FALSE;
}

// Sends the file to the running instance's window and raises it. False when
// that window can't be found (the other instance is still starting or gone).
bool ForwardToRunningInstance() {
  HWND other = nullptr;
  // The first instance may still be creating its window.
  for (int tries = 0; tries < 20 && other == nullptr; tries++) {
    ::EnumWindows(FindInstance, reinterpret_cast<LPARAM>(&other));
    if (other == nullptr) ::Sleep(100);
  }
  if (other == nullptr) return false;
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  const wchar_t* file = argv ? GameArgument(argc, argv) : nullptr;
  if (file != nullptr) {
    wchar_t full[MAX_PATH * 4];
    const DWORD n = ::GetFullPathNameW(file, MAX_PATH * 4, full, nullptr);
    const std::wstring path = n > 0 && n < MAX_PATH * 4 ? full : file;
    COPYDATASTRUCT data = {};
    data.dwData = FlutterWindow::kOpenFileMessage;
    data.cbData = static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t));
    data.lpData = const_cast<wchar_t*>(path.c_str());
    ::SendMessageW(other, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data));
  }
  if (argv) ::LocalFree(argv);
  if (::IsIconic(other)) ::ShowWindow(other, SW_RESTORE);
  ::SetForegroundWindow(other);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  HANDLE instance_mutex = ::CreateMutexW(nullptr, FALSE, kInstanceMutex);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS &&
      ForwardToRunningInstance()) {
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Dena.emu", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    // Keys go to the focused Flutter child window, so a playing game takes
    // its keys here, before Flutter sees them (docs/specs/desktop-shell.md).
    if (window.HandleWindowKey(msg)) continue;
    if (window.HandleGameKey(msg)) continue;
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) ::CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
