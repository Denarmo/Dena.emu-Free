// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/handheld-session.md (Audio, Volume keys)
#include "audio.h"

#include <alsa/asoundlib.h>
#include <stdio.h>
#include <string.h>

static char pcm_name[32] = "default";
static char ctl_name[32] = "default";
static char volume_name[48];
static char level_path[512];
static int level = DENA_VOLUME_DEFAULT;

// The card whose ALSA driver is `driver` ("sun4i-codec"), or -1.
static int find_card(const char *driver) {
  int card = -1;
  while (snd_card_next(&card) == 0 && card >= 0) {
    char name[16];
    snprintf(name, sizeof name, "hw:%d", card);
    snd_ctl_t *ctl;
    if (snd_ctl_open(&ctl, name, 0) < 0) continue;
    snd_ctl_card_info_t *info;
    snd_ctl_card_info_alloca(&info);
    bool match = snd_ctl_card_info(ctl, info) == 0 &&
                 strcmp(snd_ctl_card_info_get_driver(info), driver) == 0;
    snd_ctl_close(ctl);
    if (match) return card;
  }
  return -1;
}

// Sets every channel of one control: on/off, a number or N% for switches
// and volumes, an item name for enums.
static void set_control(snd_ctl_t *ctl, const struct dena_mixer_setting *m) {
  snd_ctl_elem_id_t *id;
  snd_ctl_elem_info_t *info;
  snd_ctl_elem_value_t *val;
  snd_ctl_elem_id_alloca(&id);
  snd_ctl_elem_info_alloca(&info);
  snd_ctl_elem_value_alloca(&val);
  snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_MIXER);
  snd_ctl_elem_id_set_name(id, m->control);
  snd_ctl_elem_info_set_id(info, id);
  if (snd_ctl_elem_info(ctl, info) < 0) {
    fprintf(stderr, "dena: audio: no control \"%s\"\n", m->control);
    return;
  }
  snd_ctl_elem_value_set_id(val, id);
  unsigned count = snd_ctl_elem_info_get_count(info);
  long v = 0;
  switch (snd_ctl_elem_info_get_type(info)) {
    case SND_CTL_ELEM_TYPE_BOOLEAN:
      if (!dena_mixer_int(m->value, 0, 1, &v)) goto bad;
      for (unsigned i = 0; i < count; i++) snd_ctl_elem_value_set_boolean(val, i, v);
      break;
    case SND_CTL_ELEM_TYPE_INTEGER:
      if (!dena_mixer_int(m->value, snd_ctl_elem_info_get_min(info),
                          snd_ctl_elem_info_get_max(info), &v))
        goto bad;
      for (unsigned i = 0; i < count; i++) snd_ctl_elem_value_set_integer(val, i, v);
      break;
    case SND_CTL_ELEM_TYPE_ENUMERATED: {
      unsigned items = snd_ctl_elem_info_get_items(info), item = items;
      for (unsigned i = 0; i < items; i++) {
        snd_ctl_elem_info_set_item(info, i);
        if (snd_ctl_elem_info(ctl, info) == 0 &&
            strcmp(snd_ctl_elem_info_get_item_name(info), m->value) == 0) {
          item = i;
          break;
        }
      }
      if (item == items) goto bad;
      for (unsigned i = 0; i < count; i++) snd_ctl_elem_value_set_enumerated(val, i, item);
      break;
    }
    default:
      goto bad;
  }
  if (snd_ctl_elem_write(ctl, val) < 0)
    fprintf(stderr, "dena: audio: cannot set \"%s\"\n", m->control);
  return;
bad:
  fprintf(stderr, "dena: audio: bad value \"%s\" for \"%s\"\n", m->value, m->control);
}

// Puts `level` on the volume control (the profile's, else dena_pick_mixer's).
static void apply_level(void) {
  snd_mixer_t *mixer;
  if (snd_mixer_open(&mixer, 0) < 0) return;
  if (snd_mixer_attach(mixer, ctl_name) < 0 || snd_mixer_selem_register(mixer, NULL, NULL) < 0 ||
      snd_mixer_load(mixer) < 0) {
    snd_mixer_close(mixer);
    return;
  }
  snd_mixer_elem_t *elem = NULL;
  if (volume_name[0]) {
    snd_mixer_selem_id_t *sid;
    snd_mixer_selem_id_alloca(&sid);
    snd_mixer_selem_id_set_name(sid, volume_name);
    elem = snd_mixer_find_selem(mixer, sid);
  }
  if (!elem) {
    snd_mixer_elem_t *elems[32];
    const char *names[32];
    int n = 0;
    for (snd_mixer_elem_t *e = snd_mixer_first_elem(mixer); e && n < 32; e = snd_mixer_elem_next(e))
      if (snd_mixer_selem_is_active(e) && snd_mixer_selem_has_playback_volume(e)) {
        elems[n] = e;
        names[n++] = snd_mixer_selem_get_name(e);
      }
    int pick = dena_pick_mixer(names, n);
    if (pick >= 0) elem = elems[pick];
  }
  if (elem && snd_mixer_selem_has_playback_volume(elem)) {
    long min, max, db_min, db_max;
    snd_mixer_selem_get_playback_volume_range(elem, &min, &max);
    if (level == 0) {
      snd_mixer_selem_set_playback_volume_all(elem, min);
    } else if (snd_mixer_selem_get_playback_dB_range(elem, &db_min, &db_max) == 0 &&
               db_min < db_max) {
      long db = dena_volume_db100(level);
      db = db < db_min ? db_min : db > db_max ? db_max : db;
      snd_mixer_selem_set_playback_dB_all(elem, db, -1);
    } else {
      snd_mixer_selem_set_playback_volume_all(elem, dena_volume_raw(level, min, max));
    }
    if (snd_mixer_selem_has_playback_switch(elem))
      snd_mixer_selem_set_playback_switch_all(elem, level > 0);
  }
  snd_mixer_close(mixer);
}

const char *dena_audio_setup(const struct dena_profile *p, const char *card_root) {
  if (p->audio_card[0]) {
    snprintf(pcm_name, sizeof pcm_name, "%s", p->audio_card);
    snprintf(ctl_name, sizeof ctl_name, "%s", p->audio_card);
  }
  if (p->audio_driver[0]) {
    int card = find_card(p->audio_driver);
    if (card >= 0) {
      snprintf(pcm_name, sizeof pcm_name, "plughw:%d,0", card);
      snprintf(ctl_name, sizeof ctl_name, "hw:%d", card);
    } else {
      fprintf(stderr, "dena: audio: no %s card, using %s\n", p->audio_driver, pcm_name);
    }
  }
  snprintf(volume_name, sizeof volume_name, "%s", p->volume_control);

  if (p->mixer_count > 0) {
    snd_ctl_t *ctl;
    if (snd_ctl_open(&ctl, ctl_name, 0) == 0) {
      for (int i = 0; i < p->mixer_count; i++) set_control(ctl, &p->mixer[i]);
      snd_ctl_close(ctl);
    } else {
      fprintf(stderr, "dena: audio: cannot open the mixer %s\n", ctl_name);
    }
  }

  if (card_root && *card_root) {
    snprintf(level_path, sizeof level_path, "%s/Dena/user/volume", card_root);
    char buf[16] = "";
    FILE *f = fopen(level_path, "r");
    if (f) {
      if (!fgets(buf, sizeof buf, f)) buf[0] = '\0';
      fclose(f);
    }
    level = dena_volume_parse(f ? buf : NULL);
  }
  apply_level();
  fprintf(stderr, "dena: audio on %s, volume %d/%d\n", pcm_name, level, DENA_VOLUME_STEPS);
  return pcm_name;
}

void dena_audio_volume_key(int dir) {
  int next = dena_volume_next(level, dir);
  if (next == level) return;
  level = next;
  apply_level();
  if (!level_path[0]) return;
  FILE *f = fopen(level_path, "w");
  if (f) {
    fprintf(f, "%d\n", level);
    fclose(f);
  }
}
