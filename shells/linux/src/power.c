// SPDX-License-Identifier: GPL-3.0-or-later
// Power policy state machine. Spec: docs/specs/power-daemon.md
#include "dena/power.h"

#include <string.h>

void dena_power_init(struct dena_power *p, const struct dena_power_config *cfg,
                     uint64_t now_ms) {
  memset(p, 0, sizeof *p);
  p->cfg = *cfg;
  if (!p->cfg.long_press_ms) p->cfg.long_press_ms = 2000;
  if (!p->cfg.save_timeout_ms) p->cfg.save_timeout_ms = 5000;
  if (!p->cfg.warn_level) p->cfg.warn_level = 10;
  if (!p->cfg.shutdown_level) p->cfg.shutdown_level = 3;
  if (!p->cfg.wake_grace_ms) p->cfg.wake_grace_ms = 1000;
  p->state = DENA_AWAKE;
  p->last_activity = now_ms;
}

static unsigned start_saving(struct dena_power *p, enum dena_power_state next,
                             uint64_t now) {
  p->state = next;
  p->saving_since = now;
  return DENA_DO_REQUEST_SAVE;
}

static unsigned finish_saving(struct dena_power *p) {
  if (p->state == DENA_SAVING_FOR_SLEEP) {
    p->state = DENA_ASLEEP;
    return DENA_DO_BACKLIGHT_OFF | DENA_DO_SUSPEND;
  }
  p->state = DENA_OFF;
  return DENA_DO_BACKLIGHT_OFF | DENA_DO_POWEROFF;
}

unsigned dena_power_step(struct dena_power *p, const struct dena_power_event *e) {
  const uint64_t now = e->now_ms;
  if (p->state == DENA_OFF) return 0;

  switch (e->kind) {
    case DENA_EV_POWER_DOWN:
      // The press that woke the device may arrive after the resume.
      if (p->resumed_at && now - p->resumed_at < p->cfg.wake_grace_ms) return 0;
      p->power_down_at = now ? now : 1;
      p->last_activity = now;
      return 0;

    case DENA_EV_POWER_UP: {
      if (!p->power_down_at) return 0; // a release without its press
      uint64_t held = now - p->power_down_at;
      p->power_down_at = 0;
      p->last_activity = now;
      if (held >= p->cfg.long_press_ms) return 0; // the tick already acted
      if (p->state == DENA_AWAKE) {
        return start_saving(p, DENA_SAVING_FOR_SLEEP, now);
      }
      if (p->state == DENA_ASLEEP) {
        // No resume event came (some kernels): the key press is the wake-up.
        p->state = DENA_AWAKE;
        p->resumed_at = now;
        return DENA_DO_BACKLIGHT_ON | DENA_DO_NOTIFY_RESUMED;
      }
      return 0;
    }

    case DENA_EV_ACTIVITY:
      p->last_activity = now;
      return 0;

    case DENA_EV_SAVED:
      if (p->state == DENA_SAVING_FOR_SLEEP ||
          p->state == DENA_SAVING_FOR_SHUTDOWN) {
        return finish_saving(p);
      }
      return 0;

    case DENA_EV_RESUMED:
      p->last_activity = now;
      p->power_down_at = 0;
      p->resumed_at = now;
      if (p->state == DENA_ASLEEP) {
        p->state = DENA_AWAKE;
        return DENA_DO_BACKLIGHT_ON | DENA_DO_NOTIFY_RESUMED;
      }
      return 0;

    case DENA_EV_LID_CLOSED:
      // Closing the lid is a short power press.
      p->last_activity = now;
      if (p->state == DENA_AWAKE) return start_saving(p, DENA_SAVING_FOR_SLEEP, now);
      return 0;

    case DENA_EV_LID_OPENED:
      p->last_activity = now;
      if (p->state == DENA_ASLEEP) {
        // The lid woke the device (or no resume event came): the screen on.
        p->state = DENA_AWAKE;
        p->resumed_at = now;
        return DENA_DO_BACKLIGHT_ON | DENA_DO_NOTIFY_RESUMED;
      }
      return 0;

    case DENA_EV_BATTERY:
      if (e->charging) {
        p->warned = false;
        return 0;
      }
      if (e->level >= 0 && e->level <= p->cfg.shutdown_level &&
          p->state != DENA_SAVING_FOR_SHUTDOWN) {
        unsigned extra = p->state == DENA_ASLEEP ? DENA_DO_BACKLIGHT_ON : 0;
        return extra | start_saving(p, DENA_SAVING_FOR_SHUTDOWN, now);
      }
      if (e->level >= 0 && e->level <= p->cfg.warn_level && !p->warned &&
          p->state == DENA_AWAKE) {
        p->warned = true;
        return DENA_DO_WARN_BATTERY;
      }
      return 0;

    case DENA_EV_TICK: {
      // Long press: shut down while the key is still held.
      if (p->power_down_at && now - p->power_down_at >= p->cfg.long_press_ms &&
          p->state != DENA_SAVING_FOR_SHUTDOWN) {
        p->power_down_at = 0;
        unsigned extra = p->state == DENA_ASLEEP ? DENA_DO_BACKLIGHT_ON : 0;
        return extra | start_saving(p, DENA_SAVING_FOR_SHUTDOWN, now);
      }
      // The launcher didn't answer: act anyway (its saves are best effort).
      if ((p->state == DENA_SAVING_FOR_SLEEP ||
           p->state == DENA_SAVING_FOR_SHUTDOWN) &&
          now - p->saving_since >= p->cfg.save_timeout_ms) {
        return finish_saving(p);
      }
      if (p->state == DENA_AWAKE && p->cfg.idle_sleep_ms &&
          now - p->last_activity >= p->cfg.idle_sleep_ms) {
        return start_saving(p, DENA_SAVING_FOR_SLEEP, now);
      }
      return 0;
    }
  }
  return 0;
}
