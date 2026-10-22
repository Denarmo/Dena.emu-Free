// SPDX-License-Identifier: GPL-3.0-or-later
// Power policy for Linux handhelds: sleep/resume, idle sleep, low battery and
// long-press shutdown, always flushing saves first. Pure: the daemon feeds it
// events with timestamps and carries out the actions it returns.
// Spec: docs/specs/power-daemon.md
#ifndef DENA_POWER_H
#define DENA_POWER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum dena_power_state {
  DENA_AWAKE,
  DENA_SAVING_FOR_SLEEP,    // asked the launcher to save; waiting
  DENA_ASLEEP,
  DENA_SAVING_FOR_SHUTDOWN, // asked the launcher to save; waiting
  DENA_OFF,                 // shutdown issued
};

enum dena_power_event_kind {
  DENA_EV_TICK,          // time passes (call at least once a second)
  DENA_EV_POWER_DOWN,    // power key pressed
  DENA_EV_POWER_UP,      // power key released
  DENA_EV_ACTIVITY,      // any other input
  DENA_EV_SAVED,         // the launcher finished flushing saves
  DENA_EV_RESUMED,       // the kernel woke from suspend
  DENA_EV_BATTERY,       // a battery reading: level (0-100), charging
  DENA_EV_LID_CLOSED,    // clamshell closed (SW_LID on, RG35XX SP)
  DENA_EV_LID_OPENED,    // clamshell opened
};

struct dena_power_event {
  enum dena_power_event_kind kind;
  uint64_t now_ms; // monotonic
  int level;       // DENA_EV_BATTERY
  bool charging;   // DENA_EV_BATTERY
};

// Things the daemon must do, as bits.
enum {
  DENA_DO_REQUEST_SAVE = 1 << 0,  // tell the launcher: pause and flush saves
  DENA_DO_BACKLIGHT_OFF = 1 << 1,
  DENA_DO_BACKLIGHT_ON = 1 << 2,  // restore the user's level
  DENA_DO_SUSPEND = 1 << 3,       // write "mem" to /sys/power/state
  DENA_DO_NOTIFY_RESUMED = 1 << 4,// tell the launcher it woke (stay paused)
  DENA_DO_WARN_BATTERY = 1 << 5,  // show the low-battery warning
  DENA_DO_POWEROFF = 1 << 6,      // sync and power off
};

struct dena_power_config {
  uint32_t long_press_ms;   // hold to shut down (default 2000)
  uint32_t save_timeout_ms; // stop waiting for the launcher (default 5000)
  uint32_t idle_sleep_ms;   // no input for this long → sleep; 0 = never
  int warn_level;           // warn once at or below (default 10)
  int shutdown_level;       // shut down at or below, unplugged (default 3)
  uint32_t wake_grace_ms;   // ignore the power key after waking (default 1000)
};

struct dena_power {
  struct dena_power_config cfg;
  enum dena_power_state state;
  uint64_t power_down_at;   // 0 = key not held
  uint64_t last_activity;
  uint64_t saving_since;
  uint64_t resumed_at;      // power key ignored shortly after a wake-up
  bool warned;
};

void dena_power_init(struct dena_power *p, const struct dena_power_config *cfg,
                     uint64_t now_ms);

// Feeds one event; returns the DENA_DO_* actions to carry out now.
unsigned dena_power_step(struct dena_power *p, const struct dena_power_event *e);

#ifdef __cplusplus
}
#endif
#endif
