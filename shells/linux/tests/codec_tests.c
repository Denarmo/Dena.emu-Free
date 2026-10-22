// SPDX-License-Identifier: GPL-3.0-or-later
// Tests for the Flutter StandardMessageCodec implementation.
// Spec: docs/specs/embedder.md
#include <stdio.h>
#include <string.h>

#include "dena/std_codec.h"

static int failures;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      failures++;                                                 \
    }                                                             \
  } while (0)

static uint8_t enc[4096];
static struct dena_val vals[512];
static struct dena_val_arena arena;

static struct dena_buf new_buf(void) {
  struct dena_buf b;
  b.data = enc;
  b.len = 0;
  b.cap = sizeof enc;
  b.failed = false;
  return b;
}

static int dec(const uint8_t *buf, size_t len, struct dena_val *out) {
  arena.used = 0;
  return dena_decode(buf, len, &arena, out);
}

static void exact_bytes(void) {
  struct dena_buf b;

  // int 1 -> 03 01 00 00 00
  b = new_buf();
  dena_put_int(&b, 1);
  const uint8_t i1[] = {0x03, 0x01, 0x00, 0x00, 0x00};
  CHECK(!b.failed);
  CHECK(b.len == sizeof i1);
  CHECK(memcmp(enc, i1, sizeof i1) == 0);

  // int 2^40 -> 04 + 8 little-endian bytes
  b = new_buf();
  int64_t big = (int64_t)1 << 40;
  dena_put_int(&b, big);
  CHECK(!b.failed);
  CHECK(b.len == 9u);
  CHECK(enc[0] == 0x04);
  for (int i = 0; i < 8; i++)
    CHECK(enc[1 + i] == (uint8_t)((uint64_t)big >> (8 * i)));

  // string "hi" -> 07 02 68 69
  b = new_buf();
  dena_put_string(&b, "hi");
  const uint8_t hi[] = {0x07, 0x02, 0x68, 0x69};
  CHECK(b.len == sizeof hi && memcmp(enc, hi, sizeof hi) == 0);

  // a 300-byte string uses the uint16 size form: 07 FE 2C 01 ...
  static char s[301];
  memset(s, 'a', 300);
  s[300] = '\0';
  b = new_buf();
  dena_put_string(&b, s);
  CHECK(!b.failed);
  CHECK(enc[0] == 0x07 && enc[1] == 0xFE && enc[2] == 0x2C && enc[3] == 0x01);
  CHECK(b.len == 4u + 300u);
}

static void double_padding(void) {
  double d = -12.5;
  uint64_t bits;
  memcpy(&bits, &d, sizeof bits);

  // Tag, then 7 zero bytes, then the 8 data bytes (offset 0 -> 8).
  struct dena_buf b = new_buf();
  dena_put_double(&b, d);
  CHECK(!b.failed);
  CHECK(b.len == 16u);
  CHECK(enc[0] == 0x06);
  for (int i = 1; i < 8; i++) CHECK(enc[i] == 0x00);
  for (int i = 0; i < 8; i++)
    CHECK(enc[8 + i] == (uint8_t)(bits >> (8 * i)));

  // A 1-byte prefix (custom tag) leaves the 8 data bytes 8-aligned too.
  b = new_buf();
  dena_put_custom_start(&b, 130);
  dena_put_double(&b, d);
  CHECK(!b.failed);
  CHECK(b.len == 16u);
  CHECK(enc[0] == 130 && enc[1] == 0x06);
  for (int i = 2; i < 8; i++) CHECK(enc[i] == 0x00);
}

static void round_trip_scalars(void) {
  struct dena_buf b;
  struct dena_val v;

  b = new_buf();
  dena_put_null(&b);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_NULL);

  b = new_buf();
  dena_put_bool(&b, true);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_TRUE);

  b = new_buf();
  dena_put_bool(&b, false);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_FALSE);

  const int64_t ints[] = {0,
                          1,
                          -1,
                          42,
                          INT32_MAX,
                          INT32_MIN,
                          2147483648LL,
                          -2147483649LL,
                          (int64_t)1 << 40,
                          0x7fffffffffffffffLL,
                          -0x7fffffffffffffffLL - 1};
  for (size_t i = 0; i < sizeof ints / sizeof ints[0]; i++) {
    b = new_buf();
    dena_put_int(&b, ints[i]);
    CHECK(!b.failed);
    CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_INT &&
          v.i == ints[i]);
    // Small values use the int32 tag; large values use the int64 tag.
    CHECK(enc[0] == ((ints[i] >= INT32_MIN && ints[i] <= INT32_MAX) ? 3 : 4));
  }

  const double doubles[] = {0.0, 1.5, -3.25, 1e300, -1e-300};
  for (size_t i = 0; i < sizeof doubles / sizeof doubles[0]; i++) {
    b = new_buf();
    dena_put_double(&b, doubles[i]);
    CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_DOUBLE &&
          v.d == doubles[i]);
  }
}

static void round_trip_string_bytes(void) {
  struct dena_buf b;
  struct dena_val v;

  b = new_buf();
  dena_put_string(&b, "hello \xc3\xa9");
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_STRING &&
        v.size == 8u && dena_val_string_eq(&v, "hello \xc3\xa9"));

  b = new_buf();
  dena_put_string(&b, NULL);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_NULL);

  b = new_buf();
  dena_put_string(&b, "");
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_STRING && v.size == 0u &&
        dena_val_string_eq(&v, ""));

  const uint8_t raw[] = {0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0xFF};
  b = new_buf();
  dena_put_bytes(&b, raw, sizeof raw);
  CHECK(!b.failed);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_BYTES &&
        v.size == sizeof raw && memcmp(v.data, raw, sizeof raw) == 0);

  // The string helper rejects non-strings and mismatches.
  CHECK(!dena_val_string_eq(&v, "x"));
  CHECK(!dena_val_string_eq(NULL, "x"));
}

static void round_trip_containers(void) {
  struct dena_buf b;
  struct dena_val v;

  // list [7, "xy", null]
  b = new_buf();
  dena_put_list_start(&b, 3);
  dena_put_int(&b, 7);
  dena_put_string(&b, "xy");
  dena_put_null(&b);
  CHECK(!b.failed);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_LIST && v.size == 3u);
  const struct dena_val *e0 = dena_list_at(&v, 0);
  CHECK(e0 && e0->type == DENA_VAL_INT && e0->i == 7);
  const struct dena_val *e1 = dena_list_at(&v, 1);
  CHECK(e1 && dena_val_string_eq(e1, "xy"));
  const struct dena_val *e2 = dena_list_at(&v, 2);
  CHECK(e2 && e2->type == DENA_VAL_NULL);
  CHECK(dena_list_at(&v, 3) == NULL);
  CHECK(dena_list_at(NULL, 0) == NULL);

  // map {"a": 1, "b": [true, false]}
  b = new_buf();
  dena_put_map_start(&b, 2);
  dena_put_string(&b, "a");
  dena_put_int(&b, 1);
  dena_put_string(&b, "b");
  dena_put_list_start(&b, 2);
  dena_put_bool(&b, true);
  dena_put_bool(&b, false);
  CHECK(!b.failed);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_MAP && v.size == 2u);
  CHECK(v.items[0].type == DENA_VAL_STRING &&
        dena_val_string_eq(&v.items[0], "a"));
  CHECK(v.items[1].type == DENA_VAL_INT && v.items[1].i == 1);
  CHECK(v.items[2].type == DENA_VAL_STRING &&
        dena_val_string_eq(&v.items[2], "b"));
  CHECK(v.items[3].type == DENA_VAL_LIST && v.items[3].size == 2u);
  CHECK(dena_list_at(&v, 0) == NULL); // a map is not a list
  CHECK(dena_list_at(&v.items[3], 0)->type == DENA_VAL_TRUE);
  CHECK(dena_list_at(&v.items[3], 1)->type == DENA_VAL_FALSE);

  // custom tag 130 wrapping a list of two ints
  b = new_buf();
  dena_put_custom_start(&b, 130);
  dena_put_list_start(&b, 2);
  dena_put_int(&b, 1);
  dena_put_int(&b, 256);
  CHECK(!b.failed);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_CUSTOM &&
        v.custom == 130);
  CHECK(v.items[0].type == DENA_VAL_LIST && v.items[0].size == 2u);
  CHECK(dena_list_at(&v.items[0], 0)->i == 1);
  CHECK(dena_list_at(&v.items[0], 1)->i == 256);

  // a custom tag wrapping another custom tag
  b = new_buf();
  dena_put_custom_start(&b, 128);
  dena_put_custom_start(&b, 255);
  dena_put_string(&b, "z");
  CHECK(!b.failed);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_CUSTOM &&
        v.custom == 128 && v.items[0].type == DENA_VAL_CUSTOM &&
        v.items[0].custom == 255 &&
        dena_val_string_eq(&v.items[0].items[0], "z"));
}

// The encoder has no typed-list writers; these are hand-built to exercise the
// decoder, including the alignment padding.
static void typed_lists(void) {
  struct dena_val v;

  // Int32List [1, -2, 3]: tag, count 3, 2 pad, then 12 element bytes.
  uint8_t i32[16];
  size_t n = 0;
  i32[n++] = 0x09;
  i32[n++] = 0x03;
  i32[n++] = 0x00; // pad to offset 4
  i32[n++] = 0x00;
  const int32_t iv[3] = {1, -2, 3};
  for (int k = 0; k < 3; k++)
    for (int j = 0; j < 4; j++)
      i32[n++] = (uint8_t)((uint32_t)iv[k] >> (8 * j));
  CHECK(n == 16u);
  CHECK(dec(i32, n, &v) == 0 && v.type == DENA_VAL_INT32_LIST && v.size == 3u);
  for (int k = 0; k < 3; k++) {
    uint32_t u = 0;
    for (int j = 0; j < 4; j++) u |= (uint32_t)v.data[k * 4 + j] << (8 * j);
    CHECK((int32_t)u == iv[k]);
  }

  // Int64List [1, -2]: tag, count 2, 6 pad, then 16 element bytes.
  uint8_t i64[24];
  n = 0;
  i64[n++] = 0x0A;
  i64[n++] = 0x02;
  for (int j = 0; j < 6; j++) i64[n++] = 0x00; // pad to offset 8
  const int64_t lv[2] = {1, -2};
  for (int k = 0; k < 2; k++)
    for (int j = 0; j < 8; j++)
      i64[n++] = (uint8_t)((uint64_t)lv[k] >> (8 * j));
  CHECK(n == 24u);
  CHECK(dec(i64, n, &v) == 0 && v.type == DENA_VAL_INT64_LIST && v.size == 2u);
  for (int k = 0; k < 2; k++) {
    uint64_t u = 0;
    for (int j = 0; j < 8; j++) u |= (uint64_t)v.data[k * 8 + j] << (8 * j);
    CHECK((int64_t)u == lv[k]);
  }

  // Float64List [1.5, -2.25]: tag, count 2, 6 pad, then 16 element bytes.
  uint8_t f64[24];
  n = 0;
  f64[n++] = 0x0B;
  f64[n++] = 0x02;
  for (int j = 0; j < 6; j++) f64[n++] = 0x00; // pad to offset 8
  const double dv[2] = {1.5, -2.25};
  for (int k = 0; k < 2; k++) {
    uint64_t bits;
    memcpy(&bits, &dv[k], sizeof bits);
    for (int j = 0; j < 8; j++) f64[n++] = (uint8_t)(bits >> (8 * j));
  }
  CHECK(n == 24u);
  CHECK(dec(f64, n, &v) == 0 && v.type == DENA_VAL_FLOAT64_LIST &&
        v.size == 2u);
  for (int k = 0; k < 2; k++) {
    uint64_t bits = 0;
    for (int j = 0; j < 8; j++) bits |= (uint64_t)v.data[k * 8 + j] << (8 * j);
    double got;
    memcpy(&got, &bits, sizeof got);
    CHECK(got == dv[k]);
  }

  // Float32List [2.5]: tag, count 1, 2 pad, then 4 element bytes.
  uint8_t f32[8];
  n = 0;
  f32[n++] = 0x0E;
  f32[n++] = 0x01;
  f32[n++] = 0x00; // pad to offset 4
  f32[n++] = 0x00;
  const float fv = 2.5f;
  uint32_t fb;
  memcpy(&fb, &fv, sizeof fb);
  for (int j = 0; j < 4; j++) f32[n++] = (uint8_t)(fb >> (8 * j));
  CHECK(n == 8u);
  CHECK(dec(f32, n, &v) == 0 && v.type == DENA_VAL_FLOAT32_LIST && v.size == 1u);
  uint32_t g = 0;
  for (int j = 0; j < 4; j++) g |= (uint32_t)v.data[j] << (8 * j);
  float gf;
  memcpy(&gf, &g, sizeof gf);
  CHECK(gf == fv);

  // An empty typed list is valid.
  const uint8_t empty[] = {0x09, 0x00, 0x00, 0x00};
  CHECK(dec(empty, sizeof empty, &v) == 0 && v.type == DENA_VAL_INT32_LIST &&
        v.size == 0u);
}

static void decode_errors(void) {
  struct dena_val v;

  // truncated int32
  const uint8_t t1[] = {0x03, 0x00, 0x00};
  CHECK(dec(t1, sizeof t1, &v) == -1);

  // truncated string body
  const uint8_t t2[] = {0x07, 0x05, 'a', 'b'};
  CHECK(dec(t2, sizeof t2, &v) == -1);

  // trailing bytes after a valid int
  const uint8_t t3[] = {0x03, 0x01, 0x00, 0x00, 0x00, 0x99};
  CHECK(dec(t3, sizeof t3, &v) == -1);

  // unknown tag 20
  const uint8_t t4[] = {20};
  CHECK(dec(t4, sizeof t4, &v) == -1);

  // large-int tag 5 is malformed for us
  const uint8_t t5[] = {0x05, 0x02, 'f', 'f'};
  CHECK(dec(t5, sizeof t5, &v) == -1);

  // empty input
  CHECK(dec(t1, 0, &v) == -1);

  // truncated typed list body
  const uint8_t t6[] = {0x09, 0x04, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00};
  CHECK(dec(t6, sizeof t6, &v) == -1);

  // 40 nested lists wrap a null: deeper than 32 -> error
  struct dena_buf b = new_buf();
  for (int i = 0; i < 40; i++) dena_put_list_start(&b, 1);
  dena_put_null(&b);
  CHECK(!b.failed);
  CHECK(dec(enc, b.len, &v) == -1);

  // 32 levels is still accepted
  b = new_buf();
  for (int i = 0; i < 32; i++) dena_put_list_start(&b, 1);
  dena_put_null(&b);
  CHECK(!b.failed);
  CHECK(dec(enc, b.len, &v) == 0 && v.type == DENA_VAL_LIST);

  // arena exhaustion
  b = new_buf();
  dena_put_list_start(&b, 4);
  for (int i = 0; i < 4; i++) dena_put_int(&b, i);
  arena.used = 0;
  arena.cap = 2;
  CHECK(dena_decode(enc, b.len, &arena, &v) == -1);
  arena.cap = sizeof vals / sizeof vals[0];
}

static void encode_overflow(void) {
  uint8_t small[8];
  struct dena_buf b;

  // A string that cannot fit sets failed and stops writing.
  b.data = small;
  b.len = 0;
  b.cap = 4;
  b.failed = false;
  dena_put_string(&b, "hello world");
  CHECK(b.failed);
  CHECK(b.len <= b.cap);

  // Writing at the exact boundary then one more byte.
  b.data = small;
  b.len = 0;
  b.cap = 5;
  b.failed = false;
  dena_put_int(&b, 1); // exactly 5 bytes
  CHECK(!b.failed && b.len == 5u);
  dena_put_null(&b); // no room left
  CHECK(b.failed);

  // Zero capacity always fails.
  b.data = small;
  b.len = 0;
  b.cap = 0;
  b.failed = false;
  dena_put_null(&b);
  CHECK(b.failed);
}

int main(void) {
  arena.vals = vals;
  arena.cap = sizeof vals / sizeof vals[0];
  arena.used = 0;

  exact_bytes();
  double_padding();
  round_trip_scalars();
  round_trip_string_bytes();
  round_trip_containers();
  typed_lists();
  decode_errors();
  encode_overflow();

  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  puts("codec: all passed");
  return 0;
}
