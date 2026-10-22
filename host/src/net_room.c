/* Rooms: direct connections and the relay. Spec: docs/specs/netplay.md */
#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "dena/net_room.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "net_sock.h"

#if !defined(_WIN32)
#include <ifaddrs.h>
#include <net/if.h>
#endif

#define RELAY_HELLO "DENA-RELAY 1 "
#define DIRECT_TIMEOUT_MS 1500
#define RELAY_TIMEOUT_MS 5000
#define BRIDGE_TIMEOUT_MS 12000

static void say(char *err, int errlen, const char *what, int sys) {
  if (!err || errlen <= 0) return;
  if (sys) snprintf(err, (size_t)errlen, "%s: %s", what, dsock_strerror(sys));
  else snprintf(err, (size_t)errlen, "%s", what);
}

/* "host[:port]" into host and port (default_port when absent). */
static void split_address(const char *text, int default_port, char *host, size_t hostlen,
                          int *port) {
  snprintf(host, hostlen, "%s", text ? text : "");
  *port = default_port;
  char *colon = strrchr(host, ':');
  if (colon && strchr(host, ':') == colon) {  /* one colon: IPv4 or name with port */
    int p = atoi(colon + 1);
    if (p > 0 && p < 65536) *port = p;
    *colon = 0;
  }
  /* Trim spaces the person may have typed. */
  char *s = host;
  while (*s == ' ') s++;
  memmove(host, s, strlen(s) + 1);
  for (size_t n = strlen(host); n && host[n - 1] == ' '; n--) host[n - 1] = 0;
}

static int stopped(const volatile int *stop) { return stop && *stop; }

/* Connects with a timeout; DSOCK_BAD on failure (*sys_err set, 0 = timeout or
 * name not found). */
static dsock connect_host(const char *host, int port, int timeout_ms, const volatile int *stop,
                          int *sys_err, int *resolved) {
  *sys_err = 0;
  *resolved = 0;
  char service[16];
  snprintf(service, sizeof service, "%d", port);
  struct addrinfo hints, *res = NULL;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, service, &hints, &res) != 0 || !res) return DSOCK_BAD;
  *resolved = 1;
  dsock s = socket(AF_INET, SOCK_STREAM, 0);
  int ok = 0;
  if (s != DSOCK_BAD) {
    dsock_set_blocking(s, 0);
    if (connect(s, res->ai_addr, (dsocklen)res->ai_addrlen) == 0) {
      ok = 1;
    } else if (dsock_in_progress(dsock_error())) {
      for (int waited = 0; waited < timeout_ms && !stopped(stop) && !ok; waited += 100) {
        dpollfd p;
        p.fd = s;
        p.events = POLLOUT;
        p.revents = 0;
        if (dsock_poll(&p, 1, 100) <= 0) continue;
        int e = 0;
        dsocklen el = sizeof e;
        getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&e, &el);
        if (e) {
          *sys_err = e;
          break;
        }
        ok = 1;
      }
    } else {
      *sys_err = dsock_error();
    }
    if (ok) dsock_set_blocking(s, 1);
  }
  freeaddrinfo(res);
  if (!ok) {
    if (s != DSOCK_BAD) dsock_close(s);
    return DSOCK_BAD;
  }
  dsock_nodelay(s);
  return s;
}

/* One line (without the newline), byte by byte so nothing after it is
 * consumed. 1, 0 on timeout, -1 closed. */
static int read_line(dsock s, char *out, size_t len, int timeout_ms) {
  size_t n = 0;
  uint64_t until = dnet_now_ms() + (uint64_t)timeout_ms;
  for (;;) {
    uint64_t now = dnet_now_ms();
    if (now >= until) return n ? -1 : 0;
    int left = (int)(until - now);
    char c;
    int r = dsock_read_all(s, &c, 1, left, left);
    if (r == 0) return n ? -1 : 0;
    if (r < 0) return -1;
    if (c == '\n') break;
    if (c != '\r' && n + 1 < len) out[n++] = c;
  }
  out[n] = 0;
  return 1;
}

static int write_line(dsock s, const char *line) {
  return dsock_write_all(s, line, strlen(line));
}

static void peer_name(dsock s, char *peer, int peerlen) {
  if (!peer || peerlen <= 0) return;
  peer[0] = 0;
  struct sockaddr_in a;
  dsocklen al = sizeof a;
  if (getpeername(s, (struct sockaddr *)&a, &al) == 0)
    inet_ntop(AF_INET, &a.sin_addr, peer, (dsocklen)peerlen);
}

int dena_room_is_code(const char *text) {
  if (!text) return 0;
  while (*text == ' ') text++;
  int n = 0;
  for (; text[n] && text[n] != ' '; n++) {
    if (n >= DENA_ROOM_CODE_LEN) return 0;
    if (!strchr(DENA_ROOM_ALPHABET, toupper((unsigned char)text[n]))) return 0;
  }
  for (int i = n; text[i]; i++)
    if (text[i] != ' ') return 0;
  return n == DENA_ROOM_CODE_LEN;
}

static void normalize_code(const char *text, char *out) {
  while (*text == ' ') text++;
  int i = 0;
  for (; i < DENA_ROOM_CODE_LEN && text[i]; i++) out[i] = (char)toupper((unsigned char)text[i]);
  out[i] = 0;
}

void dena_room_close_socket(intptr_t s) {
  if (s >= 0) dsock_close((dsock)s);
}

int dena_room_open(dena_room *r, int port, char *err, int errlen) {
  memset(r, 0, sizeof *r);
  r->listen_sock = -1;
  if (dsock_init() != 0) {
    say(err, errlen, "cannot start networking", 0);
    return -1;
  }
  r->port = port;
  dsock s = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (s == DSOCK_BAD) {
    say(err, errlen, "cannot open the port", dsock_error());
    return -1;
  }
#if !defined(_WIN32)
  /* Windows' SO_REUSEADDR lets another program steal the port: not there. */
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof one);
#else
  (void)one;
#endif
  if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 2) < 0) {
    say(err, errlen, "cannot open the port", dsock_error());
    dsock_close(s);
    return -1;
  }
  if (port == 0) { /* any free port (tests): report the one picked */
    dsocklen al = sizeof a;
    if (getsockname(s, (struct sockaddr *)&a, &al) == 0) r->port = ntohs(a.sin_port);
  }
  r->listen_sock = (intptr_t)s;
  return 0;
}

intptr_t dena_room_accept(dena_room *r, int timeout_ms, int *via_relay, char *peer, int peerlen,
                          char *err, int errlen) {
  if (r->listen_sock < 0) {
    say(err, errlen, "the room is closed", 0);
    return -2;
  }
  dpollfd p;
  p.fd = (dsock)r->listen_sock;
  p.events = POLLIN;
  p.revents = 0;
  if (dsock_poll(&p, 1, timeout_ms) <= 0 || !p.revents) return -1;
  struct sockaddr_in a;
  dsocklen al = sizeof a;
  dsock s = accept((dsock)r->listen_sock, (struct sockaddr *)&a, &al);
  if (s == DSOCK_BAD) return -1;
  dsock_nodelay(s);
  if (via_relay) *via_relay = 0;
  peer_name(s, peer, peerlen);
  return (intptr_t)s;
}

void dena_room_close(dena_room *r) {
  if (r->listen_sock >= 0) dsock_close((dsock)r->listen_sock);
  r->listen_sock = -1;
}

/* Asks the relay where the room's host is. Fills up to two candidates. */
static int lookup(const char *relay_host, int relay_port, const char *code, char cand[2][96],
                  int *ncand, char *err, int errlen) {
  int sys, resolved;
  *ncand = 0;
  dsock s = connect_host(relay_host, relay_port, RELAY_TIMEOUT_MS, NULL, &sys, &resolved);
  if (s == DSOCK_BAD) {
    say(err, errlen, resolved ? "cannot reach the relay server" : "cannot find the relay server",
        sys);
    return -1;
  }
  char line[256];
  snprintf(line, sizeof line, RELAY_HELLO "LOOKUP %s\n", code);
  int got = write_line(s, line) < 0 ? -1 : read_line(s, line, sizeof line, RELAY_TIMEOUT_MS);
  dsock_close(s);
  if (got != 1) {
    say(err, errlen, "the relay server did not answer", 0);
    return -1;
  }
  if (strncmp(line, "ERR ", 4) == 0) {
    say(err, errlen, line + 4, 0);
    return -1;
  }
  char pub[96], lan[96], you[64];
  int k = sscanf(line, "HOST %95s %95s YOU %63s", pub, lan, you);
  if (k < 1) {
    say(err, errlen, "the relay server sent something unexpected", 0);
    return -1;
  }
  /* Same public address: both behind one router, so the LAN address first. */
  char pub_ip[96];
  snprintf(pub_ip, sizeof pub_ip, "%s", pub);
  if (strchr(pub_ip, ':')) *strchr(pub_ip, ':') = 0;
  if (k == 3 && strcmp(pub_ip, you) == 0 && lan[0] != '-')
    snprintf(cand[(*ncand)++], 96, "%s", lan);
  snprintf(cand[(*ncand)++], 96, "%s", pub);
  return 0;
}

intptr_t dena_room_connect(const char *target, int default_port, const char *relay,
                           const volatile int *stop, int *via_relay, char *peer, int peerlen,
                           char *err, int errlen) {
  if (via_relay) *via_relay = 0;
  if (dsock_init() != 0) {
    say(err, errlen, "cannot start networking", 0);
    return -1;
  }
  if (!target || !*target) {
    say(err, errlen, "no address", 0);
    return -1;
  }
  int sys = 0, resolved = 0;
  if (!dena_room_is_code(target)) {
    char host[256];
    int port;
    split_address(target, default_port, host, sizeof host, &port);
    dsock s = connect_host(host, port, 5000, stop, &sys, &resolved);
    if (s == DSOCK_BAD) {
      say(err, errlen, resolved ? "cannot connect" : "cannot resolve that address", sys);
      return -1;
    }
    peer_name(s, peer, peerlen);
    return (intptr_t)s;
  }
  if (!relay || !*relay) {
    say(err, errlen, "room codes need a relay server (Settings > NETPLAY.CFG)", 0);
    return -1;
  }
  char code[DENA_ROOM_CODE_LEN + 2], relay_host[256];
  int relay_port;
  normalize_code(target, code);
  split_address(relay, DENA_RELAY_PORT, relay_host, sizeof relay_host, &relay_port);
  char cand[2][96];
  int ncand = 0;
  if (lookup(relay_host, relay_port, code, cand, &ncand, err, errlen) < 0) return -1;
  const char *only_relay = getenv("DENA_NET_RELAY_ONLY");
  if (!(only_relay && *only_relay == '1')) {
    for (int i = 0; i < ncand && !stopped(stop); i++) {
      char host[96];
      int port;
      split_address(cand[i], DENA_NETPLAY_PORT, host, sizeof host, &port);
      dsock s = connect_host(host, port, DIRECT_TIMEOUT_MS, stop, &sys, &resolved);
      if (s != DSOCK_BAD) {
        peer_name(s, peer, peerlen);
        return (intptr_t)s;
      }
    }
  }
  if (stopped(stop)) {
    say(err, errlen, "cancelled", 0);
    return -1;
  }
  dsock s = connect_host(relay_host, relay_port, RELAY_TIMEOUT_MS, stop, &sys, &resolved);
  if (s == DSOCK_BAD) {
    say(err, errlen, "cannot reach the relay server", sys);
    return -1;
  }
  char line[160];
  snprintf(line, sizeof line, RELAY_HELLO "JOIN %s\n", code);
  int got = write_line(s, line) < 0 ? -1 : read_line(s, line, sizeof line, BRIDGE_TIMEOUT_MS);
  if (got != 1 || strcmp(line, "OK") != 0) {
    say(err, errlen,
        got == 1 && strncmp(line, "ERR ", 4) == 0 ? line + 4 : "the relay could not reach the host",
        0);
    dsock_close(s);
    return -1;
  }
  if (via_relay) *via_relay = 1;
  if (peer && peerlen > 0) snprintf(peer, (size_t)peerlen, "relay");
  return (intptr_t)s;
}

int dena_room_local_address(char *out, int len) {
  if (!out || len <= 0) return 0;
  out[0] = 0;
#if defined(_WIN32)
  /* The address Windows would send from towards the internet; a UDP
   * "connect" sends nothing. */
  if (dsock_init() != 0) return 0;
  dsock s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s == DSOCK_BAD) return 0;
  struct sockaddr_in to, me;
  memset(&to, 0, sizeof to);
  to.sin_family = AF_INET;
  to.sin_port = htons(53);
  inet_pton(AF_INET, "8.8.8.8", &to.sin_addr);
  dsocklen ml = sizeof me;
  if (connect(s, (struct sockaddr *)&to, sizeof to) == 0 &&
      getsockname(s, (struct sockaddr *)&me, &ml) == 0 && me.sin_addr.s_addr != 0)
    inet_ntop(AF_INET, &me.sin_addr, out, (dsocklen)len);
  dsock_close(s);
#else
  struct ifaddrs *list = NULL;
  if (getifaddrs(&list) != 0) return 0;
  int best = 0; /* 2 = a wlan interface, 1 = any other */
  for (struct ifaddrs *i = list; i; i = i->ifa_next) {
    if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
    if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
    int score = strncmp(i->ifa_name, "wlan", 4) == 0 ? 2 : 1;
    if (score <= best) continue;
    inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, out, (socklen_t)len);
    best = score;
  }
  freeifaddrs(list);
#endif
  return (int)strlen(out);
}
