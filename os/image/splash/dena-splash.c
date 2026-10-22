// SPDX-License-Identifier: GPL-3.0-or-later
// dena-splash: the Dena boot, progress and shutdown screens on the Linux
// framebuffer (single-card image, docs/specs/single-card.md). Draws the
// Dena logo (docs/branding/logo.svg, rendered here from its geometry) on the
// Dark Anthracite background, with an optional line of text and a Dena Gold
// progress bar. Static, no libraries: it runs before anything else is up.
//
// Usage:
//   dena-splash [--fb DEV] [--size WxH] logo
//   dena-splash [--fb DEV] [--size WxH] message TEXT...
//   dena-splash [--fb DEV] [--size WxH] progress PERCENT TEXT...
//   dena-splash [--fb DEV] --daemon STATEFILE [--wait SECONDS]
// --fb defaults to /dev/fb0. --size writes raw XRGB8888 to a regular file
// instead (tests and previews). In daemon mode the screen follows STATEFILE
// (one command line as above, or "quit"), redrawn when it changes: callers
// replace the file, so they never block. The daemon waits up to --wait
// seconds (default 30) for the framebuffer to appear (the panel probes late)
// and exits on "quit", leaving the last screen up.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define BG 0x202024u     // Dark Anthracite
#define GOLD 0xF1C40Fu   // Dena Gold
#define INK 0xF5F6F7u    // logo "D"
#define TEXT 0xC9CAD0u
#define TRACK 0x3A3A41u

struct fb {
  int fd;
  int w, h, bpp, line;  // bytes per line
  long offset;          // byte offset of the visible page
  struct fb_bitfield r, g, b;
};

static uint32_t *canvas;  // XRGB8888, w*h

static void fill(int x0, int y0, int x1, int y1, uint32_t c, int w, int h) {
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > w) x1 = w;
  if (y1 > h) y1 = h;
  for (int y = y0; y < y1; y++)
    for (int x = x0; x < x1; x++) canvas[y * w + x] = c;
}

static uint32_t mix(uint32_t a, uint32_t b, float t) {
  if (t <= 0) return a;
  if (t >= 1) return b;
  uint32_t out = 0;
  for (int s = 0; s < 24; s += 8) {
    float ca = (a >> s) & 255, cb = (b >> s) & 255;
    out |= (uint32_t)(ca + (cb - ca) * t + 0.5f) << s;
  }
  return out;
}

static float clampf(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

static float seg_dist(float px, float py, float ax, float ay, float bx, float by) {
  float dx = bx - ax, dy = by - ay;
  float t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  return hypotf(px - ax - t * dx, py - ay - t * dy);
}

// The logo in its own 108-unit coordinates (logo.svg, foreground group):
// a stroked "D" (two bars, a spine and a half circle) and a gold dot.
static void draw_logo(int w, int h, float cx, float cy, float unit) {
  const float sx = 0.86f, half = 3.5f;  // group scale, stroke-width / 2
  float px_local = 1.0f / (unit * sx);   // one screen pixel in local units
  int r = (int)(60 * unit);
  for (int y = (int)cy - r; y < (int)cy + r; y++) {
    if (y < 0 || y >= h) continue;
    for (int x = (int)cx - r; x < (int)cx + r; x++) {
      if (x < 0 || x >= w) continue;
      // screen -> canvas (54,54 at the centre) -> group-local
      float u = (x + 0.5f - cx) / unit + 54, v = (y + 0.5f - cy) / unit + 54;
      float lx = (u - 54.75f) / sx + 54, ly = (v - 54) / sx + 54;
      float d = seg_dist(lx, ly, 33.5f, 39.5f, 46.5f, 39.5f);
      float d2 = seg_dist(lx, ly, 33.5f, 39.5f, 33.5f, 68.5f);
      float d3 = seg_dist(lx, ly, 33.5f, 68.5f, 46.5f, 68.5f);
      if (d2 < d) d = d2;
      if (d3 < d) d = d3;
      if (lx >= 46.5f) {
        float a = fabsf(hypotf(lx - 46.5f, ly - 54) - 14.5f);
        if (a < d) d = a;
      }
      uint32_t *p = &canvas[y * w + x];
      float cov = clampf((half - d) / px_local + 0.5f);
      if (cov > 0) *p = mix(*p, INK, cov);
      float dot = hypotf(lx - 72, ly - 67.5f) - 4.5f;
      cov = clampf(-dot / px_local + 0.5f);
      if (cov > 0) *p = mix(*p, GOLD, cov);
    }
  }
}

// 5x7 capitals, digits and a little punctuation, drawn for this tool.
static const struct { char c; const char *rows[7]; } FONT[] = {
  {'A', {".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"}},
  {'B', {"####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."}},
  {'C', {".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."}},
  {'D', {"####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."}},
  {'E', {"#####", "#....", "#....", "####.", "#....", "#....", "#####"}},
  {'F', {"#####", "#....", "#....", "####.", "#....", "#....", "#...."}},
  {'G', {".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"}},
  {'H', {"#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"}},
  {'I', {".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."}},
  {'J', {"..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."}},
  {'K', {"#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"}},
  {'L', {"#....", "#....", "#....", "#....", "#....", "#....", "#####"}},
  {'M', {"#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"}},
  {'N', {"#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"}},
  {'O', {".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."}},
  {'P', {"####.", "#...#", "#...#", "####.", "#....", "#....", "#...."}},
  {'Q', {".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"}},
  {'R', {"####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"}},
  {'S', {".####", "#....", "#....", ".###.", "....#", "....#", "####."}},
  {'T', {"#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."}},
  {'U', {"#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."}},
  {'V', {"#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."}},
  {'W', {"#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."}},
  {'X', {"#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"}},
  {'Y', {"#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."}},
  {'Z', {"#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"}},
  {'0', {".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."}},
  {'1', {"..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."}},
  {'2', {".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"}},
  {'3', {"####.", "....#", "....#", ".###.", "....#", "....#", "####."}},
  {'4', {"...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."}},
  {'5', {"#####", "#....", "####.", "....#", "....#", "#...#", ".###."}},
  {'6', {".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."}},
  {'7', {"#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."}},
  {'8', {".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."}},
  {'9', {".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."}},
  {'.', {".....", ".....", ".....", ".....", ".....", ".##..", ".##.."}},
  {',', {".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."}},
  {'%', {"##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"}},
  {'-', {".....", ".....", ".....", ".###.", ".....", ".....", "....."}},
  {':', {".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."}},
  {'/', {"....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."}},
};

static const char *const *glyph(char c) {
  if (c >= 'a' && c <= 'z') c -= 32;
  for (size_t i = 0; i < sizeof FONT / sizeof FONT[0]; i++)
    if (FONT[i].c == c) return FONT[i].rows;
  return NULL;  // space and anything unknown: blank
}

static void draw_text(const char *s, int w, int h, int cy, int k) {
  int n = (int)strlen(s);
  int x = (w - (n * 6 - 1) * k) / 2;
  int y = cy - 7 * k / 2;
  for (; *s; s++, x += 6 * k) {
    const char *const *g = glyph(*s);
    if (!g) continue;
    for (int r = 0; r < 7; r++)
      for (int c = 0; c < 5; c++)
        if (g[r][c] == '#') fill(x + c * k, y + r * k, x + (c + 1) * k, y + (r + 1) * k, TEXT, w, h);
  }
}

// cmd: "logo" | "message TEXT" | "progress PCT TEXT". Returns -1 if unknown.
static int render(const char *cmd, int w, int h) {
  int pct = -1;
  const char *text = "";
  if (strncmp(cmd, "message", 7) == 0 && (cmd[7] == ' ' || !cmd[7])) {
    text = cmd[7] ? cmd + 8 : "";
  } else if (strncmp(cmd, "progress", 8) == 0 && (cmd[8] == ' ' || !cmd[8])) {
    char *end;
    pct = (int)strtol(cmd + 8, &end, 10);
    pct = pct < 0 ? 0 : pct > 100 ? 100 : pct;
    while (*end == ' ') end++;
    text = end;
  } else if (strcmp(cmd, "logo") != 0) {
    return -1;
  }
  int m = w < h ? w : h;
  fill(0, 0, w, h, BG, w, h);
  int busy = *text || pct >= 0;
  draw_logo(w, h, w / 2.0f, h / 2.0f - (busy ? h * 0.08f : 0), m / 108.0f * 0.7f);
  int k = m / 160 > 1 ? m / 160 : 1;
  if (*text) draw_text(text, w, h, (int)(h * 0.70f), k);
  if (pct >= 0) {
    int bw = w / 2, bh = m / 80 > 3 ? m / 80 : 3;
    int x0 = (w - bw) / 2, y0 = (int)(h * 0.80f);
    fill(x0, y0, x0 + bw, y0 + bh, TRACK, w, h);
    fill(x0, y0, x0 + bw * pct / 100, y0 + bh, GOLD, w, h);
  }
  return 0;
}

static int fb_open(const char *path, const char *size, struct fb *f) {
  memset(f, 0, sizeof *f);
  f->fd = open(path, size ? O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC : O_RDWR | O_CLOEXEC, 0644);
  if (f->fd < 0) return -1;
  if (size) {  // raw XRGB8888 file
    if (sscanf(size, "%dx%d", &f->w, &f->h) != 2 || f->w <= 0 || f->h <= 0) return -1;
    f->bpp = 32;
    f->line = f->w * 4;
    f->r = (struct fb_bitfield){16, 8, 0};
    f->g = (struct fb_bitfield){8, 8, 0};
    f->b = (struct fb_bitfield){0, 8, 0};
    return 0;
  }
  struct fb_var_screeninfo var;
  struct fb_fix_screeninfo fix;
  if (ioctl(f->fd, FBIOGET_VSCREENINFO, &var) < 0 || ioctl(f->fd, FBIOGET_FSCREENINFO, &fix) < 0) {
    close(f->fd);
    return -1;
  }
  f->w = (int)var.xres;
  f->h = (int)var.yres;
  f->bpp = (int)var.bits_per_pixel;
  f->line = (int)fix.line_length;
  f->offset = (long)var.yoffset * fix.line_length + (long)var.xoffset * (var.bits_per_pixel / 8);
  f->r = var.red;
  f->g = var.green;
  f->b = var.blue;
  if (f->bpp != 16 && f->bpp != 24 && f->bpp != 32) {
    close(f->fd);
    return -1;
  }
  ioctl(f->fd, FBIOBLANK, FB_BLANK_UNBLANK);
  return 0;
}

static uint32_t pack(const struct fb *f, uint32_t c) {
  uint32_t r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
  return ((r >> (8 - f->r.length)) << f->r.offset) | ((g >> (8 - f->g.length)) << f->g.offset) |
         ((b >> (8 - f->b.length)) << f->b.offset);
}

static int present(const struct fb *f) {
  int bytes = f->bpp / 8;
  uint8_t *row = malloc((size_t)f->line);
  if (!row) return -1;
  int rc = 0;
  for (int y = 0; y < f->h && rc == 0; y++) {
    memset(row, 0, (size_t)f->line);
    for (int x = 0; x < f->w; x++) {
      uint32_t v = pack(f, canvas[y * f->w + x]);
      memcpy(row + x * bytes, &v, (size_t)bytes);  // little endian
    }
    if (pwrite(f->fd, row, (size_t)f->line, f->offset + (long)y * f->line) != f->line) rc = -1;
  }
  free(row);
  return rc;
}

static int show(const struct fb *f, const char *cmd) {
  if (render(cmd, f->w, f->h) < 0) {
    fprintf(stderr, "dena-splash: unknown screen \"%s\"\n", cmd);
    return 2;
  }
  return present(f) == 0 ? 0 : 1;
}

static size_t read_state(const char *path, char *buf, size_t cap) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  ssize_t n = read(fd, buf, cap - 1);
  close(fd);
  if (n < 0) n = 0;
  buf[n] = '\0';
  buf[strcspn(buf, "\r\n")] = '\0';
  return strlen(buf);
}

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int daemon_loop(const char *dev, const char *state, double wait_s) {
  struct fb f = {.fd = -1};
  char want[256], drawn[256] = "";
  double give_up = now_s() + wait_s;
  const struct timespec tick = {0, 50 * 1000 * 1000};
  for (;;) {
    if (!read_state(state, want, sizeof want)) strcpy(want, "logo");
    if (strcmp(want, "quit") == 0) break;
    if (f.fd < 0) {
      if (fb_open(dev, NULL, &f) < 0) {
        f.fd = -1;
        if (now_s() > give_up) {
          fprintf(stderr, "dena-splash: no framebuffer after %.0f s\n", wait_s);
          return 0;
        }
        nanosleep(&tick, NULL);
        continue;
      }
      canvas = calloc((size_t)f.w * f.h, sizeof *canvas);
      if (!canvas) return 1;
    }
    if (strcmp(want, drawn) != 0) {
      show(&f, want);  // an unknown command leaves the screen as it was
      strcpy(drawn, want);
    }
    nanosleep(&tick, NULL);
  }
  if (f.fd >= 0) close(f.fd);
  return 0;
}

int main(int argc, char **argv) {
  const char *dev = "/dev/fb0", *size = NULL, *state = NULL;
  double wait_s = 30;
  int i = 1;
  for (; i < argc; i++) {
    if (strcmp(argv[i], "--fb") == 0 && i + 1 < argc) dev = argv[++i];
    else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) size = argv[++i];
    else if (strcmp(argv[i], "--daemon") == 0 && i + 1 < argc) state = argv[++i];
    else if (strcmp(argv[i], "--wait") == 0 && i + 1 < argc) wait_s = atof(argv[++i]);
    else break;
  }
  if (state) return daemon_loop(dev, state, wait_s);
  if (i >= argc) {
    fprintf(stderr, "usage: dena-splash [--fb DEV] [--size WxH] logo|message TEXT|progress PCT TEXT\n"
                    "       dena-splash [--fb DEV] --daemon STATEFILE [--wait SECONDS]\n");
    return 2;
  }
  char cmd[256] = "";
  for (; i < argc; i++) {
    if (cmd[0]) strncat(cmd, " ", sizeof cmd - strlen(cmd) - 1);
    strncat(cmd, argv[i], sizeof cmd - strlen(cmd) - 1);
  }
  struct fb f;
  if (fb_open(dev, size, &f) < 0) {
    fprintf(stderr, "dena-splash: %s: %s\n", dev, errno ? strerror(errno) : "unsupported");
    return 1;
  }
  canvas = calloc((size_t)f.w * f.h, sizeof *canvas);
  if (!canvas) return 1;
  int rc = show(&f, cmd);
  close(f.fd);
  return rc;
}
