/* Link cable over Wi-Fi: one TCP connection between two devices on the same
 * network, plus a UDP broadcast beacon so the joiner can find the host; on
 * the desktop a joiner can also reach a relay room (net_room.h).
 * Spec: docs/specs/link-cable.md
 *
 * One link per process. All functions are thread-safe; the emulator thread
 * only touches it through the dena_link_api handed to the core. */
#ifndef DENA_LINK_H
#define DENA_LINK_H

#include <stddef.h>
#include <stdint.h>

#include "dena/link_api.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define DENA_LINK_EXPORT
#else
#define DENA_LINK_EXPORT __attribute__((visibility("default")))
#endif

#define DENA_LINK_PORT 47320        /* TCP, game traffic */
#define DENA_LINK_BEACON_PORT 47321 /* UDP broadcast, discovery */

enum {
  DENA_LINK_OFF = 0,
  DENA_LINK_WAITING = 1,   /* hosting, or connecting */
  DENA_LINK_CONNECTED = 2,
  DENA_LINK_FAILED = 3     /* see dena_link_error() */
};

/* Hosts on port (0 = DENA_LINK_PORT) and announces name on the beacon.
 * Replaces any current link. Returns 0, or -1 (see dena_link_error()). */
DENA_LINK_EXPORT int dena_link_host(int port, const char *name);
/* Connects to a host by IPv4 address or name. Returns 0 once started;
 * the connection completes in the background. */
DENA_LINK_EXPORT int dena_link_join(const char *address, int port);
/* Internet play (netplay.md): joins a room code (needs relay) or
 * "host[:port]", direct first and through the relay when that fails. */
DENA_LINK_EXPORT int dena_link_join_room(const char *target, const char *relay);
DENA_LINK_EXPORT void dena_link_stop(void);
DENA_LINK_EXPORT int dena_link_state(void);
/* DENA_LINK_PARENT (host) or DENA_LINK_CHILD (joiner). */
DENA_LINK_EXPORT int dena_link_role(void);
/* Static strings, valid until the next call into this module. */
DENA_LINK_EXPORT const char *dena_link_error(void);
DENA_LINK_EXPORT const char *dena_link_peer(void);
/* The room code while hosting a relay room: always "" in this edition,
 * which hosts only on the local network. */
DENA_LINK_EXPORT const char *dena_link_room_code(void);
/* 1 while the connection goes through the relay. */
DENA_LINK_EXPORT int dena_link_via_relay(void);

/* Discovery: listens for beacons until dena_link_scan_stop(). Results are
 * "name\taddress\tport\n" lines for hosts heard in the last 3 seconds;
 * returns the bytes written (truncated to fit, always NUL-terminated). */
DENA_LINK_EXPORT int dena_link_scan_start(void);
DENA_LINK_EXPORT void dena_link_scan_stop(void);
DENA_LINK_EXPORT int dena_link_scan_results(char *out, int len);

/* This device's Wi-Fi (or first non-loopback) IPv4 address, for showing to
 * the person joining by hand. Returns its length, 0 when there is none. */
DENA_LINK_EXPORT int dena_link_local_address(char *out, int len);

/* The transport for cores (dena_link_attach). */
const struct dena_link_api *dena_link_core_api(void);

#ifdef __cplusplus
}
#endif

#endif
