// SPDX-License-Identifier: GPL-3.0-or-later
// dena-keytest: prints every key and hat event from the device's input nodes
// with the action the matching profile gives it, so a profile can be checked
// (or written) on a new handheld. Linux only. Spec: docs/specs/platform-modules.md
//
// Usage: dena-keytest [profile.conf]   (Ctrl+C or the power key to quit)
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "dena/platform.h"

#define MAX_NODES 16

static size_t read_file(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  size_t n = fread(buf, 1, cap - 1, f);
  fclose(f);
  buf[n] = '\0';
  return n;
}

static const char *action_name(int a) {
  static const char *const pad[16] = {"b", "y", "select", "start", "up",
                                      "down", "left", "right", "a", "x", "l",
                                      "r", "l2", "r2", "l3", "r3"};
  if (a >= 0 && a < 16) return pad[a];
  switch (a) {
    case DENA_KEY_MENU: return "menu";
    case DENA_KEY_POWER: return "power";
    case DENA_KEY_VOLUME_UP: return "volume_up";
    case DENA_KEY_VOLUME_DOWN: return "volume_down";
    default: return "(unmapped)";
  }
}

int main(int argc, char **argv) {
  static struct dena_profile builtin[8], custom;
  const struct dena_profile *profile = NULL;
  static char text[16384];
  if (argc > 1) {
    if (!read_file(argv[1], text, sizeof text)) {
      fprintf(stderr, "cannot read %s\n", argv[1]);
      return 2;
    }
    int line = dena_profile_parse(text, &custom);
    if (line) {
      fprintf(stderr, "%s:%d: bad profile line\n", argv[1], line);
      return 2;
    }
    profile = &custom;
  } else {
    int n = dena_builtin_profiles(builtin, 8);
    size_t len = read_file("/proc/device-tree/compatible", text, sizeof text);
    profile = dena_profile_pick(builtin, n, text, len);
  }
  printf("profile: %s\n", profile ? profile->id : "(none matched)");

  struct pollfd fds[MAX_NODES];
  int count = 0;
  DIR *dir = opendir("/dev/input");
  if (!dir) {
    perror("/dev/input");
    return 1;
  }
  struct dirent *e;
  while ((e = readdir(dir)) && count < MAX_NODES) {
    if (strncmp(e->d_name, "event", 5) != 0) continue;
    char path[300];
    snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) continue;
    char name[128] = "?";
    ioctl(fd, EVIOCGNAME(sizeof name), name);
    printf("listening: %s (%s)\n", path, name);
    fds[count++] = (struct pollfd){.fd = fd, .events = POLLIN};
  }
  closedir(dir);

  for (;;) {
    if (poll(fds, count, -1) < 0) break;
    for (int i = 0; i < count; i++) {
      struct input_event ev;
      while (read(fds[i].fd, &ev, sizeof ev) == sizeof ev) {
        int code = -1;
        if (ev.type == EV_SW) {  // lid, headphone jack: dena-powerd handles the lid
          printf("switch %d %s%s\n", ev.code, ev.value ? "on" : "off",
                 ev.code == SW_LID ? " (lid: sleeps when closed)" : "");
          fflush(stdout);
          continue;
        }
        if (ev.type == EV_SYN && ev.code == SYN_DROPPED) {
          printf("events dropped (the launcher re-reads the key state)\n");
          continue;
        }
        if (ev.type == EV_KEY && ev.value != 2) {
          code = ev.code;
        } else if (ev.type == EV_ABS && ev.code >= ABS_HAT0X &&
                   ev.code <= ABS_HAT3Y && ev.value != 0) {
          code = 0x10000 + ev.code * 2 + (ev.value > 0);
        }
        if (code < 0) continue;
        int action = profile ? dena_profile_action(profile, code) : DENA_KEY_NONE;
        if (ev.type == EV_KEY) {
          printf("key.%d %s -> %s\n", code, ev.value ? "down" : "up",
                 action_name(action));
        } else {
          printf("abs.%d%c -> %s\n", ev.code, ev.value > 0 ? '+' : '-',
                 action_name(action));
        }
        fflush(stdout);
        if (action == DENA_KEY_POWER && ev.value == 0) return 0;
      }
    }
  }
  return 0;
}
