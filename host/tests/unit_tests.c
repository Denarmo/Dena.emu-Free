/* Unit tests for frame conversion, hashing, replay parsing and audio.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <string.h>

#include "dena/audio.h"
#include "dena/host.h"
#include "libretro.h"

#include <stdlib.h>

static int failures;

#define CHECK(cond)                                                   \
  do {                                                                \
    if (!(cond)) {                                                    \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, \
              #cond);                                                 \
      failures++;                                                     \
    }                                                                 \
  } while (0)

static void test_fnv(void) {
  /* Standard FNV-1a 64 test vectors. */
  CHECK(dena_fnv1a(DENA_FNV_OFFSET, "", 0) == 0xcbf29ce484222325ULL);
  CHECK(dena_fnv1a(DENA_FNV_OFFSET, "a", 1) == 0xaf63dc4c8601ec8cULL);
  CHECK(dena_fnv1a(DENA_FNV_OFFSET, "foobar", 6) == 0x85944171f73967e8ULL);
}

static void test_convert(void) {
  dena_frame f = {0, 0, NULL};
  /* RGB565: pure red, pure green, pure blue, white; with 2 bytes row padding. */
  uint16_t rgb565[2][3] = {{0xf800, 0x07e0, 0}, {0x001f, 0xffff, 0}};
  CHECK(dena_frame_convert(&f, rgb565, 2, 2, 6, DENA_PIXEL_RGB565) == 0);
  CHECK(f.width == 2 && f.height == 2);
  CHECK(f.pixels[0] == 0x00ff0000u);
  CHECK(f.pixels[1] == 0x0000ff00u);
  CHECK(f.pixels[2] == 0x000000ffu);
  CHECK(f.pixels[3] == 0x00ffffffu);

  /* 0RGB1555: mid values expand by bit replication. 0x10 -> 0x84. */
  uint16_t rgb1555[1] = {(uint16_t)((0x10 << 10) | (0x10 << 5) | 0x10)};
  CHECK(dena_frame_convert(&f, rgb1555, 1, 1, 2, DENA_PIXEL_0RGB1555) == 0);
  CHECK(f.pixels[0] == 0x00848484u);

  /* XRGB8888: X byte is masked off. */
  uint32_t xrgb[1] = {0xab123456u};
  CHECK(dena_frame_convert(&f, xrgb, 1, 1, 4, DENA_PIXEL_XRGB8888) == 0);
  CHECK(f.pixels[0] == 0x00123456u);

  CHECK(dena_frame_convert(&f, xrgb, 1, 1, 4, (dena_pixel_format)7) == -1);

  /* Hash covers dimensions: same pixels, different shape, different hash. */
  uint32_t px[2] = {1, 2};
  dena_frame a = {2, 1, px}, b = {1, 2, px};
  CHECK(dena_frame_hash(&a) != dena_frame_hash(&b));
  dena_frame_free(&f);
}

static void test_replay(void) {
  dena_replay r;
  unsigned line = 0;
  const char *ok =
      "# walk right then press A\n"
      "0 0 0x0080\n"
      "\n"
      "  10 0 0181  \n"
      "10 1 ffff\n"
      "20 0 0\n";
  CHECK(dena_replay_parse(&r, ok, &line) == 0);
  CHECK(r.count == 4);
  uint16_t b[DENA_MAX_PORTS] = {0};
  dena_replay_apply(&r, 0, b);
  CHECK(b[0] == 0x0080 && b[1] == 0);
  dena_replay_apply(&r, 9, b);
  CHECK(b[0] == 0x0080);
  dena_replay_apply(&r, 15, b);
  CHECK(b[0] == 0x0181 && b[1] == 0xffff);
  dena_replay_apply(&r, 20, b);
  CHECK(b[0] == 0);
  dena_replay_free(&r);

  CHECK(dena_replay_parse(&r, "0 0 1\n5 8 1\n", &line) == -1 && line == 2);
  CHECK(dena_replay_parse(&r, "0 7 1\n", &line) == 0);  /* eight ports */
  dena_replay_free(&r);
  CHECK(dena_replay_parse(&r, "5 0 1\n4 0 1\n", &line) == -1 && line == 2);
  CHECK(dena_replay_parse(&r, "0 0 10000\n", &line) == -1 && line == 1);
  CHECK(dena_replay_parse(&r, "0 0\n", &line) == -1 && line == 1);
  CHECK(dena_replay_parse(&r, "# c\n0 0 zz\n", &line) == -1 && line == 2);
  CHECK(dena_replay_parse(&r, "0 0 1 extra\n", &line) == -1 && line == 1);
}

/* gamepads.md, Desktop: eight players. */
static void test_multitap(void) {
  const struct retro_controller_description p0[] = {{"RetroPad", RETRO_DEVICE_JOYPAD}};
  const struct retro_controller_description p1[] = {
      {"RetroPad", RETRO_DEVICE_JOYPAD},
      {"Mouse", RETRO_DEVICE_MOUSE},
      {"SNES Multitap", RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 1)}};
  const struct retro_controller_description p2[] = {{"Multi-Tap 5", 517}};
  const struct retro_controller_info info[] = {
      {p0, 1}, {p1, 3}, {p2, 1}, {NULL, 0}};
  CHECK(dena_find_multitap(info, 0) == 0);
  CHECK(dena_find_multitap(info, 1) == RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 1));
  CHECK(dena_find_multitap(info, 2) == 517);
  CHECK(dena_find_multitap(info, 3) == 0); /* past the list's end */
  CHECK(dena_find_multitap(NULL, 1) == 0);
}

/* gamecube-wii.md, Wii Remote: Dolphin's Wii list starts on the Nunchuk. */
static void test_pad_device(void) {
  const unsigned nc = RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 2);
  const struct retro_controller_description wii[] = {
      {"WiiMote (upright)", RETRO_DEVICE_JOYPAD},
      {"WiiMote (sideways)", RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 1)},
      {"WiiMote + MotionPlus + Nunchuk", RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 9)},
      {"WiiMote + Nunchuk", nc}};
  const struct retro_controller_description gc[] = {{"GameCube Controller", RETRO_DEVICE_JOYPAD}};
  const struct retro_controller_info info[] = {{wii, 4}, {gc, 1}, {NULL, 0}};
  CHECK(dena_find_pad_device(info, 0) == nc);
  CHECK(dena_find_pad_device(info, 1) == 0);
  CHECK(dena_find_pad_device(info, 2) == 0);
  CHECK(dena_find_pad_device(NULL, 0) == 0);
}

static void test_ring(void) {
  dena_ring r;
  CHECK(dena_ring_init(&r, 100) == 0 && r.cap == 128);
  int16_t in[200 * 2], out[200 * 2];
  for (int i = 0; i < 400; i++) in[i] = (int16_t)i;
  CHECK(dena_ring_write(&r, in, 200) == 128); /* full: rest dropped */
  CHECK(dena_ring_fill(&r) == 128);
  CHECK(dena_ring_read(&r, out, 100) == 100 && out[0] == 0 && out[199] == 199);
  CHECK(atomic_load(&r.underruns) == 0);
  CHECK(dena_ring_read(&r, out, 50) == 28 && out[2 * 28] == 0); /* zero-filled */
  CHECK(atomic_load(&r.underruns) == 1);
  dena_ring_free(&r);
}

static void test_resampler(void) {
  dena_resampler rs;
  /* Constant input stays constant; 1 s at 32768 Hz becomes ~48000 frames. */
  dena_resampler_init(&rs, 32768, 48000);
  int16_t in[512 * 2], out[1024 * 2];
  for (int i = 0; i < 512 * 2; i++) in[i] = 1000;
  uint32_t total = 0;
  int constant = 1;
  for (int k = 0; k < 64; k++) {
    uint32_t n = dena_resample(&rs, in, 512, out, 1024, 1.0);
    for (uint32_t i = 0; i < n * 2; i++) constant &= out[i] == 1000;
    total += n;
  }
  CHECK(constant);
  CHECK(total > 47990 && total < 48010);

  dena_rate_ctl ctl;
  dena_rate_ctl_init(&ctl, 0.005);
  CHECK(dena_rate_ctl_update(&ctl, 50, 100) > 1.0);
  dena_rate_ctl_init(&ctl, 0.005);
  CHECK(dena_rate_ctl_update(&ctl, 150, 100) < 1.0);
  dena_rate_ctl_init(&ctl, 0.005);
  CHECK(dena_rate_ctl_update(&ctl, 100, 100) == 1.0);
  for (int i = 0; i < 10000; i++) dena_rate_ctl_update(&ctl, 100000, 100);
  CHECK(dena_rate_ctl_update(&ctl, 100000, 100) >= 0.995 - 1e-12);
}

/* 60 s of a 60 fps core at 32768 Hz feeding a 48 kHz device whose clock runs
 * 0.3 % fast. With rate control the mean buffer fill must settle at its
 * target and the buffer must never underrun after warm-up. */
static void test_rate_control_sim(void) {
  const uint32_t target = 1920; /* 40 ms at 48 kHz */
  dena_ring ring;
  dena_resampler rs;
  CHECK(dena_ring_init(&ring, 8192) == 0);
  dena_resampler_init(&rs, 32768, 48000);
  int16_t in[1024 * 2], tmp[2048 * 2], dev[256 * 2];
  for (int i = 0; i < 1024; i++) in[i * 2] = in[i * 2 + 1] = (int16_t)(i * 7);
  dena_rate_ctl ctl;
  dena_rate_ctl_init(&ctl, 0.005);
  double core_acc = 0, next_frame = 0, next_cb = 0;
  uint32_t underruns_after_warmup = 0;
  double fill_sum = 0, fill_n = 0;
  /* prefill to target, as the runner does before starting the stream */
  memset(tmp, 0, sizeof tmp);
  dena_ring_write(&ring, tmp, target);
  for (double t = 0; t < 60000.0; t += 0.25) { /* ms */
    if (t >= next_frame) {
      core_acc += 32768.0 / 60.0;
      uint32_t n = (uint32_t)core_acc;
      core_acc -= n;
      uint32_t fill = dena_ring_fill(&ring);
      if (t > 30000) {
        fill_sum += fill;
        fill_n++;
      }
      double mul = dena_rate_ctl_update(&ctl, fill, target);
      uint32_t m = dena_resample(&rs, in, n, tmp, 2048, mul);
      dena_ring_write(&ring, tmp, m);
      next_frame += 1000.0 / 60.0;
    }
    if (t >= next_cb) {
      uint32_t before = atomic_load(&ring.underruns);
      dena_ring_read(&ring, dev, 192);
      if (t > 2000 && atomic_load(&ring.underruns) != before) underruns_after_warmup++;
      next_cb += 4.0 / 1.003; /* 192 frames per 4 ms, device 0.3 % fast */
    }
  }
  CHECK(underruns_after_warmup == 0);
  /* Sampled where the controller sees it (just before each write), the mean
   * fill must sit at the target: the integral term removed the 0.3 % offset. */
  double mean = fill_sum / fill_n;
  CHECK(mean > target * 0.9 && mean < target * 1.1);
  if (!(mean > target * 0.9 && mean < target * 1.1))
    fprintf(stderr, "mean fill %.0f frames, target %u\n", mean, target);
  dena_ring_free(&ring);
}

int main(void) {
  test_ring();
  test_resampler();
  test_rate_control_sim();
  test_fnv();
  test_convert();
  test_replay();
  test_multitap();
  test_pad_device();
  if (failures) {
    fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  printf("all unit tests passed\n");
  return 0;
}
