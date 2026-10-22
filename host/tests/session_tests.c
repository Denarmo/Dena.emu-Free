/* Battery-save and state-file round trips with dena_testcore.
 * Usage: session_tests <core> <scratch dir>
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <string.h>

#include "dena/host.h"
#include "dena/session.h"

#define RETRO_START (1u << 3)

static int failures;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

static void press_start(dena_core *core) {
  dena_core_set_buttons(core, 0, RETRO_START);
  dena_core_run_frame(core);
  dena_core_set_buttons(core, 0, 0);
  dena_core_run_frame(core);
}

int main(int argc, char **argv) {
  if (argc < 3) return 2;
  char err[256], srm[512], state[512];
  snprintf(srm, sizeof srm, "%s/test.srm", argv[2]);
  snprintf(state, sizeof state, "%s/test.state", argv[2]);
  remove(srm);
  remove(state);

  dena_core *core = dena_core_load(argv[1], err, sizeof err);
  if (!core || dena_core_load_game(core, NULL, err, sizeof err)) {
    fprintf(stderr, "%s\n", err);
    return 3;
  }
  dena_core_set_hashing(core, 0);
  uint64_t before = dena_core_audio_hash(core);
  dena_core_run_frame(core);
  CHECK(dena_core_audio_hash(core) == before); /* hashing off */

  /* Nothing to load yet is not an error. */
  CHECK(dena_battery_load(core, srm) == DENA_NO_DATA);
  CHECK(dena_state_load_file(core, state) == DENA_NO_DATA);

  size_t size;
  unsigned char *ram = dena_core_memory(core, DENA_MEMORY_SAVE_RAM, &size);
  CHECK(ram && size == 256);
  press_start(core);
  press_start(core);
  CHECK(ram[0] == 2);
  uint64_t h = dena_battery_hash(core);
  CHECK(dena_battery_save(core, srm) == 0);

  press_start(core);
  CHECK(ram[0] == 3 && dena_battery_hash(core) != h);
  CHECK(dena_battery_load(core, srm) == 0);
  CHECK(ram[0] == 2 && dena_battery_hash(core) == h);

  /* State file round trip: same frame after the same frames. */
  CHECK(dena_state_save_file(core, state) == 0);
  for (int i = 0; i < 30; i++) dena_core_run_frame(core);
  uint64_t a = dena_frame_hash(dena_core_frame(core));
  CHECK(dena_state_load_file(core, state) == 0);
  for (int i = 0; i < 30; i++) dena_core_run_frame(core);
  CHECK(dena_frame_hash(dena_core_frame(core)) == a);

  /* A garbage state is rejected and leaves the core usable. */
  FILE *f = fopen(state, "wb");
  fputs("not a state", f);
  fclose(f);
  CHECK(dena_state_load_file(core, state) == -1);
  dena_core_run_frame(core);

  /* Cheats: REDSQUARE changes the picture; reset restores it. */
  CHECK(dena_state_save_file(core, state) == 0);
  dena_core_run_frame(core);
  uint64_t plain = dena_frame_hash(dena_core_frame(core));
  CHECK(dena_state_load_file(core, state) == 0);
  dena_core_cheat_set(core, 0, 1, "REDSQUARE");
  dena_core_run_frame(core);
  CHECK(dena_frame_hash(dena_core_frame(core)) != plain);
  dena_core_cheats_reset(core);
  CHECK(dena_state_load_file(core, state) == 0);
  dena_core_run_frame(core);
  CHECK(dena_frame_hash(dena_core_frame(core)) == plain);

  /* Thumbnail: PNG and PPM of the same frame; check_png.py compares them. */
  char png[512], ppm[512];
  snprintf(png, sizeof png, "%s/thumb.png", argv[2]);
  snprintf(ppm, sizeof ppm, "%s/thumb.ppm", argv[2]);
  CHECK(dena_frame_write_png(dena_core_frame(core), png) == 0);
  CHECK(dena_frame_write_ppm(dena_core_frame(core), ppm) == 0);
  dena_frame empty = {0, 0, NULL};
  CHECK(dena_frame_write_png(&empty, png) == -1);

  /* Analog (n64.md): full right tilt moves the square 1 px per frame. */
  {
    dena_core_set_pointer(core, 0, 0, 0);
    dena_core_set_buttons(core, 0, 0);
    uint8_t s0[64], s1[64];
    size_t n = dena_core_state_size(core);
    CHECK(n <= sizeof s0);
    dena_core_save_state(core, s0, n);
    dena_core_set_analog(core, 0, 0, 0x7fff, 0);
    dena_core_run_frame(core);
    dena_core_set_analog(core, 0, 0, 0, 0);
    dena_core_save_state(core, s1, n);
    int32_t x0, x1; /* state_t: frame, rng, x, ... */
    memcpy(&x0, s0 + 8, 4);
    memcpy(&x1, s1 + 8, 4);
    CHECK(x1 == x0 + 1);
  }

  /* Pointer (ds.md): the test core draws a green dot where it is pressed. */
  const dena_frame *fr = dena_core_frame(core);
  dena_core_set_pointer(core, 0, 0, 1); /* centre */
  dena_core_run_frame(core);
  unsigned cx = 0x7fff * (fr->width - 1) / 0xfffe, cy = 0x7fff * (fr->height - 1) / 0xfffe;
  CHECK(fr->pixels[cy * fr->width + cx] == 0x0000ff00u);
  dena_core_set_pointer(core, -0x7fff, 0x7fff, 1); /* bottom left */
  dena_core_run_frame(core);
  CHECK(fr->pixels[(fr->height - 1) * fr->width] == 0x0000ff00u);
  dena_core_set_pointer(core, 0, 0, 0);
  dena_core_run_frame(core);
  CHECK(fr->pixels[cy * fr->width + cx] != 0x0000ff00u);

  dena_core_unload(core);
  if (failures) {
    fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  printf("session tests passed\n");
  return 0;
}
