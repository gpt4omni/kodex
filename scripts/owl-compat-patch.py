#!/usr/bin/env python3
"""Neutralize the Owl app-shell gate so Codex runs on stock Electron.

Upstream Codex desktop (v26.901.x, possibly later) refuses to start on
anything but OpenAI's Owl Electron fork:

    if(process.versions.electron!=null
       && typeof a.app.showTaskManager!=`function`)
      throw Error(`Codex requires the Owl app shell; ...`);

Stock Electron has no `app.showTaskManager`, so the AppImage would launch
and then sit there doing nothing. This patch replaces the throw with a
no-op stub assignment in the same scope (the minified `a` is the Electron
module import, so it is in scope at the patch site). The Help > Task
Manager menu item then harmlessly does nothing instead of crashing.

The match must be exact and unique; anything else fails loudly so a
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
            f.write(src.replace(NEEDLE, STUB))
        patched.append(path)
    if not patched:
        print("owl-compat-patch: Owl gate not found in any bootstrap "
              "bundle; upstream may have changed shape. Failing loudly "
              "rather than shipping an AppImage that cannot start.",
              file=sys.stderr)
        return 1
    for path in patched:
        print(f"owl-compat-patch: stubbed Owl gate in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
