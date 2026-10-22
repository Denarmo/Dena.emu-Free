/* Rooms: the connection both the link cable and netplay play over. A host
 * listens for a direct connection; a joiner gives an address, or a room
 * code held on a relay server, and gets one connected TCP socket, direct
 * when it can, bridged by the relay when it cannot. This edition does not
 * register rooms on a relay (hosting a relay room is not included).
 * Spec: docs/specs/netplay.md (Rooms and connecting)
 *
 * Sockets are passed as intptr_t (a SOCKET on Windows, an fd elsewhere);
 * -1 is "none". Blocking calls; run them on a worker thread. */
#ifndef DENA_NET_ROOM_H
#define DENA_NET_ROOM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DENA_NETPLAY_PORT 47330 /* TCP, netplay (the link cable keeps 47320) */
#define DENA_RELAY_PORT 47340   /* the relay's default port */
#define DENA_ROOM_CODE_LEN 6
#define DENA_ROOM_ALPHABET "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

typedef struct dena_room {
  intptr_t listen_sock; /* direct connections */
  int port;
} dena_room;

/* Starts listening on port. 0, or -1 with err set. */
int dena_room_open(dena_room *r, int port, char *err, int errlen);
/* Waits up to timeout_ms for the other player (*via_relay is set to 0).
 * Returns the connected socket; -1 when nobody came yet; -2 when the room
 * is closed (err set). */
intptr_t dena_room_accept(dena_room *r, int timeout_ms, int *via_relay, char *peer, int peerlen,
                          char *err, int errlen);
void dena_room_close(dena_room *r);

/* Joins target: a room code (needs relay) or "host[:port]" (default_port
 * when none). Tries direct addresses first, then the relay bridge. stop is
 * checked between attempts (may be NULL). Returns the connected socket, or
 * -1 with err set. DENA_NET_RELAY_ONLY=1 in the environment skips the direct
 * attempts (tests). */
intptr_t dena_room_connect(const char *target, int default_port, const char *relay,
                           const volatile int *stop, int *via_relay, char *peer, int peerlen,
                           char *err, int errlen);

/* 1 when text is a room code (six letters/digits of DENA_ROOM_ALPHABET,
 * any case). */
int dena_room_is_code(const char *text);
/* This computer's LAN IPv4 address; returns its length, 0 for none. */
int dena_room_local_address(char *out, int len);
/* Closes a socket returned above. */
void dena_room_close_socket(intptr_t s);

#ifdef __cplusplus
}
#endif

#endif
