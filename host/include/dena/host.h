/* Dena.emu emulator host: headless libretro frontend.
 * Spec: docs/specs/test-harness.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef DENA_HOST_H
#define DENA_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Eight players: desktop multitap games (gamepads.md, Desktop: eight
 * players); the phone and handheld shells use the first four. */
#define DENA_MAX_PORTS 8
#define DENA_MAX_OPTIONS 64

/* ---- Canonical frames and hashing (frame.c) ---- */

typedef enum {
  DENA_PIXEL_0RGB1555 = 0, /* values match enum retro_pixel_format */
  DENA_PIXEL_XRGB8888 = 1,
  DENA_PIXEL_RGB565 = 2
} dena_pixel_format;

typedef struct {
  unsigned width;
  unsigned height;
  uint32_t *pixels; /* XRGB8888, X byte = 0, width*height, no padding */
} dena_frame;

#define DENA_FNV_OFFSET 0xcbf29ce484222325ULL

uint64_t dena_fnv1a(uint64_t hash, const void *data, size_t len);

/* Converts one source frame to canonical form. Reallocates out->pixels as
 * needed. Returns 0 on success, -1 on bad format or allocation failure. */
int dena_frame_convert(dena_frame *out, const void *data, unsigned width,
                       unsigned height, size_t pitch, dena_pixel_format fmt);

uint64_t dena_frame_hash(const dena_frame *frame);

/* Writes a binary PPM. Returns 0 on success. */
int dena_frame_write_ppm(const dena_frame *frame, const char *path);

void dena_frame_free(dena_frame *frame);

/* ---- Input replay (replay.c) ---- */

typedef struct {
  unsigned frame;
  unsigned port;
  uint16_t buttons;
} dena_replay_event;

typedef struct {
  dena_replay_event *events;
  size_t count;
  size_t next; /* playback cursor */
} dena_replay;

/* Parses .dreplay text. On error returns -1 and sets *err_line (1-based). */
int dena_replay_parse(dena_replay *out, const char *text, unsigned *err_line);
int dena_replay_load(dena_replay *out, const char *path, unsigned *err_line);

/* Applies all events whose frame <= `frame` to `buttons[DENA_MAX_PORTS]`. */
void dena_replay_apply(dena_replay *replay, unsigned frame, uint16_t *buttons);

void dena_replay_free(dena_replay *replay);

/* ---- Core host (host.c) ---- */

/* One core per process: libretro callbacks are global. */
typedef struct dena_core dena_core;

dena_core *dena_core_load(const char *path, char *err, size_t errlen);

/* rom_path may be NULL for cores that support running without content. */
int dena_core_load_game(dena_core *core, const char *rom_path, char *err,
                        size_t errlen);

void dena_core_set_buttons(dena_core *core, unsigned port, uint16_t buttons);
/* Analog sticks (RETRO_DEVICE_ANALOG): stick 0 = left, 1 = right; x/y from
 * -0x7fff to 0x7fff, +y down. n64.md */
void dena_core_set_analog(dena_core *core, unsigned port, unsigned stick, int16_t x, int16_t y);
/* Touch screen / mouse as the libretro pointer (port 0): x and y run from
 * -0x7fff (left/top) to 0x7fff (right/bottom) over the whole frame. ds.md */
void dena_core_set_pointer(dena_core *core, int16_t x, int16_t y, int pressed);
void dena_core_run_frame(dena_core *core);

/* ---- Multitap (gamepads.md, Desktop: eight players) ----
 * The device id of a multitap the core offers on `port` in its
 * RETRO_ENVIRONMENT_SET_CONTROLLER_INFO list (a `struct
 * retro_controller_info` array; a description containing "multitap" or
 * "multi-tap", any case), or 0 when it offers none. */
unsigned dena_find_multitap(const void *controller_info, unsigned port);
/* The plain pad a port starts with, from the same list: the "Wii Remote +
 * Nunchuk" entry where the core offers one (gamecube-wii.md, Wii Remote),
 * else 0 (the RetroPad). */
unsigned dena_find_pad_device(const void *controller_info, unsigned port);
/* The same for the loaded core's own list (0 before it sent one). */
unsigned dena_core_multitap_device(const dena_core *core, unsigned port);
/* retro_set_controller_port_device after the game is loaded (device 0 means
 * the port's plain pad: dena_find_pad_device's, else the RetroPad). */
void dena_core_set_port_device(dena_core *core, unsigned port, unsigned device);

const dena_frame *dena_core_frame(const dena_core *core);
uint64_t dena_core_audio_hash(const dena_core *core);
unsigned dena_core_frame_count(const dena_core *core);

typedef struct {
  double fps;
  double sample_rate;
  unsigned base_width, base_height;
  unsigned max_width, max_height; /* largest frame the core will output */
  float aspect_ratio;
} dena_av_info;

/* Valid after dena_core_load_game. */
void dena_core_av_info(dena_core *core, dena_av_info *out);

/* Optional: receives every audio batch (interleaved stereo frames) on the
 * thread that runs frames, in addition to hashing. NULL to disable. */
typedef void (*dena_audio_sink)(void *user, const int16_t *frames, size_t n);
void dena_core_set_audio_sink(dena_core *core, dena_audio_sink sink, void *user);

/* Per-sample audio hashing (on by default, for the harness). Real-time
 * runners turn it off; dena_core_audio_hash() then stops changing. */
void dena_core_set_hashing(dena_core *core, int enabled);

/* A core memory region (RETRO_MEMORY_SAVE_RAM = 0, RTC = 1, ...). Returns
 * NULL with *size 0 when the core has none. */
void *dena_core_memory(dena_core *core, unsigned id, size_t *size);

/* The core's memory map (a struct retro_memory_map from
 * RETRO_ENVIRONMENT_SET_MEMORY_MAPS), or NULL when it gave none. Valid until
 * the core is unloaded. */
const void *dena_core_memory_map(dena_core *core);

size_t dena_core_state_size(dena_core *core);
int dena_core_save_state(dena_core *core, void *buf, size_t size);
int dena_core_load_state(dena_core *core, const void *buf, size_t size);

/* Cheats (docs/specs/cheats.md). No-ops for cores without cheat support.
 * code: one or more codes joined by '+'. */
void dena_core_cheats_reset(dena_core *core);
void dena_core_cheat_set(dena_core *core, unsigned index, int enabled, const char *code);

/* ---- Hardware rendering (docs/specs/hw-render.md) ----
 * The platform supplies hooks before dena_core_load_game; without them a core
 * asking for GPU rendering is refused (and may fall back to software). */
typedef struct {
  uintptr_t (*get_framebuffer)(void *user);           /* FBO the core draws to */
  void *(*get_proc_address)(void *user, const char *sym);
  void *user;
} dena_hw_hooks;
void dena_core_set_hw_hooks(dena_core *core, const dena_hw_hooks *hooks);
/* Process-wide: 1 accepts desktop GL cores (OPENGL, OPENGL_CORE) instead of
 * GLES ones, for the Windows and Linux PC builds (desktop-shell.md). */
void dena_set_desktop_gl(int on);

typedef struct {
  int context_type; /* RETRO_HW_CONTEXT_* */
  unsigned version_major, version_minor;
  int depth, stencil, bottom_left_origin;
} dena_hw_info;
/* 1 and fills out when the core rendered through the GPU; 0 otherwise. */
int dena_core_hw_info(const dena_core *core, dena_hw_info *out);
/* Called by the platform once its context is current (and before teardown). */
void dena_core_hw_context_reset(dena_core *core);
void dena_core_hw_context_destroy(dena_core *core);
/* 1 when the last frame was drawn into the framebuffer, with its size. */
int dena_core_hw_frame(const dena_core *core, unsigned *width, unsigned *height);

/* ---- Core options ----
 * Values the core reads with RETRO_ENVIRONMENT_GET_VARIABLE. Keys never set
 * answer the default the core declared (SET_VARIABLES or SET_CORE_OPTIONS,
 * v1/v2/intl). Setting one flags an update for the core's next read. */
int dena_core_set_option(dena_core *core, const char *key, const char *value);
/* The value the core reads for key (set or declared default), or NULL. */
const char *dena_core_get_option(const dena_core *core, const char *key);

void dena_core_unload(dena_core *core);

#ifdef __cplusplus
}
#endif

#endif
