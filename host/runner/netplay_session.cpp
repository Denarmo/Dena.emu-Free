// SPDX-License-Identifier: GPL-3.0-or-later
// Netplay session: connection, handshake and framing (docs/specs/netplay.md).
#include "netplay_session.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>

extern "C" {
#include "dena/net_room.h"
}
#include "../src/net_sock.h"

namespace dena {

namespace {

enum : uint8_t {
  kMsgHello = 0x01,  // text: "DENA-NETPLAY 1\ncore=..\nrom=..\n"
  kMsgStart = 0x02,  // u8 method, u8 delay, state bytes (host -> joiner)
  kMsgPing = 0x03,   // u64 sender's clock (ms)
  kMsgPong = 0x04,   // the ping's payload back
  kMsgBye = 0x05,    // text: why
};

constexpr const char *kHelloLine = "DENA-NETPLAY 1";
constexpr size_t kMaxMessage = size_t(1) << 28;  // a Dreamcast state fits easily
constexpr uint64_t kHelloTimeoutMs = 10000;
constexpr uint64_t kPingEveryMs = 1000;

std::string json_escape(const std::string &s) {
  std::string out;
  for (char c : s) {
    if (c == '"' || c == '\\') out += '\\';
    if (uint8_t(c) < 0x20) continue;
    out += c;
  }
  return out;
}

std::string field(const std::string &text, const std::string &key) {
  const std::string k = key + "=";
  size_t at = 0;
  while (at < text.size()) {
    size_t end = text.find('\n', at);
    if (end == std::string::npos) end = text.size();
    if (text.compare(at, k.size(), k) == 0) return text.substr(at + k.size(), end - at - k.size());
    at = end + 1;
  }
  return std::string();
}

}  // namespace

uint64_t netplay_rom_id(const std::string &path) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return 0;
  std::fseek(f, 0, SEEK_END);
  const long long size = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  if (size < 0) {
    std::fclose(f);
    return 0;
  }
  uint8_t sz[8];
  for (int i = 0; i < 8; i++) sz[i] = uint8_t(uint64_t(size) >> (8 * i));
  uint64_t h = net_fnv64(sz, sizeof sz);
  std::vector<uint8_t> buf(1 << 20);
  const long long head = std::min<long long>(size, 16LL << 20);
  long long done = 0;
  while (done < head) {
    const size_t n = std::fread(buf.data(), 1, size_t(std::min<long long>(head - done, buf.size())), f);
    if (n == 0) break;
    h = net_fnv64(buf.data(), n, h);
    done += (long long)n;
  }
  if (size > head) {
    const long long tail = std::min<long long>(size - head, 1LL << 20);
    std::fseek(f, long(size - tail), SEEK_SET);
    const size_t n = std::fread(buf.data(), 1, size_t(tail), f);
    h = net_fnv64(buf.data(), n, h);
  }
  std::fclose(f);
  return h;
}

bool NetplaySession::start(const Options &opts) {
  if (thread_.joinable()) return false;
  opts_ = opts;
  if (opts_.port <= 0) opts_.port = DENA_NETPLAY_PORT;
  stop_ = false;
  stop_flag_ = 0;
  {
    std::lock_guard<std::mutex> lk(mtx_);
    error_.clear();
    code_.clear();
    peer_.clear();
    bye_.clear();
    address_.clear();
    outbuf_.clear();
    inbox_.clear();
    via_relay_ = false;
    hello_ok_ = false;
    rtt_ms_ = -1;
    stats_copy_ = NetplayStats{};
  }
  engine_.stop();
  engaged_ = false;
  start_sent_ = false;
  sync_since_ms_ = 0;
  slot_ = opts_.host ? 0 : 1;
  state_ = kWaiting;
  thread_ = std::thread([this] { thread_main(); });
  return true;
}

void NetplaySession::stop() {
  stop_ = true;
  stop_flag_ = 1;
  if (thread_.joinable()) thread_.join();
  engine_.stop();
  engaged_ = false;
  state_ = kOff;
}

std::string NetplaySession::error() const {
  std::lock_guard<std::mutex> lk(mtx_);
  return error_;
}

void NetplaySession::fail(const std::string &why) {
  {
    std::lock_guard<std::mutex> lk(mtx_);
    if (error_.empty()) error_ = why;
  }
  state_ = kEnded;
}

std::string NetplaySession::info_json() const {
  std::lock_guard<std::mutex> lk(mtx_);
  const NetplayStats &s = stats_copy_;
  char buf[640];
  std::snprintf(buf, sizeof buf,
                "{\"state\":%d,\"host\":%s,\"slot\":%d,\"method\":%d,\"delay\":%d,\"rtt_ms\":%.1f,"
                "\"via_relay\":%s,\"frame\":%lld,\"rollback_frames\":%llu,\"max_rollback\":%d,"
                "\"stalls\":%llu,\"waiting\":%s,\"desyncs\":%llu,\"resyncs\":%llu,",
                state_.load(), opts_.host ? "true" : "false", slot_, s.method, s.delay,
                rtt_ms_ < 0 ? 0.0 : rtt_ms_, via_relay_ ? "true" : "false", (long long)s.frame,
                (unsigned long long)s.rollback_frames, s.max_rollback,
                (unsigned long long)s.stalls, s.waiting > 30 ? "true" : "false",
                (unsigned long long)s.desyncs, (unsigned long long)s.resyncs);
  return std::string(buf) + "\"code\":\"" + json_escape(code_) + "\",\"address\":\"" +
         json_escape(address_) + "\",\"peer\":\"" + json_escape(peer_) + "\",\"error\":\"" +
         json_escape(error_) + "\"}";
}

void NetplaySession::send(uint8_t type, const uint8_t *data, size_t n) {
  {
    std::lock_guard<std::mutex> lk(mtx_);
    if (sock_ < 0) return;
    outbuf_.push_back(type);
    outbuf_.push_back(uint8_t(n >> 24));
    outbuf_.push_back(uint8_t(n >> 16));
    outbuf_.push_back(uint8_t(n >> 8));
    outbuf_.push_back(uint8_t(n));
    outbuf_.insert(outbuf_.end(), data, data + n);
  }
  flush();
}

bool NetplaySession::flush() {
  std::lock_guard<std::mutex> lk(mtx_);
  if (sock_ < 0) return false;
  size_t sent = 0;
  bool ok = true;
  while (sent < outbuf_.size()) {
    const size_t want = std::min<size_t>(outbuf_.size() - sent, 1 << 20);
    const int w = int(::send(dsock(sock_), reinterpret_cast<const char *>(outbuf_.data() + sent),
                             int(want), DSOCK_SEND_FLAGS));
    if (w > 0) {
      sent += size_t(w);
      continue;
    }
    const int err = dsock_error();
    if (w < 0 && dsock_interrupted(err)) continue;
    if (w < 0 && dsock_in_progress(err)) break;  // full: the network thread goes on later
    ok = false;
    break;
  }
  outbuf_.erase(outbuf_.begin(), outbuf_.begin() + std::ptrdiff_t(sent));
  return ok;
}

bool NetplaySession::connect_peer() {
  char err[256] = "", peer[64] = "";
  int via = 0;
  intptr_t s = -1;
  if (opts_.host) {
    if (opts_.room) {
      // Hosting a relay room is not part of this edition; LAN hosting and
      // joining a room code are.
      fail("Hosting a room through a relay server is not available in this edition");
      return false;
    }
    dena_room room;
    if (dena_room_open(&room, opts_.port, err, sizeof err) != 0) {
      fail(err);
      return false;
    }
    char lan[64] = "";
    if (dena_room_local_address(lan, sizeof lan) > 0) {
      std::lock_guard<std::mutex> lk(mtx_);
      address_ = std::string(lan) + ":" + std::to_string(opts_.port);
    }
    while (!stop_) {
      s = dena_room_accept(&room, 200, &via, peer, sizeof peer, err, sizeof err);
      if (s >= 0) break;
      if (s == -2) {
        dena_room_close(&room);
        fail(err);
        return false;
      }
    }
    dena_room_close(&room);
  } else {
    s = dena_room_connect(opts_.target.c_str(), opts_.port, opts_.relay.c_str(), &stop_flag_, &via,
                          peer, sizeof peer, err, sizeof err);
    if (s < 0 && !stop_) {
      fail(err[0] ? err : "Could not connect");
      return false;
    }
  }
  if (s < 0) return false;
  dsock_set_blocking(dsock(s), 0);
  dsock_nodelay(dsock(s));
  std::lock_guard<std::mutex> lk(mtx_);
  sock_ = s;
  via_relay_ = via != 0;
  peer_ = peer;
  return true;
}

void NetplaySession::thread_main() {
  dsock_init();
  if (!connect_peer()) return;
  char hello[160];
  std::snprintf(hello, sizeof hello, "%s\ncore=%s\nrom=%016llx\n", kHelloLine, opts_.core.c_str(),
                (unsigned long long)opts_.rom_id);
  send(kMsgHello, reinterpret_cast<const uint8_t *>(hello), std::strlen(hello));
  const uint64_t began = dnet_now_ms();
  uint64_t last_ping = 0;
  std::vector<uint8_t> rbuf;
  std::vector<uint8_t> chunk(1 << 16);
  const dsock s = dsock(sock_);
  while (!stop_ && state_ != kEnded) {
    dpollfd pf;
    pf.fd = s;
    pf.events = POLLIN;
    {
      std::lock_guard<std::mutex> lk(mtx_);
      if (!outbuf_.empty()) pf.events |= POLLOUT;
    }
    pf.revents = 0;
    const int r = dsock_poll(&pf, 1, 10);
    if (r < 0 && !dsock_interrupted(dsock_error())) {
      fail("Connection lost");
      break;
    }
    if (r > 0 && (pf.revents & (POLLIN | POLLHUP | POLLERR))) {
      const int k = int(::recv(s, reinterpret_cast<char *>(chunk.data()), int(chunk.size()), 0));
      if (k == 0 || (k < 0 && !dsock_in_progress(dsock_error()) &&
                     !dsock_interrupted(dsock_error()))) {
        std::string bye;
        {
          std::lock_guard<std::mutex> lk(mtx_);
          bye = bye_;
        }
        fail(bye.empty() ? "The other player left" : bye);
        break;
      }
      if (k > 0) rbuf.insert(rbuf.end(), chunk.begin(), chunk.begin() + k);
    }
    // Whole messages out of the buffer.
    size_t at = 0;
    bool go_on = true;
    while (go_on && rbuf.size() - at >= 5) {
      const size_t n = net_get32(&rbuf[at + 1]);
      if (n > kMaxMessage) {
        fail("The other side sent something that is not netplay");
        go_on = false;
        break;
      }
      if (rbuf.size() - at - 5 < n) break;
      const uint8_t type = rbuf[at];
      std::vector<uint8_t> bytes(rbuf.begin() + std::ptrdiff_t(at + 5),
                                 rbuf.begin() + std::ptrdiff_t(at + 5 + n));
      at += 5 + n;
      go_on = handle_net(type, bytes);
    }
    rbuf.erase(rbuf.begin(), rbuf.begin() + std::ptrdiff_t(at));
    if (!go_on) break;

    const uint64_t now = dnet_now_ms();
    bool hello_ok;
    {
      std::lock_guard<std::mutex> lk(mtx_);
      hello_ok = hello_ok_;
    }
    if (!hello_ok && now - began > kHelloTimeoutMs) {
      fail("The other side did not answer like Dena.emu");
      break;
    }
    if (hello_ok && now - last_ping >= kPingEveryMs) {
      last_ping = now;
      std::vector<uint8_t> p;
      net_put64(p, now);
      send(kMsgPing, p.data(), p.size());
    }
    if (!flush()) {
      fail("Connection lost");
      break;
    }
  }
  // Goodbye (best effort), then close.
  if (stop_) {
    const char *why = "The other player left";
    send(kMsgBye, reinterpret_cast<const uint8_t *>(why), std::strlen(why));
    for (int i = 0; i < 20; i++) {
      {
        std::lock_guard<std::mutex> lk(mtx_);
        if (outbuf_.empty()) break;
      }
      if (!flush()) break;
      dnet_sleep_ms(5);
    }
  }
  std::lock_guard<std::mutex> lk(mtx_);
  dsock_shutdown(s);
  dsock_close(s);
  sock_ = -1;
}

// Network thread. False ends the session.
bool NetplaySession::handle_net(uint8_t type, std::vector<uint8_t> &bytes) {
  switch (type) {
    case kMsgHello: {
      const std::string text(bytes.begin(), bytes.end());
      std::string why;
      if (text.compare(0, std::strlen(kHelloLine), kHelloLine) != 0)
        why = "The other player runs a different version of Dena.emu";
      else if (field(text, "core") != opts_.core || field(text, "rom") != [&] {
                 char hex[20];
                 std::snprintf(hex, sizeof hex, "%016llx", (unsigned long long)opts_.rom_id);
                 return std::string(hex);
               }())
        why = "The other player runs a different game";
      if (!why.empty()) {
        send(kMsgBye, reinterpret_cast<const uint8_t *>(why.data()), why.size());
        flush();
        fail(why);
        return false;
      }
      {
        std::lock_guard<std::mutex> lk(mtx_);
        hello_ok_ = true;
      }
      state_ = kPlaying;
      return true;
    }
    case kMsgPing:
      send(kMsgPong, bytes.data(), bytes.size());
      return true;
    case kMsgPong:
      if (bytes.size() >= 8) {
        const double rtt = double(dnet_now_ms() - net_get64(bytes.data()));
        std::lock_guard<std::mutex> lk(mtx_);
        rtt_ms_ = rtt_ms_ < 0 ? rtt : rtt_ms_ * 0.8 + rtt * 0.2;
      }
      return true;
    case kMsgBye: {
      const std::string why(bytes.begin(), bytes.end());
      {
        std::lock_guard<std::mutex> lk(mtx_);
        bye_ = why;
      }
      fail(why.empty() ? "The other player left" : why);
      return false;
    }
    default: {
      std::lock_guard<std::mutex> lk(mtx_);
      inbox_.push_back(Message{type, std::move(bytes)});
      return true;
    }
  }
}

void NetplaySession::start_engine(int slot, int method, int delay) {
  NetplayEngine::Config c;
  c.method = method;
  c.local_slot = slot;
  c.delay = delay;
  c.authority = slot == 0;
  engine_.start(c);
}

bool NetplaySession::frame(NetplayDriver &d, const NetInput &local, bool shown, bool *ran) {
  *ran = false;
  if (state_ != kPlaying) {
    engaged_ = false;
    return false;
  }
  std::vector<Message> in;
  double rtt;
  {
    std::lock_guard<std::mutex> lk(mtx_);
    in.swap(inbox_);
    rtt = rtt_ms_;
  }
  Out out(*this);
  for (Message &m : in) {
    if (m.type == kMsgStart) {
      if (opts_.host || m.bytes.size() < 2) continue;
      if (m.bytes.size() > 2 && !d.load(m.bytes.data() + 2, m.bytes.size() - 2)) {
        const char *why = "Could not load the host's game state";
        send(kMsgBye, reinterpret_cast<const uint8_t *>(why), std::strlen(why));
        fail(why);
        return false;
      }
      start_engine(1, m.bytes[0], m.bytes[1]);
    } else if (engine_.started()) {
      engine_.receive(m.type, m.bytes.data(), m.bytes.size());
    }
  }
  if (!engine_.started()) {
    if (!opts_.host) return true;  // the joiner waits for the host's state
    // The host starts once a round trip is measured (AUTO lockstep delay
    // needs it), or after 2 s without one.
    const int64_t now = int64_t(dnet_now_ms());
    if (!sync_since_ms_) sync_since_ms_ = now;
    if (rtt < 0 && now - sync_since_ms_ < 2000) return false;
    const int method = opts_.method;
    int delay = opts_.delay;
    if (delay < 0) {
      delay = method == kNetplayRollback
                  ? 1
                  : std::min(8, int(std::ceil(std::max(rtt, 0.0) / 2 / (1000.0 / 60.0))) + 1);
    }
    std::vector<uint8_t> p{uint8_t(method), uint8_t(delay)};
    const size_t size = d.state_size();
    if (size) {
      p.resize(2 + size);
      if (!d.save(p.data() + 2, size)) p.resize(2);
    }
    send(kMsgStart, p.data(), p.size());
    start_sent_ = true;
    start_engine(0, method, delay);
  }
  engaged_ = true;
  *ran = engine_.tick(d, out, local, shown);
  std::lock_guard<std::mutex> lk(mtx_);
  stats_copy_ = engine_.stats();
  return true;
}

}  // namespace dena
