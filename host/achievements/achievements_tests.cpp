// SPDX-License-Identifier: GPL-3.0-or-later
// Achievements against a fake server and the testcore (achievements.md, Tests).
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <string>
#include <thread>

#include "achievements.h"

static int failures = 0;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      failures++;                                                 \
    }                                                             \
  } while (0)

static void put(const std::string &fields) {
  std::memcpy(dena_ra_buffer(int32_t(fields.size())), fields.data(), fields.size());
  dena_ra_buffer(0)[fields.size()] = 0;
}

static const char *kAch =
    "{\"ID\":101,\"Title\":\"Six\",\"Description\":\"Reach six\",\"Flags\":3,\"Points\":10,"
    "\"MemAddr\":\"0xH0001=6\",\"Author\":\"a\",\"BadgeName\":\"00101\",\"Created\":1,"
    "\"Modified\":1},"
    // Measured: the overlay's progress box (6/20 once RAM[1] is 6).
    "{\"ID\":102,\"Title\":\"Twenty\",\"Description\":\"Reach twenty\",\"Flags\":3,"
    "\"Points\":5,\"MemAddr\":\"M:0xH0001=20\",\"Author\":\"a\",\"BadgeName\":\"00102\","
    "\"Created\":1,\"Modified\":1},"
    // Primed while RAM[0] is 5: the overlay's challenge badge.
    "{\"ID\":103,\"Title\":\"Challenge\",\"Description\":\"Hold five\",\"Flags\":3,"
    "\"Points\":5,\"MemAddr\":\"0xH0000=5_T:0xH0001=99\",\"Author\":\"a\","
    "\"BadgeName\":\"00103\",\"Created\":1,\"Modified\":1}";

static std::string sets_json() {
  return std::string(
             "{\"Success\":true,\"GameId\":77,\"Title\":\"Test Game\",\"ConsoleId\":7,"
             "\"ImageIconUrl\":\"http://media/Images/1.png\",\"RichPresenceGameId\":77,"
             "\"RichPresencePatch\":\"\",\"Sets\":[{\"AchievementSetId\":5,\"GameId\":77,"
             "\"Title\":null,\"Type\":\"core\",\"ImageIconUrl\":\"http://media/Images/1.png\","
             "\"Achievements\":[") +
         kAch + "],\"Leaderboards\":[]}]}";
}

// Answers every queued request like the server would; returns how many.
static int serve(std::string *seen = nullptr) {
  int n = 0;
  while (const char *req = dena_ra_take_request()) {
    std::string r = req;
    if (seen) *seen += r + "\n";
    int id = std::atoi(r.c_str() + 6);  // {"id":N
    std::string body = "{\"Success\":true}";
    if (r.find("r=login2") != std::string::npos)
      body = r.find("p=secret") != std::string::npos || r.find("t=tok") != std::string::npos
                 ? "{\"Success\":true,\"User\":\"tester\",\"Token\":\"tok\",\"Score\":12,"
                   "\"SoftcoreScore\":3,\"Messages\":0}"
                 : "{\"Success\":false,\"Error\":\"Invalid user/password combination.\","
                   "\"Code\":\"invalid_credentials\"}";
    else if (r.find("r=achievementsets") != std::string::npos)
      body = sets_json();
    else if (r.find("r=unlocks") != std::string::npos)
      body = r.find("h=1") != std::string::npos ? "{\"Success\":true,\"UserUnlocks\":[]}"
                                                : "{\"Success\":true,\"UserUnlocks\":[101]}";
    else if (r.find("r=awardachievement") != std::string::npos)
      body = "{\"Success\":true,\"Score\":22,\"SoftcoreScore\":3,\"AchievementID\":101,"
             "\"AchievementsRemaining\":0}";
    std::memcpy(dena_ra_buffer(int32_t(body.size())), body.data(), body.size());
    dena_ra_respond(id, 200, int32_t(body.size()));
    n++;
  }
  return n;
}

static dena_core *g_core = nullptr;  // frames run while waiting, as in a session
static std::deque<std::string> g_skipped;  // events another wait may want

static std::string wait_event(const char *type) {
  std::string want = std::string("\"type\":\"") + type + "\"";
  for (auto it = g_skipped.begin(); it != g_skipped.end(); ++it) {
    if (it->find(want) != std::string::npos) {
      std::string e = *it;
      g_skipped.erase(it);
      return e;
    }
  }
  for (int i = 0; i < 400; i++) {
    serve();
    while (const char *e = dena_ra_take_event()) {
      if (std::strstr(e, want.c_str())) return e;
      g_skipped.push_back(e);
    }
    if (g_core) {
      dena_core_run_frame(g_core);
      dena_ra_frame(g_core);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return "";
}

int main(int argc, char **argv) {
  const char *core_path = argc > 1 ? argv[1] : nullptr;
  std::string tmp = argc > 2 ? argv[2] : ".";
  std::string rom = tmp + "/ra_test.nes";
  {
    std::ofstream f(rom, std::ios::binary);
    for (int i = 0; i < 4096; i++) f.put(char(i * 7));
  }

  // Wrong password, then right password.
  put(std::string("tester\0wrong\0", 13));
  dena_ra_login(0);
  std::string e = wait_event("login");
  CHECK(e.find("\"ok\":false") != std::string::npos);
  CHECK(e.find("Invalid user/password") != std::string::npos);
  put(std::string("tester\0secret\0", 14));
  dena_ra_login(0);
  e = wait_event("login");
  CHECK(e.find("\"ok\":true") != std::string::npos);
  CHECK(e.find("\"token\":\"tok\"") != std::string::npos);
  CHECK(e.find("\"score\":12") != std::string::npos);

  // Game page list: achievements with the softcore unlock marked.
  put(rom + std::string(1, '\0'));
  dena_ra_fetch_game(7, 42);
  e = wait_event("game_info");
  CHECK(e.find("\"seq\":42") != std::string::npos);
  CHECK(e.find("\"title\":\"Test Game\"") != std::string::npos);
  CHECK(e.find("\"title\":\"Six\"") != std::string::npos);
  CHECK(e.find("\"unlocked\":1") != std::string::npos);

  if (!core_path) {
    std::fprintf(stderr, "no testcore: session part skipped\n");
    return failures ? 1 : 0;
  }

  // Session: load the testcore, identify, unlock when RAM[1] reaches 6.
  char err[256] = {0};
  dena_core *core = dena_core_load(core_path, err, sizeof err);
  CHECK(core != nullptr);
  if (!core) return 1;
  CHECK(dena_core_load_game(core, rom.c_str(), err, sizeof err) == 0);
  dena_ra_set_hardcore(1);
  g_core = core;
  put(rom + std::string(1, '\0'));
  dena_ra_session_begin(7);
  e = wait_event("game");
  CHECK(e.find("\"ok\":true") != std::string::npos);
  CHECK(e.find("\"total\":3") != std::string::npos);
  CHECK(e.find("\"hardcore\":true") != std::string::npos);
  CHECK(dena_ra_hardcore_active() == 1);

  for (int i = 0; i < 5; i++) {
    dena_core_run_frame(core);
    dena_ra_frame(core);
  }
  const char *list = dena_ra_session_list();
  CHECK(list && std::strstr(list, "\"title\":\"Six\""));
  size_t size = 0;
  auto *ram = static_cast<uint8_t *>(dena_core_memory(core, 2, &size));
  CHECK(ram && size >= 2);
  if (ram) ram[0] = 5;  // the core sets RAM[1] = RAM[0] + 1 each frame
  for (int i = 0; i < 3; i++) {
    dena_core_run_frame(core);
    dena_ra_frame(core);
  }
  e = wait_event("unlock");
  CHECK(e.find("\"id\":101") != std::string::npos);
  CHECK(e.find("\"hardcore\":true") != std::string::npos);
  e = wait_event("progress");
  CHECK(e.find("\"id\":102") != std::string::npos);
  CHECK(e.find("\"progress\":\"6/20\"") != std::string::npos);
  CHECK(e.find("\"percent\":30.0") != std::string::npos);
  e = wait_event("challenge");
  CHECK(e.find("\"id\":103") != std::string::npos);
  if (ram) ram[0] = 7;  // no longer primed
  e = wait_event("challenge_hide");
  CHECK(e.find("\"id\":103") != std::string::npos);
  std::string seen;
  serve(&seen);

  g_core = nullptr;
  dena_ra_session_end();
  CHECK(dena_ra_hardcore_active() == 0);
  CHECK(dena_ra_session_list() == nullptr);
  dena_core_unload(core);
  dena_ra_reset_for_tests();
  std::remove(rom.c_str());
  if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
  else std::printf("achievements: ok\n");
  return failures ? 1 : 0;
}
