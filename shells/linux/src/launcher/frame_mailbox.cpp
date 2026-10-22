// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/handheld-session.md
#include "frame_mailbox.h"

namespace dena {

void xrgb_to_rgba(const uint32_t *src, size_t count, uint8_t *dst) {
  for (size_t i = 0; i < count; i++) {
    uint32_t v = src[i];
    dst[4 * i] = uint8_t(v >> 16);
    dst[4 * i + 1] = uint8_t(v >> 8);
    dst[4 * i + 2] = uint8_t(v);
    dst[4 * i + 3] = 255;
  }
}

void FrameMailbox::put(const uint32_t *xrgb, uint32_t width, uint32_t height) {
  // back_ belongs to the writer; only the swap needs the lock.
  size_t n = size_t(width) * height;
  back_.rgba.resize(n * 4);
  back_.width = width;
  back_.height = height;
  xrgb_to_rgba(xrgb, n, back_.rgba.data());
  std::lock_guard<std::mutex> lk(mtx_);
  std::swap(back_, ready_);
  has_ready_ = true;
}

const MailFrame *FrameMailbox::take(bool *fresh) {
  std::lock_guard<std::mutex> lk(mtx_);
  bool got = has_ready_;
  if (got) {
    std::swap(ready_, front_);
    has_ready_ = false;
  }
  if (fresh) *fresh = got;
  return front_.width ? &front_ : nullptr;
}

void FrameMailbox::clear() {
  std::lock_guard<std::mutex> lk(mtx_);
  back_ = ready_ = front_ = MailFrame();
  has_ready_ = false;
}

}  // namespace dena
