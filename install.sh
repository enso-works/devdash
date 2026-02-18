#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/enso-works/devdash.git"
REPO_API="https://api.github.com/repos/enso-works/devdash"
INSTALL_DIR="$HOME/.devdash"
BIN_DIR="$HOME/.local/bin"

info()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
error() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Find Python >= 3.10 ---
find_python() {
    for cmd in python3.12 python3.11 python3.10 python3 python; do
        if command -v "$cmd" >/dev/null 2>&1; then
            version=$("$cmd" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null) || continue
            major=${version%%.*}
            minor=${version#*.}
            if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
                echo "$cmd"
                return
            fi
        fi
    done
    return 1
}

PYTHON=$(find_python) || error "Python 3.10+ is required but not found."
info "Using $PYTHON ($($PYTHON --version 2>&1))"

# --- Check git ---
command -v git >/dev/null 2>&1 || error "git is required but not found."

# --- Resolve version ---
resolve_version() {
    if [ -n "${VERSION:-}" ]; then
        echo "v${VERSION#v}"
        return
    fi
    # Try GitHub API for latest release
    if command -v curl >/dev/null 2>&1; then
        tag=$(curl -fsSL "$REPO_API/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ -n "$tag" ]; then
            echo "$tag"
            return
        fi
    fi
    # Try git ls-remote for latest tag
    tag=$(git ls-remote --tags --sort=-v:refname "$REPO_URL" 2>/dev/null | head -1 | sed 's|.*/||')
    if [ -n "$tag" ]; then
        echo "$tag"
        return
    fi
    # Fallback to main
    echo "main"
}

TARGET_REF=$(resolve_version)
info "Target version: $TARGET_REF"

# --- Clone or update ---
if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing installation..."
    git -C "$INSTALL_DIR" fetch --tags --force
    if [ "$TARGET_REF" = "main" ]; then
        git -C "$INSTALL_DIR" checkout main --quiet
        git -C "$INSTALL_DIR" pull --ff-only
    else
        git -C "$INSTALL_DIR" checkout "$TARGET_REF" --quiet
    fi
else
    if [ -d "$INSTALL_DIR" ]; then
        error "$INSTALL_DIR exists but is not a git repo. Remove it first: rm -rf $INSTALL_DIR"
    fi
    info "Cloning devdash..."
    if [ "$TARGET_REF" = "main" ]; then
        git clone "$REPO_URL" "$INSTALL_DIR"
    else
        git clone --branch "$TARGET_REF" "$REPO_URL" "$INSTALL_DIR"
    fi
fi

# --- Create venv and install ---
info "Setting up virtual environment..."
$PYTHON -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip --quiet
"$INSTALL_DIR/.venv/bin/pip" install -e "$INSTALL_DIR" --quiet

# --- Symlink binary ---
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/.venv/bin/devdash" "$BIN_DIR/devdash"

# --- Shell PATH setup ---
add_to_path() {
    local rc_file="$1"
    local line='export PATH="$HOME/.local/bin:$PATH"'
    if [ -f "$rc_file" ] && grep -qF '/.local/bin' "$rc_file"; then
        return
    fi
    printf '\n# devdash\n%s\n' "$line" >> "$rc_file"
    info "Added ~/.local/bin to PATH in $rc_file"
}

case "${SHELL:-}" in
    */zsh)  add_to_path "$HOME/.zshrc" ;;
    */bash)
        if [ -f "$HOME/.bash_profile" ]; then
            add_to_path "$HOME/.bash_profile"
        else
            add_to_path "$HOME/.bashrc"
        fi
        ;;
    *)
        if [ -f "$HOME/.zshrc" ]; then
            add_to_path "$HOME/.zshrc"
        elif [ -f "$HOME/.bashrc" ]; then
            add_to_path "$HOME/.bashrc"
        fi
        ;;
esac

# --- Done ---
VERSION=$("$INSTALL_DIR/.venv/bin/devdash" --version 2>&1 || echo "devdash")
info ""
info "Installed $VERSION"
info ""
info "Open a new shell (or run 'source ~/.zshrc') then:"
info "  devdash"
