/* Link cable transport: a host and a joiner (two processes) over loopback
 * exchange words through the core API. Spec: docs/specs/link-cable.md */
#include "dena/link.h"

#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
int main(void) {
  printf("link: not supported on Windows, skipped\n");
  return 77;
}
#else
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PORT 47390

static int fails;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c); \
      fails++;                                                    \
    }                                                             \
  } while (0)

static int wait_state(int want, int ms) {
  for (int i = 0; i < ms / 10; i++) {
    if (dena_link_state() == want) return 1;
    usleep(10 * 1000);
  }
  return dena_link_state() == want;
}

/* Child: answers every request with value + 1 until told to stop. */
static int joiner(void) {
  const struct dena_link_api *api = dena_link_core_api();
  if (dena_link_join("127.0.0.1", PORT) != 0) return 2;
  if (!wait_state(DENA_LINK_CONNECTED, 5000)) return 3;
  if (api->role(api->user) != DENA_LINK_CHILD) return 4;
  for (;;) {
    uint8_t kind;
    uint32_t value;
    int r = api->recv(api->user, &kind, &value, 2000);
    if (r < 0) return 0;  /* host hung up: done */
    if (r == 0) return 5;
    if (kind == DENA_LINK_GB && value == 0xDEAD) {
      dena_link_stop();
      return 0;
    }
    api->send(api->user, kind | DENA_LINK_REPLY, value + 1);
  }
}

int main(void) {
  /* Discovery sees our own beacon. */
  CHECK(dena_link_scan_start() == 0);
  CHECK(dena_link_host(PORT, "Test\thost") == 0);
  CHECK(dena_link_state() == DENA_LINK_WAITING);
  char list[512] = "";
  for (int i = 0; i < 30 && !strstr(list, "\t"); i++) {
    usleep(100 * 1000);
    dena_link_scan_results(list, sizeof list);
  }
  CHECK(strstr(list, "Test host\t") != NULL);
  CHECK(strstr(list, "\t47390\n") != NULL);
  dena_link_scan_stop();

  pid_t pid = fork();
  if (pid == 0) _exit(joiner());

  CHECK(wait_state(DENA_LINK_CONNECTED, 5000));
  const struct dena_link_api *api = dena_link_core_api();
  CHECK(api->connected(api->user));
  CHECK(api->role(api->user) == DENA_LINK_PARENT);
  CHECK(strcmp(dena_link_peer(), "127.0.0.1") == 0);

  /* Request/reply round trips, timed for the spec's latency note. */
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (uint32_t i = 0; i < 500; i++) {
    uint8_t kinds[] = {DENA_LINK_GB, DENA_LINK_GBA_NORMAL, DENA_LINK_GBA_MULTI};
    uint8_t kind = kinds[i % 3];
    CHECK(api->send(api->user, kind, i * 7) == 0);
    uint8_t k = 0;
    uint32_t v = 0;
    CHECK(api->recv(api->user, &k, &v, 1000) == 1);
    CHECK(k == (kind | DENA_LINK_REPLY));
    CHECK(v == i * 7 + 1);
  }
  clock_gettime(CLOCK_MONOTONIC, &t1);
  double us = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / 1e3 / 500;
  printf("link: loopback round trip %.0f us\n", us);

  /* Nothing pending: a poll returns at once. */
  uint8_t k;
  uint32_t v;
  CHECK(api->recv(api->user, &k, &v, 0) == 0);

  /* The joiner leaves: the host sees it and the API reports disconnected. */
  CHECK(api->send(api->user, DENA_LINK_GB, 0xDEAD) == 0);
  int status = 0;
  waitpid(pid, &status, 0);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(wait_state(DENA_LINK_FAILED, 3000));
  CHECK(strstr(dena_link_error(), "disconnected") != NULL);
  CHECK(api->recv(api->user, &k, &v, 0) == -1);
  CHECK(api->send(api->user, DENA_LINK_GB, 1) == -1);

  dena_link_stop();
  CHECK(dena_link_state() == DENA_LINK_OFF);

  /* Joining nobody fails cleanly. */
  CHECK(dena_link_join("127.0.0.1", PORT + 1) == 0);
  CHECK(wait_state(DENA_LINK_FAILED, 6000));
  dena_link_stop();

  if (fails) return 1;
  printf("link: ok\n");
  return 0;
}
#endif
