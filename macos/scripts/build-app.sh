#!/usr/bin/env bash
# Builds DevDash.app (menu bar app) and installs it to ~/Applications.
#   ./scripts/build-app.sh            release build + install
#   DEVDASH_BIN=/path/to/devdash ...  override the CLI the app launches
#   NO_INSTALL=1 ...                  leave the bundle in macos/build/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP_NAME="DevDash"
BUNDLE_ID="works.enso.devdash.bar"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$REPO/devdash/__init__.py")"
OUT="$ROOT/build/$APP_NAME.app"

# Prefer an explicit override, then the repo venv, then an installed devdash.
if [[ -z "${DEVDASH_BIN:-}" ]]; then
    if [[ -x "$REPO/.venv/bin/devdash" ]]; then
        DEVDASH_BIN="$REPO/.venv/bin/devdash"
    else
        DEVDASH_BIN="$(command -v devdash || true)"
    fi
fi

echo "==> Building release binary"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/DevDashBar"

echo "==> Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>DevDash opens Terminal to start Claude sessions and the devdash TUI.</string>
    <key>DevDashCommand</key><string>$DEVDASH_BIN</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$OUT"

if [[ "${NO_INSTALL:-}" != "1" ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    mkdir -p "$HOME/Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$OUT" "$DEST"
    echo "Done. Launch with: open \"$DEST\""
else
    echo "Done: $OUT"
fi
echo "devdash CLI: ${DEVDASH_BIN:-<not found, set it in Settings>}"
