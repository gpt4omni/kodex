#!/usr/bin/env bash
# Compare the upstream Codex release tag against local state.
#
# Usage: scripts/check-version.sh [--json] [--upstream-tag TAG]
#                                  [--workdir DIR] [--timeout SECONDS]
#
# Exit codes: 0 = update available, 1 = up-to-date, 2 = error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_TAG=""
WORKDIR="$(pwd)"
TIMEOUT=30
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT=1; shift ;;
    --upstream-tag) UPSTREAM_TAG="${2:?--upstream-tag needs a value}"; shift 2 ;;
    --workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$SCRIPT_DIR/check-version.sh" | sed 's/^# \?//'
      echo "Exit codes: 0 update available, 1 up-to-date, 2 error."
      exit 2 ;;
    *) echo "check-version: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() {  # fail <message>  (JSON-aware, exit 2)
  if [ "$JSON_OUT" -eq 1 ]; then
    printf '{"error": "%s"}\n' "$1"
  else
    echo "check-version: error: $1" >&2
  fi
  exit 2
}

# --- Determine upstream tag -------------------------------------------------
if [ -z "$UPSTREAM_TAG" ]; then
  if ! UPSTREAM_TAG="$("$SCRIPT_DIR/fetch-upstream.py" --tag-only --timeout "$TIMEOUT" 2>/dev/null)"; then
    fail "could not fetch upstream appcast"
  fi
  if [ -z "$UPSTREAM_TAG" ] || [[ "$UPSTREAM_TAG" == *"="* ]]; then
    fail "upstream arm64/x64 feeds disagree ($UPSTREAM_TAG); refusing to guess"
  fi
fi

# --- Determine local tag ----------------------------------------------------
# Precedence: dist/latest.json ("tag"), dist/version.txt, version.txt,
# latest.json ("tag").
LOCAL_TAG=""
LOCAL_SOURCE="none"
if [ -f "$WORKDIR/dist/latest.json" ]; then
  LOCAL_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag",""))' "$WORKDIR/dist/latest.json" 2>/dev/null)"
  [ -n "$LOCAL_TAG" ] && LOCAL_SOURCE="dist/latest.json"
fi
if [ -z "$LOCAL_TAG" ] && [ -f "$WORKDIR/dist/version.txt" ]; then
  LOCAL_TAG="$(tr -d '[:space:]' < "$WORKDIR/dist/version.txt")"
  [ -n "$LOCAL_TAG" ] && LOCAL_SOURCE="dist/version.txt"
fi
if [ -z "$LOCAL_TAG" ] && [ -f "$WORKDIR/version.txt" ]; then
  LOCAL_TAG="$(tr -d '[:space:]' < "$WORKDIR/version.txt")"
  [ -n "$LOCAL_TAG" ] && LOCAL_SOURCE="version.txt"
fi
if [ -z "$LOCAL_TAG" ] && [ -f "$WORKDIR/latest.json" ]; then
  LOCAL_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag",""))' "$WORKDIR/latest.json" 2>/dev/null)"
  [ -n "$LOCAL_TAG" ] && LOCAL_SOURCE="latest.json"
fi

# --- Compare -----------------------------------------------------------------
if [ -z "$LOCAL_TAG" ]; then
  UPDATE=true
elif [ "$LOCAL_TAG" = "$UPSTREAM_TAG" ]; then
  UPDATE=false
else
  UPDATE=true
fi

if [ "$JSON_OUT" -eq 1 ]; then
  printf '{"upstream": "%s", "local": "%s", "local_source": "%s", "update_available": %s}\n' \
    "$UPSTREAM_TAG" "$LOCAL_TAG" "$LOCAL_SOURCE" "$UPDATE"
else
  echo "upstream: $UPSTREAM_TAG"
  echo "local:    ${LOCAL_TAG:-<none>} (source: $LOCAL_SOURCE)"
  if [ "$UPDATE" = true ]; then echo "status:   update available"; else echo "status:   up-to-date"; fi
fi

if [ "$UPDATE" = true ]; then exit 0; else exit 1; fi
