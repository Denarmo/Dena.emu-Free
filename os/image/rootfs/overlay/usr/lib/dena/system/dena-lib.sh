# SPDX-License-Identifier: GPL-3.0-or-later
# Dena.emu system image: helpers shared by the init scripts (sourced, not run).
# docs/specs/single-card.md, "Release and diagnostic mode".
# DENA_TEST_ROOT puts every path below under a scratch folder (os/tests).
ROOT="${DENA_TEST_ROOT:-}"
CARD=$ROOT/mnt/card
RUN=$ROOT/run/dena
LOG=$RUN/init.log
SPLASH=$RUN/splash
SPLASH_BIN=$ROOT/usr/lib/dena/bin/dena-splash
CONSOLE=${ROOT:+$ROOT/console}
CONSOLE=${CONSOLE:-/dev/console}

# dena.diag on the kernel command line (build.sh --diagnostic): kernel text on
# the panel, no splash. Dena/diagnostic on the card: splash as usual, but the
# logs below are written to Dena/user.
cmdline_diag() { grep -qw dena.diag "$ROOT/proc/cmdline" 2>/dev/null; }
diag() { cmdline_diag || [ -e "$CARD/Dena/diagnostic" ]; }

# Every line goes to the console (the serial port) and, with its boot time,
# to /run/dena/init.log; diagnostic mode copies that to the card.
log() {
  echo "dena-init: $*" > "$CONSOLE"
  echo "$(cut -d' ' -f1 /proc/uptime) $*" >> "$LOG"
}

# The splash daemon (dena-splash --daemon) shows whatever this file says:
# "logo", "message TEXT", "progress PCT TEXT" or "quit". Replaced, never
# written in place, so the daemon never reads half a line.
splash() {
  echo "$*" > "$SPLASH.new" && mv -f "$SPLASH.new" "$SPLASH"
}

# One-off screen once the daemon is gone (shutdown).
splash_now() {
  cmdline_diag || [ ! -x "$SPLASH_BIN" ] || "$SPLASH_BIN" "$@" 2> /dev/null
}

# Kernel log, display state and this boot's init log on the card, so a
# problem can be read back on a PC. Replaced on every boot; diagnostic only.
save_diag() {
  diag || return 0
  [ -d "$CARD/Dena/user" ] || return 0
  cp "$LOG" "$CARD/Dena/user/init.log"
  t=$(cut -d' ' -f1 /proc/uptime)
  {
    echo "--- $1 ($t s)"
    for s in /sys/class/drm/card*-*/status; do
      [ -e "$s" ] && echo "$s: $(cat "$s")"
    done
    ls -l /dev/dri /dev/fb* /sys/class/backlight 2>&1
    dmesg
  } > "$CARD/Dena/user/dmesg.log" 2>&1
  sync
}
