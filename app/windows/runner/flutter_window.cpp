#include "flutter_window.h"

#include <flutter/binary_messenger.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// A Pigeon message from the host library on its way to the platform thread.
constexpr UINT kDenaSendMessage = WM_APP + 0x44;
struct PendingMessage {
  std::string channel;
  std::vector<uint8_t> data;
};

// The folder of the running executable, UTF-8.
std::string ExecutableDir() {
  wchar_t path[MAX_PATH * 4];
  const DWORD n = ::GetModuleFileNameW(nullptr, path, MAX_PATH * 4);
  std::wstring dir(path, n);
  dir = dir.substr(0, dir.find_last_of(L"\\/"));
  const int len = ::WideCharToMultiByte(CP_UTF8, 0, dir.c_str(), -1, nullptr, 0,
                                        nullptr, nullptr);
  std::string out(len > 0 ? len - 1 : 0, '\0');
  if (len > 1) {
    ::WideCharToMultiByte(CP_UTF8, 0, dir.c_str(), -1, out.data(), len, nullptr,
                          nullptr);
  }
  return out;
}

// Windows virtual keys as the host library's keys (dena/desktop.h).
int DenaKey(const MSG& msg) {
  const int vk = static_cast<int>(msg.wParam);
  if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) return vk;
  switch (vk) {
    case VK_UP: return DENA_DESKTOP_KEY_UP;
    case VK_DOWN: return DENA_DESKTOP_KEY_DOWN;
    case VK_LEFT: return DENA_DESKTOP_KEY_LEFT;
    case VK_RIGHT: return DENA_DESKTOP_KEY_RIGHT;
    case VK_RETURN: return DENA_DESKTOP_KEY_ENTER;
    case VK_BACK: return DENA_DESKTOP_KEY_BACKSPACE;
    case VK_ESCAPE: return DENA_DESKTOP_KEY_ESCAPE;
    case VK_SPACE: return DENA_DESKTOP_KEY_SPACE;
    case VK_TAB: return DENA_DESKTOP_KEY_TAB;
    case VK_SHIFT: {
      // Only the right Shift is bound (Select); scan code 0x36.
      const UINT scan = (static_cast<UINT>(msg.lParam) >> 16) & 0xff;
      return scan == 0x36 ? DENA_DESKTOP_KEY_RSHIFT : 0;
    }
    default: return 0;
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  StartWindowChannel();
  ::SetPropW(GetHandle(), kInstanceProp, reinterpret_cast<HANDLE>(1));
  StartDenaHost();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::StartDenaHost() {
  if (!dena_.load(ExecutableDir() + "\\dena_host.dll")) {
    OutputDebugStringA("dena: dena_host.dll not loaded; games are unavailable\n");
    return;
  }
  flutter::FlutterEngine* engine = flutter_controller_->engine();
  // FlutterEngine has no texture registrar of its own: take it from a plugin
  // registrar for the runner, owned by the registrar manager.
  registrar_ = flutter::PluginRegistrarManager::GetInstance()
                   ->GetRegistrar<flutter::PluginRegistrarWindows>(
                       engine->GetRegistrarForPlugin("DenaHost"))
                   ->texture_registrar();
  // The game picture: a D3D11 shared texture the host fills (desktop-shell.md).
  game_texture_ = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [this](size_t, size_t) -> const FlutterDesktopGpuSurfaceDescriptor* {
            uint32_t w = 0, h = 0;
            void* handle = dena_.frame_d3d(&w, &h);
            if (!handle) return nullptr;
            surface_ = {};
            surface_.struct_size = sizeof(surface_);
            surface_.handle = handle;
            surface_.width = surface_.visible_width = w;
            surface_.height = surface_.visible_height = h;
            surface_.format = kFlutterDesktopPixelFormatBGRA8888;
            return &surface_;
          }));
  game_texture_id_ = registrar_->RegisterTexture(game_texture_.get());

  dena_desktop_config cfg = {};
  cfg.struct_size = sizeof(cfg);
  cfg.user = this;
  cfg.frame_ready = [](void* user) {
    auto* self = static_cast<FlutterWindow*>(user);
    self->registrar_->MarkTextureFrameAvailable(self->game_texture_id_);
  };
  cfg.send = [](void* user, const char* channel, const uint8_t* msg,
                size_t len) {
    auto* self = static_cast<FlutterWindow*>(user);
    auto* pending = new PendingMessage{channel, std::vector<uint8_t>(msg, msg + len)};
    if (!::PostMessage(self->GetHandle(), kDenaSendMessage, 0,
                       reinterpret_cast<LPARAM>(pending))) {
      delete pending;
    }
  };
  cfg.window = GetHandle();
  HDC dc = ::GetDC(GetHandle());
  cfg.refresh_mhz = ::GetDeviceCaps(dc, VREFRESH) * 1000;
  ::ReleaseDC(GetHandle(), dc);
  if (!dena_.init(&cfg)) {
    registrar_->UnregisterTexture(game_texture_id_);
    game_texture_.reset();
    dena_ = dena::DesktopHost();
    return;
  }
  dena_.set_texture(game_texture_id_);
  // PBT_APMSUSPEND / PBT_APMRESUME* below, also under Modern Standby.
  sleep_notify_ = ::RegisterSuspendResumeNotification(
      GetHandle(), DEVICE_NOTIFY_WINDOW_HANDLE);

  // GameHostApi: answered on the platform thread, as the Android shell does.
  flutter::BinaryMessenger* messenger = engine->messenger();
  std::string channels = dena_.channels();
  size_t start = 0;
  while (start < channels.size()) {
    size_t end = channels.find('\n', start);
    if (end == std::string::npos) end = channels.size();
    const std::string channel = channels.substr(start, end - start);
    messenger->SetMessageHandler(
        channel, [this, channel](const uint8_t* msg, size_t size,
                                 flutter::BinaryReply reply) {
          uint8_t* out = nullptr;
          size_t out_len = 0;
          if (dena_.loaded() &&
              dena_.message(channel.c_str(), msg, size, &out, &out_len)) {
            reply(out, out_len);
            dena_.free_reply(out);
          } else {
            reply(nullptr, 0);
          }
        });
    start = end + 1;
  }
}

void FlutterWindow::StartWindowChannel() {
  window_mode_ = std::make_unique<WindowMode>(GetHandle());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dena/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "setFullscreen") {
          const auto* on = std::get_if<bool>(call.arguments());
          if (!on) {
            result->Error("bad-args", "setFullscreen takes a bool");
            return;
          }
          window_mode_->SetFullscreen(*on);
          result->Success();
        } else if (method == "isFullscreen") {
          result->Success(flutter::EncodableValue(window_mode_->fullscreen()));
        } else if (method == "restorePlacement") {
          const auto* path = std::get_if<std::string>(call.arguments());
          if (!path) {
            result->Error("bad-args", "restorePlacement takes a path");
            return;
          }
          window_mode_->Restore(*path);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::StopDenaHost() {
  if (sleep_notify_) {
    ::UnregisterSuspendResumeNotification(sleep_notify_);
    sleep_notify_ = nullptr;
  }
  if (!dena_.loaded()) return;
  dena_.shutdown();  // the game saves; no more frames or messages after this
  if (registrar_) registrar_->UnregisterTexture(game_texture_id_);
  dena_ = dena::DesktopHost();
}

bool FlutterWindow::HandleGameKey(const MSG& msg) {
  if (!dena_.loaded()) return false;
  const bool down = msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN;
  const bool up = msg.message == WM_KEYUP || msg.message == WM_SYSKEYUP;
  if (!down && !up) return false;
  const int key = DenaKey(msg);
  if (key == 0) return false;
  // Auto-repeat follows whoever took the first press.
  const bool repeat = down && (msg.lParam & (1 << 30)) != 0;
  if (repeat) return taken_keys_.count(key) != 0;
  const bool taken = dena_.key(key, down);
  if (down && taken) taken_keys_.insert(key);
  if (up) taken_keys_.erase(key);
  return taken;
}

void FlutterWindow::OnDestroy() {
  ::RemovePropW(GetHandle(), kInstanceProp);
  if (window_mode_) window_mode_->Save();
  window_channel_ = nullptr;
  StopDenaHost();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kDenaSendMessage) {
    std::unique_ptr<PendingMessage> pending(
        reinterpret_cast<PendingMessage*>(lparam));
    if (flutter_controller_ && dena_.loaded()) {
      flutter_controller_->engine()->messenger()->Send(
          pending->channel, pending->data.data(), pending->data.size());
    }
    return 0;
  }

  // Sleep and wake (deck-presets.md): the game pauses and saves before the
  // PC sleeps (Windows allows about two seconds) and continues after.
  if (message == WM_POWERBROADCAST && dena_.loaded()) {
    if (wparam == PBT_APMSUSPEND) {
      if (dena_.suspend) dena_.suspend();
    } else if (wparam == PBT_APMRESUMEAUTOMATIC ||
               wparam == PBT_APMRESUMESUSPEND) {
      if (dena_.resume) dena_.resume();
    }
  }

  // A game file from a second launch (main.cpp): the library opens it.
  if (message == WM_COPYDATA) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (data != nullptr && data->dwData == kOpenFileMessage &&
        data->cbData >= sizeof(wchar_t) && window_channel_) {
      const std::wstring path(static_cast<const wchar_t*>(data->lpData),
                              data->cbData / sizeof(wchar_t) - 1);
      window_channel_->InvokeMethod(
          "openFile", std::make_unique<flutter::EncodableValue>(
                          Utf8FromUtf16(path.c_str())));
      return TRUE;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
