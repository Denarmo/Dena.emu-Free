/* Power policy: sleep, resume, long press, idle, low battery, timeouts.
 * Spec: docs/specs/power-daemon.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>

#include "dena/power.h"

static int failures;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

static struct dena_power p;
static uint64_t now;

static unsigned ev(enum dena_power_event_kind k) {
  struct dena_power_event e = {.kind = k, .now_ms = now};
  return dena_power_step(&p, &e);
}

static unsigned battery(int level, int charging) {
  struct dena_power_event e = {.kind = DENA_EV_BATTERY, .now_ms = now,
                               .level = level, .charging = charging != 0};
  return dena_power_step(&p, &e);
}

/* Ticks every 100 ms up to `until`, OR-ing the actions. */
static unsigned run_until(uint64_t until) {
  unsigned all = 0;
  while (now < until) {
    now += 100;
    all |= ev(DENA_EV_TICK);
  }
  return all;
}

static void reset(uint32_t idle) {
  struct dena_power_config cfg = {.idle_sleep_ms = idle};
  now = 1000;
  dena_power_init(&p, &cfg, now);
}

static void short_press_sleeps_after_saving(void) {
  reset(0);
  CHECK(ev(DENA_EV_POWER_DOWN) == 0);
  now += 200;
  CHECK(ev(DENA_EV_POWER_UP) == DENA_DO_REQUEST_SAVE);
  CHECK(p.state == DENA_SAVING_FOR_SLEEP);
  now += 300;
  CHECK(ev(DENA_EV_SAVED) == (DENA_DO_BACKLIGHT_OFF | DENA_DO_SUSPEND));
  CHECK(p.state == DENA_ASLEEP);
  now += 60000;
  CHECK(ev(DENA_EV_RESUMED) == (DENA_DO_BACKLIGHT_ON | DENA_DO_NOTIFY_RESUMED));
  CHECK(p.state == DENA_AWAKE);
  /* The wake press arriving late (down + up, or a lone up) doesn't sleep. */
  now += 100;
  CHECK(ev(DENA_EV_POWER_DOWN) == 0);
  now += 100;
  CHECK(ev(DENA_EV_POWER_UP) == 0);
  CHECK(p.state == DENA_AWAKE);
  /* After the grace period a press sleeps again. */
  now += 2000;
  ev(DENA_EV_POWER_DOWN);
  now += 100;
  CHECK(ev(DENA_EV_POWER_UP) == DENA_DO_REQUEST_SAVE);
}

static void wake_key_without_resume_event(void) {
  reset(0);
  ev(DENA_EV_POWER_DOWN);
  now += 100;
  ev(DENA_EV_POWER_UP);
  ev(DENA_EV_SAVED);
  CHECK(p.state == DENA_ASLEEP);
  now += 5000;
  ev(DENA_EV_POWER_DOWN);
  now += 100;
  CHECK(ev(DENA_EV_POWER_UP) == (DENA_DO_BACKLIGHT_ON | DENA_DO_NOTIFY_RESUMED));
  CHECK(p.state == DENA_AWAKE);
}

static void lone_release_is_ignored(void) {
  reset(0);
  CHECK(ev(DENA_EV_POWER_UP) == 0);
  CHECK(p.state == DENA_AWAKE);
}

static void long_press_shuts_down_while_held(void) {
  reset(0);
  ev(DENA_EV_POWER_DOWN);
  unsigned a = run_until(now + 1900);
  CHECK(a == 0);
  a = run_until(now + 200);
  CHECK(a == DENA_DO_REQUEST_SAVE);
  CHECK(p.state == DENA_SAVING_FOR_SHUTDOWN);
  now += 50;
  CHECK(ev(DENA_EV_POWER_UP) == 0); /* release after the long press: no sleep */
  CHECK(ev(DENA_EV_SAVED) == (DENA_DO_BACKLIGHT_OFF | DENA_DO_POWEROFF));
  CHECK(p.state == DENA_OFF);
  CHECK(ev(DENA_EV_POWER_DOWN) == 0 && run_until(now + 5000) == 0);
}

static void launcher_timeout_still_acts(void) {
  reset(0);
  ev(DENA_EV_POWER_DOWN);
  now += 100;
  ev(DENA_EV_POWER_UP);
  CHECK(run_until(now + 4800) == 0);
  CHECK(run_until(now + 300) == (DENA_DO_BACKLIGHT_OFF | DENA_DO_SUSPEND));
  CHECK(p.state == DENA_ASLEEP);
}

static void idle_sleep(void) {
  reset(60000);
  CHECK(run_until(now + 30000) == 0);
  ev(DENA_EV_ACTIVITY);
  CHECK(run_until(now + 59000) == 0);
  CHECK(run_until(now + 2000) == DENA_DO_REQUEST_SAVE);
  reset(0); /* idle 0 = never */
  CHECK(run_until(now + 3600000) == 0);
}

static void battery_warns_once_and_shuts_down(void) {
  reset(0);
  CHECK(battery(50, 0) == 0);
  CHECK(battery(10, 0) == DENA_DO_WARN_BATTERY);
  CHECK(battery(9, 0) == 0); /* once */
  CHECK(battery(9, 1) == 0); /* plugged in: warning re-arms */
  CHECK(battery(8, 0) == DENA_DO_WARN_BATTERY);
  CHECK(battery(2, 1) == 0); /* charging: never shut down */
  CHECK(battery(3, 0) == DENA_DO_REQUEST_SAVE);
  CHECK(p.state == DENA_SAVING_FOR_SHUTDOWN);
  CHECK(battery(2, 0) == 0); /* already shutting down */
  CHECK(ev(DENA_EV_SAVED) == (DENA_DO_BACKLIGHT_OFF | DENA_DO_POWEROFF));

  /* Asleep when the battery runs out: wake the screen, save, power off. */
  reset(0);
  ev(DENA_EV_POWER_DOWN);
  now += 100;
  ev(DENA_EV_POWER_UP);
  ev(DENA_EV_SAVED);
  CHECK(battery(1, 0) == (DENA_DO_BACKLIGHT_ON | DENA_DO_REQUEST_SAVE));
  CHECK(battery(-1, 0) == 0); /* unreadable: no action */
  CHECK(p.state == DENA_SAVING_FOR_SHUTDOWN);
  reset(0);
  CHECK(battery(-1, 0) == 0);
  CHECK(p.state == DENA_AWAKE);
}

static void lid_sleeps_and_wakes(void) {
  reset(0);
  CHECK(ev(DENA_EV_LID_CLOSED) == DENA_DO_REQUEST_SAVE);
  CHECK(p.state == DENA_SAVING_FOR_SLEEP);
  CHECK(ev(DENA_EV_LID_CLOSED) == 0); /* bounce while saving */
  now += 100;
  CHECK(ev(DENA_EV_SAVED) == (DENA_DO_BACKLIGHT_OFF | DENA_DO_SUSPEND));
  now += 60000;
  /* Opening wakes the device: the lid event and the resume event in either
   * order act once. */
  CHECK(ev(DENA_EV_LID_OPENED) == (DENA_DO_BACKLIGHT_ON | DENA_DO_NOTIFY_RESUMED));
  CHECK(ev(DENA_EV_RESUMED) == 0);
  CHECK(p.state == DENA_AWAKE);
  /* Opened while awake: nothing. Closed while asleep: nothing. */
  CHECK(ev(DENA_EV_LID_OPENED) == 0);
  CHECK(ev(DENA_EV_LID_CLOSED) == DENA_DO_REQUEST_SAVE);
  now += 100;
  ev(DENA_EV_SAVED);
  CHECK(ev(DENA_EV_LID_CLOSED) == 0 && p.state == DENA_ASLEEP);
  /* A long power press with the lid shut still powers off. */
  now += 5000;
  ev(DENA_EV_POWER_DOWN);
  CHECK(run_until(now + 2100) & DENA_DO_REQUEST_SAVE);
  CHECK(p.state == DENA_SAVING_FOR_SHUTDOWN);
}

int main(void) {
  short_press_sleeps_after_saving();
  wake_key_without_resume_event();
  lone_release_is_ignored();
  long_press_shuts_down_while_held();
  launcher_timeout_still_acts();
  idle_sleep();
  battery_warns_once_and_shuts_down();
  lid_sleeps_and_wakes();
  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  puts("power tests passed");
  return 0;
}
