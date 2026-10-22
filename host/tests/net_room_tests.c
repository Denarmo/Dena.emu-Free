/* Rooms over loopback with the real relay (tools/relay/dena_relay.py): a
 * room code joins directly and, with DENA_NET_RELAY_ONLY=1, through the
 * relay's bridge; the link cable does the same through its own API.
 * Spec: docs/specs/netplay.md (Rooms and connecting)
 *
 * This edition only joins rooms, so the room on the relay is held by a
 * stand-in in this file (relay_room below), which speaks the relay's
 * protocol and forwards each bridge to a local port where the real host
 * (dena_room or the link cable) listens.
 *
 *   net_room_tests <python3> <dena_relay.py> */
#include "dena/link.h"
#include "dena/net_room.h"

#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
int main(void) {
  printf("net_room: needs fork, skipped on Windows\n");
  return 77;
}
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#define RELAY_PORT 47398
#define ROOM_PORT 47396
#define LINK_PORT 47397
#define RELAY "127.0.0.1:47398"

static int fails;
#define CHECK(c)                                                            \
  do {                                                                      \
    if (!(c)) {                                                             \
      fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c); \
      fails++;                                                              \
    }                                                                       \
  } while (0)

/* --- The stand-in room host --------------------------------------------- */

static int tcp_connect(int port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) return s;
  if (s >= 0) close(s);
  return -1;
}

static int read_line(int s, char *out, size_t len) {
  size_t n = 0;
  for (;;) {
    char c;
    struct pollfd p = {s, POLLIN, 0};
    if (poll(&p, 1, 5000) <= 0 || recv(s, &c, 1, 0) != 1) return -1;
    if (c == '\n') break;
    if (n + 1 < len) out[n++] = c;
  }
  out[n] = 0;
  return 0;
}

/* As read_line, but waits for as long as the control connection lives
 * (the relay sends PING lines between requests). */
static int read_line_wait(int s, char *out, size_t len) {
  struct pollfd p = {s, POLLIN, 0};
  if (poll(&p, 1, -1) <= 0) return -1;
  return read_line(s, out, len);
}

static int write_line(int s, const char *line) {
  size_t n = strlen(line);
  return send(s, line, n, MSG_NOSIGNAL) == (ssize_t)n ? 0 : -1;
}

typedef struct {
  int control;      /* the room's connection to the relay */
  int local_port;   /* where the real host listens */
  char code[8];
  char public_ip[64];
  pthread_t thread;
} relay_room;

/* Copies bytes both ways until either side closes. */
static void *pump(void *arg) {
  int *fds = arg;
  char buf[4096];
  struct pollfd p[2] = {{fds[0], POLLIN, 0}, {fds[1], POLLIN, 0}};
  for (;;) {
    if (poll(p, 2, -1) <= 0) break;
    int i = p[0].revents ? 0 : 1;
    ssize_t n = recv(fds[i], buf, sizeof buf, 0);
    if (n <= 0 || send(fds[1 - i], buf, (size_t)n, MSG_NOSIGNAL) != n) break;
  }
  close(fds[0]);
  close(fds[1]);
  free(fds);
  return NULL;
}

/* Answers PEER requests: opens the bridge and forwards it to local_port. */
static void *room_main(void *arg) {
  relay_room *r = arg;
  char line[160], token[64];
  while (read_line_wait(r->control, line, sizeof line) == 0) {
    if (sscanf(line, "PEER %63s", token) != 1) continue;
    int bridge = tcp_connect(RELAY_PORT);
    if (bridge < 0) continue;
    char hello[160];
    snprintf(hello, sizeof hello, "DENA-RELAY 1 ACCEPT %s %s\n", r->code, token);
    if (write_line(bridge, hello) < 0 || read_line(bridge, line, sizeof line) < 0 ||
        strcmp(line, "OK") != 0) {
      close(bridge);
      continue;
    }
    int local = tcp_connect(r->local_port);
    if (local < 0) {
      close(bridge);
      continue;
    }
    int *fds = malloc(2 * sizeof *fds);
    fds[0] = bridge;
    fds[1] = local;
    pthread_t t;
    pthread_create(&t, NULL, pump, fds);
    pthread_detach(t);
  }
  return NULL;
}

/* Holds a room on the relay for a host listening on local_port. */
static int relay_room_open(relay_room *r, int local_port) {
  memset(r, 0, sizeof *r);
  r->local_port = local_port;
  r->control = tcp_connect(RELAY_PORT);
  if (r->control < 0) return -1;
  char line[160];
  snprintf(line, sizeof line, "DENA-RELAY 1 HOST %d 127.0.0.1\n", local_port);
  if (write_line(r->control, line) < 0 || read_line(r->control, line, sizeof line) < 0 ||
      sscanf(line, "ROOM %7s %63s", r->code, r->public_ip) != 2) {
    close(r->control);
    return -1;
  }
  pthread_create(&r->thread, NULL, room_main, r);
  return 0;
}

static void relay_room_close(relay_room *r) {
  shutdown(r->control, SHUT_RDWR);
  pthread_join(r->thread, NULL);
  close(r->control);
}

/* --- Tests --------------------------------------------------------------- */

typedef struct {
  dena_room *room;
  intptr_t sock;
  char err[256];
} host_job;

static void *host_accept(void *arg) {
  host_job *j = arg;
  j->sock = -1;
  for (int i = 0; i < 100 && j->sock == -1; i++) {
    char peer[64];
    int via = -1;
    j->sock = dena_room_accept(j->room, 200, &via, peer, sizeof peer, j->err, sizeof j->err);
    if (j->sock >= 0 && via != 0) fails++;  /* the host side is always direct */
  }
  return NULL;
}

/* Joins target while a thread accepts on the room; checks bytes go both
 * ways. Returns the joiner's via_relay, or -1. */
static int join_and_talk(dena_room *room, const char *target) {
  host_job job = {room, -1, ""};
  pthread_t t;
  pthread_create(&t, NULL, host_accept, &job);
  int via = -1;
  char peer[64] = "", err[256] = "";
  intptr_t s = dena_room_connect(target, ROOM_PORT, RELAY, NULL, &via, peer, sizeof peer, err,
                                 sizeof err);
  pthread_join(t, NULL);
  if (s < 0 || job.sock < 0) {
    fprintf(stderr, "join %s: %s / %s\n", target, err, job.err);
    if (s >= 0) dena_room_close_socket(s);
    if (job.sock >= 0) dena_room_close_socket(job.sock);
    return -1;
  }
  char buf[6] = "";
  CHECK(send((int)s, "hello", 5, 0) == 5);
  CHECK(recv((int)job.sock, buf, 5, MSG_WAITALL) == 5 && memcmp(buf, "hello", 5) == 0);
  CHECK(send((int)job.sock, "world", 5, 0) == 5);
  CHECK(recv((int)s, buf, 5, MSG_WAITALL) == 5 && memcmp(buf, "world", 5) == 0);
  dena_room_close_socket(s);
  dena_room_close_socket(job.sock);
  return via;
}

static pid_t start_relay(const char *python, const char *script) {
  pid_t pid = fork();
  if (pid == 0) {
    execl(python, python, script, "--host", "127.0.0.1", "--port", "47398", "--quiet",
          (char *)NULL);
    _exit(127);
  }
  /* Up when it answers a lookup. */
  for (int i = 0; i < 100; i++) {
    int s = tcp_connect(RELAY_PORT);
    if (s >= 0) {
      char line[160];
      int ok = write_line(s, "DENA-RELAY 1 LOOKUP ZZZZZZ\n") == 0 &&
               read_line(s, line, sizeof line) == 0;
      close(s);
      if (ok) return pid;
    }
    usleep(100 * 1000);
  }
  kill(pid, SIGTERM);
  return -1;
}

static int wait_link(int want, int ms) {
  for (int i = 0; i < ms / 10; i++) {
    if (dena_link_state() == want) return 1;
    usleep(10 * 1000);
  }
  return dena_link_state() == want;
}

/* Link cable joiner (child process): answers one word through the relay. */
static int link_joiner(const char *code) {
  setenv("DENA_NET_RELAY_ONLY", "1", 1);
  const struct dena_link_api *api = dena_link_core_api();
  if (dena_link_join_room(code, RELAY) != 0) return 2;
  if (!wait_link(DENA_LINK_CONNECTED, 15000)) return 3;
  if (!dena_link_via_relay()) return 4;
  uint8_t kind;
  uint32_t value;
  if (api->recv(api->user, &kind, &value, 5000) != 1) return 5;
  api->send(api->user, kind | DENA_LINK_REPLY, value + 1);
  usleep(300 * 1000);
  dena_link_stop();
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    printf("net_room: no python3 for the relay, skipped\n");
    return 77;
  }
  signal(SIGPIPE, SIG_IGN);

  CHECK(dena_room_is_code("ab3k9z") && dena_room_is_code("AB3K9Z"));
  CHECK(!dena_room_is_code("AB3K9") && !dena_room_is_code("AB3K9ZZ"));
  CHECK(!dena_room_is_code("AB1K9Z") && !dena_room_is_code("10.0.0.1"));

  pid_t relay = start_relay(argv[1], argv[2]);
  if (relay < 0) {
    fprintf(stderr, "net_room: the relay did not start\n");
    return 1;
  }

  dena_room room;
  relay_room held;
  char err[256] = "";
  CHECK(dena_room_open(&room, ROOM_PORT, err, sizeof err) == 0);
  CHECK(relay_room_open(&held, ROOM_PORT) == 0);
  CHECK(dena_room_is_code(held.code));
  CHECK(strcmp(held.public_ip, "127.0.0.1") == 0);

  /* A code: direct first (same public address, so the LAN candidate). */
  unsetenv("DENA_NET_RELAY_ONLY");
  CHECK(join_and_talk(&room, held.code) == 0);
  /* A code with direct blocked: the relay bridges. */
  setenv("DENA_NET_RELAY_ONLY", "1", 1);
  CHECK(join_and_talk(&room, held.code) == 1);
  char lower[8];
  for (int i = 0; i < 7; i++) lower[i] = (char)(held.code[i] | (held.code[i] ? 0x20 : 0));
  CHECK(join_and_talk(&room, lower) == 1);  /* codes are not case sensitive */
  unsetenv("DENA_NET_RELAY_ONLY");
  /* An address skips the relay. */
  CHECK(join_and_talk(&room, "127.0.0.1:47396") == 0);

  /* An unknown code fails with a message. */
  int via = 0;
  intptr_t s = dena_room_connect("ZZZZZZ", ROOM_PORT, RELAY, NULL, &via, NULL, 0, err, sizeof err);
  CHECK(s == -1 && strstr(err, "no room") != NULL);
  /* A code without a relay cannot work. */
  s = dena_room_connect("ZZZZZZ", ROOM_PORT, "", NULL, &via, NULL, 0, err, sizeof err);
  CHECK(s == -1 && err[0] != 0);
  dena_room_close(&room);

  /* Closing the room removes it from the relay. */
  relay_room_close(&held);
  usleep(200 * 1000);
  s = dena_room_connect(held.code, ROOM_PORT, RELAY, NULL, &via, NULL, 0, err, sizeof err);
  CHECK(s == -1);

  /* Link cable: a LAN host has no room code; a child process joins it
   * through a room on the relay. */
  CHECK(dena_link_host(LINK_PORT, "Room host") == 0);
  CHECK(dena_link_room_code()[0] == 0);
  CHECK(relay_room_open(&held, LINK_PORT) == 0);
  pid_t pid = fork();
  if (pid == 0) _exit(link_joiner(held.code));
  CHECK(wait_link(DENA_LINK_CONNECTED, 15000));
  const struct dena_link_api *api = dena_link_core_api();
  CHECK(api->send(api->user, DENA_LINK_GB, 41) == 0);
  uint8_t k = 0;
  uint32_t v = 0;
  CHECK(api->recv(api->user, &k, &v, 5000) == 1 && v == 42);
  int status = 0;
  waitpid(pid, &status, 0);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  dena_link_stop();
  relay_room_close(&held);

  kill(relay, SIGTERM);
  waitpid(relay, NULL, 0);
  if (fails) return 1;
  printf("net_room: ok\n");
  return 0;
}
#endif
