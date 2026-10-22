/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "dena/host.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint64_t dena_fnv1a(uint64_t hash, const void *data, size_t len) {
  const uint8_t *p = (const uint8_t *)data;
  for (size_t i = 0; i < len; i++) {
    hash ^= p[i];
    hash *= 0x100000001b3ULL;
  }
  return hash;
}

static uint32_t expand5(uint32_t c) { return (c << 3) | (c >> 2); }
static uint32_t expand6(uint32_t c) { return (c << 2) | (c >> 4); }

int dena_frame_convert(dena_frame *out, const void *data, unsigned width,
                       unsigned height, size_t pitch, dena_pixel_format fmt) {
  if (fmt != DENA_PIXEL_0RGB1555 && fmt != DENA_PIXEL_XRGB8888 &&
      fmt != DENA_PIXEL_RGB565)
    return -1;
  size_t count = (size_t)width * height;
  if (count != (size_t)out->width * out->height || !out->pixels) {
    uint32_t *px = (uint32_t *)realloc(out->pixels, count * sizeof(uint32_t));
    if (!px && count) return -1;
    out->pixels = px;
  }
  out->width = width;
  out->height = height;
  const uint8_t *src = (const uint8_t *)data;
  for (unsigned y = 0; y < height; y++) {
    const uint8_t *row = src + (size_t)y * pitch;
    uint32_t *dst = out->pixels + (size_t)y * width;
    for (unsigned x = 0; x < width; x++) {
      uint32_t v;
      if (fmt == DENA_PIXEL_XRGB8888) {
        uint32_t s;
        memcpy(&s, row + x * 4, 4);
        v = s & 0x00ffffffu;
      } else {
        uint16_t s;
        memcpy(&s, row + x * 2, 2);
        uint32_t r, g, b;
        if (fmt == DENA_PIXEL_RGB565) {
          r = expand5((s >> 11) & 0x1f);
          g = expand6((s >> 5) & 0x3f);
          b = expand5(s & 0x1f);
        } else {
          r = expand5((s >> 10) & 0x1f);
          g = expand5((s >> 5) & 0x1f);
          b = expand5(s & 0x1f);
        }
        v = (r << 16) | (g << 8) | b;
      }
      dst[x] = v;
    }
  }
  return 0;
}

static void put_le32(uint8_t *b, uint32_t v) {
  b[0] = (uint8_t)v;
  b[1] = (uint8_t)(v >> 8);
  b[2] = (uint8_t)(v >> 16);
  b[3] = (uint8_t)(v >> 24);
}

uint64_t dena_frame_hash(const dena_frame *frame) {
  uint8_t hdr[8];
  put_le32(hdr, frame->width);
  put_le32(hdr + 4, frame->height);
  uint64_t h = dena_fnv1a(DENA_FNV_OFFSET, hdr, sizeof hdr);
  size_t count = (size_t)frame->width * frame->height;
  for (size_t i = 0; i < count; i++) {
    uint8_t px[4];
    put_le32(px, frame->pixels[i]);
    h = dena_fnv1a(h, px, 4);
  }
  return h;
}

int dena_frame_write_ppm(const dena_frame *frame, const char *path) {
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  fprintf(f, "P6\n%u %u\n255\n", frame->width, frame->height);
  size_t count = (size_t)frame->width * frame->height;
  for (size_t i = 0; i < count; i++) {
    uint32_t v = frame->pixels[i];
    uint8_t rgb[3] = {(uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    fwrite(rgb, 1, 3, f);
  }
  return fclose(f) == 0 ? 0 : -1;
}

void dena_frame_free(dena_frame *frame) {
  free(frame->pixels);
  frame->pixels = NULL;
  frame->width = frame->height = 0;
}
