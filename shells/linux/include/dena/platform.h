// SPDX-License-Identifier: GPL-3.0-or-later
// Per-device platform modules for Linux handhelds: device profiles (text
// files), input mapping, sysfs parsing. Spec: docs/specs/platform-modules.md
#ifndef DENA_PLATFORM_H
#define DENA_PLATFORM_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What a physical key does. RetroPad buttons use their libretro ids (0-15).
enum dena_key_action {
  DENA_KEY_NONE = -1,
  // 0..15: RETRO_DEVICE_ID_JOYPAD_* (B, Y, SELECT, START, UP, DOWN, LEFT,
  // RIGHT, A, X, L, R, L2, R2, L3, R3).
  DENA_KEY_MENU = 100,
  DENA_KEY_POWER,
  DENA_KEY_VOLUME_UP,
  DENA_KEY_VOLUME_DOWN,
};

#define DENA_MAX_KEYS 64
#define DENA_MAX_MATCH 8
#define DENA_PATH 160
#define DENA_MAX_MIXER 16

struct dena_key_map {
  int code;   // evdev key code (EV_KEY), or 0x10000 + ABS axis for hats
  int action; // enum dena_key_action or a RetroPad id
};

// One mixer control the launcher sets at start (`mixer = <control> = <value>`).
struct dena_mixer_setting {
  char control[48]; // full ALSA control name, "Line Out Playback Switch"
  char value[24];   // on, off, a raw number, N% of the range, or an enum item
};

struct dena_profile {
  char id[48];
  char name[64];
  char match[DENA_MAX_MATCH][64]; // device-tree compatible / model substrings
  int match_count;
  int width, height, refresh;
  int rotate;                    // panel mounted rotated: 0, 90, 180, 270 (clockwise)
  char backlight[DENA_PATH];     // sysfs brightness file
  int backlight_max;
  int backlight_min;             // lowest raw value that is still visible
  bool backlight_perceptual;     // the kernel's levels already look even
  char battery[DENA_PATH];       // power_supply directory
  char audio_card[32];           // ALSA card name, e.g. "default"
  char audio_driver[32];         // ALSA driver of the card to use, e.g. "sun4i-codec"
  char volume_control[48];       // simple mixer element the volume keys drive
  struct dena_mixer_setting mixer[DENA_MAX_MIXER];
  int mixer_count;
  bool verified;                 // checked on real hardware
  struct dena_key_map keys[DENA_MAX_KEYS];
  int key_count;
};

// Parses a profile from `key = value` text (see profiles/*.conf). Unknown
// keys are ignored. Returns 0, or the 1-based line number of the first error.
int dena_profile_parse(const char *text, struct dena_profile *out);

// The action for an evdev key code, or DENA_KEY_NONE.
int dena_profile_action(const struct dena_profile *p, int code);

// Whether the profile matches a device-tree compatible/model string (the
// NUL-separated list from /proc/device-tree/compatible works: pass its length).
bool dena_profile_matches(const struct dena_profile *p, const char *compat,
                          size_t len);

// Picks the first matching profile, or NULL.
const struct dena_profile *dena_profile_pick(const struct dena_profile *list,
                                             int count, const char *compat,
                                             size_t len);

// The profiles built into the launcher (generic defaults, unverified until a
// device is on the rig).
int dena_builtin_profiles(struct dena_profile *out, int max);

// RetroPad id or special action for a name ("a", "up", "menu"...), or
// DENA_KEY_NONE.
int dena_action_from_name(const char *name);

// sysfs helpers (pure: they parse text that the caller read).
// Battery capacity 0-100 from "87\n"; -1 if unreadable.
int dena_parse_percent(const char *text);
// "Charging" / "Full" → true; "Discharging" / "Not charging" → false.
bool dena_parse_charging(const char *text);
// Raw backlight value for a 0-100 user level between min and max; 0 stays 0
// (screen off). A squared (perceptual) curve, or a straight line when the
// kernel's level table is already perceptual.
int dena_backlight_raw(const struct dena_profile *p, int percent);
// Takes the backlight range from the kernel: the device's max_brightness and
// scale files ("linear", "non-linear", "unknown"; NULL if unreadable), so 100 %
// is the panel's real maximum whatever the profile says. With a non-linear
// scale every level from 1 is usable and the curve is left to the kernel.
void dena_backlight_adopt(struct dena_profile *p, const char *max_text,
                          const char *scale_text);

// Volume (handheld-session.md): a level 0..DENA_VOLUME_STEPS, 0 is mute.
// Controls with dB information get DENA_VOLUME_FLOOR_DB..0 dB in equal dB
// steps; others an equal share of their raw range.
#define DENA_VOLUME_STEPS 20
#define DENA_VOLUME_DEFAULT 16       // -10 dB
#define DENA_VOLUME_FLOOR_DB100 (-5000)
// The level one key press up (dir > 0) or down, clamped.
int dena_volume_next(int level, int dir);
// Target in 1/100 dB for levels 1..DENA_VOLUME_STEPS (0 for the top).
long dena_volume_db100(int level);
// Raw value for a level on a control without dB information.
long dena_volume_raw(int level, long min, long max);
// "12\n" read back from the saved level file; DENA_VOLUME_DEFAULT if unreadable.
int dena_volume_parse(const char *text);
// Mixer setting value for an integer control with the range [min, max]:
// on/off are max/min, N% a share of the range, a number is clamped. False if
// the text is none of these (an enum item name, for instance).
bool dena_mixer_int(const char *value, long min, long max, long *out);
// ALSA hardware buffer for an audio latency setting (performance.md): how many
// periods of `period_frames` at `rate` Hz. About half the setting, at least 3
// periods, at most 8; the runner's ring stays the main buffer.
int dena_audio_periods(int latency_ms, int period_frames, int rate);
// Which mixer element the volume keys drive: the first of Master, PCM,
// Speaker, Headphone, DAC, Playback (case-insensitive) in that order, else
// the first one. names[i] are elements with a playback volume. -1 if none.
int dena_pick_mixer(const char *const *names, int count);

#ifdef __cplusplus
}
#endif
#endif
