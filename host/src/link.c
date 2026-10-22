/* Link cable over Wi-Fi. Spec: docs/specs/link-cable.md */
#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "dena/link.h"

#include <string.h>

#if defined(_WIN32) && !defined(__MINGW32__)

/* MSVC builds only run the harness: no pthreads, so no link. */
int dena_link_host(int port, const char *name) { (void)port, (void)name; return -1; }
int dena_link_join(const char *address, int port) { (void)address, (void)port; return -1; }
int dena_link_join_room(const char *target, const char *relay) { (void)target, (void)relay; return -1; }
void dena_link_stop(void) {}
int dena_link_state(void) { return DENA_LINK_OFF; }
int dena_link_role(void) { return DENA_LINK_PARENT; }
int dena_link_via_relay(void) { return 0; }
const char *dena_link_error(void) { return "link cable is not supported in this build"; }
const char *dena_link_peer(void) { return ""; }
const char *dena_link_room_code(void) { return ""; }
int dena_link_scan_start(void) { return -1; }
void dena_link_scan_stop(void) {}
int dena_link_scan_results(char *out, int len) { if (len > 0) out[0] = 0; return 0; }
int dena_link_local_address(char *out, int len) { if (len > 0) out[0] = 0; return 0; }
const struct dena_link_api *dena_link_core_api(void) { return NULL; }

#else

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "dena/net_room.h"
#include "net_sock.h"

#define MSG_SIZE 8
#define MSG_MAGIC 'D'
#define MSG_HELLO 0x01
#define INBOX_CAP 256
#define SCAN_MAX 16
#define SCAN_TTL_MS 3000
/* How long a clock-driving side waits for the reply (dena_link.inc asks for
 * 40 ms): longer when the other side is across the internet (netplay.md). */
#define INTERNET_WAIT_MS 400

typedef struct {
  uint8_t kind;
  uint32_t value;
} msg;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;   /* state below */
static pthread_mutex_t g_send = PTHREAD_MUTEX_INITIALIZER;   /* socket writes */
static pthread_cond_t g_inbox_cond = PTHREAD_COND_INITIALIZER;

static atomic_int g_state = DENA_LINK_OFF;
static atomic_int g_role = DENA_LINK_PARENT;
static atomic_intptr_t g_sock = -1;  /* connected peer */
static atomic_int g_stop = 0;
static atomic_int g_via_relay = 0;
static atomic_int g_wait_ms = 0;     /* 0: what the core asks for */
static pthread_t g_thread, g_beacon_thread;
static int g_thread_live, g_beacon_live;
static char g_error[160];
static char g_peer[64];
static char g_name[64];
static char g_target[256];  /* joining: address or room code */
static char g_relay[256];   /* joining a room */
static int g_port;
static dena_room g_room;
static int g_room_live;

static msg g_inbox[INBOX_CAP];
static unsigned g_head, g_tail;   /* under g_lock */
static atomic_uint g_pending;     /* lock-free emptiness check for polls */

static void set_error_text(const char *what) {
  pthread_mutex_lock(&g_lock);
  snprintf(g_error, sizeof g_error, "%s", what);
  pthread_mutex_unlock(&g_lock);
}

static uint64_t now_ms(void) { return dnet_now_ms(); }

static int send_msg(dsock fd, uint8_t kind, uint32_t value) {
  uint8_t b[MSG_SIZE] = {MSG_MAGIC, kind, 0, 0,
                         (uint8_t)(value >> 24), (uint8_t)(value >> 16),
                         (uint8_t)(value >> 8), (uint8_t)value};
  pthread_mutex_lock(&g_send);
  int r = dsock_write_all(fd, b, sizeof b);
  pthread_mutex_unlock(&g_send);
  return r;
}

/* Reads one message, waiting at most timeout_ms (-1 forever) for it to
 * start. Returns 1, 0 on timeout, -1 on a closed or broken connection. */
static int read_msg(dsock fd, msg *out, int timeout_ms) {
  uint8_t b[MSG_SIZE];
  int r = dsock_read_all(fd, b, sizeof b, timeout_ms, 1000);
  if (r <= 0) return r;
  if (b[0] != MSG_MAGIC) return -1;
  out->kind = b[1];
  out->value = ((uint32_t)b[4] << 24) | ((uint32_t)b[5] << 16) | ((uint32_t)b[6] << 8) | b[7];
  return 1;
}

static void inbox_clear(void) {
  pthread_mutex_lock(&g_lock);
  g_head = g_tail = 0;
  atomic_store(&g_pending, 0);
  pthread_cond_broadcast(&g_inbox_cond);
  pthread_mutex_unlock(&g_lock);
}

static void inbox_push(msg m) {
  pthread_mutex_lock(&g_lock);
  if (g_tail - g_head < INBOX_CAP) {
    g_inbox[g_tail++ % INBOX_CAP] = m;
    atomic_fetch_add(&g_pending, 1);
  }
  pthread_cond_signal(&g_inbox_cond);
  pthread_mutex_unlock(&g_lock);
}

static void set_peer(const char *peer) {
  pthread_mutex_lock(&g_lock);
  snprintf(g_peer, sizeof g_peer, "%s", peer);
  pthread_mutex_unlock(&g_lock);
}

/* Both sides say hello first, so a stray connection never reaches a core. */
static int handshake(dsock fd) {
  if (send_msg(fd, MSG_HELLO, DENA_LINK_API_VERSION) < 0) return -1;
  msg m;
  if (read_msg(fd, &m, 5000) != 1 || m.kind != MSG_HELLO) {
    set_error_text("the other device did not answer as Dena.emu");
    return -1;
  }
  if (m.value != DENA_LINK_API_VERSION) {
    set_error_text("the other device runs a different Dena.emu version");
    return -1;
  }
  return 0;
}

/* A peer outside the private ranges is across the internet. */
static int is_private(const char *ip) {
  unsigned a = 0, b = 0;
  if (sscanf(ip, "%u.%u", &a, &b) != 2) return 0;
  return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b < 32) ||
         (a == 169 && b == 254) || (a == 100 && b >= 64 && b < 128);
}

static void *link_thread(void *arg) {
  (void)arg;
  dsock fd = DSOCK_BAD;
  char peer[64] = "", err[160] = "";
  int via = 0;
  if (atomic_load(&g_role) == DENA_LINK_PARENT) {
    while (!atomic_load(&g_stop) && fd == DSOCK_BAD) {
      intptr_t s = dena_room_accept(&g_room, 200, &via, peer, sizeof peer, err, sizeof err);
      if (s == -2) {
        set_error_text(err);
        break;
      }
      if (s >= 0) fd = (dsock)s;
    }
  } else {
    intptr_t s = dena_room_connect(g_target, g_port, g_relay, (const volatile int *)&g_stop, &via, peer, sizeof peer,
                                   err, sizeof err);
    if (s < 0) set_error_text(err);
    else fd = (dsock)s;
  }
  if (fd != DSOCK_BAD && !atomic_load(&g_stop)) {
    set_peer(peer);
    atomic_store(&g_via_relay, via);
    atomic_store(&g_wait_ms, via || !is_private(peer) ? INTERNET_WAIT_MS : 0);
    if (handshake(fd) == 0) {
      inbox_clear();
      atomic_store(&g_sock, (intptr_t)fd);
      atomic_store(&g_state, DENA_LINK_CONNECTED);
      msg m;
      int r;
      while (!atomic_load(&g_stop) && (r = read_msg(fd, &m, 200)) >= 0) {
        if (r == 1 && m.kind != MSG_HELLO) inbox_push(m);
      }
      if (!atomic_load(&g_stop)) set_error_text("the other device disconnected");
      atomic_store(&g_sock, -1);
    }
  }
  if (fd != DSOCK_BAD) dsock_close(fd);
  if (!atomic_load(&g_stop)) atomic_store(&g_state, DENA_LINK_FAILED);
  pthread_mutex_lock(&g_lock);
  pthread_cond_broadcast(&g_inbox_cond);
  pthread_mutex_unlock(&g_lock);
  return NULL;
}

static void *beacon_thread(void *arg) {
  (void)arg;
  dsock fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd == DSOCK_BAD) return NULL;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_BROADCAST, (const char *)&one, sizeof one);
  struct sockaddr_in to;
  memset(&to, 0, sizeof to);
  to.sin_family = AF_INET;
  to.sin_port = htons(DENA_LINK_BEACON_PORT);
  to.sin_addr.s_addr = htonl(INADDR_BROADCAST);
  char payload[128];
  snprintf(payload, sizeof payload, "DENALINK%d %d %s", DENA_LINK_API_VERSION, g_port, g_name);
  while (!atomic_load(&g_stop) && atomic_load(&g_state) == DENA_LINK_WAITING) {
    sendto(fd, payload, (int)strlen(payload), 0, (struct sockaddr *)&to, sizeof to);
    for (int i = 0; i < 10 && !atomic_load(&g_stop); i++) dnet_sleep_ms(100);
  }
  dsock_close(fd);
  return NULL;
}

void dena_link_stop(void) {
  atomic_store(&g_stop, 1);
  intptr_t fd = atomic_load(&g_sock);
  if (fd >= 0) dsock_shutdown((dsock)fd);
  if (g_thread_live) pthread_join(g_thread, NULL);
  if (g_beacon_live) pthread_join(g_beacon_thread, NULL);
  g_thread_live = g_beacon_live = 0;
  if (g_room_live) dena_room_close(&g_room);
  g_room_live = 0;
  atomic_store(&g_sock, -1);
  atomic_store(&g_state, DENA_LINK_OFF);
  atomic_store(&g_via_relay, 0);
  atomic_store(&g_wait_ms, 0);
  atomic_store(&g_stop, 0);
  inbox_clear();
  pthread_mutex_lock(&g_lock);
  g_error[0] = g_peer[0] = 0;
  pthread_mutex_unlock(&g_lock);
}

static int start(int role) {
  atomic_store(&g_role, role);
  atomic_store(&g_state, DENA_LINK_WAITING);
  if (pthread_create(&g_thread, NULL, link_thread, NULL) != 0) {
    set_error_text("cannot start the link thread");
    atomic_store(&g_state, DENA_LINK_FAILED);
    return -1;
  }
  g_thread_live = 1;
  return 0;
}

int dena_link_host(int port, const char *name) {
  dena_link_stop();
  g_port = port > 0 ? port : DENA_LINK_PORT;
  snprintf(g_name, sizeof g_name, "%s", name && *name ? name : "Dena.emu");
  for (char *c = g_name; *c; c++) if (*c == '\t' || *c == '\n') *c = ' ';
  g_relay[0] = 0;
  char err[160];
  if (dena_room_open(&g_room, g_port, err, sizeof err) < 0) {
    set_error_text("cannot open the link port");
    atomic_store(&g_state, DENA_LINK_FAILED);
    return -1;
  }
  g_room_live = 1;
  if (start(DENA_LINK_PARENT) < 0) return -1;
  if (pthread_create(&g_beacon_thread, NULL, beacon_thread, NULL) == 0) g_beacon_live = 1;
  return 0;
}


static int join(const char *target, const char *relay, int port) {
  dena_link_stop();
  g_port = port > 0 ? port : DENA_LINK_PORT;
  if (!target || !*target) {
    set_error_text("no address");
    atomic_store(&g_state, DENA_LINK_FAILED);
    return -1;
  }
  snprintf(g_target, sizeof g_target, "%s", target);
  snprintf(g_relay, sizeof g_relay, "%s", relay ? relay : "");
  return start(DENA_LINK_CHILD);
}

int dena_link_join_room(const char *target, const char *relay) { return join(target, relay, 0); }

int dena_link_join(const char *address, int port) { return join(address, NULL, port); }

int dena_link_state(void) { return atomic_load(&g_state); }
int dena_link_role(void) { return atomic_load(&g_role); }
int dena_link_via_relay(void) { return atomic_load(&g_via_relay); }

const char *dena_link_error(void) {
  static char copy[sizeof g_error];
  pthread_mutex_lock(&g_lock);
  memcpy(copy, g_error, sizeof copy);
  pthread_mutex_unlock(&g_lock);
  return copy;
}

const char *dena_link_peer(void) {
  static char copy[sizeof g_peer];
  pthread_mutex_lock(&g_lock);
  memcpy(copy, g_peer, sizeof copy);
  pthread_mutex_unlock(&g_lock);
  return copy;
}

/* No relay rooms are hosted in this edition. */
const char *dena_link_room_code(void) { return ""; }

/* --- Discovery --- */

typedef struct {
  char name[64];
  char addr[64];
  int port;
  uint64_t seen;
} scan_entry;

static pthread_mutex_t g_scan_lock = PTHREAD_MUTEX_INITIALIZER;
static scan_entry g_scan[SCAN_MAX];
static pthread_t g_scan_thread;
static int g_scan_live;
static atomic_int g_scan_stop;
static dsock g_scan_sock = DSOCK_BAD;

static void *scan_thread(void *arg) {
  (void)arg;
  dsock fd = g_scan_sock;
  while (!atomic_load(&g_scan_stop)) {
    dpollfd p;
    p.fd = fd;
    p.events = POLLIN;
    p.revents = 0;
    if (dsock_poll(&p, 1, 200) <= 0) continue;
    char buf[160];
    struct sockaddr_in from;
    dsocklen fl = sizeof from;
    int n = (int)recvfrom(fd, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
    if (n <= 0) continue;
    buf[n] = 0;
    int version = 0, port = 0, used = 0;
    if (sscanf(buf, "DENALINK%d %d %n", &version, &port, &used) < 2 || !used) continue;
    if (version != DENA_LINK_API_VERSION || port <= 0 || port > 65535) continue;
    char addr[64];
    inet_ntop(AF_INET, &from.sin_addr, addr, sizeof addr);
    uint64_t t = now_ms();
    pthread_mutex_lock(&g_scan_lock);
    int slot = -1;
    for (int i = 0; i < SCAN_MAX; i++) {
      if (g_scan[i].seen && !strcmp(g_scan[i].addr, addr) && g_scan[i].port == port) { slot = i; break; }
    }
    for (int i = 0; slot < 0 && i < SCAN_MAX; i++) {
      if (!g_scan[i].seen || t - g_scan[i].seen > SCAN_TTL_MS) slot = i;
    }
    if (slot >= 0) {
      snprintf(g_scan[slot].name, sizeof g_scan[slot].name, "%s", buf + used);
      snprintf(g_scan[slot].addr, sizeof g_scan[slot].addr, "%s", addr);
      g_scan[slot].port = port;
      g_scan[slot].seen = t;
    }
    pthread_mutex_unlock(&g_scan_lock);
  }
  dsock_close(fd);
  return NULL;
}

int dena_link_scan_start(void) {
  dena_link_scan_stop();
  if (dsock_init() != 0) return -1;
  dsock fd = socket(AF_INET, SOCK_DGRAM, 0);
  int one = 1;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(DENA_LINK_BEACON_PORT);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (fd == DSOCK_BAD ||
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof one) < 0 ||
      bind(fd, (struct sockaddr *)&a, sizeof a) < 0) {
    if (fd != DSOCK_BAD) dsock_close(fd);
    return -1;
  }
  atomic_store(&g_scan_stop, 0);
  g_scan_sock = fd;
  if (pthread_create(&g_scan_thread, NULL, scan_thread, NULL) != 0) {
    dsock_close(fd);
    return -1;
  }
  g_scan_live = 1;
  return 0;
}

void dena_link_scan_stop(void) {
  if (!g_scan_live) return;
  atomic_store(&g_scan_stop, 1);
  pthread_join(g_scan_thread, NULL);
  g_scan_live = 0;
  pthread_mutex_lock(&g_scan_lock);
  memset(g_scan, 0, sizeof g_scan);
  pthread_mutex_unlock(&g_scan_lock);
}

int dena_link_scan_results(char *out, int len) {
  if (!out || len <= 0) return 0;
  out[0] = 0;
  int used = 0;
  uint64_t t = now_ms();
  pthread_mutex_lock(&g_scan_lock);
  for (int i = 0; i < SCAN_MAX; i++) {
    if (!g_scan[i].seen || t - g_scan[i].seen > SCAN_TTL_MS) continue;
    int n = snprintf(out + used, (size_t)(len - used), "%s\t%s\t%d\n", g_scan[i].name,
                     g_scan[i].addr, g_scan[i].port);
    if (n < 0 || n >= len - used) { out[used] = 0; break; }
    used += n;
  }
  pthread_mutex_unlock(&g_scan_lock);
  return used;
}

int dena_link_local_address(char *out, int len) { return dena_room_local_address(out, len); }

/* --- Core transport --- */

static int api_connected(void *user) {
  (void)user;
  return atomic_load(&g_state) == DENA_LINK_CONNECTED;
}

static int api_role(void *user) {
  (void)user;
  return atomic_load(&g_role);
}

static int api_send(void *user, uint8_t kind, uint32_t value) {
  (void)user;
  intptr_t fd = atomic_load(&g_sock);
  if (fd < 0 || kind == MSG_HELLO) return -1;
  return send_msg((dsock)fd, kind, value);
}

static int api_recv(void *user, uint8_t *kind, uint32_t *value, int timeout_ms) {
  (void)user;
  if (timeout_ms <= 0 && atomic_load(&g_pending) == 0) {
    return api_connected(NULL) ? 0 : -1;
  }
  int wait = atomic_load(&g_wait_ms);
  if (timeout_ms > 0 && wait > timeout_ms) timeout_ms = wait;
  pthread_mutex_lock(&g_lock);
  if (g_head == g_tail && timeout_ms > 0 && api_connected(NULL)) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    until.tv_sec += timeout_ms / 1000 + until.tv_nsec / 1000000000L;
    until.tv_nsec %= 1000000000L;
    while (g_head == g_tail && api_connected(NULL)) {
      if (pthread_cond_timedwait(&g_inbox_cond, &g_lock, &until) == ETIMEDOUT) break;
    }
  }
  int r = 0;
  if (g_head != g_tail) {
    msg m = g_inbox[g_head++ % INBOX_CAP];
    atomic_fetch_sub(&g_pending, 1);
    *kind = m.kind;
    *value = m.value;
    r = 1;
  } else if (!api_connected(NULL)) {
    r = -1;
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

static const struct dena_link_api g_api = {
    DENA_LINK_API_VERSION, NULL, api_connected, api_role, api_send, api_recv};

const struct dena_link_api *dena_link_core_api(void) { return &g_api; }

#endif
