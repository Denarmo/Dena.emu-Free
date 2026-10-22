/* Rewind ring buffer of XOR-delta, run-length encoded save states.
 * Spec: docs/specs/rewind.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef DENA_REWIND_H
#define DENA_REWIND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dena_rewind dena_rewind;

/* budget_bytes bounds the memory used by stored states (the newest full state
 * included). Returns NULL when out of memory. */
dena_rewind *dena_rewind_create(size_t budget_bytes);
void dena_rewind_destroy(dena_rewind *rw);

/* Adds the newest state. A state of a different size clears the buffer first.
 * 0 ok, -1 out of memory (the buffer is cleared). */
int dena_rewind_push(dena_rewind *rw, const void *state, size_t size);

/* Writes the state before the newest into out and makes it the newest.
 * 0 ok, DENA_NO_DATA (1) when there is nothing older, -1 on a size mismatch. */
int dena_rewind_step_back(dena_rewind *rw, void *out, size_t size);

/* Scrubbing (rewind.md, Long rewind): moves the head to capture `target`
 * (0 = oldest, dena_rewind_count = newest) without dropping anything, so it
 * can move forward again, and writes that state into out. Stops early once
 * it has applied max_bytes of deltas (at least one step); call again to go
 * on. A push or step_back first drops the captures newer than the head, as
 * does dena_rewind_keep. 0 ok, DENA_NO_DATA when empty, -1 size mismatch. */
int dena_rewind_seek(dena_rewind *rw, size_t target, size_t max_bytes, void *out, size_t size);
void dena_rewind_keep(dena_rewind *rw);
size_t dena_rewind_position(const dena_rewind *rw);

/* Captures stored (not counting the newest full state). */
size_t dena_rewind_count(const dena_rewind *rw);
size_t dena_rewind_bytes(const dena_rewind *rw);
void dena_rewind_clear(dena_rewind *rw);

/* XOR of a and b, run-length encoded into out (capacity cap).
 * Returns the encoded length, or 0 if it doesn't fit. Exposed for tests. */
size_t dena_xor_rle_encode(const uint8_t *a, const uint8_t *b, size_t size,
                           uint8_t *out, size_t cap);
/* XORs an encoded delta into buf in place. 0 ok, -1 if malformed. */
int dena_xor_rle_apply(uint8_t *buf, size_t size, const uint8_t *enc, size_t len);

#ifdef __cplusplus
}
#endif

#endif
