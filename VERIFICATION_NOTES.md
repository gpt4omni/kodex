# VERIFICATION_NOTES.md

Honest record of what was executed in the build session (2026-09-05)
versus what remains unverified. Nothing was committed (no git repo).

## Actually executed (all passed)

- `bash -n` on every shell script: `scripts/check-version.sh`,
  `scripts/build-appimage.sh`, `scripts/computer-use-check.sh`,
  `resources/AppRun.sh`, `resources/bin/screencapture` — all OK.
- `python3 -m py_compile scripts/fetch-upstream.py` — OK.
- Live `python3 scripts/fetch-upstream.py` (default + `--arch x64`
  + `--tag-only`): fetched both real Sparkle feeds, feeds in agreement,
  tag `v26.901.41600-b7982`, per-arch version/build/pubDate/URL/length
  all present and plausible (arm64 zip ~594 MB, x64 zip ~580 MB).
- Live `bash scripts/check-version.sh --json` with no local state:
  `{"upstream": "v26.901.41600-b7982", ..., "update_available": true}`,
  exit 0. With `--upstream-tag` overrides in a scratch workdir:
  matching `dist/version.txt` -> exit 1; stale local -> exit 0;
  matching `version.txt` fallback -> exit 1; unknown flag -> exit 2.
- `bash scripts/computer-use-check.sh` (human + `--json`) on this host:
  all six checks PASS (x11 session, grim, ydotool, portal, uinput, userns).
  Probes are presence-only; no screenshot taken, no input synthesized.
- `scripts/build-appimage.sh --help`, `--src bogus` (exit 2), three
  positionals (exit 2) — parsing behaves as documented.
- `resources/bin/screencapture`: no-args usage (exit 2), `-t bmp`
  rejection (exit 2), no-backend PATH (exit 1, clear message), and
  dispatch to a fake `grim` on PATH (exit 0, correct output path).
- `.github/workflows/build.yml` parsed with js-yaml (via npx):
  jobs `build/check/release`, 4x-daily cron, dispatch inputs
  version/arch/src, push path filter — all present.
- `shellcheck`: not installed on this host; skipped (bash -n only).

## Deliberately NOT verified

- **End-to-end AppImage build** (`scripts/build-appimage.sh` full run):
  requires downloading ~580 MB upstream zip + Linux Electron runtime and
  compiling native modules with @electron/rebuild. Not run here; the
  first real proof must be a CI run or a manual invocation.
- **DMG source path** (`--src dmg`, 7z extraction): same reason; the 7z
  command is written but never executed against a real Codex.dmg.
- **Electron version auto-detection**: Info.plist path logic written
  against the documented bundle layout but never run against a real
  Codex.app (no macOS bundle on Linux CI until download step runs).
- **`resources/AppRun.sh` runtime behavior**: syntax-checked only; needs
  a built AppDir (Electron binary + app.asar) to execute.
- **Real screenshot capture**: shim dispatches correctly to a stub, but
  no real grim/gnome-screenshot/scrot/import capture was performed.
- **Real computer-use session**: diagnostics report tooling presence;
  actual agent-driven control was not exercised.
- **GitHub workflow execution**: YAML parses, but no workflow run
  (schedule/dispatch/release creation) has happened yet.

## Builder session (2026-09-05, user-facing layer)

Fixes made (all re-verified after editing):

- `scripts/fetch-upstream.py`: added `--json` flag (no-op; output was
  always JSON, but the documented invocation `fetch-upstream.py --json`
  previously exited 2 via argparse). Usage text updated.
- `scripts/build-appimage.sh`: `mktemp -d` failure now calls `fail`
  instead of continuing with an empty `$WORK`; the copied
  `Codex.desktop` gets `X-AppImage-Version=` stamped with the real `$TAG`
  instead of shipping the `latest` placeholder.
- `.github/workflows/build.yml`: top-level `on:` quoted as `"on":` so
  YAML 1.1 parsers (PyYAML safe_load) keep the string key instead of
  boolean `True`; added `permissions: contents: read` to `check`/`build`.
- Exec bits already correct (all scripts, `AppRun.sh`, `screencapture`
  are `+x`); left untouched. No `set -u` hazards found in any script.

Actually executed:

- `bash -n` on all five shell files (3 scripts + AppRun.sh +
  screencapture): all OK, before and after edits.
- `python3 -m py_compile scripts/fetch-upstream.py`: OK.
- Live `python3 scripts/fetch-upstream.py --json --tag-only`:
  `v26.901.41600-b7982`, exit 0. Live `--json --json-indent 0` output
  re-parsed with stdlib json: tag `v26.901.41600-b7982`,
  `feeds_in_agreement: True` (arm64 zip 594524373 B, x64 zip
  580686466 B). No ~600 MB artifact downloaded (metadata only).
- Live `bash scripts/check-version.sh` and `--json`: upstream
  `v26.901.41600-b7982`, local `<none>`, `update_available: true`,
  exit 0.
- Live `bash scripts/computer-use-check.sh` (human + `--json`): all six
  checks PASS on this host (x11 session on DISPLAY=:0, grim, ydotool,
  portal on user bus, /dev/uinput rw, max_user_namespaces=256607),
  exit 0. Not the headless-WARN path: this host has X11.
- Workflow YAML parsed with PyYAML 6.0.3 (installed via the nix env
  python into /tmp, not into the repo): top keys now
  `['jobs', 'name', 'on']`, jobs `build/check/release`, cron
  `0 0,6,12,18 * * *`, check/build permissions `contents: read`.
- `assets/demo.gif`: rendered with ImageMagick 7 `convert` from the
  real captured outputs above (DejaVu-Sans-Mono 14pt, 800 px wide,
  3 frames, ~2.2 s delay, loop forever). `identify` reports 3 frames
  at 800x168; python magic-byte check confirms `GIF89a`, 24064 bytes.
  `file(1)` is not installed on this host, so that exact check was
  replaced by the identify + magic-byte checks. Frames eyeballed via
  image read: all three legible.
- README scanned: none of seamless/blazing/supercharge/leverage/delve,
  zero non-ASCII characters (no emoji).

Deliberately NOT verified (unchanged from above, plus):

- `file assets/demo.gif`: `file(1)` missing on host; validity shown by
  other means (see above).
- `shellcheck`: still not installed; `bash -n` only.
- End-to-end AppImage build, DMG path, Electron auto-detection, AppRun
  runtime, real screenshot/input, real computer-use session, workflow
  run: all still untested, as before.
- Nothing committed: the workspace has no git repo (`git status`
  reports "not a git repository"), so there was nothing to commit or
  push with.

## Launch-debug session (2026-09-05, same host, X11)

The first CI-built release launched but showed failures in sequence; each
was root-caused against the extracted bundle and fixed in the repo, then
re-verified by launch-testing locally built test AppImages:

- `Codex requires the Owl app shell` (bootstrap threw on stock Electron):
  upstream gates on its Owl fork via `app.showTaskManager`. Fixed in
  `scripts/owl-compat-patch.py` (conditional stubs; fail-loud on shape
  change). Verified: gate error gone, window created.
- `cannot access its local database`: CI's in-tree `@electron/rebuild`
  failed (app tree uses `workspace:*` links npm cannot resolve; node-gyp
  configure failed) and deleted `better_sqlite3.node`. Fixed:
  `scripts/build-appimage.sh` rebuilds better-sqlite3/node-pty in a clean
  staging dir, asserts ELF + presence (fatal otherwise), packs asar with
  `--unpack '*.node'`. Verified in shipped asar: both `.node` files ELF.
- `setDebugChromePagesEnabled / isInputShapeSupported /
  isSystemBackdropSupported / isHidden is not a function`: Owl-only APIs
  confirmed absent from stock Electron 40.8.5 by runtime introspection
  (descriptor walk; direct typeof-walk SIGTRAPs on a native getter).
  Stubbed conditionally in the patch script; `setPreferredLanguages`
  guarded at its single call site. Verified: startup proceeds past all.
- `Unable to locate the Codex CLI binary`: resolver joins the name onto
  `process.resourcesPath` directly (`resources/codex`, not `bin/codex`
  despite the error text). Build now bundles the Linux CLI from npm
  `@openai/codex` there. Verified: app-server transport reaches
  `connected` over stdio.
- Black window: two causes. (1) AppRun passed the asar path explicitly,
  forcing `isPackaged=false`, for which the bundle loads a localhost dev
  server. Fixed: no asar arg + `ELECTRON_FORCE_IS_PACKAGED=1`.
  (2) macOS-vibrancy transparency (startup background, opaqueWindows
  default, GPU compositing flags). Fixed via renderer patches in
  `owl-compat-patch.py` and AppRun defaults (`--ozone-platform-hint=auto
  --disable-gpu-sandbox --disable-gpu-compositing`).
- Final release `v26.901.41600-b7982` (rebuilt by CI after fixes)
  smoke-tested locally: `packaged=true`, 0 localhost refs, no bootstrap
  errors, `startup window revealed`, `local app-server sqlite
  initialized`. Only remaining log item: non-fatal
  `browserSession.getDownloadHistory is not a function` (caught; native
  download history unavailable).
- Not verified: real login + chat session, Wayland, non-NixOS distros,
  arm64 build, DMG (`--src dmg`) path.
