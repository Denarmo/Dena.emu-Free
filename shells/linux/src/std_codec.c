// SPDX-License-Identifier: GPL-3.0-or-later
// Flutter StandardMessageCodec (encode/decode). Spec: docs/specs/embedder.md
#include "dena/std_codec.h"

#include <string.h>

// Decoder state: the input buffer and the current read offset. Padding and
// alignment are always measured from the start of this buffer.
struct rd {
  const uint8_t *buf;
  size_t len;
  size_t pos;
  struct dena_val_arena *arena;
};

static int rd_byte(struct rd *r, uint8_t *out) {
  if (r->pos >= r->len) return -1;
  *out = r->buf[r->pos++];
  return 0;
}

static int rd_u16(struct rd *r, uint16_t *out) {
  uint8_t a, b;
  if (rd_byte(r, &a) || rd_byte(r, &b)) return -1;
  *out = (uint16_t)((uint16_t)a | ((uint16_t)b << 8));
  return 0;
}

static int rd_u32(struct rd *r, uint32_t *out) {
  uint8_t b[4];
  for (int i = 0; i < 4; i++)
    if (rd_byte(r, &b[i])) return -1;
  *out = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
         ((uint32_t)b[3] << 24);
  return 0;
}

static int rd_u64(struct rd *r, uint64_t *out) {
  uint8_t b[8];
  for (int i = 0; i < 8; i++)
    if (rd_byte(r, &b[i])) return -1;
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) v = (v << 8) | b[i];
  *out = v;
  return 0;
}

// size: < 254 is one byte; 254 then uint16; 255 then uint32.
static int rd_size(struct rd *r, size_t *out) {
  uint8_t b;
  if (rd_byte(r, &b)) return -1;
  if (b < 254) {
    *out = b;
    return 0;
  }
  if (b == 254) {
    uint16_t v;
    if (rd_u16(r, &v)) return -1;
    *out = v;
    return 0;
  }
  uint32_t v;
  if (rd_u32(r, &v)) return -1;
  *out = v;
  return 0;
}

// Skip zero-or-more padding bytes so the next byte is at a multiple of align.
static int rd_pad(struct rd *r, size_t align) {
  size_t m = r->pos % align;
  if (m != 0) {
    size_t pad = align - m;
    if (pad > r->len - r->pos) return -1;
    r->pos += pad;
  }
  return 0;
}

// Reserves n nodes in the arena, or NULL if they do not fit.
static struct dena_val *arena_take(struct dena_val_arena *a, size_t n) {
  if (n == 0) return a->vals;
  if (n > a->cap - a->used) return NULL;
  struct dena_val *p = &a->vals[a->used];
  a->used += n;
  return p;
}

static int decode_val(struct rd *r, int depth, struct dena_val *out) {
  if (depth > 32) return -1;
  uint8_t tag;
  if (rd_byte(r, &tag)) return -1;
  memset(out, 0, sizeof *out);
  switch (tag) {
    case 0:
      out->type = DENA_VAL_NULL;
      return 0;
    case 1:
      out->type = DENA_VAL_TRUE;
      return 0;
    case 2:
      out->type = DENA_VAL_FALSE;
      return 0;
    case 3: {
      uint32_t u;
      if (rd_u32(r, &u)) return -1;
      out->type = DENA_VAL_INT;
      out->i = (int64_t)(int32_t)u;
      return 0;
    }
    case 4: {
      uint64_t u;
      if (rd_u64(r, &u)) return -1;
      out->type = DENA_VAL_INT;
      out->i = (int64_t)u;
      return 0;
    }
    case 5: // large int: unsupported, treated as malformed input
      return -1;
    case 6: {
      if (rd_pad(r, 8)) return -1;
      uint64_t u;
      if (rd_u64(r, &u)) return -1;
      memcpy(&out->d, &u, sizeof u);
      out->type = DENA_VAL_DOUBLE;
      return 0;
    }
    case 7:
    case 8: {
      size_t n;
      if (rd_size(r, &n)) return -1;
      if (n > r->len - r->pos) return -1;
      out->data = r->buf + r->pos;
      out->size = n;
      r->pos += n;
      out->type = tag == 7 ? DENA_VAL_STRING : DENA_VAL_BYTES;
      return 0;
    }
    case 9:
    case 10:
    case 11:
    case 14: {
      size_t count;
      if (rd_size(r, &count)) return -1;
      size_t elem = (tag == 10 || tag == 11) ? 8 : 4;
      size_t align = (tag == 10 || tag == 11) ? 8 : 4;
      if (rd_pad(r, align)) return -1;
      if (count > (r->len - r->pos) / elem) return -1;
      out->data = r->buf + r->pos;
      out->size = count;
      r->pos += count * elem;
      out->type = tag == 9    ? DENA_VAL_INT32_LIST
                  : tag == 10 ? DENA_VAL_INT64_LIST
                  : tag == 11 ? DENA_VAL_FLOAT64_LIST
                              : DENA_VAL_FLOAT32_LIST;
      return 0;
    }
    case 12: {
      size_t count;
      if (rd_size(r, &count)) return -1;
      struct dena_val *items = arena_take(r->arena, count);
      if (!items) return -1;
      out->type = DENA_VAL_LIST;
      out->size = count;
      out->items = items;
      for (size_t i = 0; i < count; i++)
        if (decode_val(r, depth + 1, &items[i])) return -1;
      return 0;
    }
    case 13: {
      size_t count;
      if (rd_size(r, &count)) return -1;
      if (count > (r->arena->cap - r->arena->used) / 2) return -1;
      struct dena_val *items = arena_take(r->arena, count * 2);
      if (!items) return -1;
      out->type = DENA_VAL_MAP;
      out->size = count;
      out->items = items;
      for (size_t i = 0; i < count * 2; i++)
        if (decode_val(r, depth + 1, &items[i])) return -1;
      return 0;
    }
    default: {
      // Tags 128..255 are custom (Pigeon): the tag then exactly one value.
      if (tag < 128) return -1; // 15..127 are unknown and malformed.
      struct dena_val *slot = arena_take(r->arena, 1);
      if (!slot) return -1;
      out->type = DENA_VAL_CUSTOM;
      out->custom = tag;
      out->items = slot;
      return decode_val(r, depth + 1, slot);
    }
  }
}

int dena_decode(const uint8_t *buf, size_t len, struct dena_val_arena *arena,
                struct dena_val *out) {
  if (!buf || !arena || !out) return -1;
  struct rd r = {buf, len, 0, arena};
  if (decode_val(&r, 0, out)) return -1;
  if (r.pos != len) return -1; // trailing bytes
  return 0;
}

// --- Encoder ---------------------------------------------------------------

static void put_byte(struct dena_buf *b, uint8_t v) {
  if (b->failed || b->len >= b->cap) {
    b->failed = true;
    return;
  }
  b->data[b->len++] = v;
}

static void put_mem(struct dena_buf *b, const void *p, size_t n) {
  if (b->failed) return;
  if (b->len > b->cap || n > b->cap - b->len) {
    b->failed = true;
    return;
  }
  if (n != 0) memcpy(b->data + b->len, p, n);
  b->len += n;
}

static void put_u16(struct dena_buf *b, uint16_t v) {
  put_byte(b, (uint8_t)(v & 0xff));
  put_byte(b, (uint8_t)(v >> 8));
}

static void put_u32(struct dena_buf *b, uint32_t v) {
  for (int i = 0; i < 4; i++) put_byte(b, (uint8_t)(v >> (8 * i)));
}

static void put_u64(struct dena_buf *b, uint64_t v) {
  for (int i = 0; i < 8; i++) put_byte(b, (uint8_t)(v >> (8 * i)));
}

static void put_size(struct dena_buf *b, size_t n) {
  if (n < 254) {
    put_byte(b, (uint8_t)n);
  } else if (n <= 0xFFFFu) {
    put_byte(b, 254);
    put_u16(b, (uint16_t)n);
  } else {
    put_byte(b, 255);
    put_u32(b, (uint32_t)n);
  }
}

// Zero padding until the next byte sits at a multiple of align from the start.
static void put_pad(struct dena_buf *b, size_t align) {
  while (!b->failed && (b->len % align) != 0) put_byte(b, 0);
}

void dena_put_null(struct dena_buf *b) { put_byte(b, 0); }

void dena_put_bool(struct dena_buf *b, bool v) { put_byte(b, v ? 1 : 2); }

void dena_put_int(struct dena_buf *b, int64_t v) {
  if (v >= INT32_MIN && v <= INT32_MAX) {
    put_byte(b, 3);
    put_u32(b, (uint32_t)(int32_t)v);
  } else {
    put_byte(b, 4);
    put_u64(b, (uint64_t)v);
  }
}

void dena_put_double(struct dena_buf *b, double v) {
  put_byte(b, 6);
  put_pad(b, 8);
  uint64_t bits;
  memcpy(&bits, &v, sizeof bits);
  put_u64(b, bits);
}

void dena_put_string(struct dena_buf *b, const char *s) {
  if (!s) {
    dena_put_null(b);
    return;
  }
  size_t n = strlen(s);
  put_byte(b, 7);
  put_size(b, n);
  put_mem(b, s, n);
}

void dena_put_bytes(struct dena_buf *b, const uint8_t *data, size_t len) {
  put_byte(b, 8);
  put_size(b, len);
  put_mem(b, data, len);
}

void dena_put_list_start(struct dena_buf *b, size_t count) {
  put_byte(b, 12);
  put_size(b, count);
}

void dena_put_map_start(struct dena_buf *b, size_t count) {
  put_byte(b, 13);
  put_size(b, count);
}

void dena_put_custom_start(struct dena_buf *b, int tag) {
  put_byte(b, (uint8_t)tag);
}

// --- Lookups ---------------------------------------------------------------

const struct dena_val *dena_list_at(const struct dena_val *list, size_t i) {
  if (!list || list->type != DENA_VAL_LIST || i >= list->size) return NULL;
  return &list->items[i];
}

bool dena_val_string_eq(const struct dena_val *v, const char *s) {
  if (!v || !s || v->type != DENA_VAL_STRING) return false;
  size_t n = strlen(s);
  return v->size == n && memcmp(v->data, s, n) == 0;
}
