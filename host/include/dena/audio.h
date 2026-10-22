/* Audio path between the emulator thread and the device audio callback.
 * Spec: docs/specs/latency-spike.md (Timing)
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef DENA_AUDIO_H
#define DENA_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#include <atomic>
typedef std::atomic<uint32_t> dena_atomic_u32;
extern "C" {
#else
#include <stdatomic.h>
typedef _Atomic uint32_t dena_atomic_u32;
#endif

/* Single-producer single-consumer ring of interleaved stereo int16 frames.
 * The producer is the emulator thread, the consumer the audio callback. */
typedef struct {
  int16_t *buf;
  uint32_t cap; /* frames; power of two */
  dena_atomic_u32 r, w;
  dena_atomic_u32 underruns; /* consumer wanted more than was buffered */
} dena_ring;

int dena_ring_init(dena_ring *ring, uint32_t min_frames);
void dena_ring_free(dena_ring *ring);
uint32_t dena_ring_fill(const dena_ring *ring); /* frames buffered */
/* Writes up to n frames; returns frames written (drops the rest when full). */
uint32_t dena_ring_write(dena_ring *ring, const int16_t *frames, uint32_t n);
/* Reads n frames; missing frames are zero-filled and count as one underrun.
 * Returns frames actually read. */
uint32_t dena_ring_read(dena_ring *ring, int16_t *out, uint32_t n);

/* Linear-interpolating resampler with dynamic rate control. */
typedef struct {
  double in_rate, out_rate;
  double pos;       /* fractional read position into the current input */
  int16_t prev[2];  /* last input frame of the previous call */
  int has_prev;
} dena_resampler;

void dena_resampler_init(dena_resampler *rs, double in_rate, double out_rate);

/* Dynamic rate control: a PI controller on buffer fill. The proportional
 * part reacts to jitter; the integral part absorbs a steady clock mismatch
 * (device vs. core), so the fill settles at the target. Output is bounded to
 * 1 +- max_adjust (e.g. 0.005), which is inaudible as pitch. */
typedef struct {
  double max_adjust;
  double integral;
} dena_rate_ctl;

void dena_rate_ctl_init(dena_rate_ctl *ctl, double max_adjust);
/* Called once per produced block. Returns the multiplier for the output rate. */
double dena_rate_ctl_update(dena_rate_ctl *ctl, uint32_t fill, uint32_t target);

/* Resamples n_in frames into out (capacity out_cap frames) at
 * out_rate * rate_mul. Returns frames produced. */
uint32_t dena_resample(dena_resampler *rs, const int16_t *in, uint32_t n_in,
                       int16_t *out, uint32_t out_cap, double rate_mul);

#ifdef __cplusplus
}
#endif

#endif
