#!/usr/bin/env bash
# Embeds a universal Python runtime with devdash and its dependencies into DevDash.app, so the
# app works without a separate CLI install. Signing is left to build-app.sh.
#   ./scripts/embed-python.sh path/to/DevDash.app
#
# Layout inside the bundle:
#   Contents/Resources/python/    CPython (python-build-standalone), arm64 + x86_64 merged with lipo
#   Contents/Resources/bin/devdash  launcher script; the app runs it and users can symlink it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP="${1:?usage: embed-python.sh path/to/DevDash.app}"

PBS_TAG="20260924"
PY_VERSION="3.13.15"
PY_MINOR="3.13"
SHA_arm64="064afb7c2fc0bbf511d886288adf98696af5105e36c138cdf2c199c0146fcf68"
SHA_x86_64="327814efd865a0b6a99c149b12a261e9d0ad409183515c745d41bda2d07282e9"

CACHE="$ROOT/build/cache"
WORK="$ROOT/build/python"
DEST="$APP/Contents/Resources/python"
HOST_ARCH="$(uname -m)"

info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

pbs_arch() { [[ "$1" == "arm64" ]] && echo aarch64 || echo x86_64; }

# --- Fetch and unpack both architectures ----------------------------------------------------
rm -rf "$WORK"
mkdir -p "$CACHE" "$WORK"
for arch in arm64 x86_64; do
    name="cpython-$PY_VERSION+$PBS_TAG-$(pbs_arch "$arch")-apple-darwin-install_only_stripped.tar.gz"
    if [[ ! -f "$CACHE/$name" ]]; then
        info "Downloading Python $PY_VERSION ($arch)"
        curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/${name//+/%2B}" -o "$CACHE/$name.part"
        mv "$CACHE/$name.part" "$CACHE/$name"
    fi
    sha_var="SHA_$arch"
    echo "${!sha_var}  $CACHE/$name" | shasum -a 256 -c --quiet
    mkdir -p "$WORK/$arch"
    tar -xzf "$CACHE/$name" -C "$WORK/$arch"
done
HOST_PY="$WORK/$HOST_ARCH/python/bin/python3"

# --- Install devdash and its dependencies per architecture ----------------------------------
info "Building devdash wheel"
"$HOST_PY" -m pip wheel --quiet --no-deps --wheel-dir "$WORK/wheel" "$REPO"
for arch in arm64 x86_64; do
    info "Installing dependencies ($arch)"
    "$HOST_PY" -m pip install --quiet --no-compile --disable-pip-version-check \
        --target "$WORK/site-$arch" --platform "macosx_11_0_$arch" --only-binary=:all: \
        --python-version "$PY_MINOR" --implementation cp \
        "$WORK"/wheel/devdash-*.whl
done

# --- Assemble the runtime, trimmed to what devdash needs ------------------------------------
info "Assembling runtime in $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$WORK/arm64/python" "$DEST"
STDLIB="$DEST/lib/python$PY_MINOR"
# bin/python3.13 links the interpreter statically, so libpython is not needed either.
rm -rf "$DEST/include" "$DEST/share" "$DEST/lib/pkgconfig" "$DEST/lib/"tcl* "$DEST/lib/"tk* "$DEST/lib/"itcl* \
    "$DEST/lib/"thread* "$DEST/lib/"lib*.dylib "$DEST/bin/python" "$DEST/bin/"idle* "$DEST/bin/"pydoc* "$DEST/bin/"pip* "$DEST/bin/"*-config \
    "$STDLIB/"config-* "$STDLIB/"{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data} \
    "$STDLIB/"lib-dynload/_tkinter* "$STDLIB/"lib-dynload/_test* "$STDLIB/"lib-dynload/xxlimited* \
    "$STDLIB/site-packages/"*
cp -R "$WORK/site-arm64/." "$STDLIB/site-packages/"
find "$DEST" -name "__pycache__" -type d -prune -exec rm -rf {} +

# --- Merge x86_64 slices into every Mach-O file ---------------------------------------------
info "Merging x86_64 slices"
merged=0
while IFS= read -r -d '' file; do
    [[ "$(file -b --mime-type "$file")" == "application/x-mach-binary" ]] || continue
    rel="${file#"$DEST"/}"
    if [[ "$rel" == lib/python$PY_MINOR/site-packages/* ]]; then
        other="$WORK/site-x86_64/${rel#lib/python$PY_MINOR/site-packages/}"
    else
        other="$WORK/x86_64/python/$rel"
    fi
    [[ -f "$other" ]] || { echo "missing x86_64 counterpart for $rel" >&2; exit 1; }
    lipo -create "$file" "$other" -output "$file.universal"
    mv "$file.universal" "$file"
    merged=$((merged + 1))
done < <(find "$DEST" -type f -print0)
echo "$merged universal binaries"

# --- Precompile bytecode so nothing is written into the signed bundle -----------------------
info "Compiling bytecode"
"$HOST_PY" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$STDLIB" >/dev/null

# --- Launcher -------------------------------------------------------------------------------
mkdir -p "$APP/Contents/Resources/bin"
cat > "$APP/Contents/Resources/bin/devdash" <<'SH'
#!/bin/sh
# devdash CLI bundled with DevDash.app. Safe to symlink, e.g. into ~/.local/bin.
here="$(dirname "$(realpath "$0")")"
DEVDASH_BUNDLED=1 exec "$here/../python/bin/python3" -I -B -m devdash.cli "$@"
SH
chmod 755 "$APP/Contents/Resources/bin/devdash"

"$APP/Contents/Resources/bin/devdash" --version
du -sh "$DEST"
