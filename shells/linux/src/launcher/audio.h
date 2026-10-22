// SPDX-License-Identifier: GPL-3.0-or-later
// The launcher's ALSA setup: which card plays, the mixer path the profile
// asks for, and the volume keys. Spec: docs/specs/handheld-session.md
#ifndef DENA_LAUNCHER_AUDIO_H
#define DENA_LAUNCHER_AUDIO_H

#include "dena/platform.h"

#ifdef __cplusplus
extern "C" {
#endif

// Picks the card (the profile's audio_driver, else its audio name), applies
// the profile's mixer settings and the saved volume (level file under
// `card_root`/Dena/user/volume, DENA_VOLUME_DEFAULT if none). Returns the PCM
// device name for the game audio; it stays valid for the process.
const char *dena_audio_setup(const struct dena_profile *p, const char *card_root);

// One volume step up (dir > 0) or down; saves the new level.
void dena_audio_volume_key(int dir);

#ifdef __cplusplus
}
#endif
#endif
