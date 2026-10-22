// SPDX-License-Identifier: GPL-3.0-or-later
// Loads the desktop host library at run time for the Flutter runners
// (app/windows/runner, app/linux/runner). The library is built by its own
// toolchain (MinGW-w64 on Windows), so the runners never link it; a build
// without it still opens the UI. Spec: docs/specs/desktop-shell.md
#ifndef DENA_DESKTOP_LOADER_H
#define DENA_DESKTOP_LOADER_H

#include <string>
#include <type_traits>

#include "dena/desktop.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace dena {

struct DesktopHost {
  decltype(&dena_desktop_init) init = nullptr;
  decltype(&dena_desktop_shutdown) shutdown = nullptr;
  decltype(&dena_desktop_channels) channels = nullptr;
  decltype(&dena_desktop_message) message = nullptr;
  decltype(&dena_desktop_free) free_reply = nullptr;
  decltype(&dena_desktop_key) key = nullptr;
  decltype(&dena_desktop_set_texture) set_texture = nullptr;
  decltype(&dena_desktop_set_refresh) set_refresh = nullptr;
  decltype(&dena_desktop_frame_rgba) frame_rgba = nullptr;
  decltype(&dena_desktop_frame_d3d) frame_d3d = nullptr;
  // Optional: sleep and wake (deck-presets.md); null in an older library.
  decltype(&dena_desktop_suspend) suspend = nullptr;
  decltype(&dena_desktop_resume) resume = nullptr;

  bool loaded() const { return init != nullptr; }

  // path: the library file. Returns false (and stays empty) when it is
  // missing or lacks an entry point.
  bool load(const std::string &path) {
#ifdef _WIN32
    HMODULE lib = LoadLibraryA(path.c_str());
    auto sym = [lib](const char *name) {
      return reinterpret_cast<void *>(GetProcAddress(lib, name));
    };
#else
    // RTLD_GLOBAL: dart:ffi opens the same file and must share its state.
    void *lib = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
    auto sym = [lib](const char *name) { return dlsym(lib, name); };
#endif
    if (!lib) return false;
    bool ok = true;
    auto get = [&](auto &fn, const char *name) {
      fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(sym(name));
      ok = ok && fn != nullptr;
    };
    get(init, "dena_desktop_init");
    get(shutdown, "dena_desktop_shutdown");
    get(channels, "dena_desktop_channels");
    get(message, "dena_desktop_message");
    get(free_reply, "dena_desktop_free");
    get(key, "dena_desktop_key");
    get(set_texture, "dena_desktop_set_texture");
    get(set_refresh, "dena_desktop_set_refresh");
    get(frame_rgba, "dena_desktop_frame_rgba");
    get(frame_d3d, "dena_desktop_frame_d3d");
    if (!ok) {
      *this = DesktopHost();
      return false;
    }
    suspend = reinterpret_cast<decltype(suspend)>(sym("dena_desktop_suspend"));
    resume = reinterpret_cast<decltype(resume)>(sym("dena_desktop_resume"));
    return ok;
  }
};

}  // namespace dena

#endif
