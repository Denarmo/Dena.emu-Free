/* Rewind ring buffer. Spec: docs/specs/rewind.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "dena/rewind.h"

#include <stdlib.h>
#include <string.h>

#define NO_DATA 1     /* DENA_NO_DATA in dena/session.h */
#define MIN_ZERO_RUN 4 /* shorter zero runs stay inside a literal */

typedef struct {
  uint8_t *data;
  size_t len;
} entry;

struct dena_rewind {
  size_t budget;
  size_t size;      /* state size; 0 until the first push */
  uint8_t *head;    /* newest state, in full */
  uint8_t *scratch; /* encode buffer, 2 * size + 32 */
  entry *ring;      /* deltas, oldest at ring[start] */
  size_t cap, start, count;
  size_t cursor;    /* head is the state after entry cursor - 1; count when not seeking */
  size_t bytes;     /* size + sum of entry lengths */
};

/* ---- XOR + run-length codec ---- */

static size_t put_varint(uint8_t *out, size_t pos, size_t cap, size_t v) {
  do {
    if (pos >= cap) return 0;
    uint8_t b = v & 0x7f;
    v >>= 7;
    out[pos++] = b | (v ? 0x80 : 0);
  } while (v);
  return pos;
}

static int get_varint(const uint8_t *in, size_t len, size_t *pos, size_t *v) {
  size_t r = 0;
  for (unsigned shift = 0; shift < 64; shift += 7) {
    if (*pos >= len) return -1;
    uint8_t b = in[(*pos)++];
    r |= (size_t)(b & 0x7f) << shift;
    if (!(b & 0x80)) {
      *v = r;
      return 0;
    }
  }
  return -1;
}

size_t dena_xor_rle_encode(const uint8_t *a, const uint8_t *b, size_t size,
                           uint8_t *out, size_t cap) {
  size_t i = 0, o = 0;
  while (i < size) {
    size_t z = 0;
    while (i < size && a[i] == b[i]) z++, i++;
    size_t start = i;
    while (i < size) {
      if (a[i] != b[i]) {
        i++;
        continue;
      }
      size_t j = i;
      while (j < size && a[j] == b[j] && j - i < MIN_ZERO_RUN) j++;
      if (j - i >= MIN_ZERO_RUN || j == size) break;
      i = j;
    }
    size_t lit = i - start;
    if (!(o = put_varint(out, o, cap, z))) return 0;
    if (!(o = put_varint(out, o, cap, lit))) return 0;
    if (o + lit > cap) return 0;
    for (size_t k = start; k < i; k++) out[o++] = a[k] ^ b[k];
  }
  return o;
}

int dena_xor_rle_apply(uint8_t *buf, size_t size, const uint8_t *enc, size_t len) {
  size_t p = 0, pos = 0;
  while (p < len) {
    size_t z, lit;
    if (get_varint(enc, len, &p, &z) || get_varint(enc, len, &p, &lit)) return -1;
    if (z > size - pos) return -1;
    pos += z;
    if (lit > size - pos || lit > len - p) return -1;
    for (size_t k = 0; k < lit; k++) buf[pos + k] ^= enc[p + k];
    pos += lit;
    p += lit;
  }
  return 0;
}

/* ---- Ring ---- */

dena_rewind *dena_rewind_create(size_t budget_bytes) {
  dena_rewind *rw = calloc(1, sizeof *rw);
  if (rw) rw->budget = budget_bytes;
  return rw;
}

static void drop_oldest(dena_rewind *rw) {
  entry *e = &rw->ring[rw->start];
  rw->bytes -= e->len;
  free(e->data);
  e->data = NULL;
  rw->start = (rw->start + 1) % rw->cap;
  rw->count--;
  if (rw->cursor) rw->cursor--;
}

static entry *at(dena_rewind *rw, size_t i) { return &rw->ring[(rw->start + i) % rw->cap]; }

/* Drops the captures newer than the cursor: the head becomes the newest. */
static void truncate_to_cursor(dena_rewind *rw) {
  while (rw->count > rw->cursor) {
    entry *e = at(rw, rw->count - 1);
    rw->bytes -= e->len;
    free(e->data);
    e->data = NULL;
    rw->count--;
  }
}

void dena_rewind_clear(dena_rewind *rw) {
  while (rw->count) drop_oldest(rw);
  free(rw->head);
  free(rw->scratch);
  rw->head = rw->scratch = NULL;
  rw->size = rw->bytes = rw->start = rw->cursor = 0;
}

void dena_rewind_destroy(dena_rewind *rw) {
  if (!rw) return;
  dena_rewind_clear(rw);
  free(rw->ring);
  free(rw);
}

static int grow(dena_rewind *rw) {
  size_t cap = rw->cap ? rw->cap * 2 : 64;
  entry *ring = malloc(cap * sizeof *ring);
  if (!ring) return -1;
  for (size_t i = 0; i < rw->count; i++) ring[i] = rw->ring[(rw->start + i) % rw->cap];
  free(rw->ring);
  rw->ring = ring;
  rw->cap = cap;
  rw->start = 0;
  return 0;
}

int dena_rewind_push(dena_rewind *rw, const void *state, size_t size) {
  truncate_to_cursor(rw);
  if (size != rw->size) {
    dena_rewind_clear(rw);
    rw->head = malloc(size);
    rw->scratch = malloc(2 * size + 32);
    if (!rw->head || !rw->scratch) {
      dena_rewind_clear(rw);
      return -1;
    }
    memcpy(rw->head, state, size);
    rw->size = rw->bytes = size;
    return 0;
  }
  /* Delta that turns the new state back into the current head. */
  size_t len = dena_xor_rle_encode(state, rw->head, size, rw->scratch, 2 * size + 32);
  uint8_t *data = malloc(len ? len : 1);
  if (!data || (rw->count == rw->cap && grow(rw))) {
    free(data);
    dena_rewind_clear(rw);
    return -1;
  }
  memcpy(data, rw->scratch, len);
  rw->ring[(rw->start + rw->count) % rw->cap] = (entry){data, len};
  rw->count++;
  rw->cursor = rw->count;
  rw->bytes += len;
  memcpy(rw->head, state, size);
  while (rw->count && rw->bytes > rw->budget) drop_oldest(rw);
  return 0;
}

int dena_rewind_step_back(dena_rewind *rw, void *out, size_t size) {
  truncate_to_cursor(rw);
  if (!rw->count) return NO_DATA;
  if (size != rw->size) return -1;
  entry *e = at(rw, rw->count - 1);
  if (dena_xor_rle_apply(rw->head, size, e->data, e->len)) return -1;
  rw->bytes -= e->len;
  free(e->data);
  e->data = NULL;
  rw->count--;
  rw->cursor = rw->count;
  memcpy(out, rw->head, size);
  return 0;
}

/* XOR deltas undo themselves: entry i turns state i + 1 into state i and
 * state i back into state i + 1, so the cursor moves both ways. */
int dena_rewind_seek(dena_rewind *rw, size_t target, size_t max_bytes, void *out, size_t size) {
  if (!rw->count) return NO_DATA;
  if (size != rw->size) return -1;
  if (target > rw->count) target = rw->count;
  size_t spent = 0;
  while (rw->cursor != target && (spent == 0 || spent < max_bytes)) {
    size_t i = rw->cursor > target ? rw->cursor - 1 : rw->cursor;
    entry *e = at(rw, i);
    if (dena_xor_rle_apply(rw->head, size, e->data, e->len)) return -1;
    spent += e->len + 1;
    rw->cursor = rw->cursor > target ? rw->cursor - 1 : rw->cursor + 1;
  }
  memcpy(out, rw->head, size);
  return 0;
}

void dena_rewind_keep(dena_rewind *rw) { truncate_to_cursor(rw); }

size_t dena_rewind_count(const dena_rewind *rw) { return rw->count; }

size_t dena_rewind_position(const dena_rewind *rw) { return rw->cursor; }

size_t dena_rewind_bytes(const dena_rewind *rw) { return rw->bytes; }
