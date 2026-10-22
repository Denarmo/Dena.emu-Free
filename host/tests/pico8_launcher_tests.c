/* Dena Explore launcher cart on the fake-08 runtime, driven through the GPIO
 * mailbox like the app does (docs/specs/pico8-launcher-cart.md).
 * Usage: pico8_launcher_tests <fake08 core> <dena-explore.p8> [--print]
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dena/host.h"

#define GPIO 0x5f80
#define RETRO_MEMORY_SYSTEM_RAM 2
#define BTN_B 0 /* RetroPad B = PICO-8 O */

/* Golden frame hashes; --print shows the current ones and writes PPMs. */
static const char *kLibraryHash = "acd117aa158cd612";
static const char *kOnlineHash = "7906075650f1bce7";
static const char *kNoHostHash = "f9622747a443d70d";

static int failures;
static int print_hashes;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      failures++;                                                 \
    }                                                             \
  } while (0)

static dena_core *open_cart(const char *core_path, const char *cart) {
  char err[256];
  dena_core *core = dena_core_load(core_path, err, sizeof err);
  if (!core) {
    fprintf(stderr, "core: %s\n", err);
    exit(2);
  }
  if (dena_core_load_game(core, cart, err, sizeof err) != 0) {
    fprintf(stderr, "cart: %s\n", err);
    exit(2);
  }
  return core;
}

static unsigned char *gpio(dena_core *core) {
  size_t size = 0;
  unsigned char *ram = dena_core_memory(core, RETRO_MEMORY_SYSTEM_RAM, &size);
  if (!ram || size < GPIO + 128) {
    fprintf(stderr, "the core does not expose PICO-8 RAM\n");
    exit(2);
  }
  return ram + GPIO;
}

/* Runs frames until the cart posts a request (state 1); returns the command. */
static int wait_request(dena_core *core, int max_frames) {
  unsigned char *g = gpio(core);
  for (int i = 0; i < max_frames; i++) {
    if (g[0] == 1) return g[1];
    dena_core_run_frame(core);
  }
  return -1;
}

static void reply(dena_core *core, const char *text, int error) {
  unsigned char *g = gpio(core);
  size_t n = strlen(text);
  memcpy(g + 8, text, n);
  g[3] = (unsigned char)n;
  g[4] = (unsigned char)(error ? 2 : 0);
  g[0] = 3; /* g[5] keeps the cart's sequence number */
}

static void check_hash(const char *name, dena_core *core, const char *want) {
  char got[17];
  snprintf(got, sizeof got, "%016llx",
           (unsigned long long)dena_frame_hash(dena_core_frame(core)));
  if (print_hashes) {
    char ppm[64];
    snprintf(ppm, sizeof ppm, "launcher-%s.ppm", name);
    dena_frame_write_ppm(dena_core_frame(core), ppm);
    printf("%s %s (%s)\n", name, got, ppm);
  }
  else if (strcmp(got, want) != 0) {
    fprintf(stderr, "%s: frame hash %s, expected %s\n", name, got, want);
    failures++;
  }
}

static void test_library(const char *core_path, const char *cart) {
  dena_core *core = open_cart(core_path, cart);
  unsigned char *g = gpio(core);
  CHECK(wait_request(core, 10) == 1); /* hello */
  reply(core, "0", 0);                 /* offline */
  CHECK(wait_request(core, 10) == 2); /* local */
  CHECK(g[3] == 3 && memcmp(g + 8, "all", 3) == 0);
  reply(core, "7\tcelery quest\tsam\t0\n9\tjump jump\t\t1\n", 0);
  for (int i = 0; i < 5; i++) dena_core_run_frame(core);
  check_hash("library", core, kLibraryHash);
  dena_core_set_buttons(core, 0, 1u << BTN_B);
  CHECK(wait_request(core, 10) == 5); /* run */
  CHECK(g[3] == 1 && g[8] == '7');
  dena_core_unload(core);
}

/* Presses a button for one frame, then releases it. */
static void tap(dena_core *core, unsigned button) {
  dena_core_set_buttons(core, 0, (uint16_t)(1u << button));
  for (int i = 0; i < 4; i++) dena_core_run_frame(core);
  dena_core_set_buttons(core, 0, 0);
  for (int i = 0; i < 4; i++) dena_core_run_frame(core);
}

#define BTN_LEFT 6
#define BTN_RIGHT 7

/* Online: the BBS tabs follow the local ones; O on a BBS cart downloads it. */
static void test_online(const char *core_path, const char *cart) {
  dena_core *core = open_cart(core_path, cart);
  unsigned char *g = gpio(core);
  CHECK(wait_request(core, 10) == 1);
  reply(core, "1", 0);
  CHECK(wait_request(core, 10) == 2);
  reply(core, "", 0);
  for (int i = 0; i < 4; i++) dena_core_run_frame(core);
  tap(core, BTN_LEFT); /* wraps from library to search: no request */
  tap(core, BTN_LEFT); /* new */
  CHECK(wait_request(core, 10) == 3);
  CHECK(g[3] == 3 && memcmp(g + 8, "n 1", 3) == 0);
  reply(core, "more\t0\n0\tpixel pond\tkit\t-\n", 0);
  for (int i = 0; i < 4; i++) dena_core_run_frame(core);
  tap(core, BTN_B);
  CHECK(wait_request(core, 10) == 4); /* get */
  CHECK(g[3] == 1 && g[8] == '0');
  reply(core, "ok 12", 0);
  for (int i = 0; i < 4; i++) dena_core_run_frame(core);
  check_hash("online", core, kOnlineHash);
  tap(core, BTN_B);
  CHECK(wait_request(core, 10) == 5); /* now in the library: run */
  CHECK(g[3] == 2 && memcmp(g + 8, "12", 2) == 0);
  dena_core_unload(core);
}

static void test_no_host(const char *core_path, const char *cart) {
  dena_core *core = open_cart(core_path, cart);
  for (int i = 0; i < 150; i++) dena_core_run_frame(core); /* past 2 s */
  check_hash("nohost", core, kNoHostHash);
  dena_core_unload(core);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: pico8_launcher_tests <core> <cart> [--print]\n");
    return 2;
  }
  print_hashes = argc > 3 && strcmp(argv[3], "--print") == 0;
  test_library(argv[1], argv[2]);
  test_online(argv[1], argv[2]);
  test_no_host(argv[1], argv[2]);
  if (failures) fprintf(stderr, "%d failure(s)\n", failures);
  return failures ? 1 : 0;
}
