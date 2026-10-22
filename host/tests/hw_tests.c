/* Hardware-render plumbing and core options with dena_testcore.
 * Usage: hw_tests <core>
 * Spec: docs/specs/hw-render.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <string.h>

#include "dena/host.h"
#include "libretro.h"

static int failures;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

typedef struct {
  int fb_calls, proc_calls, resets, destroys;
  char last_sym[64];
} hooks_log;

static uintptr_t get_fb(void *user) {
  ((hooks_log *)user)->fb_calls++;
  return 42;
}

static void *get_proc(void *user, const char *sym) {
  hooks_log *h = user;
  h->proc_calls++;
  snprintf(h->last_sym, sizeof h->last_sym, "%s", sym);
  if (strcmp(sym, "dena_test_context_reset") == 0) h->resets++;
  if (strcmp(sym, "dena_test_context_destroy") == 0) h->destroys++;
  return NULL;
}

static dena_core *load(const char *path, int hooks, hooks_log *log, const char *hw_option) {
  char err[256];
  dena_core *core = dena_core_load(path, err, sizeof err);
  if (!core) {
    fprintf(stderr, "%s\n", err);
    return NULL;
  }
  if (hooks) {
    dena_hw_hooks h = {get_fb, get_proc, log};
    dena_core_set_hw_hooks(core, &h);
  }
  if (hw_option) CHECK(dena_core_set_option(core, "dena_test_hw", hw_option) == 0);
  if (dena_core_load_game(core, NULL, err, sizeof err) != 0) {
    dena_core_unload(core);
    return NULL;
  }
  return core;
}

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  hooks_log log;
  dena_hw_info info;
  unsigned w, h;

  /* Software by default: no HW request, frames in memory. */
  memset(&log, 0, sizeof log);
  dena_core *core = load(argv[1], 1, &log, NULL);
  CHECK(core != NULL);
  dena_core_run_frame(core);
  CHECK(dena_core_hw_info(core, &info) == 0);
  CHECK(dena_core_hw_frame(core, &w, &h) == 0);
  CHECK(dena_core_frame(core)->pixels != NULL);
  dena_core_unload(core);

  /* Asked for GLES3 with hooks: accepted, hooks reached, frames in the FBO. */
  memset(&log, 0, sizeof log);
  core = load(argv[1], 1, &log, "enabled");
  CHECK(core != NULL);
  CHECK(dena_core_hw_info(core, &info) == 1);
  CHECK(info.context_type == RETRO_HW_CONTEXT_OPENGLES3 && info.version_major == 3);
  CHECK(info.bottom_left_origin == 1);
  dena_core_hw_context_reset(core);
  CHECK(log.resets == 1);
  dena_core_run_frame(core);
  CHECK(log.fb_calls == 1);
  CHECK(strcmp(log.last_sym, "glClear") == 0);
  CHECK(dena_core_hw_frame(core, &w, &h) == 1 && w == 160 && h == 144);
  dena_core_hw_context_destroy(core);
  CHECK(log.destroys == 1);
  dena_core_unload(core);

  /* Without hooks the request is refused (the test core then fails to load). */
  memset(&log, 0, sizeof log);
  core = load(argv[1], 0, &log, "enabled");
  CHECK(core == NULL);
  CHECK(log.proc_calls == 0);

  /* Options: overwrite in place; over-long values are rejected. */
  char err[256];
  core = dena_core_load(argv[1], err, sizeof err);
  CHECK(dena_core_set_option(core, "k", "a") == 0);
  CHECK(dena_core_set_option(core, "k", "b") == 0);
  char longv[200];
  memset(longv, 'x', sizeof longv - 1);
  longv[sizeof longv - 1] = 0;
  CHECK(dena_core_set_option(core, "k", longv) == -1);

  /* Declared defaults answer keys never set (v2 default, v2 first value,
   * legacy first value); a set value wins; unknown keys stay unanswered. */
  CHECK(dena_core_get_option(core, "dena_test_v2") &&
        strcmp(dena_core_get_option(core, "dena_test_v2"), "b") == 0);
  CHECK(dena_core_get_option(core, "dena_test_first") &&
        strcmp(dena_core_get_option(core, "dena_test_first"), "first") == 0);
  CHECK(dena_core_get_option(core, "dena_test_legacy") &&
        strcmp(dena_core_get_option(core, "dena_test_legacy"), "x") == 0);
  CHECK(dena_core_set_option(core, "dena_test_v2", "a") == 0);
  CHECK(strcmp(dena_core_get_option(core, "dena_test_v2"), "a") == 0);
  CHECK(dena_core_get_option(core, "nope") == NULL);
  dena_core_unload(core);

  if (failures) fprintf(stderr, "%d failure(s)\n", failures);
  else printf("hw: ok\n");
  return failures ? 1 : 0;
}
