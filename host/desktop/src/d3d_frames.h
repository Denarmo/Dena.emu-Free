// SPDX-License-Identifier: GPL-3.0-or-later
// Windows: game frames reach Flutter as D3D11 textures with DXGI shared
// handles (GpuSurfaceTexture), three of them triple-buffered. Software
// frames are uploaded; GPU frames are blitted from the core's GL framebuffer
// into the texture through WGL_NV_DX_interop2, else read back and uploaded.
// Also waits for the vblank of the monitor the window is on (DXGI).
// Spec: docs/specs/desktop-shell.md
#ifndef DENA_D3D_FRAMES_H
#define DENA_D3D_FRAMES_H
#ifdef _WIN32

#include <d3d11.h>
#include <dxgi.h>

#include <cstdint>
#include <vector>

#include "gl_desktop.h"
#include "slot_mailbox.h"

namespace dena {

class D3dFrames {
 public:
  D3dFrames() = default;
  ~D3dFrames();
  D3dFrames(const D3dFrames &) = delete;
  D3dFrames &operator=(const D3dFrames &) = delete;

  // Creates the device on the default adapter (the one Flutter's ANGLE uses).
  bool init();
  bool ready() const { return dev_ != nullptr; }

  // Emulator thread: a 0x00RRGGBB frame into the next texture.
  bool put_pixels(const uint32_t *xrgb, unsigned w, unsigned h);
  // Emulator thread, gl's context current: opens the interop device. False
  // when the driver lacks WGL_NV_DX_interop2 (frames then go through
  // read_pixels and put_pixels).
  bool attach_gl(DesktopGl *gl);
  bool gl_attached() const { return gl_ != nullptr; }
  // Emulator thread: the core's w x h frame into the next texture, or the
  // framebuffer `src` of gl's context (0: the core's).
  bool put_gl(unsigned w, unsigned h, bool bottom_left, GLuint src = 0);
  // Emulator thread, before the GL context goes away.
  void detach_gl();

  // Raster thread: the newest frame's shared handle, null before the first.
  HANDLE take(uint32_t *w, uint32_t *h);
  // Forget the frames shown so far (a new game).
  void clear() { slots_.clear(); }

  // Emulator thread: blocks until the next vblank of the monitor `window`
  // is on and returns true, or false at once when DXGI can't tell.
  bool wait_vblank(HWND window);

 private:
  struct Slot {
    ID3D11Texture2D *tex = nullptr;
    HANDLE share = nullptr;
    uint32_t w = 0, h = 0;
    GLuint gl_tex = 0, gl_fbo = 0;
    HANDLE gl_obj = nullptr;
  };
  bool ensure_slot(Slot &s, unsigned w, unsigned h);
  void release_gl(Slot &s);
  void publish();

  ID3D11Device *dev_ = nullptr;
  ID3D11DeviceContext *ctx_ = nullptr;
  Slot slot_[3];
  SlotMailbox slots_;
  std::vector<uint32_t> scratch_;

  DesktopGl *gl_ = nullptr;
  HANDLE interop_ = nullptr;

  IDXGIOutput *output_ = nullptr;
  HMONITOR output_monitor_ = nullptr;
  unsigned output_checks_ = 0;
};

}  // namespace dena

#endif
#endif
