#!/usr/bin/env bash
# Diagnose Linux computer-use readiness for the Codex AppImage.
#
# Checks: session type (Wayland/X11/headless), screenshot backends,
# input-automation tooling, desktop portal, uinput/userns.
# Safe headless behavior: never takes a screenshot, never synthesizes input,
# never touches /dev — presence/version probes only.
#
# Usage: scripts/computer-use-check.sh [--json]
# Exit code is always 0 unless --json output itself fails; individual
# results are PASS/WARN/FAIL rows (human or JSON).
set -u

JSON_OUT=0
if [ "${1:-}" = "--json" ]; then JSON_OUT=1; fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: scripts/computer-use-check.sh [--json]"
  exit 0
fi

RESULTS=""  # newline-separated: name|status|detail

add() { RESULTS="${RESULTS}${1}|${2}|${3}
"; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Session type ---------------------------------------------------------
SESSION="headless"
if [ -n "${WAYLAND_DISPLAY:-}" ]; then SESSION="wayland"; fi
if [ -n "${DISPLAY:-}" ]; then
  if [ "$SESSION" = "wayland" ]; then SESSION="wayland+x11"; else SESSION="x11"; fi
fi
case "$SESSION" in
  headless) add "session" "FAIL" "no WAYLAND_DISPLAY or DISPLAY; GUI automation needs a session" ;;
  *)        add "session" "PASS" "detected $SESSION" ;;
esac

# --- 2. Screenshot tooling ---------------------------------------------------
SHOT_DETAIL=""
SHOT_STATUS="FAIL"
for tool in grim gnome-screenshot scrot import; do
  if have "$tool"; then
    SHOT_DETAIL="$tool"
    SHOT_STATUS="PASS"
    break
  fi
done
if [ "$SHOT_STATUS" = "FAIL" ]; then
  SHOT_DETAIL="none of grim, gnome-screenshot, scrot, ImageMagick import found"
elif have grim && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
  SHOT_STATUS="WARN"; SHOT_DETAIL="grim present but no display session"
fi
if [ -x "$(dirname "$0")/../resources/bin/screencapture" ]; then
  SHOT_DETAIL="$SHOT_DETAIL; bundled screencapture shim present"
fi
add "screenshot" "$SHOT_STATUS" "$SHOT_DETAIL"

# --- 3. Input automation ------------------------------------------------------
INPUT_STATUS="FAIL"
INPUT_DETAIL="none of ydotool, wtype, xdotool, dotool found"
for tool in ydotool wtype xdotool dotool; do
  if have "$tool"; then INPUT_STATUS="PASS"; INPUT_DETAIL="$tool available"; break; fi
done
if [ "$SESSION" = "headless" ] && [ "$INPUT_STATUS" = "PASS" ]; then
  INPUT_STATUS="WARN"; INPUT_DETAIL="$INPUT_DETAIL but no display session"
fi
add "input" "$INPUT_STATUS" "$INPUT_DETAIL"

# --- 4. Desktop portal (screencast/remote-desktop for Wayland) ----------------
if have busctl; then
  if busctl --user list 2>/dev/null | grep -q org.freedesktop.portal.Desktop; then
    add "portal" "PASS" "org.freedesktop.portal.Desktop on user bus"
  else
    add "portal" "WARN" "no org.freedesktop.portal.Desktop on user bus"
  fi
elif have gdbus; then
  if gdbus call --session --dest org.freedesktop.DBus --object-path / \
      --method org.freedesktop.DBus.ListNames 2>/dev/null \
      | grep -q org.freedesktop.portal.Desktop; then
    add "portal" "PASS" "org.freedesktop.portal.Desktop on session bus"
  else
    add "portal" "WARN" "no org.freedesktop.portal.Desktop on session bus"
  fi
else
  add "portal" "WARN" "cannot query session bus (no busctl/gdbus)"
fi

# --- 5. uinput (kernel-level input injection) ---------------------------------
if [ -e /dev/uinput ]; then
  if [ -r /dev/uinput ] && [ -w /dev/uinput ]; then
    add "uinput" "PASS" "/dev/uinput readable+writable"
  else
    add "uinput" "WARN" "/dev/uinput exists but not accessible (permission)"
  fi
else
  add "uinput" "WARN" "no /dev/uinput; kernel input injection unavailable"
fi

# --- 6. User namespaces (Electron/Chromium sandbox) ---------------------------
if [ -r /proc/sys/user/max_user_namespaces ]; then
  MAXNS="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)"
  if [ "$MAXNS" -gt 0 ] 2>/dev/null; then
    add "userns" "PASS" "max_user_namespaces=$MAXNS"
  else
    add "userns" "WARN" "user namespaces disabled; Electron needs --no-sandbox"
  fi
else
  add "userns" "WARN" "cannot read max_user_namespaces"
fi

# --- Report -------------------------------------------------------------------
if [ "$JSON_OUT" -eq 1 ]; then
  python3 - "$RESULTS" <<'EOF'
import json, sys
checks = []
for line in sys.argv[1].splitlines():
    name, status, detail = line.split("|", 2)
    checks.append({"name": name, "status": status, "detail": detail})
overall = "PASS"
if any(c["status"] == "FAIL" for c in checks):
    overall = "FAIL"
elif any(c["status"] == "WARN" for c in checks):
    overall = "WARN"
print(json.dumps({"overall": overall, "checks": checks}, indent=2))
EOF
  exit 0
fi

printf '%-10s %-6s %s\n' "CHECK" "STATUS" "DETAIL"
while IFS='|' read -r name status detail; do
  [ -z "$name" ] && continue
  printf '%-10s %-6s %s\n' "$name" "$status" "$detail"
done <<< "$RESULTS"
