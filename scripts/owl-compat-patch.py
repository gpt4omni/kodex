#!/usr/bin/env python3
"""Linux compatibility patches for the Codex desktop bundle.

Upstream Codex desktop (v26.901.x, possibly later) is built for OpenAI's
Owl Electron fork and macOS vibrancy. Three groups of patches make it run
on stock Linux Electron:

1. Owl app-shell gate (bootstrap): refuses stock Electron unless
   app.showTaskManager exists. Replaced with conditional no-op stubs for
   every Owl-only API the bundle uses (verified against stock Electron
   40.8.5 by runtime introspection). Help > Task Manager becomes a
   harmless no-op; unknown runtime features fall back to false through
   the app's own `Unsupported Owl feature:` handler.
2. Main-bundle call-site guards (e.g. session.setPreferredLanguages),
   where a runtime stub is impossible.
3. Renderer/opaque defaults (startup background, opaqueWindows on
   Linux) so windows paint without a blur compositor.

Every match must be exact and unique; anything else fails loudly so a
future upstream refactor never ships a silently broken AppImage.

Usage: scripts/owl-compat-patch.py <extracted-asar-dir>
"""
import glob
import os
import sys

# Backtick-quoted minified guard, exactly as shipped in
# .vite/build/bootstrap-*.js (verified against v26.901.41600-b7982).
NEEDLE = (
    "if(process.versions.electron!=null"
    "&&typeof a.app.showTaskManager!=`function`)"
    "throw Error(`Codex requires the Owl app shell;"
    " stock Electron is no longer supported.`);"
)
STUB = (
    "if(typeof a.app.showTaskManager!=`function`)"
    "a.app.showTaskManager=()=>{};"
)

# Further Owl-only app APIs used by the main bundle (verified absent from
# stock Electron 40.8.5 via runtime introspection; verified present-but-
# guarded call sites in main-C5K7o1Hr.js). Each stub is conditional so a
# future Owl-based or fixed runtime keeps its real implementation.
# - setDebugChromePagesEnabled: debug-menu toggle, safe no-op.
# - setRuntimeFeatures: applies a boolean feature map, safe no-op.
# - isRuntimeFeatureEnabled: the app itself catches
#   `Unsupported Owl feature:` and falls back to false, so mimic Owl.
# - begin/endNativeMenuTracking: darwin tray/menu hooks, safe no-ops.
# - getApplicationInfoForProtocol: unreachable on Linux (both call sites
#   are darwin/win32-guarded); same-shape fallback just in case.
EXTRA_STUBS = (
    "if(typeof a.app.setDebugChromePagesEnabled!=`function`)"
    "a.app.setDebugChromePagesEnabled=()=>{};"
    "if(typeof a.app.setRuntimeFeatures!=`function`)"
    "a.app.setRuntimeFeatures=()=>{};"
    "if(typeof a.app.isRuntimeFeatureEnabled!=`function`)"
    "a.app.isRuntimeFeatureEnabled=e=>{throw Error(`Unsupported Owl feature: `+e)};"
    "if(typeof a.app.beginNativeMenuTracking!=`function`)"
    "a.app.beginNativeMenuTracking=()=>{};"
    "if(typeof a.app.endNativeMenuTracking!=`function`)"
    "a.app.endNativeMenuTracking=()=>{};"
    "if(typeof a.app.getApplicationInfoForProtocol!=`function`)"
    "a.app.getApplicationInfoForProtocol=async()=>({name:``,path:``});"
)

# Owl-only BrowserWindow statics (verified absent from stock Electron
# 40.8.5 via runtime introspection). Both are pure capability queries;
# false is the honest answer on stock Linux.
BW_EXTRA_STUBS = (
    "if(typeof a.BrowserWindow.isInputShapeSupported!=`function`)"
    "a.BrowserWindow.isInputShapeSupported=()=>!1;"
    "if(typeof a.BrowserWindow.isSystemBackdropSupported!=`function`)"
    "a.BrowserWindow.isSystemBackdropSupported=()=>!1;"
)

# app.isHidden is called unguarded by the pet-controls proximity timer.
# False (not hidden) is the honest answer on stock Linux.
APP_HIDDEN_STUB = (
    "if(typeof a.app.isHidden!=`function`)"
    "a.app.isHidden=()=>!1;"
)


# Call-site patches for Owl-only APIs used in the main bundle, where a
# runtime stub is impossible or wrong. Each (description, needle,
# replacement) must match exactly once in .vite/build/main-*.js.
MAIN_PATCHES = [
    # Session.setPreferredLanguages exists only on Owl; the single call
    # site configures the browser session partition. Optional chaining
    # keeps stock behavior (default languages) when it is absent.
    ("session.setPreferredLanguages guard",
     "ed(`app`).setPreferredLanguages(t.length>0?t:[l.app.getLocale()])",
     "(ed(`app`).setPreferredLanguages?.(t.length>0?t:[l.app.getLocale()]))"),
]


# Renderer patches for Linux: the UI is designed around macOS vibrancy
# (transparent windows). On Linux that paints black, so default opaque
# windows on and give the startup page an opaque background. Same idea as
# the community codex-desktop-linux port, matched against this bundle.
WEBVIEW_PATCHES = [
    # webview/index.html startup splash: transparent shows through as
    # black on X11 without a blur compositor.
    ("startup background opaque",
     "webview/index.html",
     "--startup-background: transparent;",
     "--startup-background: #1e1e1e;"),
    # Renderer settings merge: default opaqueWindows to true on Linux
    # unless the user already chose otherwise.
    ("opaqueWindows default on Linux",
     "webview/assets/app-initial-*.js",
     "opaqueWindows:e?.opaqueWindows??r.opaqueWindows,semanticColors:",
     "opaqueWindows:e?.opaqueWindows??(typeof navigator<`u`&&"
     "((navigator.userAgentData?.platform??navigator.platform??"
     "navigator.userAgent).toLowerCase().includes(`linux`))?!0:"
     "r.opaqueWindows),semanticColors:"),
]


def patch_one(path, needle, replacement, desc):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    n = src.count(needle)
    if n != 1:
        print(f"owl-compat-patch: {desc}: found {n}x in {path}, "
              "expected exactly 1; refusing to patch", file=sys.stderr)
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(needle, replacement))
    print(f"owl-compat-patch: applied {desc} in {path}")
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: owl-compat-patch.py <extracted-asar-dir>",
              file=sys.stderr)
        return 2
    root = sys.argv[1]
    cands = sorted(glob.glob(
        os.path.join(root, ".vite", "build", "bootstrap-*.js")))
    if not cands:
        print("owl-compat-patch: no .vite/build/bootstrap-*.js found under "
              + root, file=sys.stderr)
        return 1
    patched = []
    for path in cands:
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
        n = src.count(NEEDLE)
        if n == 0:
            continue
        if n > 1:
            print(f"owl-compat-patch: guard found {n}x in {path}, "
                  "expected exactly 1; refusing to patch", file=sys.stderr)
            return 1
        with open(path, "w", encoding="utf-8") as f:
            f.write(src.replace(
                NEEDLE, STUB + EXTRA_STUBS + BW_EXTRA_STUBS + APP_HIDDEN_STUB))
        patched.append(path)
    if not patched:
        print("owl-compat-patch: Owl gate not found in any bootstrap "
              "bundle; upstream may have changed shape. Failing loudly "
              "rather than shipping an AppImage that cannot start.",
              file=sys.stderr)
        return 1
    for path in patched:
        print(f"owl-compat-patch: stubbed Owl gate in {path}")
    mains = sorted(glob.glob(
        os.path.join(root, ".vite", "build", "main-*.js")))
    if not mains:
        print("owl-compat-patch: no .vite/build/main-*.js found under "
              + root, file=sys.stderr)
        return 1
    for desc, needle, replacement in MAIN_PATCHES:
        ok = False
        for path in mains:
            with open(path, "r", encoding="utf-8") as f:
                if needle in f.read():
                    if not patch_one(path, needle, replacement, desc):
                        return 1
                    ok = True
                    break
        if not ok:
            print(f"owl-compat-patch: {desc}: needle not found; upstream "
                  "may have changed shape. Failing loudly rather than "
                  "shipping an AppImage that cannot start.", file=sys.stderr)
            return 1
    for desc, pattern, needle, replacement in WEBVIEW_PATCHES:
        cands = sorted(glob.glob(os.path.join(root, pattern)))
        if not cands:
            print(f"owl-compat-patch: {desc}: no files match {pattern}; "
                  "upstream may have changed shape. Failing loudly.",
                  file=sys.stderr)
            return 1
        applied = False
        for path in cands:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
            if needle not in content:
                continue
            if not patch_one(path, needle, replacement, desc):
                return 1
            applied = True
            break
        if not applied:
            print(f"owl-compat-patch: {desc}: needle not found; upstream "
                  "may have changed shape. Failing loudly rather than "
                  "shipping an AppImage that cannot start.", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
