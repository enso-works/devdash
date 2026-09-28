#!/usr/bin/env bash
# Regenerates README screenshots from synthetic demo data (no real processes or usage).
#   scripts/screenshots.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEVDASH="$REPO/.venv/bin/devdash"
OUT="$REPO/screenshots"
APP_SHOTS=(hero dev docker system claude usage cleanup graph heatmap project detail)

echo "==> Terminal UI"
"$REPO/.venv/bin/python" "$REPO/scripts/tui_screenshots.py" "$OUT"

echo "==> Menu bar app"
swift build --package-path "$REPO/macos"
TMP="$(mktemp -d)"
DEVDASH_DEMO=1 DEVDASH_BIN="$DEVDASH" "$(swift build --package-path "$REPO/macos" --show-bin-path)/DevDashBar" --render "$TMP"
mkdir -p "$OUT/app"
for name in "${APP_SHOTS[@]}"; do
    cp "$TMP/$name.png" "$OUT/app/$name.png"
done
DEVDASH_DEMO=1 "$(swift build --package-path "$REPO/macos" --show-bin-path)/DevDashBar" --render-disk "$OUT/app/disk-tree.png"
rm -rf "$TMP"
ls -lh "$OUT" "$OUT/app"
