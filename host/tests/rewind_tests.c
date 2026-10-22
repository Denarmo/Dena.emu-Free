/* Rewind codec, ring buffer and a test-core round trip.
 * Usage: rewind_tests <core>
 * Spec: docs/specs/rewind.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dena/host.h"
#include "dena/rewind.h"
#include "dena/session.h"

static int failures;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

static uint32_t rng = 12345;
static uint8_t rnd(void) {
  rng = rng * 1103515245u + 12345u;
  return (uint8_t)(rng >> 16);
}

static void codec(void) {
  enum { N = 5000 };
  static uint8_t a[N], b[N], enc[2 * N + 32], buf[N];
  /* Random, mostly equal, equal, and differing only at the ends. */
  for (int round = 0; round < 4; round++) {
    for (int i = 0; i < N; i++) {
      a[i] = rnd();
      b[i] = round == 0 ? rnd() : a[i];
    }
    if (round == 1)
      for (int i = 0; i < N; i += 37) b[i] ^= 0x5a;
    if (round == 3) b[0] ^= 1, b[N - 1] ^= 0x80, b[N - 3] ^= 2;
    size_t len = dena_xor_rle_encode(a, b, N, enc, sizeof enc);
    CHECK(len > 0);
    if (round == 2) CHECK(len <= 4);
    if (round == 1) CHECK(len < N / 2);
    memcpy(buf, b, N);
    CHECK(dena_xor_rle_apply(buf, N, enc, len) == 0);
    CHECK(memcmp(buf, a, N) == 0);
  }
  /* Too small an output buffer and malformed input are rejected. */
  for (int i = 0; i < N; i++) a[i] = rnd(), b[i] = rnd();
  CHECK(dena_xor_rle_encode(a, b, N, enc, 100) == 0);
  uint8_t bad[] = {0x10, 0xff, 0xff, 0x7f};
  CHECK(dena_xor_rle_apply(buf, 8, bad, sizeof bad) == -1);
}

static void ring(void) {
  enum { S = 1024, K = 40 };
  static uint8_t states[K][S], out[S];
  for (int k = 0; k < K; k++)
    for (int i = 0; i < S; i++)
      states[k][i] = k ? states[k - 1][i] ^ (i % (k + 3) == 0 ? rnd() | 1 : 0) : rnd();

  dena_rewind *rw = dena_rewind_create(1 << 20);
  CHECK(dena_rewind_step_back(rw, out, S) == DENA_NO_DATA);
  for (int k = 0; k < K; k++) CHECK(dena_rewind_push(rw, states[k], S) == 0);
  CHECK(dena_rewind_count(rw) == K - 1);
  for (int k = K - 2; k >= 0; k--) {
    CHECK(dena_rewind_step_back(rw, out, S) == 0);
    CHECK(memcmp(out, states[k], S) == 0);
  }
  CHECK(dena_rewind_step_back(rw, out, S) == DENA_NO_DATA);

  /* Continuing after a rewind drops the future. */
  for (int k = 0; k < 10; k++) dena_rewind_push(rw, states[k], S);
  CHECK(dena_rewind_step_back(rw, out, S) == 0 && memcmp(out, states[8], S) == 0);
  dena_rewind_push(rw, states[20], S);
  CHECK(dena_rewind_step_back(rw, out, S) == 0 && memcmp(out, states[8], S) == 0);

  /* A size change clears. */
  dena_rewind_push(rw, states[0], S / 2);
  CHECK(dena_rewind_count(rw) == 0 && dena_rewind_bytes(rw) == S / 2);
  dena_rewind_destroy(rw);

  /* The budget evicts the oldest steps but keeps the newest. */
  rw = dena_rewind_create(S + 300);
  for (int k = 0; k < K; k++) dena_rewind_push(rw, states[k], S);
  CHECK(dena_rewind_bytes(rw) <= S + 300);
  size_t n = dena_rewind_count(rw);
  CHECK(n > 0 && n < K - 1);
  for (size_t s = 0; s < n; s++) CHECK(dena_rewind_step_back(rw, out, S) == 0);
  CHECK(memcmp(out, states[K - 1 - n], S) == 0);
  dena_rewind_destroy(rw);

  /* A budget smaller than one state still keeps the newest. */
  rw = dena_rewind_create(10);
  dena_rewind_push(rw, states[0], S);
  dena_rewind_push(rw, states[1], S);
  CHECK(dena_rewind_count(rw) == 0);
  dena_rewind_destroy(rw);
}

/* Long rewind (rewind.md): the cursor scrubs both ways without losing
 * anything until a push or keep. */
static void seek(void) {
  enum { S = 2048, K = 60 };
  static uint8_t states[K][S], out[S];
  for (int k = 0; k < K; k++)
    for (int i = 0; i < S; i++)
      states[k][i] = k ? states[k - 1][i] ^ (i % (k + 5) == 0 ? rnd() | 1 : 0) : rnd();
  dena_rewind *rw = dena_rewind_create(8 << 20);
  CHECK(dena_rewind_seek(rw, 0, 0, out, S) == DENA_NO_DATA);
  for (int k = 0; k < K; k++) dena_rewind_push(rw, states[k], S);
  size_t newest = dena_rewind_count(rw);
  CHECK(newest == K - 1 && dena_rewind_position(rw) == newest);
  size_t bytes = dena_rewind_bytes(rw);
  /* Back, forward past where it was, and back again, byte for byte. */
  size_t targets[] = {40, 10, 55, 0, K - 1, 25};
  for (size_t t = 0; t < sizeof targets / sizeof *targets; t++) {
    CHECK(dena_rewind_seek(rw, targets[t], (size_t)-1, out, S) == 0);
    CHECK(dena_rewind_position(rw) == targets[t]);
    CHECK(memcmp(out, states[targets[t]], S) == 0);
    CHECK(dena_rewind_count(rw) == newest && dena_rewind_bytes(rw) == bytes);
  }
  /* A byte limit moves one step at least and stops short of the target. */
  CHECK(dena_rewind_seek(rw, 5, 1, out, S) == 0);
  CHECK(dena_rewind_position(rw) == 24 && memcmp(out, states[24], S) == 0);
  /* Past the newest clamps. */
  CHECK(dena_rewind_seek(rw, 1000, (size_t)-1, out, S) == 0);
  CHECK(dena_rewind_position(rw) == newest && memcmp(out, states[K - 1], S) == 0);
  /* Keep drops what is newer than the cursor. */
  dena_rewind_seek(rw, 30, (size_t)-1, out, S);
  dena_rewind_keep(rw);
  CHECK(dena_rewind_count(rw) == 30 && dena_rewind_position(rw) == 30);
  CHECK(dena_rewind_bytes(rw) < bytes);
  CHECK(dena_rewind_step_back(rw, out, S) == 0 && memcmp(out, states[29], S) == 0);
  /* A push while scrubbed back continues from the cursor. */
  dena_rewind_seek(rw, 10, (size_t)-1, out, S);
  dena_rewind_push(rw, states[50], S);
  CHECK(dena_rewind_count(rw) == 11);
  CHECK(dena_rewind_step_back(rw, out, S) == 0 && memcmp(out, states[10], S) == 0);
  CHECK(dena_rewind_step_back(rw, out, S) == 0 && memcmp(out, states[9], S) == 0);
  /* Step back while scrubbed also drops the newer captures first. */
  dena_rewind_seek(rw, 4, (size_t)-1, out, S);
  CHECK(dena_rewind_step_back(rw, out, S) == 0 && memcmp(out, states[3], S) == 0);
  CHECK(dena_rewind_count(rw) == 3);
  dena_rewind_destroy(rw);

  /* Eviction keeps the cursor on the newest. */
  rw = dena_rewind_create(S + 600);
  for (int k = 0; k < K; k++) dena_rewind_push(rw, states[k], S);
  CHECK(dena_rewind_position(rw) == dena_rewind_count(rw));
  CHECK(dena_rewind_seek(rw, 0, (size_t)-1, out, S) == 0);
  CHECK(memcmp(out, states[K - 1 - dena_rewind_count(rw)], S) == 0);
  dena_rewind_destroy(rw);
}

static void with_core(const char *path) {
  char err[256];
  dena_core *core = dena_core_load(path, err, sizeof err);
  if (!core || dena_core_load_game(core, NULL, err, sizeof err)) {
    fprintf(stderr, "%s\n", err);
    failures++;
    return;
  }
  enum { FRAMES = 120, BACK = 30 };
  size_t size = dena_core_state_size(core);
  CHECK(size > 0);
  uint8_t *state = malloc(size);
  uint64_t hashes[FRAMES];
  dena_rewind *rw = dena_rewind_create(8 << 20);
  for (int f = 0; f < FRAMES; f++) {
    dena_core_set_buttons(core, 0, (f / 7) % 2 ? 1u << 8 : 0);
    CHECK(dena_core_save_state(core, state, size) == 0);
    dena_rewind_push(rw, state, size);
    dena_core_run_frame(core);
    hashes[f] = dena_frame_hash(dena_core_frame(core));
  }
  for (int s = 0; s < BACK; s++) CHECK(dena_rewind_step_back(rw, state, size) == 0);
  /* The capture before frame FRAMES-1-BACK ran; rerun it with the same input. */
  int f = FRAMES - 1 - BACK;
  CHECK(dena_core_load_state(core, state, size) == 0);
  dena_core_set_buttons(core, 0, (f / 7) % 2 ? 1u << 8 : 0);
  dena_core_run_frame(core);
  CHECK(dena_frame_hash(dena_core_frame(core)) == hashes[f]);
  dena_rewind_destroy(rw);
  free(state);
  dena_core_unload(core);
}

int main(int argc, char **argv) {
  codec();
  ring();
  seek();
  if (argc > 1) with_core(argv[1]);
  if (failures) fprintf(stderr, "%d failure(s)\n", failures);
  else printf("rewind: ok\n");
  return failures ? 1 : 0;
}
