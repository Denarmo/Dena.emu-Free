// SPDX-License-Identifier: GPL-3.0-or-later
// Sleep and wake on Linux (SteamOS, systemd distros): saves the running game
// before the system sleeps and resumes it after.
// Spec: docs/specs/deck-presets.md (Suspend and resume)
#ifndef RUNNER_DENA_SLEEP_H_
#define RUNNER_DENA_SLEEP_H_

#include "dena/desktop_loader.h"

struct DenaSleep;

// Starts watching logind on the system bus; host must outlive the watch.
// Without a system bus or logind nothing happens.
DenaSleep* dena_sleep_start(dena::DesktopHost* host);
void dena_sleep_stop(DenaSleep* sleep);

#endif  // RUNNER_DENA_SLEEP_H_
