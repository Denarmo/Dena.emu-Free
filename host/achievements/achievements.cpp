// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/achievements.md
#include "achievements.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "rc_api_runtime.h"
#include "rc_api_user.h"
#include "rc_client.h"
#include "rc_consoles.h"
#include "rc_hash.h"
#include "rc_libretro.h"

namespace {

using Handler = std::function<void(const rc_api_server_response_t &)>;

struct Request {
  std::string url, post, type;
  Handler done;
};

struct State {
  std::mutex mtx;  // queues below
  std::deque<std::pair<int, Request>> pending;
  std::map<int, Handler> inflight;
  std::deque<std::string> events;
  int next_id = 1;

  std::mutex mem_mtx;  // memory regions
  dena_core *core = nullptr;
  rc_libretro_memory_regions_t regions{};
  bool regions_ok = false;
  uint32_t console = 0;

  std::atomic<bool> session{false};
  std::atomic<bool> hardcore{false};
  std::atomic<int64_t> last_frame_ns{0};

  // App thread only.
  std::vector<uint8_t> buffer = std::vector<uint8_t>(4096);
  std::string out;
  rc_client_t *client = nullptr;
};

State &g() {
  static State *s = new State;  // never destroyed: detached hash threads use it
  return *s;
}

int64_t now_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// The NUL-separated fields in the input buffer.
std::vector<std::string> fields(size_t n) {
  std::vector<std::string> v;
  auto &b = g().buffer;
  size_t i = 0;
  while (v.size() < n && i < b.size()) {
    size_t end = i;
    while (end < b.size() && b[end]) end++;
    v.emplace_back(reinterpret_cast<const char *>(b.data() + i), end - i);
    i = end + 1;
  }
  while (v.size() < n) v.emplace_back();
  return v;
}

std::string q(const char *s) {
  if (!s) return "null";
  std::string o = "\"";
  for (const char *p = s; *p; p++) {
    unsigned char c = static_cast<unsigned char>(*p);
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) {
          char t[8];
          std::snprintf(t, sizeof t, "\\u%04x", c);
          o += t;
        } else {
          o += char(c);
        }
    }
  }
  return o + "\"";
}
std::string q(const std::string &s) { return q(s.c_str()); }

void post_event(std::string json) {
  std::lock_guard<std::mutex> lk(g().mtx);
  g().events.push_back(std::move(json));
}

void send(Request r) {
  std::lock_guard<std::mutex> lk(g().mtx);
  g().pending.emplace_back(g().next_id++, std::move(r));
}

Request from_api(const rc_api_request_t &req, Handler done) {
  return Request{req.url ? req.url : "", req.post_data ? req.post_data : "",
                 req.content_type ? req.content_type : "", std::move(done)};
}

void RC_CCONV server_call(const rc_api_request_t *req, rc_client_server_callback_t cb,
                          void *cb_data, rc_client_t *) {
  send(from_api(*req, [cb, cb_data](const rc_api_server_response_t &r) { cb(&r, cb_data); }));
}

// rc_libretro has no user pointer; called with mem_mtx held.
void RC_CCONV core_memory_info(uint32_t id, rc_libretro_core_memory_info_t *info) {
  size_t size = 0;
  info->data = static_cast<uint8_t *>(dena_core_memory(g().core, id, &size));
  info->size = info->data ? size : 0;
}

uint32_t RC_CCONV read_memory(uint32_t address, uint8_t *buffer, uint32_t n, rc_client_t *) {
  std::lock_guard<std::mutex> lk(g().mem_mtx);
  if (!g().regions_ok) return 0;
  return rc_libretro_memory_read(&g().regions, address, buffer, n);
}

void drop_regions() {  // mem_mtx held
  if (g().regions_ok) rc_libretro_memory_destroy(&g().regions);
  g().regions_ok = false;
  g().core = nullptr;
}

std::string achievement_json(const rc_client_achievement_t *a) {
  char t[256];
  std::snprintf(t, sizeof t, "{\"id\":%u,\"points\":%u,\"unlocked\":%u,\"unlock_time\":%lld,",
                a->id, a->points, unsigned(a->unlocked), (long long)a->unlock_time);
  std::string o = t;
  o += "\"title\":" + q(a->title) + ",\"description\":" + q(a->description) +
       ",\"badge\":" + q(a->badge_url) + ",\"badge_locked\":" + q(a->badge_locked_url) +
       ",\"progress\":" + q(a->measured_progress);
  std::snprintf(t, sizeof t, ",\"percent\":%.1f}", double(a->measured_percent));
  return o + t;
  return o;
}

void RC_CCONV on_event(const rc_client_event_t *e, rc_client_t *client) {
  switch (e->type) {
    case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
      post_event("{\"type\":\"unlock\",\"hardcore\":" +
                 std::string(rc_client_get_hardcore_enabled(client) ? "true" : "false") +
                 ",\"achievement\":" + achievement_json(e->achievement) + "}");
      break;
    case RC_CLIENT_EVENT_GAME_COMPLETED: {
      const rc_client_game_t *game = rc_client_get_game_info(client);
      post_event("{\"type\":\"mastered\",\"title\":" + q(game ? game->title : "") + "}");
      break;
    }
    case RC_CLIENT_EVENT_SERVER_ERROR:
      post_event("{\"type\":\"error\",\"message\":" + q(e->server_error->error_message) + "}");
      break;
    case RC_CLIENT_EVENT_DISCONNECTED:
      post_event("{\"type\":\"offline\"}");
      break;
    case RC_CLIENT_EVENT_RECONNECTED:
      post_event("{\"type\":\"online\"}");
      break;
    // The desktop overlay's progress box and challenge badges (achievements.md).
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE:
      post_event("{\"type\":\"progress\",\"achievement\":" + achievement_json(e->achievement) +
                 "}");
      break;
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE:
      post_event("{\"type\":\"progress_hide\"}");
      break;
    case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW:
      post_event("{\"type\":\"challenge\",\"achievement\":" + achievement_json(e->achievement) +
                 "}");
      break;
    case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE:
      post_event("{\"type\":\"challenge_hide\",\"id\":" + std::to_string(e->achievement->id) +
                 "}");
      break;
    default:
      break;  // leaderboards are not shown (spec, Not yet)
  }
}

rc_client_t *client() {
  auto &s = g();
  if (!s.client) {
    s.client = rc_client_create(read_memory, server_call);
    rc_client_set_event_handler(s.client, on_event);
    // Memory is read on the emulator thread only, in rc_client_do_frame.
    rc_client_set_allow_background_memory_reads(s.client, 0);
  }
  return s.client;
}

std::string user_json(rc_client_t *c) {
  const rc_client_user_t *u = rc_client_get_user_info(c);
  if (!u) return "null";
  char t[96];
  std::snprintf(t, sizeof t, "\"score\":%u,\"softcore_score\":%u", u->score, u->score_softcore);
  return "{\"user\":" + q(u->username) + ",\"display\":" + q(u->display_name) +
         ",\"token\":" + q(u->token) + ",\"avatar\":" + q(u->avatar_url) + "," + t + "}";
}

void RC_CCONV on_login(int result, const char *error, rc_client_t *c, void *) {
  if (result == RC_OK)
    post_event("{\"type\":\"login\",\"ok\":true,\"account\":" + user_json(c) + "}");
  else
    post_event("{\"type\":\"login\",\"ok\":false,\"error\":" +
               q(error && *error ? error : rc_error_str(result)) + "}");
}

void RC_CCONV on_game(int result, const char *error, rc_client_t *c, void *) {
  if (result != RC_OK) {
    g().hardcore = false;
    post_event("{\"type\":\"game\",\"ok\":false,\"unknown\":" +
               std::string(result == RC_NO_GAME_LOADED ? "true" : "false") +
               ",\"error\":" + q(error && *error ? error : rc_error_str(result)) + "}");
    return;
  }
  const rc_client_game_t *game = rc_client_get_game_info(c);
  rc_client_user_game_summary_t sum{};
  rc_client_get_user_game_summary(c, &sum);
  bool hardcore = rc_client_get_hardcore_enabled(c) && sum.num_core_achievements > 0;
  g().hardcore = hardcore;
  char t[192];
  std::snprintf(t, sizeof t,
                "\"id\":%u,\"total\":%u,\"unlocked\":%u,\"points\":%u,\"points_unlocked\":%u,"
                "\"hardcore\":%s",
                game ? game->id : 0, sum.num_core_achievements, sum.num_unlocked_achievements,
                sum.points_core, sum.points_unlocked, hardcore ? "true" : "false");
  post_event("{\"type\":\"game\",\"ok\":true,\"title\":" + q(game ? game->title : "") +
             ",\"image\":" + q(game ? game->badge_url : nullptr) + "," + t + "}");
}

// The game page's list: achievementsets, then hardcore and softcore unlocks.
struct Browse {
  int seq;
  std::string user, token;
  std::string game_json;  // without the closing brace
  std::vector<std::pair<uint32_t, std::string>> achievements;  // id, json prefix
  std::map<uint32_t, int> unlocked;                             // id -> 1 soft, 2 hard
  uint32_t game_id = 0;
};

void browse_fail(int seq, const std::string &msg) {
  post_event("{\"type\":\"game_info\",\"seq\":" + std::to_string(seq) +
             ",\"ok\":false,\"error\":" + q(msg) + "}");
}

void browse_finish(const std::shared_ptr<Browse> &b) {
  std::string o = b->game_json + ",\"achievements\":[";
  bool first = true;
  for (auto &a : b->achievements) {
    if (!first) o += ",";
    first = false;
    auto it = b->unlocked.find(a.first);
    o += a.second + ",\"unlocked\":" + std::to_string(it == b->unlocked.end() ? 0 : it->second) +
         "}";
  }
  post_event(o + "]}");
}

void browse_unlocks(const std::shared_ptr<Browse> &b, bool hardcore) {
  rc_api_fetch_user_unlocks_request_t p{};
  p.username = b->user.c_str();
  p.api_token = b->token.c_str();
  p.game_id = b->game_id;
  p.hardcore = hardcore ? 1 : 0;
  rc_api_request_t req{};
  if (rc_api_init_fetch_user_unlocks_request(&req, &p) != RC_OK) return browse_fail(b->seq, "request failed");
  send(from_api(req, [b, hardcore](const rc_api_server_response_t &r) {
    rc_api_fetch_user_unlocks_response_t res{};
    int rc = rc_api_process_fetch_user_unlocks_server_response(&res, &r);
    if (rc == RC_OK && res.response.succeeded) {
      for (uint32_t i = 0; i < res.num_achievement_ids; i++) {
        int &v = b->unlocked[res.achievement_ids[i]];
        if (v < (hardcore ? 2 : 1)) v = hardcore ? 2 : 1;
      }
    }
    rc_api_destroy_fetch_user_unlocks_response(&res);
    // Unlocks are extra: a failed query still shows the list, all locked.
    if (hardcore)
      browse_unlocks(b, false);
    else
      browse_finish(b);
  }));
  rc_api_destroy_request(&req);
}

void browse_sets(const std::shared_ptr<Browse> &b, const std::string &hash) {
  rc_api_fetch_game_sets_request_t p{};
  p.username = b->user.c_str();
  p.api_token = b->token.c_str();
  p.game_hash = hash.c_str();
  rc_api_request_t req{};
  if (rc_api_init_fetch_game_sets_request(&req, &p) != RC_OK) return browse_fail(b->seq, "request failed");
  send(from_api(req, [b](const rc_api_server_response_t &r) {
    rc_api_fetch_game_sets_response_t res{};
    int rc = rc_api_process_fetch_game_sets_server_response(&res, &r);
    if (rc != RC_OK || !res.response.succeeded) {
      browse_fail(b->seq, res.response.error_message ? res.response.error_message
                                                     : rc_error_str(rc));
    } else if (res.id == 0) {
      browse_fail(b->seq, "unknown");
    } else {
      b->game_id = res.session_game_id ? res.session_game_id : res.id;
      b->game_json = "{\"type\":\"game_info\",\"seq\":" + std::to_string(b->seq) +
                     ",\"ok\":true,\"id\":" + std::to_string(res.id) +
                     ",\"title\":" + q(res.title) + ",\"image\":" + q(res.image_url);
      for (uint32_t s = 0; s < res.num_sets; s++) {
        const auto &set = res.sets[s];
        if (set.type != RC_ACHIEVEMENT_SET_TYPE_CORE) continue;  // subsets: not yet
        for (uint32_t i = 0; i < set.num_achievements; i++) {
          const auto &a = set.achievements[i];
          if (a.category != RC_ACHIEVEMENT_CATEGORY_CORE) continue;
          char t[96];
          std::snprintf(t, sizeof t, "{\"id\":%u,\"points\":%u,\"rarity\":%.1f,", a.id, a.points,
                        double(a.rarity));
          b->achievements.emplace_back(
              a.id, t + std::string("\"title\":") + q(a.title) + ",\"description\":" +
                        q(a.description) + ",\"badge\":" + q(a.badge_url) +
                        ",\"badge_locked\":" + q(a.badge_locked_url));
        }
      }
      browse_unlocks(b, true);
    }
    rc_api_destroy_fetch_game_sets_response(&res);
  }));
  rc_api_destroy_request(&req);
}

}  // namespace

extern "C" {

uint8_t *dena_ra_buffer(int32_t size) {
  auto &b = g().buffer;
  if (size > 0 && size_t(size) + 1 > b.size()) b.resize(size_t(size) + 1);
  return b.data();
}

const char *dena_ra_user_agent_clause(void) {
  char t[64] = {0};
  rc_client_get_user_agent_clause(client(), t, sizeof t);
  g().out = t;
  return g().out.c_str();
}

void dena_ra_login(int32_t token) {
  auto f = fields(2);
  if (token)
    rc_client_begin_login_with_token(client(), f[0].c_str(), f[1].c_str(), on_login, nullptr);
  else
    rc_client_begin_login_with_password(client(), f[0].c_str(), f[1].c_str(), on_login, nullptr);
}

void dena_ra_logout(void) { rc_client_logout(client()); }

void dena_ra_set_hardcore(int32_t on) {
  // Changed only between sessions, so turning it on never resets a game.
  rc_client_set_hardcore_enabled(client(), on ? 1 : 0);
}

const char *dena_ra_take_request(void) {
  auto &s = g();
  std::lock_guard<std::mutex> lk(s.mtx);
  if (s.pending.empty()) return nullptr;
  auto item = std::move(s.pending.front());
  s.pending.pop_front();
  const Request &r = item.second;
  s.out = "{\"id\":" + std::to_string(item.first) + ",\"url\":" + q(r.url) +
          ",\"post\":" + (r.post.empty() ? std::string("null") : q(r.post)) +
          ",\"type\":" + (r.type.empty() ? std::string("null") : q(r.type)) + "}";
  s.inflight[item.first] = std::move(item.second.done);
  return s.out.c_str();
}

void dena_ra_respond(int32_t id, int32_t status, int32_t len) {
  Handler done;
  {
    std::lock_guard<std::mutex> lk(g().mtx);
    auto it = g().inflight.find(id);
    if (it == g().inflight.end()) return;
    done = std::move(it->second);
    g().inflight.erase(it);
  }
  std::string body;
  if (len > 0 && size_t(len) <= g().buffer.size())
    body.assign(reinterpret_cast<const char *>(g().buffer.data()), size_t(len));
  rc_api_server_response_t r{};
  r.body = body.c_str();
  r.body_length = body.size();
  // A network failure is retryable: rc_client queues unlocks until it is back.
  r.http_status_code = status > 0 ? status : RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;
  done(r);
}

const char *dena_ra_take_event(void) {
  auto &s = g();
  std::lock_guard<std::mutex> lk(s.mtx);
  if (s.events.empty()) return nullptr;
  s.out = std::move(s.events.front());
  s.events.pop_front();
  return s.out.c_str();
}

void dena_ra_pump(void) {
  auto &s = g();
  if (!s.client || !s.session) return;
  // Paused (no frames for a second): the queue still needs servicing.
  if (now_ns() - s.last_frame_ns > 1000000000LL) rc_client_idle(s.client);
}

void dena_ra_session_begin(int32_t console_id) {
  auto &s = g();
  std::string path = fields(1)[0];
  rc_client_t *c = client();
  {
    std::lock_guard<std::mutex> lk(s.mem_mtx);
    drop_regions();
    s.console = uint32_t(console_id);
  }
  s.hardcore = false;
  s.session = true;
  // Hashing reads the file; keep it off the app thread.
  std::thread([c, path, console_id] {
    rc_client_begin_identify_and_load_game(c, uint32_t(console_id), path.c_str(), nullptr, 0,
                                           on_game, nullptr);
  }).detach();
}

void dena_ra_session_end(void) {
  auto &s = g();
  s.session = false;
  s.hardcore = false;
  if (s.client) rc_client_unload_game(s.client);
  std::lock_guard<std::mutex> lk(s.mem_mtx);
  drop_regions();
}

int32_t dena_ra_hardcore_active(void) { return g().hardcore ? 1 : 0; }

const char *dena_ra_session_list(void) {
  auto &s = g();
  if (!s.client || !rc_client_is_game_loaded(s.client)) return nullptr;
  rc_client_achievement_list_t *list = rc_client_create_achievement_list(
      s.client, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE, RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_LOCK_STATE);
  std::string o = "[";
  bool first = true;
  for (uint32_t b = 0; list && b < list->num_buckets; b++)
    for (uint32_t i = 0; i < list->buckets[b].num_achievements; i++) {
      if (!first) o += ",";
      first = false;
      o += achievement_json(list->buckets[b].achievements[i]);
    }
  rc_client_destroy_achievement_list(list);
  s.out = o + "]";
  return s.out.c_str();
}

void dena_ra_fetch_game(int32_t console_id, int32_t seq) {
  std::string path = fields(1)[0];
  const rc_client_user_t *u = rc_client_get_user_info(client());
  if (!u) return browse_fail(seq, "Sign in to RetroAchievements first");
  auto b = std::make_shared<Browse>();
  b->seq = seq;
  b->user = u->username ? u->username : "";
  b->token = u->token ? u->token : "";
  std::thread([b, path, console_id] {
    char hash[33] = {0};
    if (!rc_hash_generate_from_file(hash, uint32_t(console_id), path.c_str()))
      return browse_fail(b->seq, "unknown");
    browse_sets(b, hash);
  }).detach();
}

void dena_ra_frame(dena_core *core) {
  auto &s = g();
  if (!s.session || !s.client) return;
  {
    std::lock_guard<std::mutex> lk(s.mem_mtx);
    if (core != s.core) {
      drop_regions();
      s.core = core;
      s.regions_ok = rc_libretro_memory_init(
                         &s.regions,
                         static_cast<const struct retro_memory_map *>(dena_core_memory_map(core)),
                         core_memory_info, s.console) != 0;
    }
  }
  s.last_frame_ns = now_ns();
  rc_client_do_frame(s.client);
}

void dena_ra_reset_for_tests(void) {
  auto &s = g();
  dena_ra_session_end();
  if (s.client) rc_client_destroy(s.client);
  s.client = nullptr;
  std::lock_guard<std::mutex> lk(s.mtx);
  s.pending.clear();
  s.inflight.clear();
  s.events.clear();
}

}  // extern "C"
