/* Link cable end to end: two processes, each running the mGBA core on one of
 * our link test ROMs (tests/roms/link), linked over loopback.
 * Usage: link_core_tests <mgba core> <master rom> <slave rom> <expect master> <expect slave>
 * where each expectation is the six hex digits the side must receive.
 * Spec: docs/specs/link-cable.md */
#include "dena/host.h"
#include "dena/link.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
int main(void) {
  printf("link_core: not supported on Windows, skipped\n");
  return 77;
}
#else
#include <sys/wait.h>
#include <unistd.h>

#define PORT 47391
#define MAX_FRAMES 1200

/* Runs rom until its three received bytes appear in save RAM. */
static int run_side(const char *core_path, const char *rom, const char *expect, const char *who) {
  char err[256];
  dena_core *core = dena_core_load(core_path, err, sizeof err);
  if (!core || dena_core_load_game(core, rom, err, sizeof err) != 0) {
    fprintf(stderr, "%s: %s\n", who, err);
    return 2;
  }
  dena_core_set_hashing(core, 0);
  char got[7] = "";
  for (int f = 0; f < MAX_FRAMES; f++) {
    dena_core_run_frame(core);
    size_t size = 0;
    uint8_t *ram = dena_core_memory(core, 0, &size);
    if (ram && size >= 3) snprintf(got, sizeof got, "%02X%02X%02X", ram[0], ram[1], ram[2]);
    if (!strcmp(got, expect)) {
      printf("%s: received %s after %d frames\n", who, got, f + 1);
      /* Keep the cable up briefly so the other side's last reply goes out. */
      for (int i = 0; i < 30; i++) dena_core_run_frame(core);
      dena_core_unload(core);
      return 0;
    }
  }
  fprintf(stderr, "%s: received %s, expected %s (link state %d %s)\n", who, got, expect,
          dena_link_state(), dena_link_error());
  dena_core_unload(core);
  return 1;
}

int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr, "usage: %s <core> <master rom> <slave rom> <expect master> <expect slave>\n", argv[0]);
    return 2;
  }
  if (dena_link_host(PORT, "link test") != 0) {
    fprintf(stderr, "host: %s\n", dena_link_error());
    return 2;
  }
  pid_t pid = fork();
  if (pid == 0) {
    dena_link_stop();
    if (dena_link_join("127.0.0.1", PORT) != 0) _exit(2);
    for (int i = 0; i < 500 && dena_link_state() != DENA_LINK_CONNECTED; i++) usleep(10000);
    int r = run_side(argv[1], argv[3], argv[5], "slave");
    fflush(stdout);
    _exit(r);
  }
  for (int i = 0; i < 500 && dena_link_state() != DENA_LINK_CONNECTED; i++) usleep(10000);
  int r = run_side(argv[1], argv[2], argv[4], "master");
  int status = 0;
  waitpid(pid, &status, 0);
  dena_link_stop();
  if (r || !WIFEXITED(status) || WEXITSTATUS(status)) return 1;
  printf("link_core: ok\n");
  return 0;
}
#endif
