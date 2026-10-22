#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Update by file: the newest Dena-update-<version>.zip on the card root
# replaces Dena/, keeping Dena/user/ (settings, device profile overrides,
# logs). The zip is checked against its manifest first; a bad zip changes
# nothing and is renamed *.failed. POSIX sh (busybox unzip, sha256sum).
# Usage: dena-update.sh <card root>. Spec: docs/specs/sd-card.md
set -u
CARD="${1:?usage: dena-update.sh <card root>}"
cd "$CARD" || exit 1

zip=""
for f in Dena-update-*.zip; do
  [ -f "$f" ] && zip="$f"   # glob order: the last is the newest version
done
[ -n "$zip" ] || exit 0
echo "dena-update: applying $zip"

tmp=".dena-update-tmp"
rm -rf "$tmp"
mkdir "$tmp"
fail() {
  echo "dena-update: $1"
  rm -rf "$tmp"
  mv "$zip" "$zip.failed"
  exit 1
}

unzip -o -q "$zip" -d "$tmp" < /dev/null || fail "cannot unzip"
[ -d "$tmp/Dena" ] && [ -f "$tmp/manifest.sha256" ] || fail "not an update zip"
(cd "$tmp" && sha256sum -c -s manifest.sha256 2>/dev/null ||
  sha256sum -c manifest.sha256 > /dev/null) || fail "checksum mismatch"

# Swap: Dena/ → Dena.old/, new → Dena/, carry user/ over, drop the old copy.
if [ -d Dena/user ]; then
  rm -rf "$tmp/Dena/user"
  mv Dena/user "$tmp/Dena/user"
fi
restore_user() {
  [ -d "$tmp/Dena/user" ] && [ ! -e Dena/user ] && mv "$tmp/Dena/user" Dena/user
}
rm -rf Dena.old
if [ -d Dena ] && ! mv Dena Dena.old; then
  restore_user
  fail "cannot move the old Dena/ aside"
fi
if [ -e Dena ] || ! mv "$tmp/Dena" Dena; then
  # Put everything back as it was.
  [ -d Dena.old ] && [ ! -e Dena ] && mv Dena.old Dena
  restore_user
  fail "cannot replace Dena/"
fi
rm -rf Dena.old "$tmp"
mv "$zip" "$zip.applied"
sync
echo "dena-update: done"
