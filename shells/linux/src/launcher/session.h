/* SPDX-License-Identifier: GPL-3.0-or-later
 * C interface from the launcher (C) to the game session (C++: the shared
 * runner, the Linux platform and the Pigeon bridge).
 * Spec: docs/specs/handheld-session.md */
#ifndef DENA_SESSION_H
#define DENA_SESSION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct dena_session_config {
  int drm_fd;
  int crtc_index;
  int refresh_mhz;
  int screen_width, screen_height; /* as the UI sees it (after rotation) */
  const char *audio_card; /* ALSA device, NULL for "default" */
  const char *card;       /* SD card root ($DENA_CARD) */
  /* EGLDisplay and the engine's resource EGLContext, for GPU cores. */
  void *egl_display;
  void *egl_share_context;
  /* Any thread: a new game frame is ready (mark texture 1 available). */
  void (*frame_ready)(void *user);
  /* Main thread: send this Pigeon message to Dart (no reply expected). */
  void (*send)(void *user, const char *channel, const uint8_t *msg, size_t len);
  void *user;
};

void dena_session_init(const struct dena_session_config *cfg);
/* Stops a running game (saves first). */
void dena_session_shutdown(void);

/* Main thread: a platform message from Dart. Returns true when handled;
 * *reply (malloc'd, the caller frees) and *reply_len hold the response. */
bool dena_session_message(const char *channel, const uint8_t *msg, size_t len, uint8_t **reply,
                          size_t *reply_len);

/* Main thread: whether a game runs and is not paused (its buttons go to the
 * core, not to Flutter). */
bool dena_session_playing(void);

/* Main thread: a profile action (RetroPad id or DENA_KEY_MENU) pressed or
 * released. Returns true when the game took it (not for Flutter): Menu, or
 * Start + Select, opens the pause menu (dena_game_input). */
bool dena_session_input(int action, bool down, int64_t event_ns);

/* Raster thread: the newest GPU core frame as a GL texture name (shared with
 * the engine's contexts), or 0 when the game draws in software. */
unsigned dena_session_gpu_frame(uint32_t *width, uint32_t *height);

/* Raster thread: the newest game frame as RGBA bytes; false before the first.
 * *fresh tells whether it changed since the last call. */
bool dena_session_frame(const uint8_t **rgba, uint32_t *width, uint32_t *height, bool *fresh);

#ifdef __cplusplus
}
#endif
#endif
