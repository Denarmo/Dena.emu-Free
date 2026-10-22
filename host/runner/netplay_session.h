// SPDX-License-Identifier: GPL-3.0-or-later
// A netplay session: the connection to the other player (a room from
// net_room.h), the handshake and framing around the engine in netplay.h.
// The network runs on its own thread; frame() runs on the emulator thread.
// Spec: docs/specs/netplay.md (Netplay session)
#ifndef DENA_NETPLAY_SESSION_H
#define DENA_NETPLAY_SESSION_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "netplay.h"

namespace dena {

// FNV-1a 64 over the file size, its first 16 MB and its last 1 MB; 0 when
// the file cannot be read.
uint64_t netplay_rom_id(const std::string &path);

class NetplaySession {
 public:
  enum State {
    kOff = 0,
    kWaiting = 1,  // host: waiting for the other player; joiner: connecting
    kPlaying = 2,  // the handshake is done (START is on its way or applied)
    kEnded = 3,    // failed or left; error() says why
  };

  struct Options {
    bool host = false;
    std::string target;   // joiner: a room code or "host[:port]"
    std::string relay;    // joiner: "host[:port]" or ""
    bool room = false;    // host: a relay room (not in this edition: fails)
    int port = 0;         // 0: DENA_NETPLAY_PORT
    int delay = -1;       // -1: AUTO
    std::string core;     // core file name (both sides must match)
    uint64_t rom_id = 0;
    int method = kNetplayRollback;
  };

  NetplaySession() = default;
  ~NetplaySession() { stop(); }
  NetplaySession(const NetplaySession &) = delete;
  NetplaySession &operator=(const NetplaySession &) = delete;

  // Starts hosting or joining on a worker thread. False when already running.
  bool start(const Options &opts);
  // Says goodbye to the other player and closes everything. Any thread.
  void stop();

  int state() const { return state_; }
  std::string error() const;
  // {"state":..,"slot":..,"method":..,"delay":..,"rtt_ms":..,"via_relay":..,
  //  "code":"..","address":"..","peer":"..","error":"..", engine stats}
  std::string info_json() const;

  // Emulator thread, before each frame. True when netplay owns this frame:
  // *ran says whether a frame ran (false: waiting for the other player).
  // False: play alone (not connected yet, or the session ended).
  bool frame(NetplayDriver &d, const NetInput &local, bool shown, bool *ran);
  // Emulator thread: true from the first netplay frame until the end.
  bool engaged() const { return engaged_; }

 private:
  struct Message {
    uint8_t type;
    std::vector<uint8_t> bytes;
  };
  class Out : public NetplayOut {
   public:
    explicit Out(NetplaySession &s) : s_(s) {}
    void send(uint8_t type, std::vector<uint8_t> payload) override {
      s_.send(type, payload.data(), payload.size());
    }

   private:
    NetplaySession &s_;
  };

  void thread_main();
  bool connect_peer();
  void pump();
  bool handle_net(uint8_t type, std::vector<uint8_t> &bytes);
  void send(uint8_t type, const uint8_t *data, size_t n);
  bool flush();  // non-blocking; false when the connection broke
  void fail(const std::string &why);
  void start_engine(int slot, int method, int delay);

  Options opts_;
  std::thread thread_;
  std::atomic<bool> stop_{false};
  volatile int stop_flag_ = 0;  // for dena_room_connect
  std::atomic<int> state_{kOff};
  mutable std::mutex mtx_;  // everything below up to the engine
  std::string error_, code_, address_, peer_;
  bool via_relay_ = false;
  intptr_t sock_ = -1;
  std::vector<uint8_t> outbuf_;
  std::vector<Message> inbox_;
  bool hello_ok_ = false;
  double rtt_ms_ = -1;
  std::string bye_;  // the other side's reason

  // Emulator thread.
  NetplayEngine engine_;
  std::atomic<bool> engaged_{false};
  bool start_sent_ = false;
  int64_t sync_since_ms_ = 0;
  NetplayStats stats_copy_;  // for info_json (under mtx_)
  int slot_ = 0;
};

}  // namespace dena

#endif
