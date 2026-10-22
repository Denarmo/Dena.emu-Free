// SPDX-License-Identifier: GPL-3.0-or-later
// Flutter StandardMessageCodec (encode/decode) for platform channels. Spec: docs/specs/embedder.md
#ifndef DENA_STD_CODEC_H
#define DENA_STD_CODEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum dena_val_type {
  DENA_VAL_NULL,
  DENA_VAL_TRUE,
  DENA_VAL_FALSE,
  DENA_VAL_INT,
  DENA_VAL_DOUBLE,
  DENA_VAL_STRING,
  DENA_VAL_BYTES,
  DENA_VAL_INT32_LIST,
  DENA_VAL_INT64_LIST,
  DENA_VAL_FLOAT32_LIST,
  DENA_VAL_FLOAT64_LIST,
  DENA_VAL_LIST,
  DENA_VAL_MAP,
  DENA_VAL_CUSTOM
};

struct dena_val {
  enum dena_val_type type;
  int64_t i;
  double d;
  const uint8_t *data;
  size_t size;       /* string/bytes: byte length; typed lists: element count;
                        list: item count; map: pair count */
  struct dena_val *items; /* list items, or map keys and values interleaved
                             (2*size) */
  int custom;        /* tag for DENA_VAL_CUSTOM; its value is items[0] */
};

// Decoding arena: a flat pool of dena_val nodes. The caller provides vals/cap;
// used is advanced as the decoder allocates. No dynamic allocation is done.
struct dena_val_arena {
  struct dena_val *vals;
  size_t cap, used;
};

// Decodes one value from buf (len bytes), filling *out and allocating nested
// nodes from arena. Returns 0, or -1 on malformed/truncated input, nesting
// deeper than 32, or arena exhaustion. Must consume exactly len bytes.
// Decoded strings/bytes/typed lists point into buf (no copy).
int dena_decode(const uint8_t *buf, size_t len, struct dena_val_arena *arena,
                struct dena_val *out);

// Encoder: the caller owns the storage. On overflow, failed is set and writing
// stops.
struct dena_buf {
  uint8_t *data;
  size_t len, cap;
  bool failed;
};

void dena_put_null(struct dena_buf *b);
void dena_put_bool(struct dena_buf *b, bool v);
void dena_put_int(struct dena_buf *b, int64_t v); // tag 3 when it fits int32
void dena_put_double(struct dena_buf *b, double v);
void dena_put_string(struct dena_buf *b, const char *s); // NULL writes null
void dena_put_bytes(struct dena_buf *b, const uint8_t *data, size_t len);
void dena_put_list_start(struct dena_buf *b, size_t count);
void dena_put_map_start(struct dena_buf *b, size_t count);
void dena_put_custom_start(struct dena_buf *b, int tag); // then one value

// Lookups: NULL if not a list or out of range; byte-wise UTF-8 compare.
const struct dena_val *dena_list_at(const struct dena_val *list, size_t i);
bool dena_val_string_eq(const struct dena_val *v, const char *s);

#ifdef __cplusplus
}
#endif
#endif
