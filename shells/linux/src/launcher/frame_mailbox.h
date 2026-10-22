// SPDX-License-Identifier: GPL-3.0-or-later
// Triple buffer between the emulator thread (writer) and the engine's raster
// thread (reader). Spec: docs/specs/handheld-session.md
#ifndef DENA_FRAME_MAILBOX_H
#define DENA_FRAME_MAILBOX_H

#include <cstdint>
#include <mutex>
#include <vector>

namespace dena {

struct MailFrame {
  std::vector<uint8_t> rgba;  // width * height * 4 bytes: R, G, B, 255
  uint32_t width = 0, height = 0;
};

// 0x00RRGGBB pixels to RGBA bytes.
void xrgb_to_rgba(const uint32_t *src, size_t count, uint8_t *dst);

class FrameMailbox {
 public:
  // Writer: copies a 0x00RRGGBB frame (rows of `width`) and makes it the newest.
  void put(const uint32_t *xrgb, uint32_t width, uint32_t height);
  // Reader: the newest complete frame, or nullptr before the first one. The
  // frame stays valid until the reader's next take(). `fresh` says whether it
  // is newer than the last take.
  const MailFrame *take(bool *fresh = nullptr);
  // Forgets all frames (a new session).
  void clear();

 private:
  std::mutex mtx_;
  MailFrame back_, ready_, front_;
  bool has_ready_ = false;
};

}  // namespace dena

#endif
