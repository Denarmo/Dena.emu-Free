/* Platform modules: profile parsing, matching, key mapping, sysfs parsing.
 * Spec: docs/specs/platform-modules.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <string.h>

#include "dena/platform.h"

static int failures;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

static void parsing(void) {
  struct dena_profile p;
  const char *text =
      "# comment\n"
      "id = test\n"
      "name = Test Device\n"
      "match = vendor,board\n"
      "match = other\n"
      "display = 640x480@60\r\n"
      "rotate = 270\n"
      "backlight = /sys/class/backlight/x/brightness\n"
      "backlight_max = 200\n"
      "backlight_min = 10\n"
      "verified = yes\n"
      "future_key = ignored\n"
      "key.304 = b\n"
      "key.316 = menu\n"
      "abs.17- = up\n";
  CHECK(dena_profile_parse(text, &p) == 0);
  CHECK(strcmp(p.id, "test") == 0);
  CHECK(strcmp(p.name, "Test Device") == 0);
  CHECK(p.match_count == 2);
  CHECK(p.width == 640 && p.height == 480 && p.refresh == 60);
  CHECK(p.rotate == 270);
  CHECK(p.backlight_max == 200 && p.backlight_min == 10);
  CHECK(p.verified);
  CHECK(strcmp(p.audio_card, "default") == 0);
  CHECK(p.audio_driver[0] == '\0' && p.volume_control[0] == '\0' && p.mixer_count == 0);
  CHECK(dena_profile_action(&p, 304) == 0); /* RetroPad B */
  CHECK(dena_profile_action(&p, 316) == DENA_KEY_MENU);
  CHECK(dena_profile_action(&p, 0x10000 + 17 * 2) == 4); /* hat up → UP */
  CHECK(dena_profile_action(&p, 999) == DENA_KEY_NONE);

  /* Errors name the line. */
  CHECK(dena_profile_parse("id = x\nno equals sign\n", &p) == 2);
  CHECK(dena_profile_parse("id = x\nkey.304 = jump\n", &p) == 2);
  CHECK(dena_profile_parse("id = x\nabs.16 = left\n", &p) == 2);
  CHECK(dena_profile_parse("id = x\ndisplay = big\n", &p) == 2);
  CHECK(dena_profile_parse("id = x\nrotate = 45\n", &p) == 2);
  CHECK(dena_profile_parse("name = no id\n", &p) != 0);

  /* Audio: card by driver, the volume control and start-up mixer settings. */
  CHECK(dena_profile_parse("id = a\n"
                           "audio_driver = sun4i-codec\n"
                           "volume = DAC\n"
                           "mixer = Line Out Playback Switch = on\n"
                           "mixer =  Line Out Source Playback Route=Stereo \n",
                           &p) == 0);
  CHECK(strcmp(p.audio_driver, "sun4i-codec") == 0);
  CHECK(strcmp(p.volume_control, "DAC") == 0);
  CHECK(p.mixer_count == 2);
  CHECK(strcmp(p.mixer[0].control, "Line Out Playback Switch") == 0);
  CHECK(strcmp(p.mixer[0].value, "on") == 0);
  CHECK(strcmp(p.mixer[1].control, "Line Out Source Playback Route") == 0);
  CHECK(strcmp(p.mixer[1].value, "Stereo") == 0);
  CHECK(dena_profile_parse("id = a\nmixer = no value\n", &p) == 2);
  CHECK(dena_profile_parse("id = a\nmixer = = on\n", &p) == 2);
}

static void matching(void) {
  struct dena_profile list[8];
  int n = dena_builtin_profiles(list, 8);
  CHECK(n == 3);
  /* /proc/device-tree/compatible is NUL-separated. */
  const char rg[] = "anbernic,rg35xx-plus\0allwinner,sun50i-h700";
  const struct dena_profile *p = dena_profile_pick(list, n, rg, sizeof rg - 1);
  CHECK(p && strcmp(p->id, "h700") == 0);
  const char brick[] = "trimui,brick\0allwinner,sun50i-a133";
  p = dena_profile_pick(list, n, brick, sizeof brick - 1);
  CHECK(p && strcmp(p->id, "a133p") == 0);
  const char flip[] = "miyoo,flip\0rockchip,rk3566";
  p = dena_profile_pick(list, n, flip, sizeof flip - 1);
  CHECK(p && strcmp(p->id, "rk3566") == 0);
  const char pc[] = "qemu,virt";
  CHECK(dena_profile_pick(list, n, pc, sizeof pc - 1) == NULL);
  for (int i = 0; i < n; i++) {
    CHECK(!list[i].verified); /* nothing checked on hardware yet */
    CHECK(dena_profile_action(&list[i], 305) == 8);  /* BTN_EAST → A */
    CHECK(dena_profile_action(&list[i], 116) == DENA_KEY_POWER);
  }
  /* H700: the analog codec, routed to the line out (speaker / headphones). */
  p = dena_profile_pick(list, n, rg, sizeof rg - 1);
  CHECK(p && strcmp(p->audio_driver, "sun4i-codec") == 0 && p->mixer_count >= 4);
}

static void sysfs(void) {
  CHECK(dena_parse_percent("87\n") == 87);
  CHECK(dena_parse_percent("120") == 100);
  CHECK(dena_parse_percent("-3") == 0);
  CHECK(dena_parse_percent("") == -1);
  CHECK(dena_parse_percent("x1") == -1);
  CHECK(dena_parse_charging("Charging\n"));
  CHECK(dena_parse_charging("Full"));
  CHECK(!dena_parse_charging("Discharging\n"));
  CHECK(!dena_parse_charging("Not charging"));

  struct dena_profile p = {0};
  p.backlight_min = 8;
  p.backlight_max = 255;
  CHECK(dena_backlight_raw(&p, 0) == 0);
  CHECK(dena_backlight_raw(&p, 1) >= 8);
  CHECK(dena_backlight_raw(&p, 100) == 255);

  // Volume keys: levels 0..20, dB steps from -50 dB.
  CHECK(dena_volume_next(16, 1) == 17);
  CHECK(dena_volume_next(16, -1) == 15);
  CHECK(dena_volume_next(DENA_VOLUME_STEPS, 1) == DENA_VOLUME_STEPS);
  CHECK(dena_volume_next(0, -1) == 0);
  CHECK(dena_volume_db100(DENA_VOLUME_STEPS) == 0);
  CHECK(dena_volume_db100(1) == -4750);
  CHECK(dena_volume_db100(DENA_VOLUME_DEFAULT) == -1000);
  CHECK(dena_volume_raw(0, 0, 63) == 0);
  CHECK(dena_volume_raw(20, 0, 63) == 63);
  CHECK(dena_volume_raw(10, 0, 63) == 32);
  CHECK(dena_volume_raw(1, 0, 7) == 0);  // small ranges round
  CHECK(dena_volume_raw(5, 5, 5) == 5);
  CHECK(dena_volume_parse("12\n") == 12);
  CHECK(dena_volume_parse("0") == 0);
  CHECK(dena_volume_parse("21") == DENA_VOLUME_DEFAULT);
  CHECK(dena_volume_parse("") == DENA_VOLUME_DEFAULT);
  CHECK(dena_volume_parse(NULL) == DENA_VOLUME_DEFAULT);

  // Mixer setting values.
  long mv = -1;
  CHECK(dena_mixer_int("on", 0, 1, &mv) && mv == 1);
  CHECK(dena_mixer_int("off", 0, 1, &mv) && mv == 0);
  CHECK(dena_mixer_int("29", 0, 31, &mv) && mv == 29);
  CHECK(dena_mixer_int("99", 0, 31, &mv) && mv == 31);
  CHECK(dena_mixer_int("100%", 0, 63, &mv) && mv == 63);
  CHECK(dena_mixer_int("50%", 0, 31, &mv) && mv == 16);
  CHECK(!dena_mixer_int("Stereo", 0, 1, &mv));
  CHECK(!dena_mixer_int("5x", 0, 31, &mv));

  // ALSA buffer: half the latency in 256-frame periods at 48 kHz, 3..8.
  CHECK(dena_audio_periods(40, 256, 48000) == 4);
  CHECK(dena_audio_periods(30, 256, 48000) == 3);
  CHECK(dena_audio_periods(20, 256, 48000) == 3);
  CHECK(dena_audio_periods(80, 256, 48000) == 8);
  CHECK(dena_audio_periods(40, 0, 48000) == 4);

  const char *mixers[] = {"Line Out", "dac", "Headphone"};
  CHECK(dena_pick_mixer(mixers, 3) == 2);  // Headphone before DAC
  const char *others[] = {"Line Out", "Mic"};
  CHECK(dena_pick_mixer(others, 2) == 0);
  CHECK(dena_pick_mixer(others, 0) == -1);
  CHECK(dena_backlight_raw(&p, 150) == 255);
  int prev = 0;
  for (int i = 1; i <= 100; i++) { /* monotonic */
    int v = dena_backlight_raw(&p, i);
    CHECK(v >= prev);
    prev = v;
  }
  CHECK(dena_backlight_raw(&p, 50) < (8 + 255) / 2); /* perceptual curve */

  /* The kernel's range wins over the profile's: 100 % is the real maximum. */
  struct dena_profile k = {0};
  k.backlight_min = 8;
  k.backlight_max = 255;
  dena_backlight_adopt(&k, "2500\n", "linear\n");
  CHECK(k.backlight_max == 2500 && !k.backlight_perceptual);
  CHECK(k.backlight_min == 78); /* the same share of the range */
  CHECK(dena_backlight_raw(&k, 100) == 2500);
  CHECK(dena_backlight_raw(&k, 50) < (78 + 2500) / 2);

  /* A perceptual kernel table (pwm-backlight brightness-levels): 1:1. */
  struct dena_profile h = {0};
  h.backlight_min = 8;
  h.backlight_max = 255;
  dena_backlight_adopt(&h, "100\n", "non-linear\n");
  CHECK(h.backlight_max == 100 && h.backlight_min == 1 && h.backlight_perceptual);
  CHECK(dena_backlight_raw(&h, 0) == 0);
  for (int i = 1; i <= 100; i++) CHECK(dena_backlight_raw(&h, i) == i);
  CHECK(dena_backlight_raw(&h, 150) == 100);

  /* pwm-backlight without a table: 2500 CIE levels at a 40000 ns period. */
  struct dena_profile c = {0};
  c.backlight_min = 8;
  c.backlight_max = 255;
  dena_backlight_adopt(&c, "2499", "non-linear");
  CHECK(dena_backlight_raw(&c, 100) == 2499 && dena_backlight_raw(&c, 1) == 1);
  prev = 0;
  for (int i = 1; i <= 100; i++) {
    int v = dena_backlight_raw(&c, i);
    CHECK(v > prev);
    prev = v;
  }

  /* Unreadable or garbage sysfs text keeps the profile. */
  struct dena_profile u = {0};
  u.backlight_min = 8;
  u.backlight_max = 255;
  dena_backlight_adopt(&u, NULL, NULL);
  dena_backlight_adopt(&u, "x", "unknown");
  dena_backlight_adopt(&u, "0", "");
  CHECK(u.backlight_max == 255 && u.backlight_min == 8 && !u.backlight_perceptual);
}

int main(void) {
  parsing();
  matching();
  sysfs();
  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  puts("platform tests passed");
  return 0;
}
