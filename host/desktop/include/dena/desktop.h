/* SPDX-License-Identifier: GPL-3.0-or-later
 * The desktop host library (dena_host.dll / libdena_host.so): the shared
 * runner with an SDL3 platform, answering the session's Pigeon calls for the
 * stock Flutter Windows and Linux runners, plus the dart:ffi entry points.
 * The runners load it at run time (desktop_loader.h), so a build without it
 * still starts (no games). Spec: docs/specs/desktop-shell.md */
#ifndef DENA_DESKTOP_H
#define DENA_DESKTOP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped when a runner-facing function or struct changes. */
#define DENA_DESKTOP_API_VERSION 1

struct dena_desktop_config {
  uint32_t struct_size; /* sizeof(struct dena_desktop_config) */
  void *user;
  /* Any thread: a new game frame is ready (mark the texture available). */
  void (*frame_ready)(void *user);
  /* Any thread: send this Pigeon message to Dart. The runner copies it and
   * sends it from the platform thread; no reply is expected. */
  void (*send)(void *user, const char *channel, const uint8_t *msg, size_t len);
  /* Windows: the top-level HWND, so vsync follows the monitor it is on.
   * NULL elsewhere. */
  void *window;
  /* The display's refresh rate in mHz for clock pacing; 0 for 60 Hz.
   * Windows reads vblanks from DXGI and uses this only as a fallback. */
  int refresh_mhz;
};

/* Main thread, once. Returns DENA_DESKTOP_API_VERSION, or 0 when the
 * library could not start (no game sessions; the UI still runs). */
int dena_desktop_init(const struct dena_desktop_config *cfg);
/* Main thread: stops a running game (it saves first) and SDL. */
void dena_desktop_shutdown(void);

/* The GameHostApi channels to answer, one per line. Static storage. */
const char *dena_desktop_channels(void);
/* Main thread: a platform message from Dart on one of those channels.
 * Returns true when handled; *reply (free with dena_desktop_free) and
 * *reply_len hold the response. */
bool dena_desktop_message(const char *channel, const uint8_t *msg, size_t len, uint8_t **reply,
                          size_t *reply_len);
void dena_desktop_free(void *p);

/* Keys the runners pass to dena_desktop_key: 'A'..'Z' and '0'..'9' as
 * ASCII, the rest below. */
enum {
  DENA_DESKTOP_KEY_UP = 0x100,
  DENA_DESKTOP_KEY_DOWN,
  DENA_DESKTOP_KEY_LEFT,
  DENA_DESKTOP_KEY_RIGHT,
  DENA_DESKTOP_KEY_ENTER,
  DENA_DESKTOP_KEY_RSHIFT,
  DENA_DESKTOP_KEY_BACKSPACE,
  DENA_DESKTOP_KEY_ESCAPE,
  DENA_DESKTOP_KEY_SPACE,
  DENA_DESKTOP_KEY_TAB,
};
/* Main thread: a key went down or up. Returns true when a game took it
 * (it must not reach Flutter); false when no game is playing or the key is
 * not bound. */
bool dena_desktop_key(int key, bool down);

/* Main thread: the texture the runner registered for the game picture
 * (Dart shows it with Texture(textureId: dena_desktop_texture())). */
void dena_desktop_set_texture(int64_t id);
/* The display refresh changed (Linux: the window moved to a monitor). */
void dena_desktop_set_refresh(int refresh_mhz);

/* Main thread: the system is about to sleep (deck-presets.md, Suspend and
 * resume). A playing game pauses, which writes its battery save and
 * auto-save state; returns when they are written. 1 when a game is loaded
 * (saved), 0 without one. */
int32_t dena_desktop_suspend(void);
/* Main thread: the system woke up. Resumes only a game the last suspend
 * paused; a second call does nothing. */
void dena_desktop_resume(void);

/* Raster thread, Linux (FlPixelBufferTexture): the newest frame as RGBA
 * bytes, valid until the next call; false before the first frame. */
bool dena_desktop_frame_rgba(const uint8_t **rgba, uint32_t *width, uint32_t *height);
/* Raster thread, Windows (GpuSurfaceTexture): the newest frame's D3D11
 * shared handle (B8G8R8A8, top row first), NULL before the first frame. */
void *dena_desktop_frame_d3d(uint32_t *width, uint32_t *height);

/* ---- dart:ffi (main isolate) ---- */

/* The game texture id, -1 when the runner registered none. */
int64_t dena_desktop_texture(void);
/* The storage root (desktop-shell.md, Storage): Bios/, Screenshots/ and
 * cores/ live under it. UTF-8. Before the first game. */
void dena_desktop_set_root(const char *path);
/* Gamepads connected now (desktop-shell.md, Controllers). */
int32_t dena_desktop_gamepads(void);
/* The runner's metrics JSON (latency-spike.md fields). Static storage,
 * valid until the next call. */
const char *dena_desktop_metrics(void);
/* Controller navigation of the UI (controller-mode.md). While no game is
 * playing (library, pause menu), every pad change calls fn on SDL's thread
 * (dart:ffi NativeCallable.listener): action is a RetroPad joypad id 0-15
 * (as the UI sees it: on pads whose bottom button is printed A or Cross,
 * that button is A), or 16 for Guide; down 1 or 0; family a
 * DENA_DESKTOP_FAMILY_* value for the hint bar's glyphs. The left stick
 * counts as the D-pad. NULL stops. */
enum {
  DENA_DESKTOP_FAMILY_GENERIC = 0,
  DENA_DESKTOP_FAMILY_XBOX = 1,
  DENA_DESKTOP_FAMILY_PLAYSTATION = 2,
  DENA_DESKTOP_FAMILY_NINTENDO = 3,
  DENA_DESKTOP_FAMILY_STEAM_DECK = 4,
};
typedef void (*dena_desktop_ui_fn)(int32_t action, int32_t down, int32_t family);
void dena_desktop_set_ui_input(dena_desktop_ui_fn fn);
/* The achievement unlock chime, mixed over the game's audio for 0.3 s
 * (achievements.md, Desktop overlay). Any thread; silent without audio. */
void dena_desktop_chime(void);
/* The family of the pad used last (or connected first), -1 without pads. */
int32_t dena_desktop_gamepad_family(void);
/* Latency log (desktop-shell.md, Latency): while a game runs, one metrics
 * JSON line per second is appended to path; "" or NULL stops. */
void dena_desktop_latency_log(const char *path);
/* Run-ahead (run-ahead.md): mode 0 off, 1 preemptive frames, 2 run-ahead;
 * frames 1-3. Applies from the next frame, also to a running game, on the
 * cores that support it; the metrics' "run_ahead" says what is in effect. */
void dena_desktop_set_run_ahead(int32_t mode, int32_t frames);
/* Controller profiles (gamepads.md, Desktop: profiles and gyro): one line
 * per controller GUID ("*" for the rest),
 *   <guid|*> map=<16 RetroPad bits> gyro=<0 off, 1 left stick, 2 right
 *   stick, 3 pointer> sens=<x100> dz=<deg/s x100> inv=<0|1> area=<0|1>
 * Replaces the whole set; applies at once and to pads that connect later.
 * Any thread; NULL or "" clears every profile. */
void dena_desktop_set_profiles(const char *text);
/* Connected pads, one line each: port (-1 waiting for a free one), GUID,
 * gyro (0/1), name, tab-separated. Valid until the next call; main thread. */
const char *dena_desktop_pads_info(void);
/* Shader stacks (shader-stacks.md): the game picture's size in physical
 * pixels, which the shader chain renders at; 0, 0 goes back to the default
 * (4x the frame, at most 3840x2160). Any thread. */
void dena_desktop_set_output_size(int32_t width, int32_t height);
/* Netplay (netplay.md), for the running game; any thread. host: listens on
 * port (0: 47330); relay and room are kept for the ABI, and room != 0 (a
 * relay room) ends the session with an error in this edition. join: target is a room code (needs relay) or
 * "host[:port]". delay -1 is AUTO. 0 started, -1 no game running. Closing the
 * game ends netplay. */
int32_t dena_netplay_host(int32_t port, const char *relay, int32_t room, int32_t delay);
int32_t dena_netplay_join(const char *target, const char *relay, int32_t delay);
void dena_netplay_stop(void);
/* 0 off, 1 waiting/connecting, 2 playing, 3 ended (the info's "error"). */
int32_t dena_netplay_state(void);
/* The running game's method: 1 rollback, 2 lockstep, 0 no game. */
int32_t dena_netplay_method(void);
/* JSON (NetplaySession::info_json); valid until the next call. */
const char *dena_netplay_info(void);
/* Frame generation (frame-generation.md), experimental: 0 off, 1
 * interpolate, 2 pixel-art. Any thread; kept for a game that starts later,
 * applies from the next frame. Only in effect on a screen at least twice
 * the game's rate and while the latency gate passes. */
void dena_desktop_set_frame_generation(int32_t mode);
/* "<mode in effect> <off reason or -> <p95 added ms> <limit ms>", e.g.
 * "0 latency 14.2 10.3"; reasons "refresh", "latency", "gl". Valid until
 * the next call; main thread. */
const char *dena_desktop_frame_generation_status(void);
/* HD texture packs (texture-packs.md): non-zero turns on the core's texture
 * replacement for the next game started; the app links the core's pack
 * folder first. Any thread. */
void dena_desktop_set_texture_packs(int32_t on);

#ifdef __cplusplus
}
#endif
#endif
