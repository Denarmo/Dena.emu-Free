// SPDX-License-Identifier: GPL-3.0-or-later
// Netplay: two players, one game, two PCs. Rollback for cores light enough
// to save a state every frame, lockstep for the rest. Header-only and free
// of sockets and of the core, so the tests drive it with a fake core and a
// simulated network; netplay_session.cpp puts it on a TCP connection and
// runner.cpp runs it in place of run-ahead.
// Spec: docs/specs/netplay.md
#ifndef DENA_NETPLAY_H
#define DENA_NETPLAY_H

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace dena {

enum NetplayMethod { kNetplayOff = 0, kNetplayRollback = 1, kNetplayLockstep = 2 };

// The method for the core at core_path (netplay.md, Systems and methods).
inline int netplay_method(const std::string &core_path) {
  std::string name = core_path.substr(core_path.find_last_of("/\\") + 1);
  // The run-ahead cores (run-ahead.md) whose states are small: rollback.
  static const char *const kRollback[] = {"fceumm", "bsnes", "mgba", "fake08", "testcore"};
  for (const char *c : kRollback)
    if (name.find(c) != std::string::npos) return kNetplayRollback;
  return kNetplayLockstep;
}

// One player's input for one frame: what is sent (16 bytes on the wire).
struct NetInput {
  uint16_t buttons = 0;
  int16_t analog[4] = {};  // lx, ly, rx, ry
  int16_t px = 0, py = 0;  // the pointer (DS-style touch, light guns)
  uint8_t pointer = 0;     // pressed

  static constexpr size_t kWire = 16;

  bool operator==(const NetInput &o) const {
    return buttons == o.buttons && std::memcmp(analog, o.analog, sizeof analog) == 0 &&
           px == o.px && py == o.py && pointer == o.pointer;
  }
  bool operator!=(const NetInput &o) const { return !(*this == o); }

  void write(uint8_t *p) const {
    put16(p, buttons);
    for (int i = 0; i < 4; i++) put16(p + 2 + 2 * i, uint16_t(analog[i]));
    put16(p + 10, uint16_t(px));
    put16(p + 12, uint16_t(py));
    p[14] = pointer;
    p[15] = 0;
  }
  static NetInput read(const uint8_t *p) {
    NetInput in;
    in.buttons = get16(p);
    for (int i = 0; i < 4; i++) in.analog[i] = int16_t(get16(p + 2 + 2 * i));
    in.px = int16_t(get16(p + 10));
    in.py = int16_t(get16(p + 12));
    in.pointer = p[14] ? 1 : 0;
    return in;
  }
  static void put16(uint8_t *p, uint16_t v) {
    p[0] = uint8_t(v >> 8);
    p[1] = uint8_t(v);
  }
  static uint16_t get16(const uint8_t *p) { return uint16_t(p[0] << 8 | p[1]); }
};

inline void net_put32(std::vector<uint8_t> &out, uint32_t v) {
  for (int s = 24; s >= 0; s -= 8) out.push_back(uint8_t(v >> s));
}
inline uint32_t net_get32(const uint8_t *p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
inline void net_put64(std::vector<uint8_t> &out, uint64_t v) {
  net_put32(out, uint32_t(v >> 32));
  net_put32(out, uint32_t(v));
}
inline uint64_t net_get64(const uint8_t *p) {
  return uint64_t(net_get32(p)) << 32 | net_get32(p + 4);
}

// FNV-1a 64: state hashes (desync check) and the ROM id.
inline uint64_t net_fnv64(const void *data, size_t n, uint64_t h = 1469598103934665603ULL) {
  const uint8_t *p = static_cast<const uint8_t *>(data);
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ULL;
  return h;
}

// What the engine needs from the core. Emulator thread.
class NetplayDriver {
 public:
  virtual ~NetplayDriver() = default;
  virtual size_t state_size() = 0;
  virtual bool save(void *buf, size_t size) = 0;
  virtual bool load(const void *buf, size_t size) = 0;
  // Sets both players' input (index = core port) and runs one frame;
  // hidden frames are replays: muted, not shown, no frame hooks.
  virtual void step(const NetInput (&in)[2], bool hidden) = 0;
};

// Engine messages; the session frames and carries them.
enum NetplayMessage : uint8_t {
  kNetMsgInput = 0x10,  // u32 frame, u32 sender's frame, u32 last frame it has from us + 1, NetInput
  kNetMsgHash = 0x11,   // u32 frame, u64 hash (joiner -> host)
  kNetMsgState = 0x12,  // u32 frame, state bytes (host -> joiner, resync)
};

class NetplayOut {
 public:
  virtual ~NetplayOut() = default;
  virtual void send(uint8_t type, std::vector<uint8_t> payload) = 0;
};

struct NetplayStats {
  int method = kNetplayOff;
  int delay = 0;
  int64_t frame = 0;
  int64_t confirmed = -1;     // last frame the other player's input is known for
  uint64_t rollback_frames = 0;  // replayed frames
  int max_rollback = 0;       // deepest replay
  uint64_t stalls = 0;        // ticks that waited for the other player
  int waiting = 0;            // ticks in a row waiting right now
  uint64_t desyncs = 0;
  uint64_t resyncs = 0;
  uint64_t skips = 0;         // time-sync skips
};

// Emulator thread only (receive() included: the session drains its inbox
// there before each tick).
class NetplayEngine {
 public:
  struct Config {
    int method = kNetplayRollback;
    int local_slot = 0;   // core port of this side: 0 host, 1 joiner
    int delay = 1;        // frames between pressing and the frame using it
    int window = 8;       // rollback: frames run past the last known input
    int hash_interval = 60;
    bool authority = false;  // the host: answers desyncs with its state
  };

  static constexpr int64_t kRing = 256;       // inputs kept (frames)
  static constexpr int64_t kSnapRing = 32;    // states kept
  static constexpr int64_t kResyncGap = 300;  // frames between resyncs (5 s)

  void start(const Config &cfg) {
    cfg_ = cfg;
    cfg_.delay = std::clamp(cfg_.delay, 0, 8);
    cfg_.window = std::clamp(cfg_.window, 1, 16);
    if (cfg_.hash_interval < 1) cfg_.hash_interval = 60;
    frame_ = 0;
    local_next_ = 0;
    remote_confirmed_ = -1;
    remote_frame_ = 0;
    last_remote_ = NetInput{};
    rollback_to_ = kNone;
    next_hash_ = cfg_.hash_interval;
    last_resync_ = -kResyncGap;
    advantage_ = 0;
    remote_adv_ = 0;
    since_skip_ = 0;
    local_.assign(kRing, Slot{});
    remote_.assign(kRing, Slot{});
    used_.assign(kRing, Slot{});
    snaps_.assign(kSnapRing, Snap{});
    my_hashes_.assign(8, HashSlot{});
    their_hashes_.assign(8, HashSlot{});
    checks_.assign(4, Snap{});
    pending_state_.frame = kNone;
    stats_ = NetplayStats{};
    stats_.method = cfg_.method;
    stats_.delay = cfg_.delay;
    started_ = true;
  }
  bool started() const { return started_; }
  void stop() { started_ = false; }
  const Config &config() const { return cfg_; }


  void receive(uint8_t type, const uint8_t *p, size_t n) {
    if (!started_) return;
    if (type == kNetMsgInput && n >= 12 + NetInput::kWire) {
      const int64_t f = net_get32(p);
      const int64_t their_frame = net_get32(p + 4);
      if (their_frame >= remote_frame_) {
        remote_frame_ = their_frame;
        remote_adv_ = double(their_frame) - double(net_get32(p + 8));
      }
      const NetInput in = NetInput::read(p + 12);
      Slot &s = remote_[idx(f)];
      s.frame = f;
      s.in = in;
      if (f == remote_confirmed_ + 1) {
        remote_confirmed_ = f;
        last_remote_ = in;
        // Later frames that came early (never with TCP, but cheap).
        while (remote_[idx(remote_confirmed_ + 1)].frame == remote_confirmed_ + 1) {
          remote_confirmed_++;
          last_remote_ = remote_[idx(remote_confirmed_)].in;
        }
      }
      // A frame already played with a wrong guess: replay from there.
      if (f < frame_ && used_[idx(f)].frame == f && used_[idx(f)].in != in)
        rollback_to_ = std::min(rollback_to_, f);
    } else if (type == kNetMsgHash && n >= 12 && cfg_.authority) {
      const int64_t f = net_get32(p);
      their_hashes_[hidx(f)] = HashSlot{f, net_get64(p + 4)};
    } else if (type == kNetMsgState && n >= 4 && !cfg_.authority) {
      pending_state_.frame = net_get32(p);
      pending_state_.bytes.assign(p + 4, p + n);
    }
    stats_.confirmed = remote_confirmed_;
  }

  // One display frame: replays what changed, then runs at most one new
  // frame with `local` as this side's input. False when it had to wait for
  // the other player (nothing new to show).
  bool tick(NetplayDriver &d, NetplayOut &out, const NetInput &local, bool shown) {
    if (!started_) return false;
    apply_resync(d);
    if (rollback_to_ < frame_) replay(d, rollback_to_, nullptr);
    rollback_to_ = kNone;
    check_hashes(d, out);

    // This side's input for frame_ + delay goes out first: lockstep with no
    // delay would wait on each other forever otherwise.
    if (local_next_ <= frame_ + cfg_.delay) {
      while (local_next_ < frame_ + cfg_.delay) send_local(out, NetInput{});  // the opening frames
      send_local(out, local);
    }

    if (!may_advance()) {
      stats_.stalls++;
      stats_.waiting++;
      return false;
    }
    stats_.waiting = 0;
    if (cfg_.method == kNetplayRollback || frame_ % cfg_.hash_interval == 0) save_snap(d, frame_);
    run(d, frame_, !shown);
    frame_++;
    stats_.frame = frame_;
    return true;
  }

  const NetplayStats &stats() const { return stats_; }
  int64_t frame() const { return frame_; }
  int64_t confirmed() const { return remote_confirmed_; }

 private:
  static constexpr int64_t kNone = std::numeric_limits<int64_t>::max();

  struct Slot {
    int64_t frame = -1;
    NetInput in;
  };
  struct Snap {
    int64_t frame = -1;
    std::vector<uint8_t> bytes;
  };
  struct HashSlot {
    int64_t frame = -1;
    uint64_t hash = 0;
  };

  static size_t idx(int64_t f) { return size_t(f % kRing); }
  static size_t sidx(int64_t f) { return size_t(f % kSnapRing); }
  size_t hidx(int64_t f) const { return size_t((f / cfg_.hash_interval) % 8); }

  void send_local(NetplayOut &out, const NetInput &in) {
    const int64_t f = local_next_++;
    local_[idx(f)] = Slot{f, in};
    std::vector<uint8_t> p;
    p.reserve(12 + NetInput::kWire);
    net_put32(p, uint32_t(f));
    net_put32(p, uint32_t(frame_));
    net_put32(p, uint32_t(remote_frame_));
    p.resize(12 + NetInput::kWire);
    in.write(p.data() + 12);
    out.send(kNetMsgInput, std::move(p));
  }

  NetInput remote_input(int64_t f) const {
    const Slot &s = remote_[idx(f)];
    if (s.frame == f) return s.in;
    return last_remote_;  // predicted: the last input seen
  }

  NetInput local_input(int64_t f) const {
    const Slot &s = local_[idx(f)];
    return s.frame == f ? s.in : NetInput{};
  }

  bool may_advance() {
    if (cfg_.method == kNetplayLockstep) return remote_confirmed_ >= frame_;
    if (frame_ - (remote_confirmed_ + 1) >= cfg_.window) return false;
    // Time sync: each side sees the other a one-way trip late, so half the
    // difference between the two views is how far this side runs ahead.
    // The side ahead skips a frame now and then, so neither ends up waiting
    // at the edge of the window.
    const double ahead = ((double(frame_) - double(remote_frame_)) - remote_adv_) / 2;
    advantage_ += (ahead - advantage_) * 0.1;
    if (++since_skip_ > 20 && advantage_ > 1.5) {
      since_skip_ = 0;
      advantage_ -= 1;
      stats_.skips++;
      return false;
    }
    return true;
  }

  void save_snap(NetplayDriver &d, int64_t f) {
    Snap &s = snaps_[sidx(f)];
    const size_t size = d.state_size();
    if (size == 0) return;
    if (s.bytes.size() != size) s.bytes.assign(size, 0);
    s.frame = d.save(s.bytes.data(), size) ? f : -1;
  }

  const Snap *snap(int64_t f) const {
    const Snap &s = snaps_[sidx(f)];
    return s.frame == f ? &s : nullptr;
  }

  void run(NetplayDriver &d, int64_t f, bool hidden) {
    NetInput in[2];
    const NetInput remote = remote_input(f);
    in[cfg_.local_slot] = local_input(f);
    in[1 - cfg_.local_slot] = remote;
    used_[idx(f)] = Slot{f, remote};
    d.step(in, hidden);
  }

  // Loads the state from before frame `from` (or `state`) and runs again up
  // to the present with the inputs known now.
  void replay(NetplayDriver &d, int64_t from, const std::vector<uint8_t> *state) {
    if (frame_ - from >= kRing) return;  // inputs gone (cannot happen inside the window)
    if (!state) {
      const Snap *s = snap(from);
      if (!s) return;
      state = &s->bytes;
    }
    if (!d.load(state->data(), state->size())) return;
    if (state != &snaps_[sidx(from)].bytes) {
      Snap &s = snaps_[sidx(from)];
      s.frame = from;
      s.bytes = *state;
    }
    const int depth = int(frame_ - from);
    for (int64_t f = from; f < frame_; f++) {
      if (f > from && (cfg_.method == kNetplayRollback || f % cfg_.hash_interval == 0))
        save_snap(d, f);
      run(d, f, true);
    }
    stats_.rollback_frames += uint64_t(depth);
    stats_.max_rollback = std::max(stats_.max_rollback, depth);
  }

  // The host's state for a frame the hashes disagreed on.
  void apply_resync(NetplayDriver &d) {
    if (pending_state_.frame == kNone) return;
    const int64_t f = pending_state_.frame;
    pending_state_.frame = kNone;
    if (f >= frame_ || frame_ - f >= kRing) return;
    replay(d, f, &pending_state_.bytes);
    stats_.resyncs++;
  }

  // Every hash_interval frames, once both inputs before that frame are
  // known: the joiner sends a hash of its state there, the host compares.
  void check_hashes(NetplayDriver &d, NetplayOut &out) {
    (void)d;
    while (frame_ > next_hash_ && remote_confirmed_ >= next_hash_ - 1) {
      const int64_t f = next_hash_;
      next_hash_ += cfg_.hash_interval;
      const Snap *s = snap(f);
      if (!s) continue;
      const uint64_t h = net_fnv64(s->bytes.data(), s->bytes.size());
      my_hashes_[hidx(f)] = HashSlot{f, h};
      if (cfg_.authority) {
        Snap &c = checks_[size_t((f / cfg_.hash_interval) % checks_.size())];
        c.frame = f;
        c.bytes = s->bytes;
      } else {
        std::vector<uint8_t> p;
        net_put32(p, uint32_t(f));
        net_put64(p, h);
        out.send(kNetMsgHash, std::move(p));
      }
    }
    if (!cfg_.authority) return;
    for (HashSlot &theirs : their_hashes_) {
      if (theirs.frame < 0) continue;
      const HashSlot &mine = my_hashes_[hidx(theirs.frame)];
      if (mine.frame != theirs.frame) continue;  // not hashed here yet
      const int64_t f = theirs.frame;
      const bool differ = mine.hash != theirs.hash;
      theirs.frame = -1;
      if (!differ) continue;
      stats_.desyncs++;
      const Snap &c = checks_[size_t((f / cfg_.hash_interval) % checks_.size())];
      if (c.frame != f || frame_ - last_resync_ < kResyncGap) continue;
      last_resync_ = frame_;
      std::vector<uint8_t> p;
      p.reserve(4 + c.bytes.size());
      net_put32(p, uint32_t(f));
      p.insert(p.end(), c.bytes.begin(), c.bytes.end());
      out.send(kNetMsgState, std::move(p));
      stats_.resyncs++;
    }
  }

  Config cfg_;
  bool started_ = false;
  int64_t frame_ = 0;         // the next frame to run
  int64_t local_next_ = 0;    // the next frame to give this side's input
  int64_t remote_confirmed_ = -1;
  int64_t remote_frame_ = 0;  // the other side's frame when it last sent
  NetInput last_remote_;
  int64_t rollback_to_ = kNone;
  int64_t next_hash_ = 60;
  int64_t last_resync_ = 0;
  double remote_adv_ = 0;  // the other side's view of how far it is ahead
  double advantage_ = 0;
  int since_skip_ = 0;
  std::vector<Slot> local_, remote_, used_;
  std::vector<Snap> snaps_;
  std::vector<HashSlot> my_hashes_, their_hashes_;
  std::vector<Snap> checks_;  // host: states at the last hashed frames
  Snap pending_state_;
  NetplayStats stats_;
};

}  // namespace dena

#endif
