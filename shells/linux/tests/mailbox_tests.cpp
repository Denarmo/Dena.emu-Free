// SPDX-License-Identifier: GPL-3.0-or-later
// FrameMailbox tests (docs/specs/handheld-session.md).
#include <cstdio>
#include <thread>

#include "frame_mailbox.h"
#include "slot_mailbox.h"

static int failures = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      std::fprintf(stderr, "%s:%d: FAIL %s\n", __FILE__, __LINE__, #c); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

int main() {
  uint32_t px[2] = {0x00112233u, 0x00ff8000u};
  uint8_t out[8];
  dena::xrgb_to_rgba(px, 2, out);
  CHECK(out[0] == 0x11 && out[1] == 0x22 && out[2] == 0x33 && out[3] == 255);
  CHECK(out[4] == 0xff && out[5] == 0x80 && out[6] == 0x00 && out[7] == 255);

  dena::FrameMailbox box;
  bool fresh = true;
  CHECK(box.take(&fresh) == nullptr && !fresh);  // nothing yet

  uint32_t a[4] = {1, 1, 1, 1}, b[6] = {2, 2, 2, 2, 2, 2};
  box.put(a, 2, 2);
  box.put(b, 3, 2);  // newer frame replaces the unread one
  const dena::MailFrame *f = box.take(&fresh);
  CHECK(f && fresh && f->width == 3 && f->height == 2 && f->rgba.size() == 24);
  CHECK(f && f->rgba[2] == 2);
  f = box.take(&fresh);  // no new frame: the same one again
  CHECK(f && !fresh && f->width == 3);
  box.put(a, 2, 2);
  f = box.take(&fresh);
  CHECK(f && fresh && f->width == 2 && f->rgba[2] == 1);
  box.clear();
  CHECK(box.take(&fresh) == nullptr && !fresh);

  // Concurrent: every frame the reader sees is complete (all pixels equal
  // its sequence number) and sequence numbers never go back.
  const int kFrames = 2000;
  const uint32_t w = 64, h = 48;
  std::thread writer([&] {
    std::vector<uint32_t> buf(w * h);
    for (int i = 1; i <= kFrames; i++) {
      for (auto &p : buf) p = uint32_t(i & 0xff);
      box.put(buf.data(), w, h);
    }
  });
  int last = 0, torn = 0, backwards = 0;
  while (last != (kFrames & 0xff)) {
    const dena::MailFrame *m = box.take(&fresh);
    if (!m || !fresh) continue;
    int v = m->rgba[2];
    for (size_t i = 0; i < size_t(w) * h; i++)
      if (m->rgba[4 * i + 2] != v) torn++;
    if (v < last && !(last > 200 && v < 50)) backwards++;  // allow 8-bit wrap
    last = v;
  }
  writer.join();
  CHECK(torn == 0);
  CHECK(backwards == 0);

  // Slots: the reader's slot is never the writer's back slot.
  dena::SlotMailbox slots;
  CHECK(slots.take(&fresh) == -1 && !fresh);
  int first = slots.back();
  slots.publish();
  int got = slots.take(&fresh);
  CHECK(got == first && fresh);
  CHECK(slots.back() != got);
  slots.publish();  // an empty back slot published twice in a row
  int second = slots.back();
  slots.publish();
  CHECK(slots.back() != slots.take(&fresh) && fresh);
  CHECK(slots.take(&fresh) == second && !fresh);
  for (int i = 0; i < 50; i++) {
    int r = slots.take();
    CHECK(slots.back() != r);
    if (i % 3) slots.publish();
  }

  if (failures) return 1;
  std::printf("mailbox: all passed\n");
  return 0;
}
