/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "dena/host.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int parse_line(const char *s, const char *end, dena_replay_event *ev) {
  char buf[128];
  size_t n = (size_t)(end - s);
  if (n >= sizeof buf) return -1;
  memcpy(buf, s, n);
  buf[n] = '\0';
  unsigned long frame, port, mask;
  char *p = buf, *q;
  frame = strtoul(p, &q, 10);
  if (q == p || !isspace((unsigned char)*q)) return -1;
  p = q;
  port = strtoul(p, &q, 10);
  if (q == p || !isspace((unsigned char)*q)) return -1;
  p = q;
  while (isspace((unsigned char)*p)) p++;
  if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
  if (!isxdigit((unsigned char)*p)) return -1;
  mask = strtoul(p, &q, 16);
  while (isspace((unsigned char)*q)) q++;
  if (*q != '\0') return -1;
  if (port >= DENA_MAX_PORTS || mask > 0xffff || frame > 0xffffffffUL) return -1;
  ev->frame = (unsigned)frame;
  ev->port = (unsigned)port;
  ev->buttons = (uint16_t)mask;
  return 0;
}

int dena_replay_parse(dena_replay *out, const char *text, unsigned *err_line) {
  memset(out, 0, sizeof *out);
  size_t cap = 0;
  unsigned line = 0;
  const char *s = text;
  while (*s) {
    line++;
    const char *nl = strchr(s, '\n');
    const char *end = nl ? nl : s + strlen(s);
    const char *a = s, *b = end;
    while (a < b && isspace((unsigned char)*a)) a++;
    while (b > a && isspace((unsigned char)b[-1])) b--;
    if (a < b && *a != '#') {
      dena_replay_event ev;
      if (parse_line(a, b, &ev) != 0 ||
          (out->count && ev.frame < out->events[out->count - 1].frame)) {
        if (err_line) *err_line = line;
        dena_replay_free(out);
        return -1;
      }
      if (out->count == cap) {
        cap = cap ? cap * 2 : 16;
        dena_replay_event *e = (dena_replay_event *)realloc(
            out->events, cap * sizeof *e);
        if (!e) {
          if (err_line) *err_line = line;
          dena_replay_free(out);
          return -1;
        }
        out->events = e;
      }
      out->events[out->count++] = ev;
    }
    s = nl ? nl + 1 : end;
  }
  return 0;
}

int dena_replay_load(dena_replay *out, const char *path, unsigned *err_line) {
  if (err_line) *err_line = 0;
  FILE *f = fopen(path, "rb");
  if (!f) return -1;
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *text = (char *)malloc((size_t)len + 1);
  if (!text || fread(text, 1, (size_t)len, f) != (size_t)len) {
    free(text);
    fclose(f);
    return -1;
  }
  fclose(f);
  text[len] = '\0';
  int rc = dena_replay_parse(out, text, err_line);
  free(text);
  return rc;
}

void dena_replay_apply(dena_replay *replay, unsigned frame, uint16_t *buttons) {
  while (replay->next < replay->count &&
         replay->events[replay->next].frame <= frame) {
    const dena_replay_event *ev = &replay->events[replay->next++];
    buttons[ev->port] = ev->buttons;
  }
}

void dena_replay_free(dena_replay *replay) {
  free(replay->events);
  memset(replay, 0, sizeof *replay);
}
