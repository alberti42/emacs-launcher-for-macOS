#!/usr/bin/env bash
#
# Build "Emacs Client.app" from the Swift launcher (Sources/EmacsClient).
#
# Unlike emacsgui-build.sh (which compiles the AppleScript applet), this produces a
# real compiled Cocoa app: SwiftPM builds the executable, then we assemble the .app
# bundle around a static Info.plist, install the dragon Assets.car icon, and register
# the file-type / org-protocol associations with Launch Services.
#
# The Swift launcher reimplements the emacsgui logic natively, so no shell script is
# shipped inside the bundle. Re-run after editing main.swift or Info.plist.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${APP:-$HOME/Applications/Emacs Client.app}"   # overridable (e.g. for side-by-side testing)
CONFIG="${CONFIG:-release}"
PLIST_SRC="$SRC_DIR/Info.plist"
ASSETS_SRC="$SRC_DIR/Assets.car"
# ICON_SRC="/path/to/Emacs.icns"   # optional pre-Tahoe .icns

echo "==> Building Swift executable ($CONFIG)"
swift build --package-path "$SRC_DIR" -c "$CONFIG"
BIN="$(swift build --package-path "$SRC_DIR" -c "$CONFIG" --show-bin-path)/EmacsClient"
[[ -x "$BIN" ]] || { echo "!! build produced no executable at $BIN" >&2; exit 1; }

echo "==> Assembling bundle: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/EmacsClient"          # must match CFBundleExecutable
chmod +x "$APP/Contents/MacOS/EmacsClient"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- icon ---
if [[ -f "$ASSETS_SRC" ]]; then
  echo "==> Installing Assets.car (dragon icon)"
  cp "$ASSETS_SRC" "$APP/Contents/Resources/Assets.car"
else
  echo "!! Assets.car not found at $ASSETS_SRC -- Tahoe will show the default app icon" >&2
fi
if [[ -n "${ICON_SRC:-}" && -f "$ICON_SRC" ]]; then
  echo "==> Installing applet.icns: $ICON_SRC"
  cp "$ICON_SRC" "$APP/Contents/Resources/applet.icns"
fi

# --- ad-hoc codesign so the bundle is treated as a stable, valid app ---
# (Required for Launch Services to honour the declared types reliably on recent macOS.)
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "!! codesign failed (continuing unsigned)" >&2
fi

# --- register with Launch Services so URL scheme + doc types take effect now ---
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
echo "==> Registering with Launch Services"
"$LSREGISTER" -f "$APP"

echo "==> Done: $APP"
