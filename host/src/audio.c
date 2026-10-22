/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "dena/audio.h"

#include <stdlib.h>
#include <string.h>

int dena_ring_init(dena_ring *ring, uint32_t min_frames) {
  uint32_t cap = 1;
  while (cap < min_frames) cap <<= 1;
  ring->buf = (int16_t *)calloc((size_t)cap * 2, sizeof(int16_t));
  if (!ring->buf) return -1;
  ring->cap = cap;
  atomic_init(&ring->r, 0);
  atomic_init(&ring->w, 0);
  atomic_init(&ring->underruns, 0);
  return 0;
}

void dena_ring_free(dena_ring *ring) {
  free(ring->buf);
  ring->buf = NULL;
}

uint32_t dena_ring_fill(const dena_ring *ring) {
  uint32_t w = atomic_load_explicit(&((dena_ring *)ring)->w, memory_order_acquire);
  uint32_t r = atomic_load_explicit(&((dena_ring *)ring)->r, memory_order_acquire);
  return w - r;
}

uint32_t dena_ring_write(dena_ring *ring, const int16_t *frames, uint32_t n) {
  uint32_t w = atomic_load_explicit(&ring->w, memory_order_relaxed);
  uint32_t r = atomic_load_explicit(&ring->r, memory_order_acquire);
  uint32_t space = ring->cap - (w - r);
  if (n > space) n = space;
  for (uint32_t i = 0; i < n; i++) {
    uint32_t idx = (w + i) & (ring->cap - 1);
    ring->buf[idx * 2] = frames[i * 2];
    ring->buf[idx * 2 + 1] = frames[i * 2 + 1];
  }
  atomic_store_explicit(&ring->w, w + n, memory_order_release);
  return n;
}

uint32_t dena_ring_read(dena_ring *ring, int16_t *out, uint32_t n) {
  uint32_t r = atomic_load_explicit(&ring->r, memory_order_relaxed);
  uint32_t w = atomic_load_explicit(&ring->w, memory_order_acquire);
  uint32_t avail = w - r;
  uint32_t got = n < avail ? n : avail;
  for (uint32_t i = 0; i < got; i++) {
    uint32_t idx = (r + i) & (ring->cap - 1);
    out[i * 2] = ring->buf[idx * 2];
    out[i * 2 + 1] = ring->buf[idx * 2 + 1];
  }
  if (got < n) {
    memset(out + got * 2, 0, (size_t)(n - got) * 2 * sizeof(int16_t));
    atomic_fetch_add_explicit(&ring->underruns, 1, memory_order_relaxed);
  }
  atomic_store_explicit(&ring->r, r + got, memory_order_release);
  return got;
}

void dena_resampler_init(dena_resampler *rs, double in_rate, double out_rate) {
  memset(rs, 0, sizeof *rs);
  rs->in_rate = in_rate;
  rs->out_rate = out_rate;
}

void dena_rate_ctl_init(dena_rate_ctl *ctl, double max_adjust) {
  ctl->max_adjust = max_adjust;
  ctl->integral = 0;
}

static double clampd(double v, double lo, double hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

double dena_rate_ctl_update(dena_rate_ctl *ctl, uint32_t fill, uint32_t target) {
  if (target == 0) return 1.0;
  /* Below target -> positive error -> produce slightly more output. */
  double err = clampd(((double)target - (double)fill) / (double)target, -1.0, 1.0);
  const double kp = 0.5, ki = 0.002; /* in units of max_adjust */
  ctl->integral = clampd(ctl->integral + ki * err, -1.0, 1.0);
  return 1.0 + ctl->max_adjust * clampd(kp * err + ctl->integral, -1.0, 1.0);
}

uint32_t dena_resample(dena_resampler *rs, const int16_t *in, uint32_t n_in,
                       int16_t *out, uint32_t out_cap, double rate_mul) {
  if (n_in == 0) return 0;
  double step = rs->in_rate / (rs->out_rate * rate_mul); /* input frames per output frame */
  uint32_t produced = 0;
  /* Virtual input: index -1 is rs->prev (if any), then in[0..n_in-1]. */
  double pos = rs->has_prev ? rs->pos - 1.0 : rs->pos;
  while (produced < out_cap) {
    double base = pos < 0 ? -1.0 : (double)(uint32_t)pos;
    long i0 = (long)base;
    if (i0 + 1 >= (long)n_in) break; /* need in[i0+1] */
    double t = pos - base;
    for (int c = 0; c < 2; c++) {
      double a = i0 < 0 ? rs->prev[c] : in[i0 * 2 + c];
      double b = in[(i0 + 1) * 2 + c];
      double v = a + (b - a) * t;
      out[produced * 2 + c] = (int16_t)(v < -32768 ? -32768 : v > 32767 ? 32767 : v);
    }
    produced++;
    pos += step;
  }
  /* Carry the last input frame so interpolation is continuous across calls. */
  rs->prev[0] = in[(n_in - 1) * 2];
  rs->prev[1] = in[(n_in - 1) * 2 + 1];
  rs->has_prev = 1;
  rs->pos = pos - (double)(n_in - 1); /* relative to the new prev (index -1 -> 0) */
  if (rs->pos < 0) rs->pos = 0;
  return produced;
}
