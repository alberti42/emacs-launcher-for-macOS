#!/usr/bin/env bash
#
# Build "Emacs Launcher.app" from the Swift sources (Sources/EmacsLauncher).
#
# SwiftPM builds the executable, then we assemble the .app bundle around a static
# Info.plist, compile the dragon icon into Assets.car at build time (actool, from the
# loose Icon Composer source under assets/icons/), and register the file-type /
# org-protocol associations with Launch Services. Re-run after editing the Swift
# sources or Info.plist.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${APP:-$HOME/Applications/Emacs Launcher.app}"   # overridable (e.g. for side-by-side testing)
CONFIG="${CONFIG:-release}"
PLIST_SRC="$SRC_DIR/Info.plist"
ICONS_DIR="${ICONS_DIR:-$SRC_DIR/assets/icons}"       # loose <name>.icon Icon Composer sources
ICON_NAME="${ICON_NAME:-dragon-plus}"                 # which one to compile; basename of the .icon
# ICON_SRC="/path/to.icns"   # optional: override the pre-Tahoe .icns with your own
SIGN_ID="${SIGN_ID:--}"      # codesign identity; default "-" (ad-hoc). CI passes a Developer ID.
REGISTER="${REGISTER:-1}"    # lsregister the bundle after building; CI sets REGISTER=0.

# UNIVERSAL=1 builds a fat arm64+x86_64 binary (to compile once and run on either
# architecture); the default compiles for the host arch only. The same flags must go on
# both swift build calls below -- the second (--show-bin-path) reports the output dir,
# which differs between a host-only and a universal build.
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == "1" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "==> Building Swift executable ($CONFIG${ARCH_FLAGS:+, universal})"
swift build --package-path "$SRC_DIR" -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN="$(swift build --package-path "$SRC_DIR" -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)/EmacsLauncher"
[[ -x "$BIN" ]] || { echo "!! build produced no executable at $BIN" >&2; exit 1; }

echo "==> Assembling bundle: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/EmacsLauncher"        # must match CFBundleExecutable
chmod +x "$APP/Contents/MacOS/EmacsLauncher"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle the daemon LaunchAgent so the "Can't reach the server" dialog can offer to
# install it (copied to ~/Library/LaunchAgents and launchctl-bootstrapped at runtime).
DAEMON_PLIST="$SRC_DIR/goodies/io.alberti42.emacs-daemon.plist"
if [[ -f "$DAEMON_PLIST" ]]; then
  cp "$DAEMON_PLIST" "$APP/Contents/Resources/"
else
  echo "!! $DAEMON_PLIST not found -- the no-daemon dialog won't offer to install it" >&2
fi

# --- icon ---
# Prefer a fresh compile of the loose Icon Composer source ($ICONS_DIR/$ICON_NAME.icon)
# into Assets.car (the macOS 26 "Tahoe" icon) + a pre-Tahoe .icns via actool. actool ships
# with full Xcode, NOT the Command Line Tools -- so when it's unavailable (or fails) we fall
# back to the committed copies in assets/prebuilt/. Only when both are missing do we skip the
# icon (the app still builds; Tahoe shows the default). actool's output isn't byte-identical
# between runs, so the committed fallback is refreshed only on demand (UPDATE_PREBUILT=1),
# not every build.
RES="$APP/Contents/Resources"
PLIST_DST="$APP/Contents/Info.plist"
PB="/usr/libexec/PlistBuddy"
ICON_DIR="$ICONS_DIR/$ICON_NAME.icon"
PREBUILT_DIR="$SRC_DIR/assets/prebuilt"
icon_installed=0

ACTOOL="$(xcrun --find actool 2>/dev/null || true)"
if [[ -d "$ICON_DIR" && -n "$ACTOOL" ]]; then
  echo "==> Compiling icon ($ICON_NAME) via actool"
  TMP="$(mktemp -d)"
  if "$ACTOOL" "$ICON_DIR" \
       --compile "$TMP" \
       --platform macosx \
       --minimum-deployment-target 12.0 \
       --app-icon "$ICON_NAME" \
       --output-partial-info-plist "$TMP/partial.plist" \
       --enable-icon-stack-fallback-generation=disabled >/dev/null \
     && [[ -f "$TMP/Assets.car" ]]; then
    cp -f "$TMP/Assets.car" "$RES/Assets.car"
    [[ -f "$TMP/$ICON_NAME.icns" ]] && cp -f "$TMP/$ICON_NAME.icns" "$RES/$ICON_NAME.icns"
    icon_installed=1
    if [[ "${UPDATE_PREBUILT:-0}" == "1" ]]; then
      echo "==> Refreshing committed fallback in assets/prebuilt/"
      mkdir -p "$PREBUILT_DIR"
      cp -f "$TMP/Assets.car" "$PREBUILT_DIR/Assets.car"
      [[ -f "$TMP/$ICON_NAME.icns" ]] && cp -f "$TMP/$ICON_NAME.icns" "$PREBUILT_DIR/$ICON_NAME.icns"
    fi
  else
    echo "!! actool failed to compile $ICON_DIR -- trying committed fallback" >&2
  fi
  rm -rf "$TMP"
fi

if [[ "$icon_installed" == "0" ]]; then
  if [[ -f "$PREBUILT_DIR/Assets.car" ]]; then
    [[ -n "$ACTOOL" ]] || echo "!! actool not found (full Xcode required)" >&2
    echo "==> Installing prebuilt icon ($ICON_NAME) from assets/prebuilt/"
    cp -f "$PREBUILT_DIR/Assets.car" "$RES/Assets.car"
    [[ -f "$PREBUILT_DIR/$ICON_NAME.icns" ]] && cp -f "$PREBUILT_DIR/$ICON_NAME.icns" "$RES/$ICON_NAME.icns"
    icon_installed=1
  else
    echo "!! no icon available (no actool, no assets/prebuilt/Assets.car) -- Tahoe will show the default app icon" >&2
  fi
fi

if [[ "$icon_installed" == "1" ]]; then
  # Point the plist at this icon (basename == icon name in both keys).
  "$PB" -c "Set :CFBundleIconName $ICON_NAME" "$PLIST_DST" 2>/dev/null \
    || "$PB" -c "Add :CFBundleIconName string $ICON_NAME" "$PLIST_DST"
  "$PB" -c "Set :CFBundleIconFile $ICON_NAME" "$PLIST_DST" 2>/dev/null \
    || "$PB" -c "Add :CFBundleIconFile string $ICON_NAME" "$PLIST_DST"
fi

# Optional: override the pre-Tahoe .icns with your own.
if [[ -n "${ICON_SRC:-}" && -f "$ICON_SRC" ]]; then
  echo "==> Installing custom .icns: $ICON_SRC"
  cp "$ICON_SRC" "$RES/$ICON_NAME.icns"
fi

# --- codesign so the bundle is treated as a stable, valid app ---
# Ad-hoc ("-") is enough for local use (and lets Launch Services honour the declared
# types reliably on recent macOS). For distribution, pass a Developer ID via SIGN_ID;
# we then add the hardened runtime + a secure timestamp (both required for notarization)
# and treat a signing failure as fatal rather than continuing unsigned.
if command -v codesign >/dev/null 2>&1; then
  sign_args=(--force --deep --sign "$SIGN_ID")
  if [[ "$SIGN_ID" == "-" ]]; then
    echo "==> Ad-hoc signing"
    codesign "${sign_args[@]}" "$APP" >/dev/null 2>&1 || \
      echo "!! codesign failed (continuing unsigned)" >&2
  else
    echo "==> Signing with Developer ID ($SIGN_ID)"
    sign_args+=(--options runtime --timestamp)
    codesign "${sign_args[@]}" "$APP"   # fail loudly: an unsigned release is not shippable
  fi
fi

# --- register with Launch Services so URL scheme + doc types take effect now ---
# Pointless on a CI runner (the bundle is zipped, not used there) -- skip with REGISTER=0.
if [[ "$REGISTER" == "1" ]]; then
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  echo "==> Registering with Launch Services"
  "$LSREGISTER" -f "$APP"
fi

echo "==> Done: $APP"
