// SPDX-License-Identifier: GPL-3.0-or-later
// dena-powerd: carries out the power policy (power.c) on a Linux handheld.
// Reads the power key from evdev, polls the battery, drives the backlight,
// suspends and powers off, and talks to the launcher over a Unix socket.
// Linux only. Spec: docs/specs/power-daemon.md
//
// Usage: dena-powerd [--profile <file>] [--socket <path>] [--idle <seconds>]
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "dena/platform.h"
#include "dena/power.h"

#define MAX_INPUTS 12
#define BATTERY_POLL_MS 30000

static struct dena_profile profile;
static char backlight_path[DENA_PATH], battery_dir[DENA_PATH];
static int user_level = 100; // 0-100, restored on wake; full until the launcher says
static int listen_fd = -1, client_fd = -1;

static uint64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static size_t read_text(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  size_t n = fread(buf, 1, cap - 1, f);
  fclose(f);
  buf[n] = '\0';
  return n;
}

static int write_text(const char *path, const char *text) {
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  int ok = fputs(text, f) >= 0;
  return (fclose(f) == 0 && ok) ? 0 : -1;
}

// First match of a glob pattern (profiles use globs for sysfs paths).
static void resolve(const char *pattern, char *out, size_t cap) {
  out[0] = '\0';
  glob_t g;
  if (pattern[0] && glob(pattern, 0, NULL, &g) == 0) {
    if (g.gl_pathc > 0) snprintf(out, cap, "%s", g.gl_pathv[0]);
    globfree(&g);
  }
}

// The range comes from the kernel, next to the brightness file.
static void adopt_backlight_range(void) {
  if (!backlight_path[0]) return;
  char dir[DENA_PATH], path[DENA_PATH + 16], max[32], scale[32];
  snprintf(dir, sizeof dir, "%s", backlight_path);
  char *slash = strrchr(dir, '/');
  if (!slash) return;
  *slash = '\0';
  snprintf(path, sizeof path, "%s/max_brightness", dir);
  bool have_max = read_text(path, max, sizeof max) > 0;
  snprintf(path, sizeof path, "%s/scale", dir);
  bool have_scale = read_text(path, scale, sizeof scale) > 0;
  dena_backlight_adopt(&profile, have_max ? max : NULL, have_scale ? scale : NULL);
}

static void set_backlight(int percent) {
  if (!backlight_path[0]) return;
  char v[16];
  snprintf(v, sizeof v, "%d", dena_backlight_raw(&profile, percent));
  write_text(backlight_path, v);
}

static void send_line(const char *line) {
  if (client_fd < 0) return;
  if (send(client_fd, line, strlen(line), MSG_NOSIGNAL) < 0) {
    close(client_fd);
    client_fd = -1;
  }
}

static void load_profile(const char *override) {
  static char text[16384];
  if (override && read_text(override, text, sizeof text) &&
      dena_profile_parse(text, &profile) == 0) {
    return;
  }
  static struct dena_profile builtin[8];
  int n = dena_builtin_profiles(builtin, 8);
  size_t len = read_text("/proc/device-tree/compatible", text, sizeof text);
  const struct dena_profile *p = dena_profile_pick(builtin, n, text, len);
  if (p) profile = *p;
  else if (n > 0) profile = builtin[0]; // best guess; logged below
  fprintf(stderr, "dena-powerd: profile %s%s\n", profile.id,
          p ? "" : " (no match, using first)");
}

static int open_inputs(struct pollfd *fds) {
  int count = 0;
  DIR *dir = opendir("/dev/input");
  if (!dir) return 0;
  struct dirent *e;
  while ((e = readdir(dir)) && count < MAX_INPUTS) {
    if (strncmp(e->d_name, "event", 5) != 0) continue;
    char path[300];
    snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) fds[count++] = (struct pollfd){.fd = fd, .events = POLLIN};
  }
  closedir(dir);
  return count;
}

static void open_socket(const char *path) {
  listen_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (listen_fd < 0) return;
  struct sockaddr_un a = {.sun_family = AF_UNIX};
  snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
  unlink(path);
  if (bind(listen_fd, (struct sockaddr *)&a, sizeof a) < 0 ||
      listen(listen_fd, 1) < 0) {
    perror("dena-powerd: socket");
    close(listen_fd);
    listen_fd = -1;
  }
}

static void act(struct dena_power *pw, unsigned todo);

static void poll_battery(struct dena_power *pw) {
  if (!battery_dir[0]) return;
  char path[DENA_PATH + 16], text[64];
  snprintf(path, sizeof path, "%s/capacity", battery_dir);
  int level = read_text(path, text, sizeof text) ? dena_parse_percent(text) : -1;
  snprintf(path, sizeof path, "%s/status", battery_dir);
  bool charging = read_text(path, text, sizeof text) && dena_parse_charging(text);
  struct dena_power_event e = {.kind = DENA_EV_BATTERY, .now_ms = now_ms(),
                               .level = level, .charging = charging};
  act(pw, dena_power_step(pw, &e));
}

// Carries out actions; suspend blocks until the kernel wakes.
static void act(struct dena_power *pw, unsigned todo) {
  if (todo & DENA_DO_REQUEST_SAVE) send_line("save\n");
  if (todo & DENA_DO_BACKLIGHT_ON) set_backlight(user_level);
  if (todo & DENA_DO_BACKLIGHT_OFF) set_backlight(0);
  if (todo & DENA_DO_WARN_BATTERY) send_line("battery-low\n");
  if (todo & DENA_DO_NOTIFY_RESUMED) send_line("resumed\n");
  if (todo & DENA_DO_SUSPEND) {
    sync();
    write_text("/sys/power/state", "mem"); // returns after wake-up
    struct dena_power_event e = {.kind = DENA_EV_RESUMED, .now_ms = now_ms()};
    act(pw, dena_power_step(pw, &e));
  }
  if (todo & DENA_DO_POWEROFF) {
    send_line("poweroff\n");
    sync();
    // The single-card system powers off through init (DENA_POWEROFF=poweroff)
    // so its shutdown script unmounts the card; init then stops us.
    const char *cmd = getenv("DENA_POWEROFF");
    if (cmd && *cmd && system(cmd) == 0) {
      for (;;) pause();
    }
    reboot(RB_POWER_OFF);
  }
}

// Launcher messages: "saved", "activity", "brightness <0-100>".
static void read_client(struct dena_power *pw) {
  char buf[256];
  ssize_t n = recv(client_fd, buf, sizeof buf - 1, 0);
  if (n <= 0) {
    close(client_fd);
    client_fd = -1;
    return;
  }
  buf[n] = '\0';
  for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n")) {
    struct dena_power_event e = {.now_ms = now_ms()};
    if (strcmp(line, "saved") == 0) {
      e.kind = DENA_EV_SAVED;
    } else if (strcmp(line, "activity") == 0) {
      e.kind = DENA_EV_ACTIVITY;
    } else if (strncmp(line, "brightness ", 11) == 0) {
      user_level = atoi(line + 11);
      if (user_level < 1) user_level = 1;
      if (user_level > 100) user_level = 100;
      if (pw->state == DENA_AWAKE) set_backlight(user_level);
      continue;
    } else {
      continue;
    }
    act(pw, dena_power_step(pw, &e));
  }
}

int main(int argc, char **argv) {
  const char *profile_file = NULL, *sock = "/tmp/dena-power.sock";
  uint32_t idle_s = 0;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (strcmp(argv[i], "--profile") == 0) profile_file = argv[i + 1];
    else if (strcmp(argv[i], "--socket") == 0) sock = argv[i + 1];
    else if (strcmp(argv[i], "--idle") == 0) idle_s = (uint32_t)atoi(argv[i + 1]);
  }
  signal(SIGPIPE, SIG_IGN);
  load_profile(profile_file);
  resolve(profile.backlight, backlight_path, sizeof backlight_path);
  adopt_backlight_range();
  resolve(profile.battery, battery_dir, sizeof battery_dir);

  struct dena_power pw;
  struct dena_power_config cfg = {.idle_sleep_ms = idle_s * 1000u};
  dena_power_init(&pw, &cfg, now_ms());
  set_backlight(user_level);
  open_socket(sock);

  struct pollfd fds[MAX_INPUTS + 2];
  int inputs = open_inputs(fds);
  uint64_t next_battery = 0;
  for (;;) {
    int n = inputs, client_idx = -1;
    if (listen_fd >= 0) fds[n++] = (struct pollfd){.fd = listen_fd, .events = POLLIN};
    if (client_fd >= 0) {
      client_idx = n;
      fds[n++] = (struct pollfd){.fd = client_fd, .events = POLLIN};
    }
    poll(fds, n, 250);

    for (int i = 0; i < inputs; i++) {
      if (!(fds[i].revents & POLLIN)) continue;
      struct input_event ev;
      while (read(fds[i].fd, &ev, sizeof ev) == sizeof ev) {
        if (ev.type != EV_KEY && ev.type != EV_ABS && ev.type != EV_SW) continue;
        struct dena_power_event e = {.kind = DENA_EV_ACTIVITY, .now_ms = now_ms()};
        if (ev.type == EV_SW) {
          if (ev.code != SW_LID) continue;  // headphone jack and the like
          e.kind = ev.value ? DENA_EV_LID_CLOSED : DENA_EV_LID_OPENED;
        } else if (ev.type == EV_KEY &&
            dena_profile_action(&profile, ev.code) == DENA_KEY_POWER) {
          if (ev.value == 2) continue; // autorepeat
          e.kind = ev.value ? DENA_EV_POWER_DOWN : DENA_EV_POWER_UP;
        }
        act(&pw, dena_power_step(&pw, &e));
      }
    }
    if (client_idx >= 0 && (fds[client_idx].revents & (POLLIN | POLLHUP))) {
      read_client(&pw);
    }
    if (listen_fd >= 0 && client_fd < 0) {
      int c = accept4(listen_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
      if (c >= 0) client_fd = c;
    }

    uint64_t t = now_ms();
    if (t >= next_battery) {
      poll_battery(&pw);
      next_battery = t + BATTERY_POLL_MS;
    }
    struct dena_power_event tick = {.kind = DENA_EV_TICK, .now_ms = t};
    act(&pw, dena_power_step(&pw, &tick));
  }
}
