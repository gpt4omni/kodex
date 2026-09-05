#!/usr/bin/env bash
# Build a Linux AppImage from the official macOS OpenAI Codex desktop build.
#
# Conversion recipe (after rgalstyan/openai-codex-5.5-linux, reimplemented):
#   1. download macOS zip (or floating DMG, extracted with 7z) and find Codex.app
#   2. detect the bundled Electron version from the framework Info.plist
#      (fallback pin when detection fails)
#   3. npx asar extract app.asar
#   4. rebuild darwin native modules for Linux with @electron/rebuild,
#      with guaranteed better-sqlite3/node-pty handling; drop what cannot
#      be rebuilt and report it
#   5. download the matching Linux Electron runtime, repack app.asar,
#      assemble AppDir, run appimagetool
#
# Usage: scripts/build-appimage.sh [VERSION] [ARCH] [--src zip|dmg]
#        [--electron-version X.Y.Z] [--outdir DIR] [--workdir DIR]
#   VERSION  canonical tag (v26.901.41600-b7982), plain version
#            (26.901.41600), or "latest" (default)
#   ARCH     x64 (default) or arm64; selects the arch-matched source
#   --src    zip (default) or dmg (floating DMG via 7z)
#
# Needs: bash, python3, curl, unzip (or python3 zipfile fallback),
#        7z (dmg only), node/npm/npx, appimagetool (auto-fetched if missing).
#        @electron/rebuild compiles native modules: python3, make and g++
#        must be installed on the build host.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="latest"
ARCH="x64"
SRC="zip"
ELECTRON_OVERRIDE=""
OUTDIR="$REPO_ROOT/dist"
WORKDIR=""
POS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:?--src needs zip|dmg}"; shift 2 ;;
    --electron-version) ELECTRON_OVERRIDE="${2:?--electron-version needs a value}"; shift 2 ;;
    --outdir) OUTDIR="${2:?--outdir needs a value}"; shift 2 ;;
    --workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$SCRIPT_DIR/build-appimage.sh" | sed 's/^# \?//'; exit 0 ;;
    --*) echo "build-appimage: unknown flag: $1" >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done

# Positionals are [VERSION] [ARCH]; a lone x64/arm64 means ARCH with latest.
if [ "${#POS[@]}" -ge 1 ]; then
  case "${POS[0]}" in
    x64|arm64) ARCH="${POS[0]}" ;;
    *) VERSION="${POS[0]}" ;;
  esac
fi
if [ "${#POS[@]}" -ge 2 ]; then
  case "${POS[1]}" in
    x64|arm64) ARCH="${POS[1]}" ;;
    *) echo "build-appimage: ARCH must be x64 or arm64, got '${POS[1]}'" >&2; exit 2 ;;
  esac
fi
if [ "${#POS[@]}" -gt 2 ]; then
  echo "build-appimage: too many positional arguments" >&2; exit 2
fi

case "$ARCH" in
  x64|arm64) ;;
  *) echo "build-appimage: ARCH must be x64 or arm64" >&2; exit 2 ;;
esac
case "$SRC" in
  zip|dmg) ;;
  *) echo "build-appimage: --src must be zip or dmg" >&2; exit 2 ;;
esac

ELECTRON_PIN="40.8.5"  # known-good fallback when auto-detection fails
APPIMAGETOOL_URL_X64="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
APPIMAGETOOL_URL_ARM64="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-aarch64.AppImage"

log() { echo "build-appimage: $*"; }
fail() { echo "build-appimage: error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "required tool missing: $1"; }

need curl; need python3; need node; need npm; need npx
[ "$SRC" = "dmg" ] && need 7z
command -v unzip >/dev/null 2>&1 || log "unzip not found; will use python3 zipfile fallback"

WORK="$(mktemp -d "${WORKDIR:-/tmp}/kodex-build.XXXXXX")" \
  || fail "could not create temporary work directory"
cleanup() { if [ -z "${KEEP_WORK:-}" ]; then rm -rf "$WORK"; else log "KEEP_WORK set; work dir kept at $WORK"; fi; }
trap cleanup EXIT

mkdir -p "$OUTDIR"

# --- 1. Resolve upstream source ---------------------------------------------
UPSTREAM_JSON="$WORK/upstream.json"
"$SCRIPT_DIR/fetch-upstream.py" --arch "$ARCH" --timeout 60 > "$UPSTREAM_JSON" \
  || fail "could not fetch upstream appcast"
UP_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$UPSTREAM_JSON")"
UP_BUILD="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$UPSTREAM_JSON")"
UP_PUBDATE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pubDate",""))' "$UPSTREAM_JSON")"
UP_ZIP_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["architectures"]["'"$ARCH"'"]["url"])' "$UPSTREAM_JSON")"

if [ "$ARCH" = "arm64" ]; then
  DMG_URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
else
  DMG_URL="https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg"
fi

if [ "$VERSION" = "latest" ]; then
  TAG="v${UP_VERSION}-b${UP_BUILD}"
  PINNED_VERSION="$UP_VERSION"
else
  PINNED_VERSION="${VERSION#v}"
  PINNED_VERSION="${PINNED_VERSION%%-b*}"
  if [ "$PINNED_VERSION" = "$UP_VERSION" ]; then
    TAG="v${UP_VERSION}-b${UP_BUILD}"
  else
    TAG="v${PINNED_VERSION}"  # pinned version not in feed; build unknown
    log "warning: pinned version $PINNED_VERSION differs from feed ($UP_VERSION); build number unknown"
  fi
fi

if [ "$SRC" = "zip" ]; then
  if [ "$PINNED_VERSION" = "$UP_VERSION" ]; then
    SRC_URL="$UP_ZIP_URL"
  else
    SRC_URL="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-${ARCH}-${PINNED_VERSION}.zip"
  fi
else
  SRC_URL="$DMG_URL"
  log "note: DMGs are floating (unversioned); tag/metadata reflect the appcast feed"
fi
log "tag=$TAG arch=$ARCH src=$SRC url=$SRC_URL"

# --- 2. Download + extract Codex.app -----------------------------------------
SRC_FILE="$WORK/source.$( [ "$SRC" = "zip" ] && echo zip || echo dmg )"
log "downloading $SRC_URL"
curl -fL --retry 3 --retry-delay 5 -o "$SRC_FILE" "$SRC_URL" || fail "download failed"

APP_SRC="$WORK/app-src"
mkdir -p "$APP_SRC"
if [ "$SRC" = "zip" ]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$SRC_FILE" -d "$APP_SRC" || fail "unzip failed"
  else
    python3 - "$SRC_FILE" "$APP_SRC" <<'EOF' || exit 1
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
EOF
  fi
else
  7z x "$SRC_FILE" -o"$APP_SRC" >/dev/null || fail "7z DMG extraction failed"
fi
APP_BUNDLE="$(find "$APP_SRC" -maxdepth 6 -name "*.app" -type d | head -n 1)"
[ -n "$APP_BUNDLE" ] || fail "no .app bundle found after extraction"
log "app bundle: $APP_BUNDLE"
APP_ASAR="$APP_BUNDLE/Contents/Resources/app.asar"
[ -f "$APP_ASAR" ] || fail "app.asar not found in bundle"

# --- 3. Detect Electron version ----------------------------------------------
detect_electron() {
  python3 - "$APP_BUNDLE" <<'EOF'
import plistlib, sys, glob, os
base = sys.argv[1]
cands = glob.glob(os.path.join(base, "Contents/Frameworks/Electron Framework.framework/**/Info.plist"), recursive=True)
cands += glob.glob(os.path.join(base, "Contents/Frameworks/Electron Framework.framework/Versions/*/Resources/Info.plist"))
for c in cands:
    try:
        with open(c, "rb") as f:
            v = plistlib.load(f).get("CFBundleShortVersionString", "")
        if v:
            print(v.strip()); return
    except Exception:
        pass
EOF
}
ELECTRON_V="${ELECTRON_OVERRIDE:-$(detect_electron)}"
if [ -z "$ELECTRON_V" ]; then
  ELECTRON_V="$ELECTRON_PIN"
  log "warning: Electron version auto-detection failed; using fallback pin $ELECTRON_PIN"
else
  log "detected Electron $ELECTRON_V"
fi

# --- 4. Unpack app.asar -------------------------------------------------------
UNPACKED="$WORK/app-unpacked"
log "extracting app.asar"
npx -y asar extract "$APP_ASAR" "$UNPACKED" || fail "asar extract failed"

scan_macho() {  # scan_macho <dir>: list Mach-O .node files (empty output = none)
  python3 - "$1" <<'EOF'
import os, sys
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
          b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe"}
for root, _, files in os.walk(sys.argv[1]):
    for fn in files:
        if not fn.endswith(".node"):
            continue
        p = os.path.join(root, fn)
        try:
            with open(p, "rb") as f:
                magic = f.read(4)
        except OSError:
            continue
        if magic in MAGICS:
            print(p)
EOF
}

MACHO_BEFORE="$(scan_macho "$UNPACKED" | tee "$WORK/macho-before.txt" | wc -l)"
log "Mach-O .node files before rebuild: $MACHO_BEFORE"

# --- 5. Rebuild native modules for Linux --------------------------------------
if [ "$MACHO_BEFORE" -gt 0 ]; then
  log "rebuilding native modules for Electron $ELECTRON_V arch $ARCH"
  (cd "$UNPACKED" && npx -y @electron/rebuild --version "$ELECTRON_V" --arch "$ARCH") \
    || log "warning: @electron/rebuild exited nonzero; will verify and drop leftovers"
fi

REPORT="$WORK/native-modules-report.txt"
{
  echo "native module report for $TAG ($ARCH, Electron $ELECTRON_V)"
  echo "Mach-O .node files before rebuild: $MACHO_BEFORE"
  [ -f "$WORK/macho-before.txt" ] && cat "$WORK/macho-before.txt"
} > "$REPORT"

# Guaranteed handling: better-sqlite3 and node-pty must end up as working
# Linux binaries or be explicitly reported.
for mod in better-sqlite3 node-pty; do
  MOD_FILES="$(find "$UNPACKED/node_modules/$mod" -name "*.node" 2>/dev/null || true)"
  if [ -z "$MOD_FILES" ]; then
    echo "NOTE: $mod not shipped in app bundle; skipping" >> "$REPORT"
    continue
  fi
  STILL_MACHO=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if scan_macho "$(dirname "$f")" | grep -qx "$f"; then STILL_MACHO=1; fi
  done <<< "$MOD_FILES"
  if [ "$STILL_MACHO" -eq 1 ]; then
    MOD_WANT="$(UNPACKED="$UNPACKED" MOD="$mod" python3 -c 'import json,os; print(json.load(open(os.path.join(os.environ["UNPACKED"],"package.json"))).get("dependencies",{}).get(os.environ["MOD"]) or "latest")')"
    log "warning: $mod still Mach-O; reinstalling $mod@$MOD_WANT from npm and rebuilding"
    (cd "$UNPACKED" && npm install --no-save --no-audit --no-fund "$mod@$MOD_WANT" \
      && npx -y @electron/rebuild --version "$ELECTRON_V" --arch "$ARCH" --only="$mod") \
      || echo "FAIL: $mod reinstall/rebuild failed" >> "$REPORT"
    if scan_macho "$UNPACKED/node_modules/$mod" | grep -q .; then
      echo "FAIL: $mod could not be rebuilt for Linux; its .node files were dropped" >> "$REPORT"
      scan_macho "$UNPACKED/node_modules/$mod" | while IFS= read -r f; do rm -f "$f"; done
    else
      echo "OK: $mod rebuilt for Linux/Electron $ELECTRON_V" >> "$REPORT"
    fi
  else
    echo "OK: $mod already Linux-native after rebuild" >> "$REPORT"
  fi
done

# Generic path: anything still Mach-O cannot load on Linux; drop + report.
LEFTOVER="$(scan_macho "$UNPACKED")"
if [ -n "$LEFTOVER" ]; then
  log "warning: dropping $(echo "$LEFTOVER" | wc -l) unrebuildable Mach-O .node file(s)"
  echo "DROPPED (still Mach-O after rebuild, deleted):" >> "$REPORT"
  echo "$LEFTOVER" >> "$REPORT"
  echo "$LEFTOVER" | while IFS= read -r f; do rm -f "$f"; done
else
  echo "OK: no Mach-O .node files remain" >> "$REPORT"
fi
log "native module report:"; sed 's/^/  /' "$REPORT"

# --- 6. Linux Electron runtime -------------------------------------------------
if [ "$ARCH" = "arm64" ]; then EARCH="arm64"; else EARCH="x64"; fi
ELECTRON_ZIP_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_V}/electron-v${ELECTRON_V}-linux-${EARCH}.zip"
log "downloading Linux Electron $ELECTRON_V ($EARCH)"
curl -fL --retry 3 --retry-delay 5 -o "$WORK/electron.zip" "$ELECTRON_ZIP_URL" \
  || fail "Electron runtime download failed (is $ELECTRON_V published for linux-$EARCH?)"
ELECTRON_DIR="$WORK/electron"
mkdir -p "$ELECTRON_DIR"
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$WORK/electron.zip" -d "$ELECTRON_DIR" || fail "Electron unzip failed"
else
  python3 - "$WORK/electron.zip" "$ELECTRON_DIR" <<'EOF' || exit 1
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
EOF
fi
[ -x "$ELECTRON_DIR/electron" ] || fail "Linux Electron binary missing after unzip"

# --- 7. Repack app.asar --------------------------------------------------------
log "repacking app.asar"
npx -y asar pack "$UNPACKED" "$WORK/app.asar" || fail "asar pack failed"

# --- 8. Assemble AppDir ---------------------------------------------------------
APPDIR="$WORK/AppDir"
APPDIR_LIB="$APPDIR/usr/lib/codex"
mkdir -p "$APPDIR_LIB" "$APPDIR/usr/bin"
cp -a "$ELECTRON_DIR"/. "$APPDIR_LIB"/
rm -f "$APPDIR_LIB/resources/default_app.asar"
cp "$WORK/app.asar" "$APPDIR_LIB/resources/app.asar"
cp "$REPO_ROOT/resources/bin/screencapture" "$APPDIR/usr/bin/screencapture"
chmod +x "$APPDIR/usr/bin/screencapture"
cp "$REPO_ROOT/resources/AppRun.sh" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp "$REPO_ROOT/resources/Codex.desktop" "$APPDIR/Codex.desktop"
# Stamp the real tag so the desktop file never ships the 'latest' placeholder.
sed -i "s/^X-AppImage-Version=.*/X-AppImage-Version=$TAG/" "$APPDIR/Codex.desktop"
cp "$REPORT" "$APPDIR_LIB/native-modules-report.txt"

# Icon: prefer a shipped PNG, else carve an embedded PNG out of electron.icns,
# else warn (desktop Icon= entry then has no image; AppImage still runs).
ICON_CANDIDATE="$(find "$APP_BUNDLE/Contents/Resources" -maxdepth 1 \( -iname "*codex*.png" -o -iname "app*.png" -o -iname "icon*.png" \) | head -n 1)"
if [ -n "$ICON_CANDIDATE" ]; then
  cp "$ICON_CANDIDATE" "$APPDIR/codex.png"
  log "icon: $ICON_CANDIDATE"
else
  ICNS="$(find "$APP_BUNDLE/Contents/Resources" -maxdepth 1 -name "*.icns" | head -n 1)"
  if [ -n "$ICNS" ] && python3 - "$ICNS" "$APPDIR/codex.png" <<'EOF'; then
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
assert data[:4] == b"icns", "not an icns file"
off = 8
found = False
while off + 8 <= len(data):
    kind, size = struct.unpack(">4sI", data[off:off + 8])
    if size < 8 or off + size > len(data):
        break
    body = data[off + 8:off + size]
    if body[:8] == b"\x89PNG\r\n\x1a\n":
        open(dst, "wb").write(body)
        found = True
        break
    off += size
sys.exit(0 if found else 1)
EOF
    log "icon: carved PNG from $ICNS"
  else
    log "warning: no usable icon found; Codex.desktop Icon=codex will have no image"
  fi
fi

# --- 9. appimagetool --------------------------------------------------------------
APPIMAGETOOL="${APPIMAGETOOL:-$(command -v appimagetool || true)}"
if [ -z "$APPIMAGETOOL" ]; then
  if [ "$ARCH" = "arm64" ]; then APPIMAGETOOL_URL="$APPIMAGETOOL_URL_ARM64"; else APPIMAGETOOL_URL="$APPIMAGETOOL_URL_X64"; fi
  log "fetching appimagetool"
  curl -fL --retry 3 --retry-delay 5 -o "$WORK/appimagetool.AppImage" "$APPIMAGETOOL_URL" \
    || fail "appimagetool download failed"
  chmod +x "$WORK/appimagetool.AppImage"
  APPIMAGETOOL="$WORK/appimagetool.AppImage"
fi

OUT_NAME="Codex-${TAG}-linux-${ARCH}.AppImage"
if [ "$ARCH" = "x64" ]; then AI_ARCH="x86_64"; else AI_ARCH="aarch64"; fi
log "running appimagetool -> $OUT_NAME"
ARCH="$AI_ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUTDIR/$OUT_NAME" || fail "appimagetool failed"
[ -f "$OUTDIR/$OUT_NAME" ] || fail "expected output missing: $OUTDIR/$OUT_NAME"

# --- 10. Release metadata ------------------------------------------------------------
SHA="$(sha256sum "$OUTDIR/$OUT_NAME" | awk '{print $1}')"
SIZE="$(stat -c %s "$OUTDIR/$OUT_NAME")"
(cd "$OUTDIR" && sha256sum "$OUT_NAME" > SHA256SUMS)
echo "$TAG" > "$OUTDIR/version.txt"
python3 - "$OUTDIR/latest.json" <<EOF
import json
doc = {
    "tag": "$TAG",
    "version": "$PINNED_VERSION",
    "build": "$UP_BUILD",
    "pubDate": "$UP_PUBDATE",
    "arch": "$ARCH",
    "src": "$SRC",
    "source_url": "$SRC_URL",
    "electron_version": "$ELECTRON_V",
    "appimage": "$OUT_NAME",
    "sha256": "$SHA",
    "size": $SIZE,
}
json.dump(doc, open("$OUTDIR/latest.json", "w"), indent=2)
EOF

log "done: $OUTDIR/$OUT_NAME"
log "sha256: $SHA"
