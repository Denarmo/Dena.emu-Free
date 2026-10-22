// SPDX-License-Identifier: GPL-3.0-or-later
// The device profiles built into the launcher (shells/linux/profiles).
// Spec: docs/specs/platform-modules.md
#include "dena/platform.h"
#include "profiles_gen.h"

int dena_builtin_profiles(struct dena_profile *out, int max) {
  int n = 0;
  int total = (int)(sizeof dena_profile_texts / sizeof dena_profile_texts[0]);
  for (int i = 0; i < total && n < max; i++) {
    if (dena_profile_parse(dena_profile_texts[i], &out[n]) == 0) n++;
  }
  return n;
}
