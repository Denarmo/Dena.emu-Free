/* Headless libretro frontend. Spec: docs/specs/test-harness.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "dena/host.h"
#include "dena/link.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libretro.h"

#ifdef _WIN32
#include <windows.h>
typedef HMODULE lib_handle;
static lib_handle lib_open(const char *p) { return LoadLibraryA(p); }
static void *lib_sym(lib_handle h, const char *s) {
  return (void *)(uintptr_t)GetProcAddress(h, s);
}
static void lib_close(lib_handle h) { FreeLibrary(h); }
static const char *lib_error(void) { return "LoadLibrary failed"; }
#else
#include <dlfcn.h>
typedef void *lib_handle;
static lib_handle lib_open(const char *p) { return dlopen(p, RTLD_NOW | RTLD_LOCAL); }
static void *lib_sym(lib_handle h, const char *s) { return dlsym(h, s); }
static void lib_close(lib_handle h) { dlclose(h); }
static const char *lib_error(void) { return dlerror(); }
#endif

struct dena_core {
  lib_handle lib;
  void (*retro_init)(void);
  void (*retro_deinit)(void);
  unsigned (*retro_api_version)(void);
  void (*retro_get_system_info)(struct retro_system_info *);
  void (*retro_get_system_av_info)(struct retro_system_av_info *);
  void (*retro_set_environment)(retro_environment_t);
  void (*retro_set_video_refresh)(retro_video_refresh_t);
  void (*retro_set_audio_sample)(retro_audio_sample_t);
  void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
  void (*retro_set_input_poll)(retro_input_poll_t);
  void (*retro_set_input_state)(retro_input_state_t);
  void (*retro_set_controller_port_device)(unsigned, unsigned);
  void (*retro_run)(void);
  size_t (*retro_serialize_size)(void);
  bool (*retro_serialize)(void *, size_t);
  bool (*retro_unserialize)(const void *, size_t);
  bool (*retro_load_game)(const struct retro_game_info *);
  void (*retro_unload_game)(void);

  bool initialized;
  bool game_loaded;
  void *rom_data;
  char *rom_path;
  enum retro_pixel_format pixel_format;
  dena_frame frame;
  uint64_t audio_hash;
  unsigned frame_count;
  uint16_t buttons[DENA_MAX_PORTS];
  int16_t analog[DENA_MAX_PORTS][2][2]; /* [port][stick][x, y] */
  int16_t pointer_x, pointer_y; /* -0x7fff..0x7fff over the frame */
  int pointer_pressed;
  unsigned multitap[DENA_MAX_PORTS]; /* device id per port, 0 = none offered */
  unsigned pad_device[DENA_MAX_PORTS]; /* the port's plain pad, 0 = RetroPad */
  char system_dir[512];
  char save_dir[512]; /* system_dir unless DENA_SAVE_DIR names another */
  dena_audio_sink audio_sink;
  void *audio_user;
  int hashing;
  void *(*retro_get_memory_data)(unsigned);
  size_t (*retro_get_memory_size)(unsigned);
  void (*retro_cheat_reset)(void);                       /* optional */
  void (*retro_cheat_set)(unsigned, bool, const char *); /* optional */
  dena_link_attach_fn link_attach;                       /* optional */

  dena_hw_hooks hw_hooks;
  int hw_hooked, hw_requested, hw_frame;
  unsigned hw_width, hw_height;
  struct retro_hw_render_callback hw;

  struct {
    char key[64], value[128];
  } options[DENA_MAX_OPTIONS];
  unsigned option_count;
  bool options_changed;
  /* The core's own defaults (SET_VARIABLES / SET_CORE_OPTIONS*), answered
   * for keys the frontend never set. */
  struct {
    char *key, *value;
  } *defaults;
  unsigned default_count, default_cap;
  /* SET_MEMORY_MAPS, copied (achievements.md); descriptor pointers stay the core's. */
  struct retro_memory_descriptor *mmap_descriptors;
  struct retro_memory_map mmap;
};

static dena_core *g_core; /* libretro callbacks carry no user pointer */

static void RETRO_CALLCONV log_cb(enum retro_log_level level, const char *fmt, ...) {
  static const char *names[] = {"debug", "info", "warn", "error"};
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[core %s] ", (unsigned)level < 4 ? names[level] : "?");
  vfprintf(stderr, fmt, ap);
  va_end(ap);
}

static uintptr_t RETRO_CALLCONV hw_get_framebuffer(void) {
  return g_core->hw_hooks.get_framebuffer(g_core->hw_hooks.user);
}

static retro_proc_address_t RETRO_CALLCONV hw_get_proc_address(const char *sym) {
  return (retro_proc_address_t)g_core->hw_hooks.get_proc_address(g_core->hw_hooks.user, sym);
}

/* GLES on Android and the handhelds; desktop GL on Windows and Linux PCs
 * (dena_set_desktop_gl, desktop-shell.md). */
static int g_desktop_gl;

void dena_set_desktop_gl(int on) { g_desktop_gl = on; }

static bool accept_hw_render(struct retro_hw_render_callback *cb) {
  if (!g_core->hw_hooked) return false;
  switch (cb->context_type) {
    case RETRO_HW_CONTEXT_OPENGLES2:
    case RETRO_HW_CONTEXT_OPENGLES3:
      if (g_desktop_gl) return false;
      break;
    case RETRO_HW_CONTEXT_OPENGLES_VERSION:
      if (g_desktop_gl || cb->version_major < 2) return false;
      break;
    case RETRO_HW_CONTEXT_OPENGL:
    case RETRO_HW_CONTEXT_OPENGL_CORE:
      if (!g_desktop_gl) return false;
      break;
    default:
      return false;
  }
  cb->get_current_framebuffer = hw_get_framebuffer;
  cb->get_proc_address = hw_get_proc_address;
  g_core->hw = *cb;
  g_core->hw_requested = 1;
  return true;
}

static const char *find_option(const char *key) {
  for (unsigned i = 0; i < g_core->option_count; i++)
    if (strcmp(g_core->options[i].key, key) == 0) return g_core->options[i].value;
  return NULL;
}

static char *dup_n(const char *s, size_t n) {
  char *d = (char *)malloc(n + 1);
  if (d) {
    memcpy(d, s, n);
    d[n] = 0;
  }
  return d;
}

static const char *find_default(const char *key) {
  for (unsigned i = 0; i < g_core->default_count; i++)
    if (strcmp(g_core->defaults[i].key, key) == 0) return g_core->defaults[i].value;
  return NULL;
}

/* Records a core option's default; a later declaration of the key wins. */
static void add_default(const char *key, const char *value, size_t value_len) {
  if (!key || !value) return;
  char *v = dup_n(value, value_len);
  if (!v) return;
  for (unsigned i = 0; i < g_core->default_count; i++)
    if (strcmp(g_core->defaults[i].key, key) == 0) {
      free(g_core->defaults[i].value);
      g_core->defaults[i].value = v;
      return;
    }
  if (g_core->default_count == g_core->default_cap) {
    unsigned cap = g_core->default_cap ? g_core->default_cap * 2 : 64;
    void *grown = realloc(g_core->defaults, cap * sizeof *g_core->defaults);
    if (!grown) {
      free(v);
      return;
    }
    g_core->defaults = grown;
    g_core->default_cap = cap;
  }
  char *k = dup_n(key, strlen(key));
  if (!k) {
    free(v);
    return;
  }
  g_core->defaults[g_core->default_count].key = k;
  g_core->defaults[g_core->default_count].value = v;
  g_core->default_count++;
}

/* Legacy "Description; first|second|..." strings: the first value is the default. */
static void add_variables(const struct retro_variable *vars) {
  for (; vars && vars->key; vars++) {
    const char *v = vars->value ? strstr(vars->value, "; ") : NULL;
    if (!v) continue;
    v += 2;
    add_default(vars->key, v, strcspn(v, "|"));
  }
}

/* v1 and v2 definitions share key, values[] and default_value. */
static void add_definition(const char *key, const struct retro_core_option_value *values,
                           const char *def) {
  if (!def) def = values[0].value;
  if (def) add_default(key, def, strlen(def));
}

static void add_definitions_v1(const struct retro_core_option_definition *d) {
  for (; d && d->key; d++) add_definition(d->key, d->values, d->default_value);
}

static void add_definitions_v2(const struct retro_core_options_v2 *o) {
  if (!o) return;
  for (const struct retro_core_option_v2_definition *d = o->definitions; d && d->key; d++)
    add_definition(d->key, d->values, d->default_value);
}

static bool RETRO_CALLCONV environment_cb(unsigned cmd, void *data) {
  switch (cmd) {
    case RETRO_ENVIRONMENT_SET_HW_RENDER:
      return accept_hw_render((struct retro_hw_render_callback *)data);
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
      if (!g_core->hw_hooked) return false;
      *(unsigned *)data = g_desktop_gl ? RETRO_HW_CONTEXT_OPENGL_CORE : RETRO_HW_CONTEXT_OPENGLES3;
      return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      enum retro_pixel_format f = *(const enum retro_pixel_format *)data;
      if (f != RETRO_PIXEL_FORMAT_0RGB1555 && f != RETRO_PIXEL_FORMAT_XRGB8888 &&
          f != RETRO_PIXEL_FORMAT_RGB565)
        return false;
      g_core->pixel_format = f;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
      *(bool *)data = true;
      return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      *(const char **)data = g_core->system_dir;
      return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      *(const char **)data = g_core->save_dir;
      return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
      ((struct retro_log_callback *)data)->log = log_cb;
      return true;
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
      return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      struct retro_variable *v = data;
      v->value = v->key ? find_option(v->key) : NULL;
      if (!v->value && v->key) v->value = find_default(v->key);
      return v->value != NULL;
    }
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
      *(unsigned *)data = 2;
      return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES:
      add_variables((const struct retro_variable *)data);
      return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
      add_definitions_v1((const struct retro_core_option_definition *)data);
      return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
      if (data) add_definitions_v1(((const struct retro_core_options_intl *)data)->us);
      return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
      add_definitions_v2((const struct retro_core_options_v2 *)data);
      return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
      if (data) add_definitions_v2(((const struct retro_core_options_v2_intl *)data)->us);
      return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
      return true; /* no options menu: visibility does not matter */
    case RETRO_ENVIRONMENT_SET_VARIABLE: {
      /* The core changes one of its own options (NULL asks for support). */
      const struct retro_variable *v = data;
      if (v && v->key && v->value) {
        bool changed = g_core->options_changed;
        dena_core_set_option(g_core, v->key, v->value);
        g_core->options_changed = changed;
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS: {
      const struct retro_memory_map *m = data;
      free(g_core->mmap_descriptors);
      g_core->mmap_descriptors = NULL;
      g_core->mmap.descriptors = NULL;
      g_core->mmap.num_descriptors = 0;
      if (m && m->num_descriptors) {
        size_t n = m->num_descriptors * sizeof *m->descriptors;
        g_core->mmap_descriptors = malloc(n);
        if (!g_core->mmap_descriptors) return false;
        memcpy(g_core->mmap_descriptors, m->descriptors, n);
        g_core->mmap.descriptors = g_core->mmap_descriptors;
        g_core->mmap.num_descriptors = m->num_descriptors;
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
      for (unsigned p = 0; p < DENA_MAX_PORTS; p++) {
        g_core->multitap[p] = dena_find_multitap(data, p);
        g_core->pad_device[p] = dena_find_pad_device(data, p);
      }
      return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      *(bool *)data = g_core->options_changed;
      g_core->options_changed = false;
      return true;
    default:
      return false;
  }
}

static void RETRO_CALLCONV video_cb(const void *data, unsigned width,
                                    unsigned height, size_t pitch) {
  if (data == RETRO_HW_FRAME_BUFFER_VALID) { /* drawn into the FBO */
    g_core->hw_frame = 1;
    g_core->hw_width = width;
    g_core->hw_height = height;
    return;
  }
  if (!data) return; /* dupe: keep previous frame */
  g_core->hw_frame = 0;
  if (dena_frame_convert(&g_core->frame, data, width, height, pitch,
                         (dena_pixel_format)g_core->pixel_format) != 0)
    fprintf(stderr, "dena: frame conversion failed\n");
}

static void hash_samples(const int16_t *s, size_t n) {
  if (!g_core->hashing) return;
  for (size_t i = 0; i < n; i++) {
    uint8_t b[2] = {(uint8_t)s[i], (uint8_t)((uint16_t)s[i] >> 8)};
    g_core->audio_hash = dena_fnv1a(g_core->audio_hash, b, 2);
  }
}

static void RETRO_CALLCONV audio_sample_cb(int16_t left, int16_t right) {
  int16_t s[2] = {left, right};
  hash_samples(s, 2);
  if (g_core->audio_sink) g_core->audio_sink(g_core->audio_user, s, 1);
}

static size_t RETRO_CALLCONV audio_batch_cb(const int16_t *data, size_t frames) {
  hash_samples(data, frames * 2);
  if (g_core->audio_sink) g_core->audio_sink(g_core->audio_user, data, frames);
  return frames;
}

static void RETRO_CALLCONV input_poll_cb(void) {}

static int16_t RETRO_CALLCONV input_state_cb(unsigned port, unsigned device,
                                             unsigned index, unsigned id) {
  if ((device & RETRO_DEVICE_MASK) == RETRO_DEVICE_POINTER) {
    if (port != 0 || index != 0) return 0;
    switch (id) {
      case RETRO_DEVICE_ID_POINTER_X: return g_core->pointer_x;
      case RETRO_DEVICE_ID_POINTER_Y: return g_core->pointer_y;
      case RETRO_DEVICE_ID_POINTER_PRESSED: return (int16_t)g_core->pointer_pressed;
      case RETRO_DEVICE_ID_POINTER_COUNT: return 1;
      default: return 0;
    }
  }
  if ((device & RETRO_DEVICE_MASK) == RETRO_DEVICE_ANALOG) {
    if (port >= DENA_MAX_PORTS || index > RETRO_DEVICE_INDEX_ANALOG_RIGHT || id > 1) return 0;
    return g_core->analog[port][index][id];
  }
  if (port >= DENA_MAX_PORTS || (device & RETRO_DEVICE_MASK) != RETRO_DEVICE_JOYPAD)
    return 0;
  if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)g_core->buttons[port];
  return id < 16 ? (int16_t)((g_core->buttons[port] >> id) & 1) : 0;
}

#define LOAD_SYM(name)                                                     \
  do {                                                                     \
    *(void **)(&c->name) = lib_sym(c->lib, #name);                         \
    if (!c->name) {                                                        \
      snprintf(err, errlen, "core is missing symbol %s", #name);           \
      lib_close(c->lib);                                                   \
      free(c);                                                             \
      return NULL;                                                         \
    }                                                                      \
  } while (0)

dena_core *dena_core_load(const char *path, char *err, size_t errlen) {
  if (g_core) {
    snprintf(err, errlen, "a core is already loaded in this process");
    return NULL;
  }
  dena_core *c = (dena_core *)calloc(1, sizeof *c);
  if (!c) {
    snprintf(err, errlen, "out of memory");
    return NULL;
  }
  c->lib = lib_open(path);
  if (!c->lib) {
    snprintf(err, errlen, "cannot load %s: %s", path, lib_error());
    free(c);
    return NULL;
  }
  LOAD_SYM(retro_init);
  LOAD_SYM(retro_deinit);
  LOAD_SYM(retro_api_version);
  LOAD_SYM(retro_get_system_info);
  LOAD_SYM(retro_get_system_av_info);
  LOAD_SYM(retro_set_environment);
  LOAD_SYM(retro_set_video_refresh);
  LOAD_SYM(retro_set_audio_sample);
  LOAD_SYM(retro_set_audio_sample_batch);
  LOAD_SYM(retro_set_input_poll);
  LOAD_SYM(retro_set_input_state);
  LOAD_SYM(retro_set_controller_port_device);
  LOAD_SYM(retro_run);
  LOAD_SYM(retro_serialize_size);
  LOAD_SYM(retro_serialize);
  LOAD_SYM(retro_unserialize);
  LOAD_SYM(retro_load_game);
  LOAD_SYM(retro_unload_game);
  LOAD_SYM(retro_get_memory_data);
  LOAD_SYM(retro_get_memory_size);
  *(void **)(&c->retro_cheat_reset) = lib_sym(c->lib, "retro_cheat_reset");
  *(void **)(&c->retro_cheat_set) = lib_sym(c->lib, "retro_cheat_set");

  if (c->retro_api_version() != RETRO_API_VERSION) {
    snprintf(err, errlen, "core API version %u, expected %u",
             c->retro_api_version(), RETRO_API_VERSION);
    lib_close(c->lib);
    free(c);
    return NULL;
  }
  const char *tmp = getenv("DENA_SYSTEM_DIR");
  if (!tmp) tmp = getenv("TMPDIR");
  if (!tmp) tmp = getenv("TEMP");
  snprintf(c->system_dir, sizeof c->system_dir, "%s", tmp ? tmp : ".");
  /* A core's own save files (PS2 memory cards, ps2.md) can go elsewhere. */
  const char *save = getenv("DENA_SAVE_DIR");
  snprintf(c->save_dir, sizeof c->save_dir, "%s",
           save && *save ? save : c->system_dir);
  c->pixel_format = RETRO_PIXEL_FORMAT_0RGB1555; /* libretro default */
  c->audio_hash = DENA_FNV_OFFSET;
  c->hashing = 1;
  g_core = c;
  c->retro_set_environment(environment_cb);
  c->retro_init();
  c->initialized = true;
  c->retro_set_video_refresh(video_cb);
  c->retro_set_audio_sample(audio_sample_cb);
  c->retro_set_audio_sample_batch(audio_batch_cb);
  c->retro_set_input_poll(input_poll_cb);
  c->retro_set_input_state(input_state_cb);
  /* Link cable (link-cable.md): cores that support it export this. */
  *(void **)(&c->link_attach) = lib_sym(c->lib, "dena_link_attach");
  if (c->link_attach) c->link_attach(dena_link_core_api());
  return c;
}

static void *read_file(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  void *buf = malloc(len > 0 ? (size_t)len : 1);
  if (buf && fread(buf, 1, (size_t)len, f) != (size_t)len) {
    free(buf);
    buf = NULL;
  }
  fclose(f);
  *size = (size_t)len;
  return buf;
}

int dena_core_load_game(dena_core *c, const char *rom_path, char *err,
                        size_t errlen) {
  struct retro_system_info sys;
  memset(&sys, 0, sizeof sys);
  c->retro_get_system_info(&sys);
  struct retro_game_info info;
  memset(&info, 0, sizeof info);
  if (rom_path) {
    c->rom_path = (char *)malloc(strlen(rom_path) + 1);
    if (!c->rom_path) {
      snprintf(err, errlen, "out of memory");
      return -1;
    }
    strcpy(c->rom_path, rom_path);
    info.path = c->rom_path;
    if (!sys.need_fullpath) {
      size_t size;
      c->rom_data = read_file(rom_path, &size);
      if (!c->rom_data) {
        snprintf(err, errlen, "cannot read %s", rom_path);
        return -1;
      }
      info.data = c->rom_data;
      info.size = size;
    }
  }
  if (!c->retro_load_game(rom_path ? &info : NULL)) {
    snprintf(err, errlen, "core refused the game");
    return -1;
  }
  c->game_loaded = true;
  for (unsigned p = 0; p < DENA_MAX_PORTS; p++)
    c->retro_set_controller_port_device(p, c->pad_device[p] ? c->pad_device[p] : RETRO_DEVICE_JOYPAD);
  return 0;
}

static int contains_nocase(const char *s, const char *word) {
  size_t n = strlen(word);
  for (; s && *s; s++) {
    size_t i = 0;
    while (i < n && s[i] && tolower((unsigned char)s[i]) == word[i]) i++;
    if (i == n) return 1;
  }
  return 0;
}

unsigned dena_find_multitap(const void *controller_info, unsigned port) {
  const struct retro_controller_info *info = controller_info;
  if (!info) return 0;
  /* The list ends with an entry without types; entry i is port i. */
  for (unsigned p = 0; info[p].types; p++) {
    if (p != port) continue;
    for (unsigned t = 0; t < info[p].num_types; t++) {
      const char *desc = info[p].types[t].desc;
      if (contains_nocase(desc, "multitap") || contains_nocase(desc, "multi-tap"))
        return info[p].types[t].id;
    }
    return 0;
  }
  return 0;
}

unsigned dena_find_pad_device(const void *controller_info, unsigned port) {
  const struct retro_controller_info *info = controller_info;
  if (!info) return 0;
  for (unsigned p = 0; info[p].types; p++) {
    if (p != port) continue;
    /* gamecube-wii.md: the Wii Remote with the Nunchuk, the first such
     * entry (Dolphin lists the MotionPlus one after it). */
    for (unsigned t = 0; t < info[p].num_types; t++) {
      const char *desc = info[p].types[t].desc;
      if (contains_nocase(desc, "nunchuk") && !contains_nocase(desc, "motionplus"))
        return info[p].types[t].id;
    }
    return 0;
  }
  return 0;
}

unsigned dena_core_multitap_device(const dena_core *c, unsigned port) {
  return c && port < DENA_MAX_PORTS ? c->multitap[port] : 0;
}

void dena_core_set_port_device(dena_core *c, unsigned port, unsigned device) {
  if (!c || !c->game_loaded || port >= DENA_MAX_PORTS) return;
  if (!device) device = c->pad_device[port] ? c->pad_device[port] : RETRO_DEVICE_JOYPAD;
  c->retro_set_controller_port_device(port, device);
}

void dena_core_set_buttons(dena_core *c, unsigned port, uint16_t buttons) {
  if (port < DENA_MAX_PORTS) c->buttons[port] = buttons;
}

void dena_core_set_analog(dena_core *c, unsigned port, unsigned stick, int16_t x, int16_t y) {
  if (port >= DENA_MAX_PORTS || stick > 1) return;
  c->analog[port][stick][0] = x;
  c->analog[port][stick][1] = y;
}

void dena_core_set_pointer(dena_core *c, int16_t x, int16_t y, int pressed) {
  c->pointer_x = x;
  c->pointer_y = y;
  c->pointer_pressed = pressed != 0;
}

void dena_core_set_hw_hooks(dena_core *c, const dena_hw_hooks *hooks) {
  c->hw_hooked = hooks && hooks->get_framebuffer && hooks->get_proc_address;
  if (c->hw_hooked) c->hw_hooks = *hooks;
}

int dena_core_hw_info(const dena_core *c, dena_hw_info *out) {
  if (!c->hw_requested) return 0;
  out->context_type = (int)c->hw.context_type;
  out->version_major = c->hw.version_major;
  out->version_minor = c->hw.version_minor;
  out->depth = c->hw.depth;
  out->stencil = c->hw.stencil;
  out->bottom_left_origin = c->hw.bottom_left_origin;
  return 1;
}

void dena_core_hw_context_reset(dena_core *c) {
  g_core = c;
  if (c->hw_requested && c->hw.context_reset) c->hw.context_reset();
}

void dena_core_hw_context_destroy(dena_core *c) {
  g_core = c;
  if (c->hw_requested && c->hw.context_destroy) c->hw.context_destroy();
}

int dena_core_hw_frame(const dena_core *c, unsigned *width, unsigned *height) {
  if (!c->hw_frame) return 0;
  *width = c->hw_width;
  *height = c->hw_height;
  return 1;
}

const char *dena_core_get_option(const dena_core *c, const char *key) {
  for (unsigned i = 0; i < c->option_count; i++)
    if (strcmp(c->options[i].key, key) == 0) return c->options[i].value;
  for (unsigned i = 0; i < c->default_count; i++)
    if (strcmp(c->defaults[i].key, key) == 0) return c->defaults[i].value;
  return NULL;
}

int dena_core_set_option(dena_core *c, const char *key, const char *value) {
  if (strlen(key) >= sizeof c->options[0].key || strlen(value) >= sizeof c->options[0].value)
    return -1;
  unsigned i = 0;
  while (i < c->option_count && strcmp(c->options[i].key, key) != 0) i++;
  if (i == c->option_count) {
    if (c->option_count == DENA_MAX_OPTIONS) return -1;
    c->option_count++;
    strcpy(c->options[i].key, key);
  }
  strcpy(c->options[i].value, value);
  c->options_changed = true;
  return 0;
}

void dena_core_run_frame(dena_core *c) {
  c->retro_run();
  c->frame_count++;
}

const dena_frame *dena_core_frame(const dena_core *c) { return &c->frame; }
uint64_t dena_core_audio_hash(const dena_core *c) { return c->audio_hash; }
unsigned dena_core_frame_count(const dena_core *c) { return c->frame_count; }

void dena_core_av_info(dena_core *c, dena_av_info *out) {
  struct retro_system_av_info av;
  memset(&av, 0, sizeof av);
  c->retro_get_system_av_info(&av);
  out->fps = av.timing.fps;
  out->sample_rate = av.timing.sample_rate;
  out->base_width = av.geometry.base_width;
  out->base_height = av.geometry.base_height;
  out->max_width = av.geometry.max_width ? av.geometry.max_width : av.geometry.base_width;
  out->max_height = av.geometry.max_height ? av.geometry.max_height : av.geometry.base_height;
  out->aspect_ratio = av.geometry.aspect_ratio > 0
                          ? av.geometry.aspect_ratio
                          : (float)av.geometry.base_width /
                                (float)(av.geometry.base_height ? av.geometry.base_height : 1);
}

void dena_core_set_audio_sink(dena_core *c, dena_audio_sink sink, void *user) {
  c->audio_sink = sink;
  c->audio_user = user;
}

void dena_core_set_hashing(dena_core *c, int enabled) { c->hashing = enabled; }

const void *dena_core_memory_map(dena_core *c) {
  return c && c->mmap.num_descriptors ? &c->mmap : NULL;
}

void *dena_core_memory(dena_core *c, unsigned id, size_t *size) {
  void *data = c->retro_get_memory_data(id);
  size_t n = c->retro_get_memory_size(id);
  if (!data || !n) {
    *size = 0;
    return NULL;
  }
  *size = n;
  return data;
}

size_t dena_core_state_size(dena_core *c) { return c->retro_serialize_size(); }

int dena_core_save_state(dena_core *c, void *buf, size_t size) {
  return c->retro_serialize(buf, size) ? 0 : -1;
}

int dena_core_load_state(dena_core *c, const void *buf, size_t size) {
  return c->retro_unserialize(buf, size) ? 0 : -1;
}

void dena_core_cheats_reset(dena_core *c) {
  if (c->retro_cheat_reset) c->retro_cheat_reset();
}

void dena_core_cheat_set(dena_core *c, unsigned index, int enabled, const char *code) {
  if (c->retro_cheat_set) c->retro_cheat_set(index, enabled != 0, code);
}

void dena_core_unload(dena_core *c) {
  if (!c) return;
  if (c->game_loaded) c->retro_unload_game();
  if (c->initialized) c->retro_deinit();
  if (c->link_attach) c->link_attach(NULL);
  lib_close(c->lib);
  free(c->rom_data);
  free(c->rom_path);
  dena_frame_free(&c->frame);
  for (unsigned i = 0; i < c->default_count; i++) {
    free(c->defaults[i].key);
    free(c->defaults[i].value);
  }
  free(c->defaults);
  free(c->mmap_descriptors);
  free(c);
  g_core = NULL;
}
