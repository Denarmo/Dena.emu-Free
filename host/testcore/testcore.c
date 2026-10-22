/* dena_testcore: a tiny deterministic libretro core used to test the host.
 * Draws a moving square over a PRNG-seeded background, plays a tone whose
 * pitch follows input, and supports save states. Needs no content.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "libretro.h"

#define W 160
#define H 144
#define SQ 16
#define SAMPLES_PER_FRAME 735 /* 44100 Hz / 60 fps */

static retro_environment_t env_cb;
static retro_video_refresh_t video_cb;
static retro_audio_sample_batch_t audio_cb;
static retro_input_poll_t poll_cb;
static retro_input_state_t input_cb;

/* Everything in here is the save state. Fixed-width fields only. */
typedef struct {
  uint32_t frame;
  uint32_t rng;
  int32_t x, y;
  uint32_t phase;
} state_t;

static state_t st;
/* Battery-backed RAM: byte 0 counts presses of Start, so tests can change it. */
static uint8_t save_ram[256];
/* System RAM: each frame sets byte 1 to byte 0 + 1, so tests can check the
 * runner's RAM mailbox (pico8-launcher-cart.md). */
static uint8_t system_ram[256];
static int start_held;
/* Cheat "REDSQUARE" draws the square red (tests the cheat path). */
static int red_square;
static uint32_t fb[W * H];
/* Option dena_test_hw=enabled: asks for GLES3 rendering and only talks to the
 * frontend's hooks (tests hw-render.md without a GPU). */
static struct retro_hw_render_callback hw;
static int use_hw;

static void hw_context_reset(void) { hw.get_proc_address("dena_test_context_reset"); }
static void hw_context_destroy(void) { hw.get_proc_address("dena_test_context_destroy"); }
static int16_t audio[SAMPLES_PER_FRAME * 2];
/* DENA_TEST_AUDIO_BLOCK=<n>: keeps samples in a buffer that states do not
 * hold and hands them out in blocks of n, like mGBA's GB path (run-ahead.md). */
static size_t audio_block, held;
static int16_t held_audio[(SAMPLES_PER_FRAME + 4096) * 2];
/* Test knobs read from the environment at load (runner tests):
 * DENA_TEST_HW=1 asks for GLES3 like the option, DENA_TEST_STATE_PAD=<bytes>
 * makes states that much larger, DENA_TEST_LATE_STATE=<n> refuses to load a
 * state until n frames have run (like PPSSPP during its boot),
 * DENA_TEST_SAVE_MS=<ms> makes every save take that long (melonDS). */
static size_t state_pad;
static unsigned save_ms;
static unsigned late_state, frames_run;

static uint32_t next_rng(void) {
  st.rng = st.rng * 1664525u + 1013904223u;
  return st.rng;
}

/* Declared options (hw-render.md, core options): v2 when the frontend
 * supports it, plus one legacy SET_VARIABLES entry. */
static struct retro_core_option_v2_definition option_defs[] = {
    {"dena_test_hw", "GLES3 rendering", NULL, NULL, NULL, NULL,
     {{"disabled", NULL}, {"enabled", NULL}, {NULL, NULL}}, "disabled"},
    {"dena_test_v2", "Test v2", NULL, NULL, NULL, NULL,
     {{"a", NULL}, {"b", NULL}, {NULL, NULL}}, "b"},
    {"dena_test_first", "No default given", NULL, NULL, NULL, NULL,
     {{"first", NULL}, {"second", NULL}, {NULL, NULL}}, NULL},
    {NULL, NULL, NULL, NULL, NULL, NULL, {{NULL, NULL}}, NULL},
};
static struct retro_core_options_v2 options_v2 = {NULL, option_defs};

RETRO_API void retro_set_environment(retro_environment_t cb) {
  env_cb = cb;
  bool no_game = true;
  cb(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &no_game);
  unsigned version = 0;
  if (cb(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version) && version >= 2)
    cb(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2, &options_v2);
  static const struct retro_variable legacy[] = {
      {"dena_test_legacy", "Legacy; x|y"}, {NULL, NULL}};
  cb(RETRO_ENVIRONMENT_SET_VARIABLES, (void *)legacy);
}
RETRO_API void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio_cb = cb; }
RETRO_API void retro_set_input_poll(retro_input_poll_t cb) { poll_cb = cb; }
RETRO_API void retro_set_input_state(retro_input_state_t cb) { input_cb = cb; }

RETRO_API void retro_init(void) {}
RETRO_API void retro_deinit(void) {}
RETRO_API unsigned retro_api_version(void) { return RETRO_API_VERSION; }

RETRO_API void retro_get_system_info(struct retro_system_info *info) {
  memset(info, 0, sizeof *info);
  info->library_name = "dena_testcore";
  info->library_version = "1";
  info->valid_extensions = "";
  info->need_fullpath = false;
  info->block_extract = false;
}

RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info) {
  memset(info, 0, sizeof *info);
  info->geometry.base_width = W;
  info->geometry.base_height = H;
  info->geometry.max_width = W;
  info->geometry.max_height = H;
  info->geometry.aspect_ratio = (float)W / H;
  info->timing.fps = 60.0;
  info->timing.sample_rate = 44100.0;
}

RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device) {
  (void)port;
  (void)device;
}

RETRO_API void retro_reset(void) {
  memset(&st, 0, sizeof st);
  st.rng = 0x00c0ffeeu;
  st.x = (W - SQ) / 2;
  st.y = (H - SQ) / 2;
}

static int pressed(unsigned id) {
  return input_cb(0, RETRO_DEVICE_JOYPAD, 0, id) != 0;
}

RETRO_API void retro_run(void) {
  system_ram[1] = (uint8_t)(system_ram[0] + 1);
  poll_cb();
  if (pressed(RETRO_DEVICE_ID_JOYPAD_LEFT) && st.x > 0) st.x--;
  if (pressed(RETRO_DEVICE_ID_JOYPAD_RIGHT) && st.x < W - SQ) st.x++;
  if (pressed(RETRO_DEVICE_ID_JOYPAD_UP) && st.y > 0) st.y--;
  if (pressed(RETRO_DEVICE_ID_JOYPAD_DOWN) && st.y < H - SQ) st.y++;
  /* The left analog stick also moves the square, one pixel at full tilt. */
  int ax = input_cb(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_X);
  int ay = input_cb(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_Y);
  st.x += ax / 0x4000;
  st.y += ay / 0x4000;
  if (st.x < 0) st.x = 0;
  if (st.x > W - SQ) st.x = W - SQ;
  if (st.y < 0) st.y = 0;
  if (st.y > H - SQ) st.y = H - SQ;
  int start = pressed(RETRO_DEVICE_ID_JOYPAD_START);
  if (start && !start_held) save_ram[0]++;
  start_held = start;
  uint32_t square = pressed(RETRO_DEVICE_ID_JOYPAD_A) ? 0x00ff4040u : 0x00ffffffu;
  if (red_square) square = 0x00ff0000u;

  uint32_t seed = next_rng();
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++) {
      uint32_t v = (uint32_t)(x * 7 + y * 13) ^ (seed >> 8) ^ (st.frame * 3u);
      fb[y * W + x] = ((v & 0xff) << 16) | (((v >> 3) & 0xff) << 8) | ((v >> 6) & 0xff);
    }
  for (int y = st.y; y < st.y + SQ; y++)
    for (int x = st.x; x < st.x + SQ; x++) fb[y * W + x] = square;
  /* A pressed pointer draws a 3x3 green dot (tests RETRO_DEVICE_POINTER). */
  if (input_cb(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED)) {
    int px = (input_cb(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_X) + 0x7fff) * (W - 1) / 0xfffe;
    int py = (input_cb(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_Y) + 0x7fff) * (H - 1) / 0xfffe;
    for (int y = py - 1; y <= py + 1; y++)
      for (int x = px - 1; x <= px + 1; x++)
        if (x >= 0 && x < W && y >= 0 && y < H) fb[y * W + x] = 0x0000ff00u;
  }
  if (use_hw) {
    hw.get_proc_address("glClear");
    hw.get_current_framebuffer();
    video_cb(RETRO_HW_FRAME_BUFFER_VALID, W, H, 0);
  } else {
    video_cb(fb, W, H, W * sizeof(uint32_t));
  }

  /* Square wave; the B button raises the pitch. */
  uint32_t step = pressed(RETRO_DEVICE_ID_JOYPAD_B) ? 2u : 1u;
  for (int i = 0; i < SAMPLES_PER_FRAME; i++) {
    st.phase += step;
    int16_t s = (st.phase / 50u) & 1 ? 4000 : -4000;
    audio[i * 2] = s;
    audio[i * 2 + 1] = s;
  }
  if (audio_block) {
    memcpy(held_audio + held * 2, audio, sizeof audio);
    held += SAMPLES_PER_FRAME;
    size_t out = held / audio_block * audio_block;
    if (out) audio_cb(held_audio, out);
    held -= out;
    memmove(held_audio, held_audio + out * 2, held * 2 * sizeof(int16_t));
  } else {
    audio_cb(audio, SAMPLES_PER_FRAME);
  }
  st.frame++;
  frames_run++;
}

RETRO_API size_t retro_serialize_size(void) { return sizeof st + state_pad; }
RETRO_API bool retro_serialize(void *data, size_t size) {
  if (size < sizeof st + state_pad) return false;
  if (save_ms) {  /* a slow state, like melonDS's 6.5 MB (rewind.md) */
    clock_t until = clock() + (clock_t)(save_ms * (double)CLOCKS_PER_SEC / 1000);
    while (clock() < until) {
    }
  }
  memcpy(data, &st, sizeof st);
  memset((uint8_t *)data + sizeof st, 0, size - sizeof st);
  return true;
}
RETRO_API bool retro_unserialize(const void *data, size_t size) {
  if (frames_run < late_state || size < sizeof st) return false;
  memcpy(&st, data, sizeof st);
  return true;
}

RETRO_API void retro_cheat_reset(void) { red_square = 0; }
RETRO_API void retro_cheat_set(unsigned i, bool e, const char *c) {
  (void)i;
  if (e && c && strcmp(c, "REDSQUARE") == 0) red_square = 1;
}

RETRO_API bool retro_load_game(const struct retro_game_info *game) {
  (void)game;
  enum retro_pixel_format fmt = RETRO_PIXEL_FORMAT_XRGB8888;
  if (!env_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &fmt)) return false;
  struct retro_variable var = {"dena_test_hw", NULL};
  use_hw = env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &var) && var.value &&
           strcmp(var.value, "enabled") == 0;
  if (getenv("DENA_TEST_HW")) use_hw = 1;
  const char *pad = getenv("DENA_TEST_STATE_PAD");
  const char *late = getenv("DENA_TEST_LATE_STATE");
  const char *block = getenv("DENA_TEST_AUDIO_BLOCK");
  const char *slow = getenv("DENA_TEST_SAVE_MS");
  save_ms = slow ? (unsigned)strtoul(slow, NULL, 10) : 0;
  audio_block = block ? (size_t)strtoul(block, NULL, 10) : 0;
  if (audio_block > 4096) audio_block = 4096;
  held = 0;
  state_pad = pad ? (size_t)strtoul(pad, NULL, 10) : 0;
  late_state = late ? (unsigned)strtoul(late, NULL, 10) : 0;
  frames_run = 0;
  if (use_hw) {
    memset(&hw, 0, sizeof hw);
    hw.context_type = RETRO_HW_CONTEXT_OPENGLES3;
    hw.version_major = 3;
    hw.context_reset = hw_context_reset;
    hw.context_destroy = hw_context_destroy;
    hw.bottom_left_origin = true;
    if (!env_cb(RETRO_ENVIRONMENT_SET_HW_RENDER, &hw)) return false;
  }
  retro_reset();
  return true;
}
RETRO_API bool retro_load_game_special(unsigned t, const struct retro_game_info *g,
                                       size_t n) {
  (void)t;
  (void)g;
  (void)n;
  return false;
}
RETRO_API void retro_unload_game(void) {}
RETRO_API unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
RETRO_API void *retro_get_memory_data(unsigned id) {
  if (id == RETRO_MEMORY_SYSTEM_RAM) return system_ram;
  return id == RETRO_MEMORY_SAVE_RAM ? save_ram : NULL;
}
RETRO_API size_t retro_get_memory_size(unsigned id) {
  if (id == RETRO_MEMORY_SYSTEM_RAM) return sizeof system_ram;
  return id == RETRO_MEMORY_SAVE_RAM ? sizeof save_ram : 0;
}
