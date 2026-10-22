/* Session persistence helpers. Spec: docs/specs/game-session.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef DENA_SESSION_H
#define DENA_SESSION_H

#include <stdint.h>

#include "dena/host.h"

#ifdef __cplusplus
extern "C" {
#endif

#define DENA_MEMORY_SAVE_RAM 0 /* RETRO_MEMORY_SAVE_RAM */
#define DENA_NO_DATA 1         /* nothing to save or no file to load: not an error */

/* Battery save (the core's save RAM) to/from a file. 0 ok, DENA_NO_DATA, or -1. */
int dena_battery_save(dena_core *core, const char *path);
int dena_battery_load(dena_core *core, const char *path);
/* Hash of the save RAM, to skip writes when nothing changed (0 if none). */
uint64_t dena_battery_hash(dena_core *core);

/* Save state to/from a file (atomic write). 0 ok, DENA_NO_DATA, or -1. */
int dena_state_save_file(dena_core *core, const char *path);
int dena_state_load_file(dena_core *core, const char *path);

/* Writes frame as an RGB PNG (stored deflate, atomic write). 0 ok, -1 on error.
 * Spec: docs/specs/save-states.md */
int dena_frame_write_png(const dena_frame *frame, const char *path);

#ifdef __cplusplus
}
#endif

#endif
