/* dena-harness: headless test runner. Spec: docs/specs/test-harness.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dena/host.h"

#if defined(_WIN32)
#define MODULE_SUFFIX ".dll"
#elif defined(__APPLE__)
#define MODULE_SUFFIX ".dylib"
#else
#define MODULE_SUFFIX ".so"
#endif

enum { EXIT_PASS = 0, EXIT_FAIL = 1, EXIT_USAGE = 2, EXIT_CORE = 3 };

typedef struct {
  const char *core;
  const char *rom;
  const char *replay;
  const char *dump_ppm;
  unsigned frames;
  unsigned after;
  int strict_state;
} run_opts;

typedef struct {
  unsigned frames, width, height;
  uint64_t frame_hash, audio_hash;
} run_result;

static int usage(void) {
  fprintf(stderr,
          "usage:\n"
          "  dena-harness run       --core <lib> [--rom <f>] --frames <N> "
          "[--replay <f>] [--dump-ppm <out.ppm>]\n"
          "  dena-harness roundtrip --core <lib> [--rom <f>] --frames <N> "
          "[--replay <f>] [--after <K>] [--strict-state]\n"
          "  dena-harness golden    <manifest> [--cores-dir <d>] "
          "[--roms-dir <d>] [--replays-dir <d>]\n");
  return EXIT_USAGE;
}

static int parse_uint(const char *s, unsigned *out) {
  char *end;
  unsigned long v = strtoul(s, &end, 10);
  if (!*s || *end || v > 0xffffffffUL) return -1;
  *out = (unsigned)v;
  return 0;
}

static int parse_run_opts(int argc, char **argv, run_opts *o) {
  memset(o, 0, sizeof *o);
  o->after = 60;
  int have_frames = 0;
  for (int i = 0; i < argc; i += 2) {
    const char *a = argv[i];
    const char *v = i + 1 < argc ? argv[i + 1] : NULL;
    if (!strcmp(a, "--strict-state")) {
      o->strict_state = 1;
      i--; /* flag without a value */
      continue;
    }
    if (!v) return -1;
    if (!strcmp(a, "--core")) o->core = v;
    else if (!strcmp(a, "--rom")) o->rom = v;
    else if (!strcmp(a, "--replay")) o->replay = v;
    else if (!strcmp(a, "--dump-ppm")) o->dump_ppm = v;
    else if (!strcmp(a, "--frames")) {
      if (parse_uint(v, &o->frames)) return -1;
      have_frames = 1;
    } else if (!strcmp(a, "--after")) {
      if (parse_uint(v, &o->after)) return -1;
    } else return -1;
  }
  return o->core && have_frames ? 0 : -1;
}

/* Runs `frames` frames, feeding the replay keyed by the core's frame count. */
static void run_frames(dena_core *core, dena_replay *rp, uint16_t *buttons,
                       unsigned frames) {
  for (unsigned i = 0; i < frames; i++) {
    if (rp) {
      dena_replay_apply(rp, dena_core_frame_count(core), buttons);
      for (unsigned p = 0; p < DENA_MAX_PORTS; p++)
        dena_core_set_buttons(core, p, buttons[p]);
    }
    dena_core_run_frame(core);
  }
}

static int open_core(const run_opts *o, dena_core **core, dena_replay *rp,
                     int *have_rp) {
  char err[512];
  *have_rp = 0;
  if (o->replay) {
    unsigned line = 0;
    if (dena_replay_load(rp, o->replay, &line) != 0) {
      fprintf(stderr, "replay %s: parse error at line %u\n", o->replay, line);
      return EXIT_USAGE;
    }
    *have_rp = 1;
  }
  *core = dena_core_load(o->core, err, sizeof err);
  if (!*core) {
    fprintf(stderr, "%s\n", err);
    if (*have_rp) dena_replay_free(rp);
    return EXIT_CORE;
  }
  if (dena_core_load_game(*core, o->rom, err, sizeof err) != 0) {
    fprintf(stderr, "%s\n", err);
    dena_core_unload(*core);
    if (*have_rp) dena_replay_free(rp);
    return EXIT_CORE;
  }
  return EXIT_PASS;
}

static void fill_result(dena_core *core, run_result *r) {
  const dena_frame *f = dena_core_frame(core);
  r->frames = dena_core_frame_count(core);
  r->width = f->width;
  r->height = f->height;
  r->frame_hash = dena_frame_hash(f);
  r->audio_hash = dena_core_audio_hash(core);
}

static int do_run(const run_opts *o, run_result *r) {
  dena_core *core;
  dena_replay rp;
  int have_rp;
  int rc = open_core(o, &core, &rp, &have_rp);
  if (rc) return rc;
  uint16_t buttons[DENA_MAX_PORTS] = {0};
  run_frames(core, have_rp ? &rp : NULL, buttons, o->frames);
  fill_result(core, r);
  if (o->dump_ppm && dena_frame_write_ppm(dena_core_frame(core), o->dump_ppm)) {
    fprintf(stderr, "cannot write %s\n", o->dump_ppm);
    rc = EXIT_FAIL;
  }
  dena_core_unload(core);
  if (have_rp) dena_replay_free(&rp);
  return rc;
}

static void print_result(const run_result *r) {
  printf("frames=%u width=%u height=%u frame_hash=%016" PRIx64
         " audio_hash=%016" PRIx64 "\n",
         r->frames, r->width, r->height, r->frame_hash, r->audio_hash);
}

static int cmd_run(int argc, char **argv) {
  run_opts o;
  if (parse_run_opts(argc, argv, &o)) return usage();
  run_result r;
  int rc = do_run(&o, &r);
  if (rc == EXIT_PASS || rc == EXIT_FAIL) print_result(&r);
  return rc;
}

static int cmd_roundtrip(int argc, char **argv) {
  run_opts o;
  if (parse_run_opts(argc, argv, &o)) return usage();
  dena_core *core;
  dena_replay rp;
  int have_rp;
  int rc = open_core(&o, &core, &rp, &have_rp);
  if (rc) return rc;
  uint16_t buttons[DENA_MAX_PORTS] = {0};
  run_frames(core, have_rp ? &rp : NULL, buttons, o.frames);

  size_t size = dena_core_state_size(core);
  uint8_t *s1 = (uint8_t *)malloc(size ? size : 1);
  uint8_t *s2 = (uint8_t *)malloc(size ? size : 1);
  int ok = s1 && s2 && size && dena_core_save_state(core, s1, size) == 0;
  if (!ok) fprintf(stderr, "save state failed (size %zu)\n", size);

  /* Input is held constant across both legs so they see identical input. */
  uint64_t a = 0, b = 0;
  if (ok) {
    run_frames(core, NULL, buttons, o.after);
    a = dena_frame_hash(dena_core_frame(core));
    ok = dena_core_load_state(core, s1, size) == 0;
    if (!ok) fprintf(stderr, "load state failed\n");
  }
  int same_bytes = 0;
  if (ok) {
    same_bytes =
        dena_core_save_state(core, s2, size) == 0 && !memcmp(s1, s2, size);
    /* Real cores may embed wall-clock data (e.g. an RTC), so byte equality
     * is only required with --strict-state. */
    if (!same_bytes && o.strict_state) {
      fprintf(stderr, "state after load differs from saved state\n");
      ok = 0;
    }
  }
  if (ok) {
    run_frames(core, NULL, buttons, o.after);
    b = dena_frame_hash(dena_core_frame(core));
    ok = a == b;
  }
  printf("state_size=%zu state_bytes=%s hash_a=%016" PRIx64
         " hash_b=%016" PRIx64 " %s\n",
         size, same_bytes ? "same" : "differ", a, b, ok ? "PASS" : "FAIL");
  free(s1);
  free(s2);
  dena_core_unload(core);
  if (have_rp) dena_replay_free(&rp);
  return ok ? EXIT_PASS : EXIT_FAIL;
}

static void join_path(char *out, size_t n, const char *dir, const char *name) {
  if (!dir || name[0] == '/' || (name[0] && name[1] == ':'))
    snprintf(out, n, "%s", name);
  else
    snprintf(out, n, "%s/%s", dir, name);
}

static int file_exists(const char *p) {
  FILE *f = fopen(p, "rb");
  if (f) fclose(f);
  return f != NULL;
}

/* golden runs each case in a child process, because a process holds one core. */
static int run_case_child(const char *self, const char *core, const char *rom,
                          const char *frames, const char *replay,
                          run_result *r) {
  char cmd[4096];
  int n = snprintf(cmd, sizeof cmd, "\"%s\" run --core \"%s\" --frames %s", self,
                   core, frames);
  if (rom) n += snprintf(cmd + n, sizeof cmd - (size_t)n, " --rom \"%s\"", rom);
  if (replay)
    n += snprintf(cmd + n, sizeof cmd - (size_t)n, " --replay \"%s\"", replay);
#ifdef _WIN32
  /* cmd.exe strips the outer quotes of the whole line */
  char wrapped[4200];
  snprintf(wrapped, sizeof wrapped, "\"%s\"", cmd);
  FILE *p = _popen(wrapped, "r");
#else
  FILE *p = popen(cmd, "r");
#endif
  if (!p) return -1;
  char line[512] = {0};
  int got = 0;
  while (fgets(line, sizeof line, p)) {
    if (sscanf(line,
               "frames=%u width=%u height=%u frame_hash=%" SCNx64
               " audio_hash=%" SCNx64,
               &r->frames, &r->width, &r->height, &r->frame_hash,
               &r->audio_hash) == 5)
      got = 1;
  }
#ifdef _WIN32
  int status = _pclose(p);
#else
  int status = pclose(p);
#endif
  return got && status == 0 ? 0 : -1;
}

static const char *dir_of(const char *path, char *buf, size_t n) {
  snprintf(buf, n, "%s", path);
  char *slash = strrchr(buf, '/');
  char *bslash = strrchr(buf, '\\');
  if (bslash > slash) slash = bslash;
  if (!slash) return ".";
  *slash = '\0';
  return buf;
}

static int cmd_golden(const char *self, int argc, char **argv) {
  if (argc < 1) return usage();
  const char *manifest = argv[0];
  char mdir[1024];
  const char *base = dir_of(manifest, mdir, sizeof mdir);
  const char *cores_dir = base, *roms_dir = base, *replays_dir = base;
  for (int i = 1; i < argc; i += 2) {
    if (i + 1 >= argc) return usage();
    if (!strcmp(argv[i], "--cores-dir")) cores_dir = argv[i + 1];
    else if (!strcmp(argv[i], "--roms-dir")) roms_dir = argv[i + 1];
    else if (!strcmp(argv[i], "--replays-dir")) replays_dir = argv[i + 1];
    else return usage();
  }
  FILE *f = fopen(manifest, "r");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", manifest);
    return EXIT_USAGE;
  }
  char line[1024];
  unsigned lineno = 0, pass = 0, fail = 0, skip = 0, fresh = 0;
  while (fgets(line, sizeof line, f)) {
    lineno++;
    char name[128], core[256], rom[256], frames[32], replay[256], ef[32], ea[32];
    char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == '#' || *p == '\n' || *p == '\r' || !*p) continue;
    if (sscanf(p, "%127s %255s %255s %31s %255s %31s %31s", name, core, rom,
               frames, replay, ef, ea) != 7) {
      fprintf(stderr, "%s:%u: expected 7 fields\n", manifest, lineno);
      fclose(f);
      return EXIT_USAGE;
    }
    char core_path[1400], rom_path[1400], replay_path[1400];
    join_path(core_path, sizeof core_path, cores_dir, core);
    join_path(rom_path, sizeof rom_path, roms_dir, rom);
    join_path(replay_path, sizeof replay_path, replays_dir, replay);
    if (!file_exists(core_path)) { /* allow platform-neutral core names */
      size_t len = strlen(core_path);
      snprintf(core_path + len, sizeof core_path - len, "%s", MODULE_SUFFIX);
    }
    int has_rom = strcmp(rom, "-") != 0, has_rp = strcmp(replay, "-") != 0;
    if (!file_exists(core_path) || (has_rom && !file_exists(rom_path))) {
      printf("SKIP %s (missing %s)\n", name,
             file_exists(core_path) ? rom_path : core_path);
      skip++;
      continue;
    }
    run_result r;
    if (run_case_child(self, core_path, has_rom ? rom_path : NULL, frames,
                       has_rp ? replay_path : NULL, &r) != 0) {
      printf("FAIL %s (run failed)\n", name);
      fail++;
      continue;
    }
    char af[17], aa[17];
    snprintf(af, sizeof af, "%016" PRIx64, r.frame_hash);
    snprintf(aa, sizeof aa, "%016" PRIx64, r.audio_hash);
    if (!strcmp(ef, "?") || !strcmp(ea, "?")) {
      printf("NEW  %s frame_hash=%s audio_hash=%s\n", name, af, aa);
      fresh++;
    } else if (!strcmp(ef, af) && !strcmp(ea, aa)) {
      printf("PASS %s\n", name);
      pass++;
    } else {
      printf("FAIL %s expected %s %s got %s %s\n", name, ef, ea, af, aa);
      fail++;
    }
  }
  fclose(f);
  printf("pass=%u fail=%u skip=%u new=%u\n", pass, fail, skip, fresh);
  return fail ? EXIT_FAIL : EXIT_PASS;
}

int main(int argc, char **argv) {
  if (argc < 2) return usage();
  if (!strcmp(argv[1], "run")) return cmd_run(argc - 2, argv + 2);
  if (!strcmp(argv[1], "roundtrip")) return cmd_roundtrip(argc - 2, argv + 2);
  if (!strcmp(argv[1], "golden")) return cmd_golden(argv[0], argc - 2, argv + 2);
  return usage();
}
