/* The few socket calls link.c, net_room.c and the netplay session need, the
 * same on POSIX and Windows (Winsock 2). Header-only.
 * Spec: docs/specs/netplay.md */
#ifndef DENA_NET_SOCK_H
#define DENA_NET_SOCK_H

#include <stdint.h>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

typedef SOCKET dsock;
#define DSOCK_BAD INVALID_SOCKET
#define DSOCK_SEND_FLAGS 0
typedef WSAPOLLFD dpollfd;
typedef int dsocklen;

static inline int dsock_init(void) {
  static volatile LONG done;
  if (InterlockedCompareExchange(&done, 1, 0) == 0) {
    WSADATA d;
    if (WSAStartup(MAKEWORD(2, 2), &d) != 0) return -1;
  }
  return 0;
}
static inline void dsock_close(dsock s) { closesocket(s); }
static inline int dsock_poll(dpollfd *p, unsigned n, int timeout_ms) {
  return WSAPoll(p, (ULONG)n, timeout_ms);
}
static inline int dsock_error(void) { return WSAGetLastError(); }
static inline int dsock_in_progress(int err) {
  return err == WSAEWOULDBLOCK || err == WSAEINPROGRESS;
}
static inline int dsock_interrupted(int err) { return err == WSAEINTR; }
static inline void dsock_set_blocking(dsock s, int blocking) {
  u_long nb = blocking ? 0 : 1;
  ioctlsocket(s, FIONBIO, &nb);
}
static inline void dsock_shutdown(dsock s) { shutdown(s, SD_BOTH); }
static inline uint64_t dnet_now_ms(void) { return (uint64_t)GetTickCount64(); }
static inline void dnet_sleep_ms(int ms) { Sleep((DWORD)ms); }
/* MinGW's GCC ignores __declspec(thread); __thread is its spelling. */
#if defined(_MSC_VER)
#define DSOCK_TLS __declspec(thread)
#else
#define DSOCK_TLS __thread
#endif
static inline const char *dsock_strerror(int err) {
  static DSOCK_TLS char buf[96];
  buf[0] = 0;
  FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, (DWORD)err, 0,
                 buf, sizeof buf, NULL);
  for (char *c = buf; *c; c++)
    if (*c == '\r' || *c == '\n') *c = 0;
  return buf;
}

#else

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef int dsock;
#define DSOCK_BAD (-1)
#ifdef MSG_NOSIGNAL
#define DSOCK_SEND_FLAGS MSG_NOSIGNAL
#else
#define DSOCK_SEND_FLAGS 0
#endif
typedef struct pollfd dpollfd;
typedef socklen_t dsocklen;

static inline int dsock_init(void) { return 0; }
static inline void dsock_close(dsock s) { close(s); }
static inline int dsock_poll(dpollfd *p, unsigned n, int timeout_ms) {
  return poll(p, (nfds_t)n, timeout_ms);
}
static inline int dsock_error(void) { return errno; }
static inline int dsock_in_progress(int err) { return err == EINPROGRESS || err == EAGAIN; }
static inline int dsock_interrupted(int err) { return err == EINTR; }
static inline void dsock_set_blocking(dsock s, int blocking) {
  int flags = fcntl(s, F_GETFL, 0);
  fcntl(s, F_SETFL, blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK));
}
static inline void dsock_shutdown(dsock s) { shutdown(s, SHUT_RDWR); }
static inline uint64_t dnet_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}
static inline void dnet_sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}
static inline const char *dsock_strerror(int err) { return strerror(err); }

#endif

static inline void dsock_nodelay(dsock s) {
  int one = 1;
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
}

/* Writes all of buf; 0, or -1 on a broken connection. */
static inline int dsock_write_all(dsock s, const void *buf, size_t n) {
  const char *p = (const char *)buf;
  while (n) {
    int w = (int)send(s, p, (int)(n > 0x40000000 ? 0x40000000 : n), DSOCK_SEND_FLAGS);
    if (w < 0 && dsock_interrupted(dsock_error())) continue;
    if (w <= 0) return -1;
    p += w;
    n -= (size_t)w;
  }
  return 0;
}

/* Reads exactly n bytes, waiting at most idle_ms between pieces (-1 forever).
 * 1 done, 0 nothing arrived before the first byte, -1 broken or stalled. */
static inline int dsock_read_all(dsock s, void *buf, size_t n, int first_ms, int idle_ms) {
  char *p = (char *)buf;
  size_t got = 0;
  while (got < n) {
    dpollfd pf;
    pf.fd = s;
    pf.events = POLLIN;
    pf.revents = 0;
    int r = dsock_poll(&pf, 1, got ? idle_ms : first_ms);
    if (r < 0 && dsock_interrupted(dsock_error())) continue;
    if (r < 0) return -1;
    if (r == 0) return got ? -1 : 0;
    int k = (int)recv(s, p + got, (int)(n - got > 0x40000000 ? 0x40000000 : n - got), 0);
    if (k < 0 && dsock_interrupted(dsock_error())) continue;
    if (k <= 0) return -1;
    got += (size_t)k;
  }
  return 1;
}

#endif
