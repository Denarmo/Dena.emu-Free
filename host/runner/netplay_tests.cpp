// SPDX-License-Identifier: GPL-3.0-or-later
// Netplay engine with a fake core and a simulated network
// (docs/specs/netplay.md, Acceptance). Both sides tick on one clock; the
// network delivers each message a few ticks later.
#include <cstdio>
#include <algorithm>
#include <cstring>
#include <deque>
#include <random>
#include <vector>

#include "netplay.h"

namespace {

int failures = 0;

#define CHECK(cond)                                                        \
  do {                                                                     \
    if (!(cond)) {                                                         \
      std::fprintf(stderr, "%s:%d: FAIL %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                          \
    }                                                                      \
  } while (0)

using dena::NetInput;

// The state is a running hash of every input both players gave; after[f] is
// the state after frame f (rewritten when a replay runs f again).
class FakeCore : public dena::NetplayDriver {
 public:
  uint64_t state = 1;
  uint64_t frame = 0;
  std::vector<uint64_t> after;
  int shown = 0, hidden = 0;
  int64_t glitch_at = -1;  // this frame comes out different here (not deterministic)

  size_t state_size() override { return 16; }
  bool save(void *buf, size_t size) override {
    if (size < 16) return false;
    std::memcpy(buf, &state, 8);
    std::memcpy(static_cast<uint8_t *>(buf) + 8, &frame, 8);
    return true;
  }
  bool load(const void *buf, size_t size) override {
    if (size < 16) return false;
    std::memcpy(&state, buf, 8);
    std::memcpy(&frame, static_cast<const uint8_t *>(buf) + 8, 8);
    return true;
  }
  void step(const NetInput (&in)[2], bool is_hidden) override {
    uint8_t w[32];
    in[0].write(w);
    in[1].write(w + 16);
    state = dena::net_fnv64(w, sizeof w, state ^ frame);
    if (int64_t(frame) == glitch_at) state ^= 0x5a5a;
    if (after.size() <= frame) after.resize(frame + 1);
    after[frame] = state;
    frame++;
    (is_hidden ? hidden : shown)++;
  }
};

struct Packet {
  int at;  // tick it arrives
  uint8_t type;
  std::vector<uint8_t> bytes;
};

// One direction of the network: in order (TCP), latency plus jitter.
class Wire : public dena::NetplayOut {
 public:
  std::deque<Packet> queue;
  int now = 0, latency = 0, jitter = 0;
  std::mt19937 rng{7};
  int last_at = 0;
  bool drop_state = false;
  uint64_t states = 0;

  void send(uint8_t type, std::vector<uint8_t> payload) override {
    if (type == dena::kNetMsgState) {
      states++;
      if (drop_state) return;
    }
    int at = now + latency + (jitter ? int(rng() % unsigned(jitter + 1)) : 0);
    at = std::max(at, last_at);  // TCP keeps the order
    last_at = at;
    queue.push_back(Packet{at, type, std::move(payload)});
  }
  void deliver(dena::NetplayEngine &to) {
    while (!queue.empty() && queue.front().at <= now) {
      const Packet &p = queue.front();
      to.receive(p.type, p.bytes.data(), p.bytes.size());
      queue.pop_front();
    }
  }
};

NetInput input_for(int side, int tick) {
  NetInput in;
  // Changes every few frames, differently for each side.
  const int phase = tick / (side ? 5 : 3);
  in.buttons = uint16_t((phase * (side ? 0x91 : 0x35)) & 0x0fff);
  in.analog[0] = int16_t(phase * (side ? -300 : 211));
  return in;
}

struct Match {
  FakeCore core[2];
  dena::NetplayEngine eng[2];
  Wire wire[2];  // wire[i]: from side i to the other
  int tick = 0;

  Match(int method, int delay, int latency, int jitter) {
    for (int i = 0; i < 2; i++) {
      dena::NetplayEngine::Config c;
      c.method = method;
      c.local_slot = i;
      c.delay = delay;
      c.authority = i == 0;
      eng[i].start(c);
      wire[i].latency = latency;
      wire[i].jitter = jitter;
      wire[i].rng.seed(unsigned(11 + i));
    }
  }

  void run(int ticks, bool idle = false) {
    for (int t = 0; t < ticks; t++, tick++) {
      for (int i = 0; i < 2; i++) wire[i].now = tick;
      wire[1].deliver(eng[0]);
      wire[0].deliver(eng[1]);
      for (int i = 0; i < 2; i++)
        eng[i].tick(core[i], wire[i], idle ? NetInput{} : input_for(i, tick), true);
    }
  }

  // Frames both sides ran with the real inputs: the states must agree.
  int64_t settled() const {
    return std::min({eng[0].confirmed(), eng[1].confirmed(), eng[0].frame() - 1,
                     eng[1].frame() - 1});
  }
  int64_t mismatches(int64_t from = 0) const {
    int64_t bad = 0;
    for (int64_t f = from; f <= settled(); f++)
      if (core[0].after.at(size_t(f)) != core[1].after.at(size_t(f))) bad++;
    return bad;
  }
};

void test_method_choice() {
  CHECK(dena::netplay_method("/x/cores/fceumm_libretro.so") == dena::kNetplayRollback);
  CHECK(dena::netplay_method("C:\\cores\\bsnes_libretro.dll") == dena::kNetplayRollback);
  CHECK(dena::netplay_method("fake08_libretro.so") == dena::kNetplayRollback);
  CHECK(dena::netplay_method("mupen64plus_next_libretro.so") == dena::kNetplayLockstep);
  CHECK(dena::netplay_method("flycast_libretro.dll") == dena::kNetplayLockstep);
  CHECK(dena::netplay_method("mednafen_psx_hw_libretro.so") == dena::kNetplayLockstep);
}

void test_input_wire() {
  NetInput a;
  a.buttons = 0xbeef;
  a.analog[0] = -32768;
  a.analog[3] = 32767;
  a.px = -5;
  a.py = 700;
  a.pointer = 1;
  uint8_t w[NetInput::kWire];
  a.write(w);
  CHECK(NetInput::read(w) == a);
  CHECK(w[0] == 0xbe && w[1] == 0xef);
}

void test_rollback_agrees() {
  Match m(dena::kNetplayRollback, 1, 4, 2);
  m.run(600);
  m.run(30, true);
  CHECK(m.settled() > 500);
  CHECK(m.mismatches() == 0);
  // With 4+ frames of latency and 1 of delay the guesses miss: replays ran.
  CHECK(m.eng[0].stats().rollback_frames > 0 && m.eng[1].stats().rollback_frames > 0);
  CHECK(m.eng[0].stats().max_rollback <= 8 && m.eng[1].stats().max_rollback <= 8);
  CHECK(m.eng[0].stats().desyncs == 0 && m.eng[1].stats().resyncs == 0);
  // Both sides keep pace: neither falls far behind the clock.
  CHECK(m.eng[0].frame() > 560 && m.eng[1].frame() > 560);
}

void test_rollback_no_latency() {
  Match m(dena::kNetplayRollback, 1, 0, 0);
  m.run(300);
  CHECK(m.mismatches() == 0);
  // Inputs arrive before they are needed: nothing replayed, nothing waited.
  CHECK(m.eng[0].stats().rollback_frames == 0 && m.eng[1].stats().rollback_frames == 0);
  CHECK(m.eng[0].stats().stalls == 0 && m.eng[1].stats().stalls == 0);
}

void test_rollback_window_stalls() {
  // 20 ticks of latency is more than the 8-frame window: the sides wait.
  Match m(dena::kNetplayRollback, 1, 20, 0);
  m.run(400);
  m.run(60, true);
  CHECK(m.mismatches() == 0);
  CHECK(m.eng[0].stats().stalls > 0);
  CHECK(m.eng[0].stats().max_rollback <= 8);
  CHECK(m.settled() > 100);
}

void test_lockstep_agrees() {
  Match m(dena::kNetplayLockstep, 2, 3, 1);
  m.run(500);
  m.run(30, true);
  CHECK(m.settled() > 300);
  CHECK(m.mismatches() == 0);
  // Lockstep never guesses: no replays, and it waits when inputs are late.
  CHECK(m.eng[0].stats().rollback_frames == 0 && m.eng[1].stats().rollback_frames == 0);
  CHECK(m.eng[0].stats().stalls > 0);
  CHECK(m.core[0].hidden == 0 && m.core[1].hidden == 0);
}

void test_lockstep_delay_covers_latency() {
  // Delay 4 against 3 ticks of latency: inputs are always there in time.
  Match m(dena::kNetplayLockstep, 4, 3, 0);
  m.run(300);
  CHECK(m.mismatches() == 0);
  // Only the opening frames wait (for the first inputs to arrive).
  CHECK(m.eng[0].stats().stalls <= 3 && m.eng[1].stats().stalls <= 3);
}

void test_desync_resyncs(int method) {
  // Lockstep needs delay >= the one-way trip to keep pace (as AUTO picks).
  Match m(method, method == dena::kNetplayLockstep ? 4 : 1, 2, 1);
  // Frame 100 comes out different on the joiner (a core that is not
  // deterministic): the next hash check catches it, the host sends its state
  // and the two agree again.
  m.core[1].glitch_at = 100;
  m.run(500);
  m.run(30, true);
  CHECK(m.eng[0].stats().desyncs >= 1);
  CHECK(m.eng[0].stats().resyncs >= 1);
  CHECK(m.eng[1].stats().resyncs >= 1);
  const int64_t end = m.settled();
  CHECK(end > 400);
  CHECK(m.mismatches(end - 120) == 0);
}

void test_resync_rate_limited() {
  // The joiner never takes the fix (state lost): the host sends at most one
  // state per 300 frames however often the hashes disagree.
  Match m(dena::kNetplayRollback, 1, 2, 0);
  m.wire[0].drop_state = true;
  m.core[1].glitch_at = 30;
  m.run(960);
  CHECK(m.eng[0].stats().desyncs >= 10);
  CHECK(m.wire[0].states >= 2 && m.wire[0].states <= 4);
}

void test_stopped_engine_does_nothing() {
  FakeCore c;
  Wire w;
  dena::NetplayEngine e;
  CHECK(!e.tick(c, w, NetInput{}, true));
  CHECK(c.shown == 0 && w.queue.empty());
}

}  // namespace

int main() {
  test_method_choice();
  test_input_wire();
  test_rollback_agrees();
  test_rollback_no_latency();
  test_rollback_window_stalls();
  test_lockstep_agrees();
  test_lockstep_delay_covers_latency();
  test_desync_resyncs(dena::kNetplayRollback);
  test_desync_resyncs(dena::kNetplayLockstep);
  test_resync_rate_limited();
  test_stopped_engine_does_nothing();
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("netplay tests passed\n");
  return 0;
}
