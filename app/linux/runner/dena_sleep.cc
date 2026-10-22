// SPDX-License-Identifier: GPL-3.0-or-later
// logind's PrepareForSleep with a delay inhibitor: on "going to sleep" the
// host pauses the game (writing its saves), then the inhibitor is closed so
// sleep goes on; on "woke up" the game continues and a new inhibitor is
// taken. Spec: docs/specs/deck-presets.md (Suspend and resume)
#include "dena_sleep.h"

#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <unistd.h>

namespace {

constexpr char kLogind[] = "org.freedesktop.login1";
constexpr char kPath[] = "/org/freedesktop/login1";
constexpr char kManager[] = "org.freedesktop.login1.Manager";

}  // namespace

struct DenaSleep {
  dena::DesktopHost* host = nullptr;
  GDBusConnection* bus = nullptr;
  GCancellable* cancel = nullptr;
  guint signal = 0;
  int inhibit_fd = -1;
};

static void dena_sleep_release(DenaSleep* self) {
  if (self->inhibit_fd >= 0) {
    close(self->inhibit_fd);
    self->inhibit_fd = -1;
  }
}

static void dena_sleep_inhibited_cb(GObject* source, GAsyncResult* result,
                                    gpointer user_data) {
  GUnixFDList* fds = nullptr;
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_with_unix_fd_list_finish(
      G_DBUS_CONNECTION(source), &fds, result, &error);
  if (reply == nullptr) {
    if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
      g_message("dena: no sleep inhibitor (%s); games are not saved "
                "before sleep",
                error->message);
    }
    return;
  }
  auto* self = static_cast<DenaSleep*>(user_data);
  gint32 index = -1;
  g_variant_get(reply, "(h)", &index);
  const int fd = fds != nullptr ? g_unix_fd_list_get(fds, index, nullptr) : -1;
  g_clear_object(&fds);
  if (fd < 0) return;
  dena_sleep_release(self);
  self->inhibit_fd = fd;
}

// Holds sleep back until the game is saved (logind waits up to its
// InhibitDelayMaxSec, 5 s by default).
static void dena_sleep_inhibit(DenaSleep* self) {
  if (self->inhibit_fd >= 0) return;
  g_dbus_connection_call_with_unix_fd_list(
      self->bus, kLogind, kPath, kManager, "Inhibit",
      g_variant_new("(ssss)", "sleep", "Dena.emu",
                    "Saving the game before sleep", "delay"),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
      self->cancel, dena_sleep_inhibited_cb, self);
}

// Main loop (the bus was got before the loop runs, so signals arrive on
// the main context): the same thread as every other host call.
static void dena_sleep_signal_cb(GDBusConnection* connection,
                                 const gchar* sender, const gchar* path,
                                 const gchar* interface, const gchar* signal,
                                 GVariant* parameters, gpointer user_data) {
  auto* self = static_cast<DenaSleep*>(user_data);
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) return;
  gboolean going = FALSE;
  g_variant_get(parameters, "(b)", &going);
  if (going) {
    if (self->host->loaded() && self->host->suspend) self->host->suspend();
    dena_sleep_release(self);  // saved: let the system sleep
  } else {
    if (self->host->loaded() && self->host->resume) self->host->resume();
    dena_sleep_inhibit(self);
  }
}

DenaSleep* dena_sleep_start(dena::DesktopHost* host) {
  if (host == nullptr || !host->loaded() || host->suspend == nullptr) {
    return nullptr;
  }
  g_autoptr(GError) error = nullptr;
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &error);
  if (bus == nullptr) {
    g_message("dena: no system bus (%s); games are not saved before sleep",
              error->message);
    return nullptr;
  }
  auto* self = new DenaSleep();
  self->host = host;
  self->bus = bus;
  self->cancel = g_cancellable_new();
  self->signal = g_dbus_connection_signal_subscribe(
      bus, kLogind, kManager, "PrepareForSleep", kPath, nullptr,
      G_DBUS_SIGNAL_FLAGS_NONE, dena_sleep_signal_cb, self, nullptr);
  dena_sleep_inhibit(self);
  return self;
}

void dena_sleep_stop(DenaSleep* self) {
  if (self == nullptr) return;
  g_cancellable_cancel(self->cancel);
  g_dbus_connection_signal_unsubscribe(self->bus, self->signal);
  dena_sleep_release(self);
  g_clear_object(&self->cancel);
  g_clear_object(&self->bus);
  delete self;
}
