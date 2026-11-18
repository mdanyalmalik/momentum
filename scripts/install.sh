#!/bin/sh
# Builds Momentum and installs it to /Applications (or $MOMENTUM_INSTALL_DIR).
# Safe to run while Momentum is open: the running copy shows "Update installed — Restart"
# in the sidebar, and restarting keeps any running timer.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST_DIR="${MOMENTUM_INSTALL_DIR:-/Applications}"
scripts/build-app.sh release
DEST="$DEST_DIR/Momentum.app"
STAGE="$DEST_DIR/.Momentum.app.new"
rm -rf "$STAGE"
ditto build/Momentum.app "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
# Refresh Launchpad/Spotlight's view of the app (icon, name).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
echo "Installed $DEST"
