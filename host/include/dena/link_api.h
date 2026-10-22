/* Link cable transport handed from the frontend to a core.
 * Spec: docs/specs/link-cable.md
 *
 * Shared verbatim with cores/mgba/dena_link.c (copied next to it at build
 * time), so it only uses the C standard library. */
#ifndef DENA_LINK_API_H
#define DENA_LINK_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DENA_LINK_API_VERSION 1

/* Message kinds. A reply carries the request kind with DENA_LINK_REPLY set. */
enum {
  DENA_LINK_GB = 0x10,          /* GB/GBC serial byte */
  DENA_LINK_GBA_NORMAL = 0x20,  /* GBA normal mode, 8 or 32 bit */
  DENA_LINK_GBA_MULTI = 0x30,   /* GBA multiplayer, 16 bit */
  DENA_LINK_REPLY = 0x80
};

enum { DENA_LINK_PARENT = 0, DENA_LINK_CHILD = 1 };

struct dena_link_api {
  uint32_t version;
  void *user;
  /* Non-zero while a peer is connected. */
  int (*connected)(void *user);
  /* DENA_LINK_PARENT for the hosting device, DENA_LINK_CHILD for the joiner. */
  int (*role)(void *user);
  /* Queues one message; returns 0, or -1 when not connected. */
  int (*send)(void *user, uint8_t kind, uint32_t value);
  /* Takes the next received message, waiting up to timeout_ms (0 = poll).
   * Returns 1 with a message, 0 on timeout, -1 when not connected. */
  int (*recv)(void *user, uint8_t *kind, uint32_t *value, int timeout_ms);
};

/* Exported by a core that supports the link cable. */
typedef void (*dena_link_attach_fn)(const struct dena_link_api *api);

#ifdef __cplusplus
}
#endif

#endif
