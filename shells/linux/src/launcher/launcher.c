// SPDX-License-Identifier: GPL-3.0-or-later
// dena-launcher: the shared Flutter UI on KMS/DRM for Linux handhelds.
// Display: DRM mode set + GBM surface + EGL; Flutter renders through the
// embedder API (engine loaded at run time); evdev buttons become Flutter key
// events through the device profile; games run in-process through the shared
// runner (session.h). Spec: docs/specs/embedder.md, handheld-session.md
//
// Usage: dena-launcher <bundle> [profile.conf]
//   <bundle> holds flutter_assets/, icudtl.dat and lib/libapp.so (AOT).
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>
#include <time.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <gbm.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include "audio.h"
#include "dena/embedder_core.h"
#include "dena/input.h"
#include "dena/platform.h"
#include "embedder.h"
#include "session.h"

#define MAX_TASKS 256

static void die(const char *what) {
  fprintf(stderr, "dena-launcher: %s\n", what);
  exit(1);
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// ---- Display: DRM, GBM, EGL ------------------------------------------------

static struct {
  int fd;
  uint32_t connector, crtc;
  int crtc_index;  // in the card's CRTC list (vblank waits)
  drmModeModeInfo mode;
  drmModeCrtc *saved;
  struct gbm_device *gbm;
  struct gbm_surface *surface;
  EGLDisplay egl;
  EGLConfig config;
  EGLContext context, resource_context;
  EGLSurface egl_surface;
  struct gbm_bo *shown;          // on screen
  bool mode_set;
  atomic_uint_fast64_t last_flip_ns;
  uint64_t period_ns;
  int rotate;
  struct dena_transform transform;
} D;

static void fb_destroy(struct gbm_bo *bo, void *data) {
  uint32_t fb = (uint32_t)(uintptr_t)data;
  if (fb) drmModeRmFB(gbm_device_get_fd(gbm_bo_get_device(bo)), fb);
}

// The DRM framebuffer for a GBM buffer, made once and kept on the buffer.
static uint32_t fb_for(struct gbm_bo *bo) {
  uint32_t fb = (uint32_t)(uintptr_t)gbm_bo_get_user_data(bo);
  if (fb) return fb;
  uint32_t handles[4] = {gbm_bo_get_handle(bo).u32};
  uint32_t strides[4] = {gbm_bo_get_stride(bo)};
  uint32_t offsets[4] = {0};
  if (drmModeAddFB2(D.fd, gbm_bo_get_width(bo), gbm_bo_get_height(bo),
                    gbm_bo_get_format(bo), handles, strides, offsets, &fb, 0))
    return 0;
  gbm_bo_set_user_data(bo, (void *)(uintptr_t)fb, fb_destroy);
  return fb;
}

// Refresh in millihertz from the mode timings (59940 for 59.94 Hz).
static int refresh_mhz(const drmModeModeInfo *m) {
  if (m->htotal && m->vtotal)
    return (int)((uint64_t)m->clock * 1000000ull / ((uint64_t)m->htotal * m->vtotal));
  return (int)m->vrefresh * 1000;
}

static void open_display(int want_w, int want_h) {
  char path[32];
  drmModeRes *res = NULL;
  drmModeConnector *conn = NULL;
  for (int i = 0; i < 8 && !conn; i++) {
    snprintf(path, sizeof path, "/dev/dri/card%d", i);
    D.fd = open(path, O_RDWR | O_CLOEXEC);
    if (D.fd < 0) continue;
    res = drmModeGetResources(D.fd);
    for (int c = 0; res && c < res->count_connectors && !conn; c++) {
      drmModeConnector *k = drmModeGetConnector(D.fd, res->connectors[c]);
      if (k && k->connection == DRM_MODE_CONNECTED && k->count_modes > 0)
        conn = k;
      else if (k)
        drmModeFreeConnector(k);
    }
    if (!conn) {
      if (res) drmModeFreeResources(res);
      close(D.fd);
    }
  }
  if (!conn) die("no connected display");

  struct dena_mode modes[64];
  int n = conn->count_modes < 64 ? conn->count_modes : 64;
  for (int i = 0; i < n; i++) {
    drmModeModeInfo *m = &conn->modes[i];
    modes[i] = (struct dena_mode){m->hdisplay, m->vdisplay,
                                  refresh_mhz(m),
                                  (m->type & DRM_MODE_TYPE_PREFERRED) != 0};
  }
  D.mode = conn->modes[dena_pick_mode(modes, n, want_w, want_h)];
  D.connector = conn->connector_id;
  int mhz = refresh_mhz(&D.mode);
  D.period_ns = 1000000000000ull / (uint64_t)(mhz > 0 ? mhz : 60000);

  // The CRTC the connector's encoder drives (or the first one it can use).
  drmModeEncoder *enc = conn->encoder_id ? drmModeGetEncoder(D.fd, conn->encoder_id) : NULL;
  if (enc && enc->crtc_id) {
    D.crtc = enc->crtc_id;
  } else {
    for (int e = 0; e < conn->count_encoders && !D.crtc; e++) {
      drmModeEncoder *k = drmModeGetEncoder(D.fd, conn->encoders[e]);
      for (int c = 0; k && c < res->count_crtcs; c++)
        if (k->possible_crtcs & (1u << c)) {
          D.crtc = res->crtcs[c];
          break;
        }
      if (k) drmModeFreeEncoder(k);
    }
  }
  if (enc) drmModeFreeEncoder(enc);
  if (!D.crtc) die("no CRTC for the display");
  for (int c = 0; c < res->count_crtcs; c++)
    if (res->crtcs[c] == D.crtc) D.crtc_index = c;
  D.saved = drmModeGetCrtc(D.fd, D.crtc);
  drmModeFreeConnector(conn);
  drmModeFreeResources(res);

  D.gbm = gbm_create_device(D.fd);
  if (!D.gbm) die("gbm_create_device failed");
  D.surface = gbm_surface_create(D.gbm, D.mode.hdisplay, D.mode.vdisplay,
                                 GBM_FORMAT_XRGB8888,
                                 GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
  if (!D.surface) die("gbm_surface_create failed");

  PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  D.egl = get_platform_display
              ? get_platform_display(EGL_PLATFORM_GBM_KHR, D.gbm, NULL)
              : eglGetDisplay((EGLNativeDisplayType)D.gbm);
  if (D.egl == EGL_NO_DISPLAY || !eglInitialize(D.egl, NULL, NULL))
    die("EGL initialisation failed");
  eglBindAPI(EGL_OPENGL_ES_API);

  // A config whose native visual is the scan-out format.
  static const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                                 EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                 EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0,
                                 EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                 EGL_NONE};
  EGLConfig configs[64];
  EGLint count = 0;
  eglChooseConfig(D.egl, attrs, configs, 64, &count);
  for (EGLint i = 0; i < count && !D.config; i++) {
    EGLint visual;
    if (eglGetConfigAttrib(D.egl, configs[i], EGL_NATIVE_VISUAL_ID, &visual) &&
        visual == GBM_FORMAT_XRGB8888)
      D.config = configs[i];
  }
  if (!D.config && count > 0) D.config = configs[0];
  if (!D.config) die("no EGL config");

  static const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  D.context = eglCreateContext(D.egl, D.config, EGL_NO_CONTEXT, ctx_attrs);
  D.resource_context = eglCreateContext(D.egl, D.config, D.context, ctx_attrs);
  D.egl_surface = eglCreateWindowSurface(D.egl, D.config,
                                         (EGLNativeWindowType)D.surface, NULL);
  if (D.context == EGL_NO_CONTEXT || D.resource_context == EGL_NO_CONTEXT ||
      D.egl_surface == EGL_NO_SURFACE)
    die("EGL context or surface failed");
  atomic_store(&D.last_flip_ns, now_ns());
}

static void flip_done(int fd, unsigned seq, unsigned sec, unsigned usec,
                      void *data) {
  (void)fd, (void)seq, (void)sec, (void)usec;
  *(bool *)data = false;
}

// Waits for a queued page flip (runs on the raster thread).
static void wait_flip(bool *pending) {
  drmEventContext ev = {.version = 2, .page_flip_handler = flip_done};
  while (*pending) {
    struct pollfd p = {.fd = D.fd, .events = POLLIN};
    if (poll(&p, 1, 100) <= 0) break;  // a lost flip must not hang the UI
    drmHandleEvent(D.fd, &ev);
  }
  atomic_store(&D.last_flip_ns, now_ns());
}

static void close_display(void) {
  if (D.saved) {
    drmModeSetCrtc(D.fd, D.saved->crtc_id, D.saved->buffer_id, D.saved->x,
                   D.saved->y, &D.connector, 1, &D.saved->mode);
    drmModeFreeCrtc(D.saved);
  }
}

// ---- Flutter renderer callbacks (raster thread) ----------------------------

static bool gl_make_current(void *u) {
  (void)u;
  return eglMakeCurrent(D.egl, D.egl_surface, D.egl_surface, D.context);
}

static bool gl_clear_current(void *u) {
  (void)u;
  return eglMakeCurrent(D.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

static bool gl_make_resource_current(void *u) {
  (void)u;
  return eglMakeCurrent(D.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, D.resource_context);
}

static uint32_t gl_fbo(void *u) {
  (void)u;
  return 0;
}

static void *gl_proc(void *u, const char *name) {
  (void)u;
  return (void *)eglGetProcAddress(name);
}

static FlutterTransformation gl_transform(void *u) {
  (void)u;
  const double *m = D.transform.m;
  return (FlutterTransformation){m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8]};
}

// Once, on the raster thread with Flutter's context current: which GL driver
// draws the UI. llvmpipe/softpipe means Mesa found no GPU (no panfrost or no
// kmsro pairing for the display card) and every frame is drawn on the CPU.
static uint64_t start_ns;  // main() entry, for the first-frame time

static void log_renderer(void) {
  const char *renderer = (const char *)glGetString(GL_RENDERER);
  const char *version = (const char *)glGetString(GL_VERSION);
  fprintf(stderr, "dena-launcher: first frame %llu ms after start; GL %s (%s), %dx%d at %d.%03d Hz\n",
          (unsigned long long)((now_ns() - start_ns) / 1000000ull),
          renderer ? renderer : "?", version ? version : "?", D.mode.hdisplay,
          D.mode.vdisplay, refresh_mhz(&D.mode) / 1000, refresh_mhz(&D.mode) % 1000);
  if (renderer && (strstr(renderer, "llvmpipe") || strstr(renderer, "softpipe")))
    fprintf(stderr, "dena-launcher: warning: software rendering, the GPU is not in use\n");
}

// Frame pacing for the boot log: every 10 s with frames in it, how many
// were shown and how many missed their vblank while the UI was animating
// (a gap of more than 1.5 refresh periods between two consecutive frames).
static struct {
  uint64_t window_start, last;
  unsigned frames, late;
  uint64_t worst_ns;
} pace;

static void count_frame(uint64_t now) {
  if (!pace.window_start) pace.window_start = now;
  uint64_t gap = pace.last ? now - pace.last : 0;
  // Gaps over 250 ms are idle time (nothing to draw), not dropped frames.
  if (gap > D.period_ns * 3 / 2 && gap < 250000000ull) {
    pace.late++;
    if (gap > pace.worst_ns) pace.worst_ns = gap;
  }
  pace.last = now;
  pace.frames++;
  if (now - pace.window_start >= 10000000000ull) {
    fprintf(stderr, "dena-launcher: %u frames in 10 s, %u late (worst %.1f ms)\n",
            pace.frames, pace.late, (double)pace.worst_ns / 1e6);
    pace.window_start = now;
    pace.frames = pace.late = 0;
    pace.worst_ns = 0;
  }
}

static bool gl_present(void *u) {
  (void)u;
  static bool logged;
  if (!logged) {
    logged = true;
    log_renderer();
  }
  if (!eglSwapBuffers(D.egl, D.egl_surface)) return false;
  struct gbm_bo *bo = gbm_surface_lock_front_buffer(D.surface);
  if (!bo) return false;
  uint32_t fb = fb_for(bo);
  if (!fb) {
    gbm_surface_release_buffer(D.surface, bo);
    return false;
  }
  if (!D.mode_set) {
    if (drmModeSetCrtc(D.fd, D.crtc, fb, 0, 0, &D.connector, 1, &D.mode))
      return false;
    D.mode_set = true;
    atomic_store(&D.last_flip_ns, now_ns());
  } else {
    bool pending = true;
    if (drmModePageFlip(D.fd, D.crtc, fb, DRM_MODE_PAGE_FLIP_EVENT, &pending) == 0)
      wait_flip(&pending);
  }
  if (D.shown) gbm_surface_release_buffer(D.surface, D.shown);
  D.shown = bo;
  count_frame(atomic_load(&D.last_flip_ns));
  return true;
}

// ---- Platform task runner (main thread) ------------------------------------

static FlutterEngineProcTable F;
static FLUTTER_API_SYMBOL(FlutterEngine) engine;
static pthread_t main_thread;
static int wake_fd;

static struct task {
  FlutterTask task;
  uint64_t when;
  intptr_t vsync_baton;  // nonzero: a vsync answer, not an engine task
} tasks[MAX_TASKS];
static int task_count;
static pthread_mutex_t task_lock = PTHREAD_MUTEX_INITIALIZER;

static void post(struct task t) {
  pthread_mutex_lock(&task_lock);
  if (task_count < MAX_TASKS) tasks[task_count++] = t;
  else fprintf(stderr, "dena-launcher: task queue full\n");
  pthread_mutex_unlock(&task_lock);
  uint64_t one = 1;
  if (write(wake_fd, &one, sizeof one) < 0) { /* the loop wakes on its timeout */ }
}

static void post_task(FlutterTask task, uint64_t target_ns, void *u) {
  (void)u;
  post((struct task){.task = task, .when = target_ns});
}

static bool on_main_thread(void *u) {
  (void)u;
  return pthread_equal(pthread_self(), main_thread);
}

// Vsync: answered at the next vblank, extrapolated from the last flip.
static void vsync(void *u, intptr_t baton) {
  (void)u;
  uint64_t last = atomic_load(&D.last_flip_ns), now = F.GetCurrentTime();
  uint64_t next = last + D.period_ns;
  while (next < now) next += D.period_ns;
  post((struct task){.when = next, .vsync_baton = baton});
}

// ---- Game sessions (handheld-session.md) -----------------------------------

#define GAME_TEXTURE 1  // the Dart session shows Texture(textureId: 1)
#define GL_RGBA8_FORMAT 0x8058  // GL_RGBA8: the format Flutter expects

static void game_frame_ready(void *u) {
  (void)u;
  F.MarkExternalTextureFrameAvailable(engine, GAME_TEXTURE);
}

static void send_to_dart(void *u, const char *channel, const uint8_t *data, size_t len) {
  (void)u;
  FlutterPlatformMessage msg = {.struct_size = sizeof msg, .channel = channel,
                                .message = data, .message_size = len};
  F.SendPlatformMessage(engine, &msg);
}

// Main thread: GameHostApi calls go to the session; anything else gets the
// empty reply Dart reads as "not implemented".
static void on_platform_message(const FlutterPlatformMessage *m, void *u) {
  (void)u;
  uint8_t *reply = NULL;
  size_t len = 0;
  bool handled = dena_session_message(m->channel, m->message, m->message_size, &reply, &len);
  if (m->response_handle)
    F.SendPlatformMessageResponse(engine, m->response_handle, handled ? reply : NULL,
                                  handled ? len : 0);
  free(reply);
}

// Raster thread (Flutter's context is current): the newest game frame as a
// GL texture, uploaded only when it changed.
static bool game_texture(void *u, int64_t id, size_t w, size_t h, FlutterOpenGLTexture *out) {
  (void)u, (void)w, (void)h;
  static GLuint tex;
  static uint32_t tex_w, tex_h;
  const uint8_t *rgba;
  uint32_t fw, fh;
  bool fresh;
  if (id != GAME_TEXTURE) return false;
  unsigned gpu = dena_session_gpu_frame(&fw, &fh);
  if (gpu) {  // a GPU core: its own texture, already finished
    *out = (FlutterOpenGLTexture){.target = GL_TEXTURE_2D, .name = gpu,
                                  .format = GL_RGBA8_FORMAT, .width = fw, .height = fh};
    return true;
  }
  if (!dena_session_frame(&rgba, &fw, &fh, &fresh)) return false;
  if (!tex) {
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    fresh = true;
  }
  glBindTexture(GL_TEXTURE_2D, tex);
  if (fresh || fw != tex_w || fh != tex_h) {
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    if (fw != tex_w || fh != tex_h) {
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)fw, (GLsizei)fh, 0, GL_RGBA,
                   GL_UNSIGNED_BYTE, rgba);
      tex_w = fw;
      tex_h = fh;
    } else {
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)fw, (GLsizei)fh, GL_RGBA,
                      GL_UNSIGNED_BYTE, rgba);
    }
  }
  *out = (FlutterOpenGLTexture){.target = GL_TEXTURE_2D, .name = tex,
                                .format = GL_RGBA8_FORMAT, .width = fw, .height = fh};
  return true;
}

// Runs due tasks; returns the poll timeout (ms) until the next one.
static int run_due_tasks(void) {
  for (;;) {
    uint64_t now = F.GetCurrentTime(), soonest = UINT64_MAX;
    struct task due;
    bool found = false;
    pthread_mutex_lock(&task_lock);
    for (int i = 0; i < task_count; i++) {
      if (tasks[i].when <= now) {
        due = tasks[i];
        tasks[i] = tasks[--task_count];
        found = true;
        break;
      }
      if (tasks[i].when < soonest) soonest = tasks[i].when;
    }
    pthread_mutex_unlock(&task_lock);
    if (!found) {
      if (soonest == UINT64_MAX) return -1;
      return (int)((soonest - now) / 1000000ull) + 1;
    }
    if (due.vsync_baton)
      F.OnVsync(engine, due.vsync_baton, due.when, due.when + D.period_ns);
    else
      F.RunTask(engine, &due.task);
  }
}

// ---- Input: evdev → router (dena/input.h) → game or Flutter key ------------

static struct dena_input router;
static struct {
  int fd;          // -1: free
  char name[16];   // "event3"
  bool dropping;   // SYN_DROPPED seen: skip events until the next SYN_REPORT
} nodes[DENA_INPUT_DEVICES];
static int watch_fd = -1;  // inotify on /dev/input: pads plugged in later
static bool ui_down[DENA_KEY_VOLUME_DOWN + 1];  // actions whose press went to Flutter

static void send_key(int action, FlutterKeyEventType type, uint64_t usec) {
  struct dena_flutter_key k = dena_flutter_key(action);
  if (!k.logical) return;  // power belongs to dena-powerd; volume is handled in route()
  FlutterKeyEvent ev = {
      .struct_size = sizeof ev,
      .timestamp = (double)usec,
      .type = type,
      .physical = k.physical,
      .logical = k.logical,
      .character = NULL,
      .synthesized = false,
      .device_type = kFlutterKeyEventDeviceTypeGamepad,
  };
  F.SendKeyEvent(engine, &ev, NULL, NULL);
  // The framework pairs each key event with a raw one on flutter/keyevent
  // (a repeat is another keydown); specifiedLogicalKey keeps the logical key
  // we chose.
  char json[256];
  int len = snprintf(json, sizeof json,
                     "{\"type\":\"%s\",\"keymap\":\"linux\",\"toolkit\":\"gtk\","
                     "\"scanCode\":%d,\"keyCode\":0,\"modifiers\":0,"
                     "\"unicodeScalarValues\":0,\"specifiedLogicalKey\":%llu}",
                     type == kFlutterKeyEventTypeUp ? "keyup" : "keydown", action + 1000,
                     (unsigned long long)k.logical);
  FlutterPlatformMessage msg = {.struct_size = sizeof msg,
                                .channel = "flutter/keyevent",
                                .message = (const uint8_t *)json,
                                .message_size = (size_t)len};
  F.SendPlatformMessage(engine, &msg);
}

// A running game takes its buttons directly; everything else is a key for
// the Flutter UI. A release goes where its press went, so neither side is
// left with a key held down.
static void route(const struct dena_input_event *e) {
  int a = e->action;
  if (a == DENA_KEY_VOLUME_UP || a == DENA_KEY_VOLUME_DOWN) {
    // Volume keys (handheld-session.md), in the UI and in games alike.
    if (e->kind != DENA_INPUT_UP) dena_audio_volume_key(a == DENA_KEY_VOLUME_UP ? 1 : -1);
    return;
  }
  if (a < 0 || a > DENA_KEY_MENU || (a >= 16 && a != DENA_KEY_MENU)) return;  // power: dena-powerd
  if (e->kind == DENA_INPUT_REPEAT) {  // held D-pad: menu navigation only
    if (ui_down[a] && !dena_session_playing())
      send_key(a, kFlutterKeyEventTypeRepeat, e->usec);
    return;
  }
  bool down = e->kind == DENA_INPUT_DOWN;
  if (dena_session_input(a, down, (int64_t)e->usec * 1000)) return;
  if (down == ui_down[a]) return;  // a release whose press the game took
  ui_down[a] = down;
  send_key(a, down ? kFlutterKeyEventTypeDown : kFlutterKeyEventTypeUp, e->usec);
}

static void route_all(const struct dena_input_event *ev, int n) {
  for (int i = 0; i < n; i++) route(&ev[i]);
}

static void open_node(const char *name) {
  if (strncmp(name, "event", 5) != 0 || strlen(name) >= sizeof nodes[0].name) return;
  int free_slot = -1;
  for (int i = 0; i < DENA_INPUT_DEVICES; i++) {
    if (nodes[i].fd >= 0 && strcmp(nodes[i].name, name) == 0) return;  // open already
    if (nodes[i].fd < 0 && free_slot < 0) free_slot = i;
  }
  if (free_slot < 0) return;
  char path[300];
  snprintf(path, sizeof path, "/dev/input/%s", name);
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return;  // not ready yet: the IN_ATTRIB that follows retries
  int clock = CLOCK_MONOTONIC;  // event times comparable with the runner's
  ioctl(fd, EVIOCSCLOCKID, &clock);
  char label[128] = "?";
  ioctl(fd, EVIOCGNAME(sizeof label), label);
  fprintf(stderr, "dena-launcher: input %s (%s)\n", name, label);
  nodes[free_slot].fd = fd;
  nodes[free_slot].dropping = false;
  snprintf(nodes[free_slot].name, sizeof nodes[0].name, "%s", name);
}

static void close_node(int i) {
  struct dena_input_event ev[DENA_INPUT_HELD * 2];
  route_all(ev, dena_input_remove(&router, i, now_ns() / 1000, ev, DENA_INPUT_HELD * 2));
  close(nodes[i].fd);
  nodes[i].fd = -1;
}

static void open_inputs(void) {
  for (int i = 0; i < DENA_INPUT_DEVICES; i++) nodes[i].fd = -1;
  watch_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (watch_fd >= 0 && inotify_add_watch(watch_fd, "/dev/input", IN_CREATE | IN_ATTRIB | IN_DELETE) < 0) {
    close(watch_fd);
    watch_fd = -1;
  }
  DIR *dir = opendir("/dev/input");
  struct dirent *e;
  while (dir && (e = readdir(dir))) open_node(e->d_name);
  if (dir) closedir(dir);
}

static void read_watch(void) {
  char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
  ssize_t len;
  while ((len = read(watch_fd, buf, sizeof buf)) > 0) {
    for (char *p = buf; p < buf + len;) {
      const struct inotify_event *ie = (const struct inotify_event *)p;
      p += sizeof *ie + ie->len;
      if (!ie->len) continue;
      if (ie->mask & IN_DELETE) {
        for (int i = 0; i < DENA_INPUT_DEVICES; i++)
          if (nodes[i].fd >= 0 && strcmp(nodes[i].name, ie->name) == 0) close_node(i);
      } else {
        open_node(ie->name);
      }
    }
  }
}

// After SYN_DROPPED the kernel's own state is the truth: read it back.
static void resync_node(int i, uint64_t usec) {
  unsigned long bits[KEY_MAX / (8 * sizeof(long)) + 1];
  memset(bits, 0, sizeof bits);
  int keys[DENA_INPUT_HELD], n = 0, hat[8] = {0};
  if (ioctl(nodes[i].fd, EVIOCGKEY(sizeof bits), bits) >= 0)
    for (int c = 1; c <= KEY_MAX && n < DENA_INPUT_HELD; c++)
      if (bits[c / (8 * sizeof(long))] & (1ul << (c % (8 * sizeof(long))))) keys[n++] = c;
  for (int a = 0; a < 8; a++) {
    struct input_absinfo abs;
    if (ioctl(nodes[i].fd, EVIOCGABS(ABS_HAT0X + a), &abs) == 0) hat[a] = abs.value;
  }
  struct dena_input_event ev[DENA_INPUT_HELD * 2];
  route_all(ev, dena_input_sync(&router, i, keys, n, hat, usec, ev, DENA_INPUT_HELD * 2));
}

static void read_node(int i) {
  struct input_event e;
  ssize_t got;
  while ((got = read(nodes[i].fd, &e, sizeof e)) == sizeof e) {
    uint64_t usec = (uint64_t)e.input_event_sec * 1000000ull + e.input_event_usec;
    struct dena_input_event ev[DENA_INPUT_MAX_OUT];
    if (e.type == EV_SYN && e.code == SYN_DROPPED) {
      nodes[i].dropping = true;
    } else if (nodes[i].dropping) {
      if (e.type == EV_SYN && e.code == SYN_REPORT) {
        nodes[i].dropping = false;
        resync_node(i, usec);
      }
    } else if (e.type == EV_KEY) {
      route_all(ev, dena_input_key(&router, i, e.code, e.value, usec, ev));
    } else if (e.type == EV_ABS && e.code >= ABS_HAT0X && e.code <= ABS_HAT3Y) {
      route_all(ev, dena_input_hat(&router, i, e.code - ABS_HAT0X, e.value, usec, ev));
    }
  }
  if (got < 0 && errno != EAGAIN && errno != EINTR) close_node(i);  // ENODEV: unplugged
}

// Held D-pad directions: the next repeat, if one is due.
static void tick_inputs(void) {
  struct dena_input_event ev;
  if (dena_input_tick(&router, now_ns() / 1000, &ev)) route(&ev);
}

// ---- Startup ----------------------------------------------------------------

static size_t read_file(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  size_t n = fread(buf, 1, cap - 1, f);
  fclose(f);
  buf[n] = '\0';
  return n;
}

static const struct dena_profile *load_profile(const char *file) {
  static struct dena_profile builtin[8], custom;
  static char text[16384];
  if (file) {
    if (read_file(file, text, sizeof text) && dena_profile_parse(text, &custom) == 0)
      return &custom;
    fprintf(stderr, "dena-launcher: bad profile %s, using the built-in ones\n", file);
  }
  int n = dena_builtin_profiles(builtin, 8);
  size_t len = read_file("/proc/device-tree/compatible", text, sizeof text);
  const struct dena_profile *p = dena_profile_pick(builtin, n, text, len);
  return p ? p : &builtin[0];
}

int main(int argc, char **argv) {
  start_ns = now_ns();
  if (argc < 2) {
    fprintf(stderr, "usage: dena-launcher <bundle> [profile.conf]\n");
    return 2;
  }
  const char *bundle = argv[1];
  const struct dena_profile *profile = load_profile(argc > 2 ? argv[2] : NULL);
  fprintf(stderr, "dena-launcher: profile %s\n", profile->id);

  void *lib = dlopen("libflutter_engine.so", RTLD_NOW | RTLD_LOCAL);
  if (!lib) die(dlerror());
  FlutterEngineResult (*get_procs)(FlutterEngineProcTable *) =
      (FlutterEngineResult(*)(FlutterEngineProcTable *))dlsym(lib, "FlutterEngineGetProcAddresses");
  F.struct_size = sizeof F;
  if (!get_procs || get_procs(&F) != kSuccess) die("not a Flutter engine library");

  open_display(profile->width, profile->height);
  D.rotate = profile->rotate;
  dena_rotation(D.rotate, D.mode.hdisplay, D.mode.vdisplay, &D.transform);
  dena_input_init(&router, profile, NULL);
  open_inputs();

  main_thread = pthread_self();
  wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  sigset_t sigs;
  sigemptyset(&sigs);
  sigaddset(&sigs, SIGINT);
  sigaddset(&sigs, SIGTERM);
  pthread_sigmask(SIG_BLOCK, &sigs, NULL);  // engine threads inherit the mask
  int sig_fd = signalfd(-1, &sigs, SFD_NONBLOCK | SFD_CLOEXEC);

  static char assets[512], icu[512], aot[512];
  snprintf(assets, sizeof assets, "%s/flutter_assets", bundle);
  snprintf(icu, sizeof icu, "%s/icudtl.dat", bundle);
  snprintf(aot, sizeof aot, "%s/lib/libapp.so", bundle);

  FlutterRendererConfig renderer = {.type = kOpenGL};
  renderer.open_gl = (FlutterOpenGLRendererConfig){
      .struct_size = sizeof(FlutterOpenGLRendererConfig),
      .make_current = gl_make_current,
      .clear_current = gl_clear_current,
      .present = gl_present,
      .fbo_callback = gl_fbo,
      .make_resource_current = gl_make_resource_current,
      .surface_transformation = gl_transform,
      .gl_proc_resolver = gl_proc,
      .gl_external_texture_frame_callback = game_texture,
  };
  FlutterTaskRunnerDescription platform = {
      .struct_size = sizeof platform,
      .runs_task_on_current_thread_callback = on_main_thread,
      .post_task_callback = post_task,
      .identifier = 1,
  };
  FlutterCustomTaskRunners runners = {.struct_size = sizeof runners,
                                      .platform_task_runner = &platform};
  FlutterProjectArgs args = {
      .struct_size = sizeof args,
      .assets_path = assets,
      .icu_data_path = icu,
      .custom_task_runners = &runners,
      .vsync_callback = vsync,
      .platform_message_callback = on_platform_message,
  };
  const char *card = getenv("DENA_CARD");
  const char *pcm = dena_audio_setup(profile, card);
  struct dena_session_config session = {
      .drm_fd = D.fd,
      .crtc_index = D.crtc_index,
      .refresh_mhz = refresh_mhz(&D.mode),
      .screen_width = (int)D.transform.logical_width,
      .screen_height = (int)D.transform.logical_height,
      .audio_card = pcm,
      .card = card && *card ? card : ".",
      .egl_display = D.egl,
      .egl_share_context = D.resource_context,
      .frame_ready = game_frame_ready,
      .send = send_to_dart,
  };
  dena_session_init(&session);

  FlutterEngineAOTData aot_data = NULL;
  // A debug (JIT) engine compiles the whole app on the device at every start
  // and runs it unoptimised: only for development (embedder.md, Build inputs).
  fprintf(stderr, "dena-launcher: %s\n", F.RunsAOTCompiledDartCode()
                                              ? "release engine, AOT app"
                                              : "warning: debug engine, JIT app (slow start, slow UI)");
  if (F.RunsAOTCompiledDartCode()) {
    FlutterEngineAOTDataSource src = {.type = kFlutterEngineAOTDataSourceTypeElfPath,
                                      .elf_path = aot};
    if (F.CreateAOTData(&src, &aot_data) != kSuccess) die("cannot load lib/libapp.so");
    args.aot_data = aot_data;
  }
  if (F.Run(FLUTTER_ENGINE_VERSION, &renderer, &args, NULL, &engine) != kSuccess)
    die("the Flutter engine did not start");

  FlutterWindowMetricsEvent metrics = {
      .struct_size = sizeof metrics,
      .width = (size_t)D.transform.logical_width,
      .height = (size_t)D.transform.logical_height,
      .pixel_ratio = 1.0,
  };
  F.SendWindowMetricsEvent(engine, &metrics);
  // Handhelds have no light/dark setting: report dark, the app's default, so
  // the "system" theme mode matches it (theming.md).
  static const char settings[] =
      "{\"textScaleFactor\":1.0,\"alwaysUse24HourFormat\":true,\"platformBrightness\":\"dark\"}";
  send_to_dart(NULL, "flutter/settings", (const uint8_t *)settings, sizeof settings - 1);
  F.RegisterExternalTexture(engine, GAME_TEXTURE);

  for (;;) {
    tick_inputs();
    int timeout = run_due_tasks();
    int repeat = dena_input_timeout_ms(&router, now_ns() / 1000);
    if (repeat >= 0 && (timeout < 0 || repeat < timeout)) timeout = repeat;
    struct pollfd fds[DENA_INPUT_DEVICES + 3];
    int node_at[DENA_INPUT_DEVICES + 3];
    fds[0] = (struct pollfd){.fd = wake_fd, .events = POLLIN};
    fds[1] = (struct pollfd){.fd = sig_fd, .events = POLLIN};
    fds[2] = (struct pollfd){.fd = watch_fd, .events = POLLIN};  // -1: skipped
    nfds_t n = 3;
    for (int i = 0; i < DENA_INPUT_DEVICES; i++)
      if (nodes[i].fd >= 0) {
        node_at[n] = i;
        fds[n++] = (struct pollfd){.fd = nodes[i].fd, .events = POLLIN};
      }
    if (poll(fds, n, timeout) < 0 && errno != EINTR) break;
    if (fds[0].revents & POLLIN) {
      uint64_t v;
      if (read(wake_fd, &v, sizeof v) < 0) { /* drained */ }
    }
    if (fds[1].revents & POLLIN) break;  // SIGTERM / SIGINT: quit
    for (nfds_t k = 3; k < n; k++)
      if (fds[k].revents & (POLLIN | POLLERR | POLLHUP)) read_node(node_at[k]);
    if (fds[2].revents & POLLIN) read_watch();
  }

  dena_session_shutdown();  // saves a running game first
  F.Shutdown(engine);
  if (aot_data) F.CollectAOTData(aot_data);
  close_display();
  return 0;
}
