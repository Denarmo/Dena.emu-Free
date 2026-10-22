// SPDX-License-Identifier: GPL-3.0-or-later
// Triple buffering of three slots (GPU textures) between a writer and a
// reader thread: the writer fills back(), publish() makes it the newest; the
// reader's take() returns the newest published slot, which the writer won't
// touch until the reader takes another. Spec: docs/specs/handheld-session.md
#ifndef DENA_SLOT_MAILBOX_H
#define DENA_SLOT_MAILBOX_H

#include <mutex>

namespace dena {

class SlotMailbox {
 public:
  int back() const { return back_; }  // writer only
  void publish() {
    std::lock_guard<std::mutex> lk(mtx_);
    std::swap(back_, ready_);
    fresh_ = true;
    any_ = true;
  }
  // The newest published slot, or -1 before the first.
  int take(bool *fresh = nullptr) {
    std::lock_guard<std::mutex> lk(mtx_);
    bool got = fresh_;
    if (got) {
      std::swap(ready_, front_);
      fresh_ = false;
    }
    if (fresh) *fresh = got;
    return any_ ? front_ : -1;
  }
  void clear() {
    std::lock_guard<std::mutex> lk(mtx_);
    back_ = 0, ready_ = 1, front_ = 2;
    fresh_ = any_ = false;
  }

 private:
  std::mutex mtx_;
  int back_ = 0, ready_ = 1, front_ = 2;
  bool fresh_ = false, any_ = false;
};

}  // namespace dena

#endif
