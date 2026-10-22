// SPDX-License-Identifier: GPL-3.0-or-later
// Two runners play one game over 127.0.0.1 (docs/specs/netplay.md, Tests):
// handshake, START, a few hundred frames of the host's input, equal
// pictures at the same frame; a different ROM is refused; states, rewind
// and fast-forward stay off while connected.
// The joiner is a second process (one core per process).
// Usage: netplay_loopback <testcore> <tmpdir>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "runner.h"

#if defined(_WIN32)
int main() {
  std::printf("netplay loopback: needs fork, skipped on Windows\n");
  return 77;
}
#else
namespace {

int failures = 0;

#define CHECK(cond)                                                        \
  do {                                                                     \
    if (!(cond)) {                                                         \
      std::fprintf(stderr, "%s:%d: FAIL %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                          \
    }                                                                      \
  } while (0)

class FakePlatform : public dena::RunnerPlatform {
 public:
  std::vector<uint64_t> shown;

  void wait(bool) override {
    std::unique_lock<std::mutex> lk(mtx_);
    cv_.wait_for(lk, std::chrono::milliseconds(20), [this] { return woken_; });
    woken_ = false;
  }
  void wake() override {
    std::lock_guard<std::mutex> lk(mtx_);
    woken_ = true;
    cv_.notify_all();
  }
  bool has_surface() override { return true; }
  bool start_gpu(unsigned, unsigned, bool, bool) override { return false; }
  bool gpu_ready() override { return false; }
  uintptr_t gpu_framebuffer() override { return 0; }
  void *gl_proc_address(const char *) override { return nullptr; }
  void stop_gpu() override {}
  bool draw_software(const dena_frame &f, int) override {
    shown.push_back(dena_frame_hash(&f));
    return true;
  }
  bool draw_gpu(unsigned, unsigned, bool, int) override { return false; }
  bool read_pixels(unsigned, unsigned, bool, std::vector<uint32_t> &) override { return false; }
  int open_audio() override { return 48000; }
  bool start_audio() override { return true; }
  void pause_audio() override {}
  void close_audio() override {}

 private:
  std::mutex mtx_;
  std::condition_variable cv_;
  bool woken_ = false;
};

const int64_t kPeriod = 16666667;

struct Side {
  FakePlatform fake;
  dena::Runner runner{&fake};
  std::shared_ptr<dena::NetplaySession> net = std::make_shared<dena::NetplaySession>();
  int64_t t = 1000000000LL;

  void vsync() {
    t += kPeriod;
    runner.run_on_emu([&] { runner.on_vsync(t); });
  }
  uint64_t last() {
    uint64_t h = 0;
    runner.run_on_emu([&] { h = fake.shown.empty() ? 0 : fake.shown.back(); });
    return h;
  }
  long long frame() {
    long long f = -1;
    const std::string j = net->info_json();
    const size_t at = j.find("\"frame\":");
    if (at != std::string::npos) std::sscanf(j.c_str() + at, "\"frame\":%lld", &f);
    return f;
  }
};

std::string g_dir;

void write_file(const std::string &p, const char *data) {
  FILE *f = std::fopen(p.c_str(), "wb");
  if (!f) return;
  std::fputs(data, f);
  std::fclose(f);
}

bool wait_for(const std::function<bool()> &cond, int ms) {
  for (int i = 0; i < ms / 5; i++) {
    if (cond()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return cond();
}

dena::NetplaySession::Options options(bool host, const std::string &core, uint64_t rom_id) {
  dena::NetplaySession::Options o;
  o.host = host;
  o.target = "127.0.0.1:47395";
  o.port = 47395;
  o.core = core.substr(core.find_last_of("/\\") + 1);
  o.rom_id = rom_id;
  o.method = dena::netplay_method(core);
  return o;
}

constexpr long long kFrames = 500;  // both sides stop here and compare
constexpr long long kInputFrames = 380;  // the host's buttons change until here

// Plays until the engine reaches kFrames. The host's buttons follow its own
// frame number, so both runs are the same game whatever the timing.
bool play_to_end(Side &s, bool host) {
  return wait_for([&] {
    const long long f = s.frame();
    if (f >= kFrames) return true;
    if (host) s.runner.set_buttons(0, f < kInputFrames ? ((f / 7) % 2 ? 0x30 : 0x0c) : 0, 0);
    s.vsync();
    std::this_thread::sleep_for(std::chrono::microseconds(300));
    return false;
  }, 30000);
}

// The joiner: its own process (one core per process).
int joiner_main(const std::string &core, const std::string &rom, int to_host, int from_host) {
  Side b;
  if (b.runner.start(core, rom, g_dir, g_dir + "/b.srm", "") < 0) return 10;
  // Its game is somewhere else before it joins: START replaces it.
  b.runner.set_buttons(0, 0x10, 0);
  for (int i = 0; i < 30; i++) b.vsync();
  b.runner.set_buttons(0, 0, 0);
  b.runner.set_netplay(b.net);
  if (!b.net->start(options(false, core, dena::netplay_rom_id(rom)))) return 11;
  if (!wait_for([&] {
        b.vsync();
        return b.runner.netplay_active();
      }, 5000))
    return 12;
  if (!play_to_end(b, false)) return 13;
  const std::string info = b.net->info_json();
  if (info.find("\"slot\":1") == std::string::npos) return 14;
  if (info.find("\"via_relay\":false") == std::string::npos) return 15;
  const uint64_t h = b.last();
  if (write(to_host, &h, sizeof h) != sizeof h) return 16;
  char done;
  if (read(from_host, &done, 1) != 1) return 17;
  b.net->stop();  // leaves: the host plays on alone
  b.runner.set_netplay(nullptr);
  b.runner.stop();
  return 0;
}

void test_play(const std::string &core) {
  const std::string rom = g_dir + "/net.rom";
  write_file(rom, "dena netplay");
  const uint64_t id = dena::netplay_rom_id(rom);
  CHECK(id != 0);
  CHECK(dena::netplay_method(core) == dena::kNetplayRollback);  // testcore

  int up[2], down[2];
  if (pipe(up) != 0 || pipe(down) != 0) {
    CHECK(!"pipe");
    return;
  }
  const pid_t pid = fork();
  if (pid == 0) _exit(joiner_main(core, rom, up[1], down[0]));

  Side a;
  CHECK(a.runner.start(core, rom, g_dir, g_dir + "/a.srm", "") >= 0);
  a.runner.set_netplay(a.net);
  CHECK(a.net->start(options(true, core, id)));
  CHECK(wait_for([&] {
    a.vsync();
    return a.runner.netplay_active();
  }, 5000));
  CHECK(a.net->state() == dena::NetplaySession::kPlaying);

  // Netplay turns off what would split the two games.
  a.runner.set_speed(4);
  CHECK(a.runner.load_state(g_dir + "/none.state") == -1);
  CHECK(a.runner.error().find("netplay") != std::string::npos);
  CHECK(!a.runner.rewinding());

  CHECK(play_to_end(a, true));
  a.runner.set_speed(1);
  uint64_t theirs = 0;
  CHECK(read(up[0], &theirs, sizeof theirs) == sizeof theirs);
  const uint64_t mine = a.last();
  std::printf("netplay: host %s\n", a.net->info_json().c_str());
  CHECK(mine != 0);
  CHECK(mine == theirs);  // the same picture at frame kFrames on both PCs
  CHECK(a.frame() == kFrames);
  CHECK(write(down[1], "x", 1) == 1);

  // The joiner leaves: the host plays on alone.
  CHECK(wait_for([&] {
    a.vsync();
    return !a.runner.netplay_active();
  }, 5000));
  CHECK(a.net->state() == dena::NetplaySession::kEnded);
  CHECK(a.net->error().find("left") != std::string::npos);
  const uint64_t before = a.last();
  a.runner.set_buttons(0, 0x40, 0);
  for (int i = 0; i < 10; i++) a.vsync();
  CHECK(a.last() != before);  // frames run again without the other player
  int status = 0;
  waitpid(pid, &status, 0);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  if (WIFEXITED(status) && WEXITSTATUS(status)) std::fprintf(stderr, "joiner exit %d\n", WEXITSTATUS(status));
  a.runner.set_netplay(nullptr);
  a.net->stop();
  a.runner.stop();
}

void test_different_rom(const std::string &core) {
  dena::NetplaySession a, b;
  CHECK(a.start(options(true, core, 1)));
  CHECK(b.start(options(false, core, 2)));
  CHECK(wait_for([&] { return b.state() == dena::NetplaySession::kEnded; }, 5000));
  CHECK(b.error().find("different game") != std::string::npos);
  CHECK(wait_for([&] { return a.state() == dena::NetplaySession::kEnded; }, 5000));
  a.stop();
  b.stop();
  CHECK(a.state() == dena::NetplaySession::kOff);
}

void test_nobody_there() {
  dena::NetplaySession b;
  dena::NetplaySession::Options o;
  o.target = "127.0.0.1:47394";
  CHECK(b.start(o));
  CHECK(wait_for([&] { return b.state() == dena::NetplaySession::kEnded; }, 8000));
  CHECK(!b.error().empty());
  // A room code without a relay setting says so.
  dena::NetplaySession c;
  o.target = "ABCDEF";
  CHECK(c.start(o));
  CHECK(wait_for([&] { return c.state() == dena::NetplaySession::kEnded; }, 3000));
  CHECK(!c.error().empty());
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: netplay_loopback <testcore> <tmpdir>\n");
    return 2;
  }
  g_dir = argv[2];
  test_play(argv[1]);
  test_different_rom(argv[1]);
  test_nobody_there();
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("netplay loopback passed\n");
  return 0;
}
#endif
