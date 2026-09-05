#!/usr/bin/env bash
# AppRun for the Codex Linux AppImage.
# Only honest, minimal flags: --no-sandbox handling for root/container
# environments and wiring for the bundled screencapture shim.
set -u

APPDIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export APPDIR

# Make the bundled screencapture shim (and any other helpers) discoverable.
if [ -d "$APPDIR/usr/bin" ]; then
  export PATH="$APPDIR/usr/bin:$PATH"
fi

ELECTRON="$APPDIR/usr/lib/codex/electron"
[ -x "$ELECTRON" ] || ELECTRON="$APPDIR/usr/bin/electron"
APP_ASAR="$APPDIR/usr/lib/codex/resources/app.asar"

EXTRA_ARGS=()
# Chromium sandbox needs root or userns setup; running as root without
# --no-sandbox fails, so add it automatically only in that case.
if [ "$(id -u)" -eq 0 ] && [[ " $* " != *" --no-sandbox "* ]]; then
  EXTRA_ARGS+=(--no-sandbox)
fi

exec "$ELECTRON" "$APP_ASAR" "${EXTRA_ARGS[@]}" "$@"
