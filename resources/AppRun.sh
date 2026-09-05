#!/usr/bin/env bash
# AppRun for the Codex Linux AppImage.
# Default flags are the same ones the community codex-desktop-linux port
# launches with: GPU compositing off (fixes black/flickering windows on
# several Linux GPU setups), GPU sandbox off (same class of issue), and
# automatic X11/Wayland selection. User-supplied arguments are appended
# after these, so passing your own --disable-gpu etc. still wins.
set -u

APPDIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export APPDIR

# Make the bundled screencapture shim (and any other helpers) discoverable.
if [ -d "$APPDIR/usr/bin" ]; then
  export PATH="$APPDIR/usr/bin:$PATH"
fi

ELECTRON="$APPDIR/usr/lib/codex/electron"
[ -x "$ELECTRON" ] || ELECTRON="$APPDIR/usr/bin/electron"

EXTRA_ARGS=(
  --ozone-platform-hint=auto
  --disable-gpu-sandbox
  --disable-gpu-compositing
)
# Chromium sandbox needs root or userns setup; running as root without
# --no-sandbox fails, so add it automatically only in that case.
if [ "$(id -u)" -eq 0 ] && [[ " $* " != *" --no-sandbox "* ]]; then
  EXTRA_ARGS+=(--no-sandbox)
fi

# IMPORTANT: never pass the app.asar path here. An explicit app path makes
# Electron run unpackaged (app.isPackaged=false), and this app loads a
# localhost dev server instead of its bundled UI when unpackaged — the
# window comes up black. The packaged app is picked up automatically from
# <exe-dir>/resources/app.asar, which is where the build places it.
#
# Belt and braces: force packaged mode explicitly too. Without this the
# app still reports unpackaged inside some launchers and takes the same
# broken dev-server path.
export ELECTRON_FORCE_IS_PACKAGED=1
exec "$ELECTRON" "${EXTRA_ARGS[@]}" "$@"
