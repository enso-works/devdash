#!/usr/bin/env bash
# Builds DevDash.app (menu bar app).
#
# Local install (default): release build for this Mac, bakes in the repo's devdash CLI path,
# installs to ~/Applications.
#   ./scripts/build-app.sh
#
# Distribution build: universal binary, no baked CLI path, zip + dmg in macos/dist/.
#   ./scripts/build-app.sh --release
#
# Environment:
#   DEVDASH_BIN=/path/to/devdash   CLI path baked into a local build
#   SIGN_IDENTITY="Developer ID Application: ..."   sign with a real identity (default: ad-hoc)
#   NOTARY_PROFILE=name            notarize + staple using a `notarytool store-credentials` profile
#   NO_INSTALL=1                   skip copying a local build into ~/Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP_NAME="DevDash"
BUNDLE_ID="works.enso.devdash.bar"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$REPO/devdash/__init__.py")"
BUILD_NUMBER="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/dist"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

# --- Resolve the CLI path baked into local builds -------------------------------------------
BAKED_BIN=""
if [[ $RELEASE -eq 0 ]]; then
    if [[ -n "${DEVDASH_BIN:-}" ]]; then
        BAKED_BIN="$DEVDASH_BIN"
    elif [[ -x "$REPO/.venv/bin/devdash" ]]; then
        BAKED_BIN="$REPO/.venv/bin/devdash"
    else
        BAKED_BIN="$(command -v devdash || true)"
    fi
fi

# --- Compile --------------------------------------------------------------------------------
ARCH_FLAGS=()
[[ $RELEASE -eq 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
info "Building $APP_NAME $VERSION ($BUILD_NUMBER)$([[ $RELEASE -eq 1 ]] && echo ' universal' || true)"
swift build -c release --package-path "$ROOT" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release --package-path "$ROOT" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/DevDashBar"

# --- Assemble bundle ------------------------------------------------------------------------
info "Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>devdash contributors</string>
    <key>NSAppleEventsUsageDescription</key><string>DevDash opens Terminal to start Claude sessions and the devdash TUI.</string>
    <key>DevDashCommand</key><string>$BAKED_BIN</string>
</dict>
</plist>
PLIST

# --- Sign -----------------------------------------------------------------------------------
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    info "Signing with $SIGN_IDENTITY (hardened runtime)"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$OUT"
else
    info "Signing ad-hoc"
    codesign --force --sign - "$OUT"
fi
codesign --verify --strict "$OUT"

# --- Local install --------------------------------------------------------------------------
if [[ $RELEASE -eq 0 ]]; then
    if [[ "${NO_INSTALL:-}" != "1" ]]; then
        DEST="$HOME/Applications/$APP_NAME.app"
        info "Installing to $DEST"
        mkdir -p "$HOME/Applications"
        pkill -x "$APP_NAME" 2>/dev/null || true
        rm -rf "$DEST"
        cp -R "$OUT" "$DEST"
        echo "Launch with: open \"$DEST\""
    fi
    echo "devdash CLI: ${BAKED_BIN:-<not found, set it in Settings>}"
    exit 0
fi

# --- Package for distribution ---------------------------------------------------------------
mkdir -p "$DIST"
ZIP="$DIST/$APP_NAME-$VERSION-macos.zip"
DMG="$DIST/$APP_NAME-$VERSION-macos.dmg"
rm -f "$ZIP" "$DMG"

notarize() {
    [[ -n "${NOTARY_PROFILE:-}" ]] || return 0
    info "Notarizing $(basename "$1")"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

info "Creating $ZIP"
ditto -c -k --keepParent "$OUT" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$ZIP"
    xcrun stapler staple "$OUT"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$OUT" "$ZIP"
fi

info "Creating $DMG"
STAGE="$(mktemp -d)"
cp -R "$OUT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$APP_NAME-$VERSION-checksums.txt")
info "Artifacts"
ls -lh "$DIST"
