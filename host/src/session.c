/* Session persistence helpers: battery saves and save-state files.
 * Spec: docs/specs/game-session.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dena/host.h"
#include "dena/session.h"

#ifdef _WIN32
#include <io.h>
#define REPLACE(from, to) (remove(to), rename(from, to))
#else
#define REPLACE(from, to) rename(from, to)
#endif

/* Writes via a temporary file and a rename, so a crash never leaves a
 * half-written save. */
static int write_atomic(const char *path, const void *data, size_t size) {
  size_t n = strlen(path);
  char *tmp = (char *)malloc(n + 5);
  if (!tmp) return -1;
  memcpy(tmp, path, n);
  memcpy(tmp + n, ".tmp", 5);
  FILE *f = fopen(tmp, "wb");
  int ok = f && fwrite(data, 1, size, f) == size;
  if (f && fclose(f) != 0) ok = 0;
  if (ok) ok = REPLACE(tmp, path) == 0;
  if (!ok) remove(tmp);
  free(tmp);
  return ok ? 0 : -1;
}

static void *read_all(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  void *buf = len > 0 ? malloc((size_t)len) : NULL;
  if (buf && fread(buf, 1, (size_t)len, f) != (size_t)len) {
    free(buf);
    buf = NULL;
  }
  fclose(f);
  *size = buf ? (size_t)len : 0;
  return buf;
}

int dena_battery_save(dena_core *core, const char *path) {
  size_t size;
  void *ram = dena_core_memory(core, DENA_MEMORY_SAVE_RAM, &size);
  if (!ram) return DENA_NO_DATA;
  return write_atomic(path, ram, size);
}

int dena_battery_load(dena_core *core, const char *path) {
  size_t size, file_size;
  void *ram = dena_core_memory(core, DENA_MEMORY_SAVE_RAM, &size);
  if (!ram) return DENA_NO_DATA;
  void *data = read_all(path, &file_size);
  if (!data) return DENA_NO_DATA;
  /* Shorter files load into the start; longer ones are truncated, as other
   * frontends do, so saves move between core versions. */
  memcpy(ram, data, file_size < size ? file_size : size);
  free(data);
  return 0;
}

uint64_t dena_battery_hash(dena_core *core) {
  size_t size;
  void *ram = dena_core_memory(core, DENA_MEMORY_SAVE_RAM, &size);
  return ram ? dena_fnv1a(DENA_FNV_OFFSET, ram, size) : 0;
}

int dena_state_save_file(dena_core *core, const char *path) {
  size_t size = dena_core_state_size(core);
  if (!size) return DENA_NO_DATA;
  void *buf = malloc(size);
  if (!buf) return -1;
  int rc = dena_core_save_state(core, buf, size);
  if (rc == 0) rc = write_atomic(path, buf, size);
  free(buf);
  return rc;
}

int dena_state_load_file(dena_core *core, const char *path) {
  size_t size;
  void *buf = read_all(path, &size);
  if (!buf) return DENA_NO_DATA;
  int rc = dena_core_load_state(core, buf, size);
  free(buf);
  return rc;
}

/* ---- PNG thumbnails (docs/specs/save-states.md) ---- */

static uint32_t png_crc(const uint8_t *p, size_t n) {
  static uint32_t table[256];
  if (!table[1]) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t c = i;
      for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
      table[i] = c;
    }
  }
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) c = table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
  return c ^ 0xFFFFFFFFu;
}

static uint8_t *put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
  return p + 4;
}

/* Appends a chunk: length, type, data, CRC over type and data. */
static uint8_t *put_chunk(uint8_t *p, const char *type, const uint8_t *data, size_t n) {
  p = put32(p, (uint32_t)n);
  uint8_t *start = p;
  memcpy(p, type, 4);
  if (n) memcpy(p + 4, data, n);
  p += 4 + n;
  return put32(p, png_crc(start, n + 4));
}

int dena_frame_write_png(const dena_frame *frame, const char *path) {
  static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
  if (!frame || !frame->pixels || !frame->width || !frame->height) return -1;
  size_t row = 1 + (size_t)frame->width * 3; /* filter byte + RGB */
  size_t raw_len = row * frame->height;
  size_t blocks = (raw_len + 65534) / 65535;
  size_t idat_len = 2 + raw_len + blocks * 5 + 4; /* zlib header, stored blocks, Adler-32 */
  size_t total = 8 + (12 + 13) + (12 + idat_len) + 12;
  uint8_t *png = (uint8_t *)malloc(total);
  uint8_t *idat = (uint8_t *)malloc(idat_len);
  uint8_t *raw = (uint8_t *)malloc(raw_len);
  int rc = -1;
  if (!png || !idat || !raw) goto out;

  for (unsigned y = 0; y < frame->height; y++) {
    uint8_t *r = raw + row * y;
    *r++ = 0; /* filter: none */
    const uint32_t *src = frame->pixels + (size_t)y * frame->width;
    for (unsigned x = 0; x < frame->width; x++) {
      *r++ = (uint8_t)(src[x] >> 16);
      *r++ = (uint8_t)(src[x] >> 8);
      *r++ = (uint8_t)src[x];
    }
  }

  uint8_t *q = idat;
  *q++ = 0x78; /* zlib header: deflate, 32 KiB window; 0x7801 % 31 == 0 */
  *q++ = 0x01;
  uint32_t a = 1, b = 0;
  for (size_t off = 0; off < raw_len;) {
    size_t n = raw_len - off > 65535 ? 65535 : raw_len - off;
    *q++ = off + n == raw_len ? 1 : 0; /* BFINAL; BTYPE 00 = stored */
    *q++ = (uint8_t)n;
    *q++ = (uint8_t)(n >> 8);
    *q++ = (uint8_t)~n;
    *q++ = (uint8_t)(~n >> 8);
    memcpy(q, raw + off, n);
    for (size_t i = 0; i < n; i++) {
      a = (a + raw[off + i]) % 65521;
      b = (b + a) % 65521;
    }
    q += n;
    off += n;
  }
  put32(q, (b << 16) | a);

  uint8_t ihdr[13];
  put32(ihdr, frame->width);
  put32(ihdr + 4, frame->height);
  ihdr[8] = 8;  /* bit depth */
  ihdr[9] = 2;  /* colour type: RGB */
  ihdr[10] = 0; /* compression: deflate */
  ihdr[11] = 0; /* filter method */
  ihdr[12] = 0; /* no interlace */

  uint8_t *p = png;
  memcpy(p, signature, sizeof signature);
  p += sizeof signature;
  p = put_chunk(p, "IHDR", ihdr, sizeof ihdr);
  p = put_chunk(p, "IDAT", idat, idat_len);
  p = put_chunk(p, "IEND", NULL, 0);
  rc = write_atomic(path, png, (size_t)(p - png));
out:
  free(png);
  free(idat);
  free(raw);
  return rc;
}
