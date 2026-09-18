#!/bin/bash
# install.sh — build strafe, install it to /Applications, launch it, and open
# the Accessibility pane so you can grant the one permission it needs.
#
# This is Scripts/bundle.sh plus the three manual steps that follow it. Nothing
# here is privileged: it copies a bundle you just built into /Applications and
# opens a Settings pane. Read it before you run it — that is the whole point of
# strafe being distributed as source.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="strafe"
BUNDLE_ID="com.rileycx.strafe"
SRC="$ROOT_DIR/build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

# --- Preflight: the Swift toolchain -----------------------------------------
# Package.swift is swift-tools-version 6.3. An older toolchain fails deep inside
# `swift build` with a message that reads like a bug in strafe, so check up front
# and say what is actually wrong.
if ! command -v swift >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: no Swift toolchain found.

Install Apple's command line tools first, then re-run this script:

    xcode-select --install

That is a ~1.5 GB download and takes a few minutes.
EOF
  exit 1
fi

# --- Build -------------------------------------------------------------------
"$SCRIPT_DIR/bundle.sh"

if [[ ! -d "$SRC" ]]; then
  echo "error: expected a bundle at $SRC but bundle.sh produced none" >&2
  exit 1
fi

# --- Replace any previous install -------------------------------------------
# Quit a running copy first: the bundle cannot be replaced underneath a live
# process.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Quitting the running ${APP_NAME}…"
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
  sleep 1
fi

if [[ -e "$DEST" ]]; then
  # Only ever remove something that is actually strafe. If a different app is
  # sitting at that path, stop and let a human sort it out rather than deleting
  # it. Overwriting the wrong /Applications entry is not a recoverable mistake.
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$DEST/Contents/Info.plist" 2>/dev/null || echo "")"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "error: $DEST exists but its bundle id is '$EXISTING_ID', not '$BUNDLE_ID'." >&2
    echo "       Refusing to replace it. Move it aside yourself and re-run." >&2
    exit 1
  fi
  echo "==> Replacing the existing ${DEST}…"
  rm -rf "$DEST"
fi

echo "==> Installing to ${DEST}…"
cp -R "$SRC" "$DEST"

# --- Launch + hand off the one step macOS reserves for a human ---------------
echo "==> Launching ${APP_NAME}…"
open "$DEST"

echo "==> Opening Privacy & Security › Accessibility…"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

cat <<EOF

Installed: $DEST

Grant Accessibility to strafe in the pane that just opened, then:

  1. Delete any older/stale "strafe" rows in that list first. This build is
     ad-hoc signed, so its identity changes on every rebuild and macOS may show
     a previous build as a separate entry.
  2. Check that strafe's menu says "Swipe interception is active". It retries
     automatically when permission becomes available. If macOS still holds an
     old build's permission identity, re-grant access and quit/relaunch strafe.
  3. Three-finger swipe between Spaces. It should be instant.

EOF
