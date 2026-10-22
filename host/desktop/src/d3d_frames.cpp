// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/desktop-shell.md
#ifdef _WIN32
#include "d3d_frames.h"

#include <cstdio>

namespace dena {

namespace {

// WGL_NV_DX_interop / WGL_NV_DX_interop2.
constexpr GLenum WGL_ACCESS_WRITE_DISCARD_NV = 0x0002;
typedef HANDLE(WINAPI *DXOpenDevice)(void *);
typedef BOOL(WINAPI *DXCloseDevice)(HANDLE);
typedef HANDLE(WINAPI *DXRegisterObject)(HANDLE, void *, GLuint, GLenum, GLenum);
typedef BOOL(WINAPI *DXUnregisterObject)(HANDLE, HANDLE);
typedef BOOL(WINAPI *DXLockObjects)(HANDLE, GLint, HANDLE *);
typedef BOOL(WINAPI *DXSetResourceShareHandle)(void *, HANDLE);

struct Interop {
  DXOpenDevice open = nullptr;
  DXCloseDevice close = nullptr;
  DXRegisterObject reg = nullptr;
  DXUnregisterObject unreg = nullptr;
  DXLockObjects lock = nullptr, unlock = nullptr;
  DXSetResourceShareHandle share = nullptr;

  bool load() {
    auto p = [](const char *s) { return DesktopGl::proc_address(s); };
    open = reinterpret_cast<DXOpenDevice>(p("wglDXOpenDeviceNV"));
    close = reinterpret_cast<DXCloseDevice>(p("wglDXCloseDeviceNV"));
    reg = reinterpret_cast<DXRegisterObject>(p("wglDXRegisterObjectNV"));
    unreg = reinterpret_cast<DXUnregisterObject>(p("wglDXUnregisterObjectNV"));
    lock = reinterpret_cast<DXLockObjects>(p("wglDXLockObjectsNV"));
    unlock = reinterpret_cast<DXLockObjects>(p("wglDXUnlockObjectsNV"));
    share = reinterpret_cast<DXSetResourceShareHandle>(p("wglDXSetResourceShareHandleNV"));
    return open && close && reg && unreg && lock && unlock;
  }
};

Interop g_interop;

template <typename T>
void release(T *&p) {
  if (p) p->Release();
  p = nullptr;
}

}  // namespace

D3dFrames::~D3dFrames() {
  detach_gl();
  for (Slot &s : slot_) release(s.tex);
  release(output_);
  release(ctx_);
  release(dev_);
}

bool D3dFrames::init() {
  if (dev_) return true;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
                                      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 4, D3D11_SDK_VERSION,
                                 &dev_, nullptr, &ctx_);
  if (FAILED(hr)) {
    std::fprintf(stderr, "dena: no D3D11 device (0x%08lx); no game picture\n", (unsigned long)hr);
    dev_ = nullptr;
    ctx_ = nullptr;
    return false;
  }
  return true;
}

bool D3dFrames::ensure_slot(Slot &s, unsigned w, unsigned h) {
  if (s.tex && s.w == w && s.h == h) return true;
  release_gl(s);
  release(s.tex);
  s.share = nullptr;
  D3D11_TEXTURE2D_DESC d = {};
  d.Width = w;
  d.Height = h;
  d.MipLevels = 1;
  d.ArraySize = 1;
  d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  d.SampleDesc.Count = 1;
  d.Usage = D3D11_USAGE_DEFAULT;
  d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  d.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  if (FAILED(dev_->CreateTexture2D(&d, nullptr, &s.tex))) return false;
  IDXGIResource *res = nullptr;
  if (FAILED(s.tex->QueryInterface(__uuidof(IDXGIResource), reinterpret_cast<void **>(&res)))) {
    release(s.tex);
    return false;
  }
  res->GetSharedHandle(&s.share);
  res->Release();
  s.w = w;
  s.h = h;
  return s.share != nullptr;
}

void D3dFrames::publish() {
  ctx_->Flush();  // Flutter's device reads the texture next
  slots_.publish();
}

bool D3dFrames::put_pixels(const uint32_t *xrgb, unsigned w, unsigned h) {
  if (!dev_ || w == 0 || h == 0) return false;
  Slot &s = slot_[slots_.back()];
  if (!ensure_slot(s, w, h)) return false;
  // 0x00RRGGBB words are B, G, R, X bytes: BGRA once alpha is opaque.
  scratch_.resize(size_t(w) * h);
  for (size_t i = 0; i < scratch_.size(); i++) scratch_[i] = xrgb[i] | 0xff000000u;
  ctx_->UpdateSubresource(s.tex, 0, nullptr, scratch_.data(), w * 4, 0);
  publish();
  return true;
}

bool D3dFrames::attach_gl(DesktopGl *gl) {
  detach_gl();
  if (!dev_ || !gl || !gl->ready()) return false;
  if (!gl->has_wgl_extension("WGL_NV_DX_interop2") || !g_interop.load()) {
    std::fprintf(stderr, "dena: no WGL_NV_DX_interop2; GPU frames are read back\n");
    return false;
  }
  interop_ = g_interop.open(dev_);
  if (!interop_) {
    std::fprintf(stderr, "dena: wglDXOpenDeviceNV failed; GPU frames are read back\n");
    return false;
  }
  gl_ = gl;
  return true;
}

void D3dFrames::release_gl(Slot &s) {
  if (!gl_) return;
  if (s.gl_obj) g_interop.unreg(interop_, s.gl_obj);
  if (s.gl_fbo) gl_->gl().DeleteFramebuffers(1, &s.gl_fbo);
  if (s.gl_tex) gl_->gl().DeleteTextures(1, &s.gl_tex);
  s.gl_obj = nullptr;
  s.gl_fbo = s.gl_tex = 0;
}

void D3dFrames::detach_gl() {
  if (!gl_) return;
  for (Slot &s : slot_) release_gl(s);
  g_interop.close(interop_);
  interop_ = nullptr;
  gl_ = nullptr;
}

bool D3dFrames::put_gl(unsigned w, unsigned h, bool bottom_left, GLuint src) {
  if (!gl_ || w == 0 || h == 0) return false;
  const GlFuncs &gl = gl_->gl();
  Slot &s = slot_[slots_.back()];
  if (!ensure_slot(s, w, h)) return false;
  if (!s.gl_obj) {
    gl.GenTextures(1, &s.gl_tex);
    if (g_interop.share) g_interop.share(s.tex, s.share);
    s.gl_obj = g_interop.reg(interop_, s.tex, s.gl_tex, GL_TEXTURE_2D, WGL_ACCESS_WRITE_DISCARD_NV);
    if (!s.gl_obj) {
      release_gl(s);
      return false;
    }
    gl.GenFramebuffers(1, &s.gl_fbo);
    gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, s.gl_fbo);
    gl.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s.gl_tex, 0);
  }
  if (!g_interop.lock(interop_, 1, &s.gl_obj)) return false;
  gl.BindFramebuffer(GL_READ_FRAMEBUFFER, src ? src : GLuint(gl_->framebuffer()));
  gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, s.gl_fbo);
  // The texture's first row is the picture's top (as Flutter samples it).
  const GLint y0 = bottom_left ? GLint(h) : 0, y1 = bottom_left ? 0 : GLint(h);
  gl.BlitFramebuffer(0, 0, GLint(w), GLint(h), 0, y0, GLint(w), y1, GL_COLOR_BUFFER_BIT,
                     GL_NEAREST);
  gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(gl_->framebuffer()));
  g_interop.unlock(interop_, 1, &s.gl_obj);  // flushes GL into the texture
  publish();
  return true;
}

HANDLE D3dFrames::take(uint32_t *w, uint32_t *h) {
  const int i = slots_.take();
  if (i < 0) return nullptr;
  *w = slot_[i].w;
  *h = slot_[i].h;
  return slot_[i].share;
}

bool D3dFrames::wait_vblank(HWND window) {
  if (!dev_) return false;
  // Look the output up again now and then: the window may have moved.
  if (!output_ || (++output_checks_ % 120) == 0) {
    HMONITOR mon = window ? MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY) : nullptr;
    if (!output_ || mon != output_monitor_) {
      release(output_);
      output_monitor_ = mon;
      IDXGIDevice *dxgi = nullptr;
      IDXGIAdapter *adapter = nullptr;
      if (SUCCEEDED(dev_->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(&dxgi))) &&
          SUCCEEDED(dxgi->GetAdapter(&adapter))) {
        IDXGIOutput *out = nullptr;
        for (UINT i = 0; adapter->EnumOutputs(i, &out) != DXGI_ERROR_NOT_FOUND; i++) {
          DXGI_OUTPUT_DESC desc;
          if (!output_ || (SUCCEEDED(out->GetDesc(&desc)) && desc.Monitor == mon)) {
            release(output_);
            output_ = out;  // the first output, unless the window's is found
            if (SUCCEEDED(out->GetDesc(&desc)) && desc.Monitor == mon) break;
          } else {
            out->Release();
          }
        }
      }
      release(adapter);
      release(dxgi);
    }
  }
  return output_ && SUCCEEDED(output_->WaitForVBlank());
}

}  // namespace dena
#endif
