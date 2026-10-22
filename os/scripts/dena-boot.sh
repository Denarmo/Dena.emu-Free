#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Dena.emu boot hook: run from the stock firmware's startup when the card holds
# Dena/. Applies a pending update, starts the power daemon and the launcher,
# and returns to the stock system when the launcher exits. Without the card,
# or if anything is missing, it exits at once and the stock OS carries on.
# On the single-card system (docs/specs/single-card.md) the app comes from the
# system image: DENA_APP names it, and an app installed on the card by an
# update zip (Dena/bin/dena-launcher) wins over it.
# POSIX sh (busybox). Spec: docs/specs/sd-card.md
set -u

here="$(cd "$(dirname "$0")" && pwd)"
CARD="${DENA_CARD:-$(cd "$here/../.." && pwd)}"
DENA="$CARD/Dena"
LOG="$DENA/user/boot.log"

[ -d "$DENA" ] || exit 0
mkdir -p "$DENA/user"
: > "$LOG"
log() { echo "$(date '+%H:%M:%S' 2>/dev/null) $*" >> "$LOG"; }

# 1. A Dena-update-*.zip on the card root replaces Dena/ (sd-card.md, Updates).
#    Run a copy from /tmp: the update replaces the folder the script lives in.
updater_src="$DENA/bin/dena-update.sh"
[ -f "$updater_src" ] || updater_src="${DENA_APP:-$DENA}/bin/dena-update.sh"
if [ -f "$updater_src" ]; then
  updater="${TMPDIR:-/tmp}/dena-update.$$.sh"
  cp "$updater_src" "$updater" &&
    sh "$updater" "$CARD" >> "$LOG" 2>&1 || log "update failed"
  rm -f "$updater"
  mkdir -p "$DENA/user"
fi

APP="$DENA"
[ -x "$DENA/bin/dena-launcher" ] || APP="${DENA_APP:-$DENA}"
launcher="$APP/bin/dena-launcher"
if [ ! -x "$launcher" ]; then
  log "no launcher: back to the stock system"
  exit 0
fi

export DENA_HANDHELD=1
export DENA_CARD="$CARD"
export LD_LIBRARY_PATH="$APP/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 2. Power daemon (sleep, battery, safe shutdown), with a user profile if any.
powerd_pid=""
if [ -x "$APP/bin/dena-powerd" ]; then
  set -- --socket /tmp/dena-power.sock
  for f in "$DENA"/user/devices/*.conf; do
    [ -f "$f" ] && set -- "$@" --profile "$f" && break
  done
  "$APP/bin/dena-powerd" "$@" >> "$LOG" 2>&1 &
  powerd_pid=$!
  log "powerd $powerd_pid"
fi

# 3. The launcher (embedder + UI + emulator host), in the foreground: the app
#    bundle in data/app, and the same user device profile if any.
set -- "$APP/data/app"
for f in "$DENA"/user/devices/*.conf; do
  [ -f "$f" ] && set -- "$@" "$f" && break
done
log "launcher start"
"$launcher" "$@" >> "$LOG" 2>&1
log "launcher exit $?"

# Wait for it: it holds the log on the card, which USB storage mode unmounts.
if [ -n "$powerd_pid" ]; then
  kill "$powerd_pid" 2>/dev/null
  wait "$powerd_pid" 2>/dev/null
fi
sync
exit 0
