// SPDX-License-Identifier: GPL-3.0-or-later
// RetroAchievements through rcheevos' rc_client (docs/specs/achievements.md).
//
// One process-wide client. The app performs the HTTP: requests queue here and
// the app takes them, sends them and hands back each response. Results come
// back the same way, as JSON events. Strings go in through dena_ra_buffer()
// as NUL-separated fields; returned strings stay valid until the next call
// that returns one. Unless noted, functions are called from one app thread.
#ifndef DENA_ACHIEVEMENTS_H
#define DENA_ACHIEVEMENTS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "dena/host.h"

#if defined(_WIN32)
#define DENA_RA_API __declspec(dllexport)
#else
#define DENA_RA_API __attribute__((visibility("default")))
#endif

/* A buffer of at least size bytes for the next call's input (and output of
 * dena_ra_hash). */
DENA_RA_API uint8_t *dena_ra_buffer(int32_t size);

/* "rcheevos/x.y" for the app's User-Agent. */
DENA_RA_API const char *dena_ra_user_agent_clause(void);

/* Buffer "user\0password\0" (token = 0) or "user\0token\0" (token = 1).
 * Answered by a "login" event. */
DENA_RA_API void dena_ra_login(int32_t token);
DENA_RA_API void dena_ra_logout(void);

/* Applies to the next game loaded. */
DENA_RA_API void dena_ra_set_hardcore(int32_t on);

/* The next queued HTTP request as {"id":n,"url":"...","post":"..."|null,
 * "type":"..."|null}, or NULL. */
DENA_RA_API const char *dena_ra_take_request(void);
/* The response to request id: status is the HTTP status (negative for a
 * network failure); the body is the buffer's first len bytes. */
DENA_RA_API void dena_ra_respond(int32_t id, int32_t status, int32_t len);

/* The next event as JSON, or NULL. */
DENA_RA_API const char *dena_ra_take_event(void);
/* Keeps a paused session's queue moving (retries, pings); call it often. */
DENA_RA_API void dena_ra_pump(void);

/* Buffer "path\0": starts identifying the running game (after the session
 * started). Answered by a "game" event. */
DENA_RA_API void dena_ra_session_begin(int32_t console_id);
DENA_RA_API void dena_ra_session_end(void);
/* 1 while the loaded game counts as hardcore (any thread). */
DENA_RA_API int32_t dena_ra_hardcore_active(void);
/* The loaded game's achievements as JSON (see the spec), or NULL. */
DENA_RA_API const char *dena_ra_session_list(void);

/* Buffer "path\0": the achievements of a game that is not running, and the
 * user's unlocks. Answered by a "game_info" event carrying seq. */
DENA_RA_API void dena_ra_fetch_game(int32_t console_id, int32_t seq);

/* Emulator thread, after every frame of a session (Runner frame hook). */
void dena_ra_frame(dena_core *core);

/* Tests: drops every queue, the session and the login. */
void dena_ra_reset_for_tests(void);

#ifdef __cplusplus
}
#endif

#endif
