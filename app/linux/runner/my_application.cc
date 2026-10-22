#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cstdio>
#include <set>
#include <string>

#include "dena/desktop_loader.h"
#include "dena_sleep.h"
#include "flutter/generated_plugin_registrant.h"

// The game picture: the newest frame of the desktop host library as RGBA
// bytes (docs/specs/desktop-shell.md).
G_DECLARE_FINAL_TYPE(DenaGameTexture, dena_game_texture, DENA, GAME_TEXTURE,
                     FlPixelBufferTexture)

struct _DenaGameTexture {
  FlPixelBufferTexture parent_instance;
  dena::DesktopHost* host;
};

G_DEFINE_TYPE(DenaGameTexture, dena_game_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean dena_game_texture_copy_pixels(FlPixelBufferTexture* texture,
                                              const uint8_t** buffer,
                                              uint32_t* width, uint32_t* height,
                                              GError** error) {
  DenaGameTexture* self = DENA_GAME_TEXTURE(texture);
  if (self->host->loaded() && self->host->frame_rgba(buffer, width, height)) {
    return TRUE;
  }
  static const uint8_t kBlack[4] = {0, 0, 0, 255};  // before the first frame
  *buffer = kBlack;
  *width = *height = 1;
  return TRUE;
}

static void dena_game_texture_class_init(DenaGameTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      dena_game_texture_copy_pixels;
}

static void dena_game_texture_init(DenaGameTexture* self) {}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The desktop host library (games); not loaded when it is not installed.
  dena::DesktopHost* dena;
  // Saves the game before the system sleeps (docs/specs/deck-presets.md).
  DenaSleep* sleep;
  FlBinaryMessenger* messenger;
  FlTextureRegistrar* texture_registrar;
  DenaGameTexture* game_texture;
  std::set<int>* taken_keys;    // presses a game took
  std::set<int>* flutter_keys;  // presses Flutter got (GTK repeats them)
  // The "dena/window" channel (docs/specs/controller-mode.md, Window).
  GtkWindow* window;
  FlMethodChannel* window_channel;
  gboolean fullscreen;
  gchar* placement_path;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// GDK key values as the host library's keys (dena/desktop.h).
static int dena_key(guint keyval) {
  const guint upper = gdk_keyval_to_upper(keyval);
  if ((upper >= 'A' && upper <= 'Z') || (upper >= '0' && upper <= '9')) {
    return static_cast<int>(upper);
  }
  switch (keyval) {
    case GDK_KEY_Up: return DENA_DESKTOP_KEY_UP;
    case GDK_KEY_Down: return DENA_DESKTOP_KEY_DOWN;
    case GDK_KEY_Left: return DENA_DESKTOP_KEY_LEFT;
    case GDK_KEY_Right: return DENA_DESKTOP_KEY_RIGHT;
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter: return DENA_DESKTOP_KEY_ENTER;
    case GDK_KEY_Shift_R: return DENA_DESKTOP_KEY_RSHIFT;
    case GDK_KEY_BackSpace: return DENA_DESKTOP_KEY_BACKSPACE;
    case GDK_KEY_Escape: return DENA_DESKTOP_KEY_ESCAPE;
    case GDK_KEY_space: return DENA_DESKTOP_KEY_SPACE;
    case GDK_KEY_Tab: return DENA_DESKTOP_KEY_TAB;
    default: return 0;
  }
}

// Remembered size and position: "x y w h" (positions are ignored where the
// compositor places windows itself, as on Wayland and gamescope).
static void dena_restore_placement(MyApplication* self, const gchar* path) {
  g_free(self->placement_path);
  self->placement_path = g_strdup(path);
  g_autofree gchar* text = nullptr;
  if (!g_file_get_contents(path, &text, nullptr, nullptr)) return;
  int x = 0, y = 0, w = 0, h = 0;
  if (sscanf(text, "%d %d %d %d", &x, &y, &w, &h) != 4 || w < 320 || h < 240) {
    return;
  }
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(self->window));
  // A monitor that is gone keeps the default position.
  GdkMonitor* monitor = gdk_display_get_monitor_at_point(display, x + w / 2,
                                                         y + h / 2);
  GdkRectangle area;
  if (monitor == nullptr) return;
  gdk_monitor_get_geometry(monitor, &area);
  if (x + w / 2 < area.x || x + w / 2 >= area.x + area.width ||
      y + h / 2 < area.y || y + h / 2 >= area.y + area.height) {
    return;
  }
  gtk_window_resize(self->window, w, h);
  gtk_window_move(self->window, x, y);
}

static void dena_save_placement(MyApplication* self) {
  if (self->placement_path == nullptr || self->fullscreen) return;
  int x = 0, y = 0, w = 0, h = 0;
  gtk_window_get_position(self->window, &x, &y);
  gtk_window_get_size(self->window, &w, &h);
  g_autofree gchar* text = g_strdup_printf("%d %d %d %d\n", x, y, w, h);
  g_file_set_contents(self->placement_path, text, -1, nullptr);
}

// Borderless fullscreen on the window's monitor.
static void dena_set_fullscreen(MyApplication* self, gboolean on) {
  if (on == self->fullscreen) return;
  if (on) {
    dena_save_placement(self);  // the windowed size, before it changes
    gtk_window_fullscreen(self->window);
  } else {
    gtk_window_unfullscreen(self->window);
  }
  self->fullscreen = on;
}

static void dena_window_method_cb(FlMethodChannel* channel,
                                  FlMethodCall* call, gpointer user_data) {
  auto* self = static_cast<MyApplication*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "setFullscreen") == 0 &&
      fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
    dena_set_fullscreen(self, fl_value_get_bool(args));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "isFullscreen") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(self->fullscreen);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "restorePlacement") == 0 &&
             fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
    dena_restore_placement(self, fl_value_get_string(args));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// F11 or Alt+Enter toggles fullscreen, also during a game; before the game
// and Flutter see the key.
static gboolean dena_window_key_cb(GtkWidget* widget, GdkEventKey* event,
                                   MyApplication* self) {
  const bool toggle =
      event->keyval == GDK_KEY_F11 ||
      ((event->keyval == GDK_KEY_Return || event->keyval == GDK_KEY_KP_Enter) &&
       (event->state & GDK_MOD1_MASK) != 0);
  if (!toggle) return FALSE;
  // Toggle on the first press only; repeats and the release are swallowed.
  static bool held = false;
  if (event->type == GDK_KEY_PRESS) {
    if (!held) dena_set_fullscreen(self, !self->fullscreen);
    held = true;
  } else {
    held = false;
  }
  return TRUE;
}

// The window manager can leave fullscreen on its own (a shortcut, gamescope).
static gboolean dena_window_state_cb(GtkWidget* widget,
                                     GdkEventWindowState* event,
                                     MyApplication* self) {
  if (event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN) {
    self->fullscreen =
        (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
  }
  return FALSE;
}

static void dena_start_window_channel(MyApplication* self, FlView* view,
                                      GtkWindow* window) {
  self->window = window;
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel =
      fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                            "dena/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_channel, dena_window_method_cb, self, nullptr);
  g_signal_connect(window, "key-press-event", G_CALLBACK(dena_window_key_cb),
                   self);
  g_signal_connect(window, "key-release-event",
                   G_CALLBACK(dena_window_key_cb), self);
  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(dena_window_state_cb), self);
}

// Runs on the window before Flutter's view: a playing game takes its keys.
static gboolean dena_key_cb(GtkWidget* widget, GdkEventKey* event,
                            MyApplication* self) {
  if (!self->dena->loaded()) return FALSE;
  const int key = dena_key(event->keyval);
  if (key == 0) return FALSE;
  const bool down = event->type == GDK_KEY_PRESS;
  if (down) {
    // X11 auto-repeat sends presses only: they follow the first press.
    if (self->taken_keys->count(key)) return TRUE;
    if (self->flutter_keys->count(key)) return FALSE;
    const bool taken = self->dena->key(key, true);
    (taken ? self->taken_keys : self->flutter_keys)->insert(key);
    return taken;
  }
  self->flutter_keys->erase(key);
  const bool was_taken = self->taken_keys->erase(key) != 0;
  return self->dena->key(key, false) || was_taken;
}

static void dena_update_refresh(MyApplication* self, GtkWidget* window) {
  GdkWindow* gdk_window = gtk_widget_get_window(window);
  if (!self->dena->loaded() || gdk_window == nullptr) return;
  GdkMonitor* monitor = gdk_display_get_monitor_at_window(
      gdk_window_get_display(gdk_window), gdk_window);
  if (monitor != nullptr) {
    self->dena->set_refresh(gdk_monitor_get_refresh_rate(monitor));
  }
}

static gboolean dena_configure_cb(GtkWidget* window, GdkEvent* event,
                                  MyApplication* self) {
  dena_update_refresh(self, window);
  return FALSE;
}

struct DenaPending {
  MyApplication* self;
  gchar* channel;
  GBytes* data;
};

// Main loop: a message from the host library to Dart.
static gboolean dena_send_idle(gpointer user_data) {
  auto* p = static_cast<DenaPending*>(user_data);
  if (p->self->dena->loaded() && p->self->messenger != nullptr) {
    fl_binary_messenger_send_on_channel(p->self->messenger, p->channel,
                                        p->data, nullptr, nullptr, nullptr);
  }
  g_free(p->channel);
  g_bytes_unref(p->data);
  g_free(p);
  return G_SOURCE_REMOVE;
}

static void dena_message_cb(FlBinaryMessenger* messenger, const gchar* channel,
                            GBytes* message,
                            FlBinaryMessengerResponseHandle* response_handle,
                            gpointer user_data) {
  auto* self = static_cast<MyApplication*>(user_data);
  gsize size = 0;
  const auto* data =
      static_cast<const uint8_t*>(g_bytes_get_data(message, &size));
  uint8_t* out = nullptr;
  size_t out_len = 0;
  g_autoptr(GBytes) response = nullptr;
  if (self->dena->loaded() &&
      self->dena->message(channel, data, size, &out, &out_len)) {
    response = g_bytes_new(out, out_len);
    self->dena->free_reply(out);
  }
  fl_binary_messenger_send_response(messenger, response_handle, response,
                                    nullptr);
}

// Loads lib/libdena_host.so from the bundle and connects it: the game
// texture, the GameHostApi channels and the events back to Dart.
static void dena_start(MyApplication* self, FlView* view, GtkWidget* window) {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return;
  g_autofree gchar* dir = g_path_get_dirname(exe);
  g_autofree gchar* path =
      g_build_filename(dir, "lib", "libdena_host.so", nullptr);
  if (!self->dena->load(path)) {
    g_message("dena: %s not loaded; games are unavailable", path);
    return;
  }
  FlEngine* engine = fl_view_get_engine(view);
  self->messenger = fl_engine_get_binary_messenger(engine);
  self->texture_registrar = fl_engine_get_texture_registrar(engine);
  self->game_texture = DENA_GAME_TEXTURE(
      g_object_new(dena_game_texture_get_type(), nullptr));
  self->game_texture->host = self->dena;
  fl_texture_registrar_register_texture(self->texture_registrar,
                                        FL_TEXTURE(self->game_texture));

  dena_desktop_config cfg = {};
  cfg.struct_size = sizeof(cfg);
  cfg.user = self;
  cfg.frame_ready = [](void* user) {
    auto* self = static_cast<MyApplication*>(user);
    fl_texture_registrar_mark_texture_frame_available(
        self->texture_registrar, FL_TEXTURE(self->game_texture));
  };
  cfg.send = [](void* user, const char* channel, const uint8_t* msg,
                size_t len) {
    auto* p = g_new0(DenaPending, 1);
    p->self = static_cast<MyApplication*>(user);
    p->channel = g_strdup(channel);
    p->data = g_bytes_new(msg, len);
    g_main_context_invoke(nullptr, dena_send_idle, p);
  };
  cfg.refresh_mhz = 60000;
  if (!self->dena->init(&cfg)) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->game_texture));
    *self->dena = dena::DesktopHost();
    return;
  }
  self->dena->set_texture(fl_texture_get_id(FL_TEXTURE(self->game_texture)));
  dena_update_refresh(self, window);

  const std::string channels = self->dena->channels();
  size_t start = 0;
  while (start < channels.size()) {
    size_t end = channels.find('\n', start);
    if (end == std::string::npos) end = channels.size();
    const std::string channel = channels.substr(start, end - start);
    fl_binary_messenger_set_message_handler_on_channel(
        self->messenger, channel.c_str(), dena_message_cb, self, nullptr);
    start = end + 1;
  }
  g_signal_connect(window, "key-press-event", G_CALLBACK(dena_key_cb), self);
  g_signal_connect(window, "key-release-event", G_CALLBACK(dena_key_cb), self);
  g_signal_connect(window, "configure-event", G_CALLBACK(dena_configure_cb),
                   self);
  self->sleep = dena_sleep_start(self->dena);
}

// Before the view and its engine go: the game saves, frames stop.
static void dena_stop(GtkWidget* window, MyApplication* self) {
  dena_save_placement(self);
  dena_sleep_stop(self->sleep);
  self->sleep = nullptr;
  if (!self->dena->loaded()) return;
  self->dena->shutdown();
  *self->dena = dena::DesktopHost();
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // One instance (open-with.md): launching again only raises the window.
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Dena.emu");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Dena.emu");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  dena_start_window_channel(self, view, window);
  dena_start(self, view, GTK_WIDGET(window));
  g_signal_connect(window, "destroy", G_CALLBACK(dena_stop), self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }
  *exit_status = 0;

  // Already running (open-with.md): hand a game file to that instance, or
  // just raise its window, and exit. Without a session bus every launch is
  // its own instance.
  if (g_application_get_is_remote(application)) {
    for (gchar** arg = self->dart_entrypoint_arguments; *arg != nullptr;
         arg++) {
      if (g_str_has_prefix(*arg, "-")) continue;
      g_autoptr(GFile) file = g_file_new_for_commandline_arg(*arg);
      GFile* files[] = {file};
      g_application_open(application, files, 1, "");
      return TRUE;
    }
  }
  g_application_activate(application);
  return TRUE;
}

// Implements GApplication::open: a game file from a second launch.
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  g_autofree gchar* path = n_files > 0 ? g_file_get_path(files[0]) : nullptr;
  if (self->window == nullptr) {
    // No window yet: start with the file as the argument.
    if (path != nullptr) {
      g_strfreev(self->dart_entrypoint_arguments);
      gchar* args[] = {path, nullptr};
      self->dart_entrypoint_arguments = g_strdupv(args);
    }
    g_application_activate(application);
    return;
  }
  gtk_window_present(self->window);
  if (path != nullptr && self->window_channel != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_string(path);
    fl_method_channel_invoke_method(self->window_channel, "openFile", value,
                                    nullptr, nullptr, nullptr);
  }
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  dena_sleep_stop(self->sleep);
  self->sleep = nullptr;
  if (self->dena != nullptr) {
    if (self->dena->loaded()) self->dena->shutdown();
    delete self->dena;
    self->dena = nullptr;
  }
  g_clear_object(&self->window_channel);
  g_clear_pointer(&self->placement_path, g_free);
  delete self->taken_keys;
  delete self->flutter_keys;
  self->taken_keys = self->flutter_keys = nullptr;
  g_clear_object(&self->game_texture);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->dena = new dena::DesktopHost();
  self->taken_keys = new std::set<int>();
  self->flutter_keys = new std::set<int>();
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_OPEN, nullptr));
}
