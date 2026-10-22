// SPDX-License-Identifier: GPL-3.0-or-later
// Device profiles: parsing, matching, key lookup, sysfs value parsing.
// Spec: docs/specs/platform-modules.md
#include "dena/platform.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *const retropad_names[16] = {
    "b", "y", "select", "start", "up", "down", "left", "right",
    "a", "x", "l", "r", "l2", "r2", "l3", "r3",
};

int dena_action_from_name(const char *name) {
  for (int i = 0; i < 16; i++) {
    if (strcmp(name, retropad_names[i]) == 0) return i;
  }
  if (strcmp(name, "menu") == 0) return DENA_KEY_MENU;
  if (strcmp(name, "power") == 0) return DENA_KEY_POWER;
  if (strcmp(name, "volume_up") == 0) return DENA_KEY_VOLUME_UP;
  if (strcmp(name, "volume_down") == 0) return DENA_KEY_VOLUME_DOWN;
  return DENA_KEY_NONE;
}

static char *trim(char *s) {
  while (isspace((unsigned char)*s)) s++;
  char *e = s + strlen(s);
  while (e > s && isspace((unsigned char)e[-1])) *--e = '\0';
  return s;
}

static void copy(char *dst, size_t cap, const char *src) {
  snprintf(dst, cap, "%s", src);
}

// "key.304" → 304; "abs.16-" / "abs.16+" → hat code 0x10000 + axis*2 + dir.
static int parse_code(const char *key) {
  char *end;
  if (strncmp(key, "key.", 4) == 0) {
    long v = strtol(key + 4, &end, 10);
    return (*end == '\0' && v > 0 && v < 0x10000) ? (int)v : -1;
  }
  if (strncmp(key, "abs.", 4) == 0) {
    long axis = strtol(key + 4, &end, 10);
    if (axis < 0 || axis > 0x3f || (end[0] != '-' && end[0] != '+') || end[1])
      return -1;
    return 0x10000 + (int)axis * 2 + (end[0] == '+');
  }
  return -1;
}

int dena_profile_parse(const char *text, struct dena_profile *out) {
  memset(out, 0, sizeof *out);
  copy(out->audio_card, sizeof out->audio_card, "default");
  int lineno = 0;
  const char *p = text;
  while (*p) {
    lineno++;
    const char *nl = strchr(p, '\n');
    size_t len = nl ? (size_t)(nl - p) : strlen(p);
    char line[256];
    if (len >= sizeof line) return lineno;
    memcpy(line, p, len);
    line[len] = '\0';
    p = nl ? nl + 1 : p + len;

    char *s = trim(line);
    if (*s == '\0' || *s == '#') continue;
    char *eq = strchr(s, '=');
    if (!eq) return lineno;
    *eq = '\0';
    char *key = trim(s), *val = trim(eq + 1);

    if (strcmp(key, "id") == 0) {
      copy(out->id, sizeof out->id, val);
    } else if (strcmp(key, "name") == 0) {
      copy(out->name, sizeof out->name, val);
    } else if (strcmp(key, "match") == 0) {
      if (out->match_count == DENA_MAX_MATCH) return lineno;
      copy(out->match[out->match_count++], sizeof out->match[0], val);
    } else if (strcmp(key, "display") == 0) {
      if (strcmp(val, "auto") == 0) {
        out->width = out->height = out->refresh = 0;
      } else if (sscanf(val, "%dx%d@%d", &out->width, &out->height,
                        &out->refresh) != 3) {
        return lineno;
      }
    } else if (strcmp(key, "rotate") == 0) {
      out->rotate = atoi(val);
      if (out->rotate != 0 && out->rotate != 90 && out->rotate != 180 &&
          out->rotate != 270)
        return lineno;
    } else if (strcmp(key, "backlight") == 0) {
      copy(out->backlight, sizeof out->backlight, val);
    } else if (strcmp(key, "backlight_max") == 0) {
      out->backlight_max = atoi(val);
    } else if (strcmp(key, "backlight_min") == 0) {
      out->backlight_min = atoi(val);
    } else if (strcmp(key, "battery") == 0) {
      copy(out->battery, sizeof out->battery, val);
    } else if (strcmp(key, "audio") == 0) {
      copy(out->audio_card, sizeof out->audio_card, val);
    } else if (strcmp(key, "audio_driver") == 0) {
      copy(out->audio_driver, sizeof out->audio_driver, val);
    } else if (strcmp(key, "volume") == 0) {
      copy(out->volume_control, sizeof out->volume_control, val);
    } else if (strcmp(key, "mixer") == 0) {
      // mixer = <control name> = <value>: the name may not hold '='.
      char *eq2 = strrchr(val, '=');
      if (!eq2 || out->mixer_count == DENA_MAX_MIXER) return lineno;
      *eq2 = '\0';
      char *name = trim(val), *v = trim(eq2 + 1);
      struct dena_mixer_setting *m = &out->mixer[out->mixer_count];
      if (!*name || !*v || strlen(name) >= sizeof m->control || strlen(v) >= sizeof m->value)
        return lineno;
      copy(m->control, sizeof m->control, name);
      copy(m->value, sizeof m->value, v);
      out->mixer_count++;
    } else if (strcmp(key, "verified") == 0) {
      out->verified = strcmp(val, "yes") == 0;
    } else if (strncmp(key, "key.", 4) == 0 || strncmp(key, "abs.", 4) == 0) {
      int code = parse_code(key), action = dena_action_from_name(val);
      if (code < 0 || action == DENA_KEY_NONE) return lineno;
      if (out->key_count == DENA_MAX_KEYS) return lineno;
      out->keys[out->key_count++] = (struct dena_key_map){code, action};
    }
    // Other keys: ignored, so newer profiles still load.
  }
  return out->id[0] ? 0 : lineno + 1;
}

int dena_profile_action(const struct dena_profile *p, int code) {
  for (int i = 0; i < p->key_count; i++) {
    if (p->keys[i].code == code) return p->keys[i].action;
  }
  return DENA_KEY_NONE;
}

static bool contains(const char *hay, size_t len, const char *needle) {
  size_t n = strlen(needle);
  if (n == 0 || n > len) return false;
  for (size_t i = 0; i + n <= len; i++) {
    if (memcmp(hay + i, needle, n) == 0) return true;
  }
  return false;
}

bool dena_profile_matches(const struct dena_profile *p, const char *compat,
                          size_t len) {
  for (int i = 0; i < p->match_count; i++) {
    if (contains(compat, len, p->match[i])) return true;
  }
  return false;
}

const struct dena_profile *dena_profile_pick(const struct dena_profile *list,
                                             int count, const char *compat,
                                             size_t len) {
  for (int i = 0; i < count; i++) {
    if (dena_profile_matches(&list[i], compat, len)) return &list[i];
  }
  return NULL;
}

int dena_parse_percent(const char *text) {
  if (!text) return -1;
  char *end;
  long v = strtol(text, &end, 10);
  if (end == text) return -1;
  while (isspace((unsigned char)*end)) end++;
  if (*end) return -1;
  return v < 0 ? 0 : v > 100 ? 100 : (int)v;
}

bool dena_parse_charging(const char *text) {
  if (!text) return false;
  while (isspace((unsigned char)*text)) text++;
  return strncmp(text, "Charging", 8) == 0 || strncmp(text, "Full", 4) == 0;
}

int dena_backlight_raw(const struct dena_profile *p, int percent) {
  if (percent <= 0) return 0;
  if (percent > 100) percent = 100;
  int lo = p->backlight_min > 0 ? p->backlight_min : 1;
  int hi = p->backlight_max > lo ? p->backlight_max : lo;
  if (p->backlight_perceptual) return lo + ((hi - lo) * (percent - 1) + 49) / 99;
  // Perceptual curve: equal steps look equal (roughly squared luminance).
  double t = percent / 100.0;
  return lo + (int)((hi - lo) * t * t + 0.5);
}

void dena_backlight_adopt(struct dena_profile *p, const char *max_text,
                          const char *scale_text) {
  char *end;
  long max = max_text ? strtol(max_text, &end, 10) : 0;
  if (max_text && end != max_text && max > 0 && max <= 1 << 20) {
    if (p->backlight_max > 0 && p->backlight_min > 0) {
      long lo = ((long)p->backlight_min * max + p->backlight_max / 2) / p->backlight_max;
      p->backlight_min = lo > 0 ? (int)lo : 1;
    }
    p->backlight_max = (int)max;
  }
  if (scale_text && strncmp(scale_text, "non-linear", 10) == 0) {
    p->backlight_perceptual = true;
    p->backlight_min = 1;
  }
}

int dena_volume_next(int level, int dir) {
  int v = level + (dir > 0 ? 1 : -1);
  return v < 0 ? 0 : v > DENA_VOLUME_STEPS ? DENA_VOLUME_STEPS : v;
}

long dena_volume_db100(int level) {
  if (level >= DENA_VOLUME_STEPS) return 0;
  if (level < 0) level = 0;
  return DENA_VOLUME_FLOOR_DB100 -
         (long)DENA_VOLUME_FLOOR_DB100 * level / DENA_VOLUME_STEPS;
}

long dena_volume_raw(int level, long min, long max) {
  if (level <= 0 || max <= min) return min;
  if (level >= DENA_VOLUME_STEPS) return max;
  return min + ((max - min) * level + DENA_VOLUME_STEPS / 2) / DENA_VOLUME_STEPS;
}

int dena_volume_parse(const char *text) {
  if (!text) return DENA_VOLUME_DEFAULT;
  char *end;
  long v = strtol(text, &end, 10);
  if (end == text) return DENA_VOLUME_DEFAULT;
  while (isspace((unsigned char)*end)) end++;
  if (*end || v < 0 || v > DENA_VOLUME_STEPS) return DENA_VOLUME_DEFAULT;
  return (int)v;
}

bool dena_mixer_int(const char *value, long min, long max, long *out) {
  if (strcmp(value, "on") == 0) {
    *out = max;
    return true;
  }
  if (strcmp(value, "off") == 0) {
    *out = min;
    return true;
  }
  char *end;
  long v = strtol(value, &end, 10);
  if (end == value) return false;
  if (*end == '%' && end[1] == '\0') {
    if (v < 0) v = 0;
    if (v > 100) v = 100;
    *out = min + ((max - min) * v + 50) / 100;
    return true;
  }
  if (*end) return false;
  *out = v < min ? min : v > max ? max : v;
  return true;
}

int dena_audio_periods(int latency_ms, int period_frames, int rate) {
  if (period_frames <= 0 || rate <= 0) return 4;
  // Half the latency, rounded to whole periods.
  long half_frames = (long)rate * latency_ms / 2000;
  int n = (int)((half_frames + period_frames / 2) / period_frames);
  return n < 3 ? 3 : n > 8 ? 8 : n;
}

static bool same_ci(const char *a, const char *b) {
  for (; *a && *b; a++, b++)
    if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return false;
  return *a == *b;
}

int dena_pick_mixer(const char *const *names, int count) {
  static const char *const preferred[] = {"Master", "PCM", "Speaker", "Headphone", "DAC",
                                          "Playback"};
  for (size_t p = 0; p < sizeof preferred / sizeof *preferred; p++)
    for (int i = 0; i < count; i++)
      if (names[i] && same_ci(names[i], preferred[p])) return i;
  return count > 0 ? 0 : -1;
}
