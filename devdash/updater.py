from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

_DATA_DIR = Path.home() / ".local" / "share" / "devdash"
_LAST_CHECK_FILE = _DATA_DIR / "last-update-check"
_CHECK_INTERVAL = 86400  # 24 hours
_RELEASES_URL = "https://api.github.com/repos/enso-works/devdash/releases/latest"


def _get_install_dir() -> Path | None:
    """Return the git repo root above this package, or None if not a git clone."""
    pkg_dir = Path(__file__).resolve().parent
    candidate = pkg_dir.parent
    if (candidate / ".git").is_dir():
        return candidate
    return None


def _get_current_tag(repo: Path) -> str | None:
    """Return the tag checked out in the repo, or None."""
    try:
        result = subprocess.run(
            ["git", "describe", "--tags", "--exact-match", "HEAD"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return None


def _get_latest_release_tag() -> str | None:
    """Fetch the latest release tag from GitHub."""
    try:
        req = urllib.request.Request(_RELEASES_URL, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            return data.get("tag_name")
    except Exception:
        return None


def should_check_for_update() -> bool:
    """Return True if more than 24h since last update check."""
    if not _LAST_CHECK_FILE.exists():
        return True
    try:
        last = float(_LAST_CHECK_FILE.read_text().strip())
        return (time.time() - last) > _CHECK_INTERVAL
    except (ValueError, OSError):
        return True


def _touch_last_check() -> None:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    _LAST_CHECK_FILE.write_text(str(time.time()))


def check_for_update() -> str | None:
    """Compare current version against latest GitHub release. Returns a message or None."""
    repo = _get_install_dir()
    if repo is None:
        return None

    _touch_last_check()

    from devdash import __version__

    latest_tag = _get_latest_release_tag()
    if latest_tag is None:
        return None

    latest_version = latest_tag.lstrip("v")
    if latest_version != __version__:
        return f"devdash {latest_tag} is available (current: {__version__}). Run 'devdash --update' to update."

    return None


def perform_update() -> None:
    """Fetch the latest release tag and checkout."""
    repo = _get_install_dir()
    if repo is None:
        print("Not installed from git clone -- update not available.")
        return

    from devdash import __version__

    print(f"Current version: {__version__}")
    print("Checking for latest release...")

    latest_tag = _get_latest_release_tag()
    if latest_tag is None:
        print("Could not fetch latest release from GitHub.")
        return

    latest_version = latest_tag.lstrip("v")
    if latest_version == __version__:
        print(f"Already up to date ({__version__}).")
        return

    print(f"Updating to {latest_tag}...")

    try:
        subprocess.run(
            ["git", "fetch", "--tags", "--force"],
            cwd=repo,
            capture_output=True,
            timeout=30,
        )
        result = subprocess.run(
            ["git", "checkout", latest_tag],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            print(f"Git checkout failed: {result.stderr.strip()}")
            return
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        print(f"Git error: {e}")
        return

    print("Reinstalling...")

    pip = str(repo / ".venv" / "bin" / "pip")
    if not Path(pip).exists():
        pip = sys.executable.replace("python", "pip")

    pip_result = subprocess.run(
        [pip, "install", "-e", "."],
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=120,
    )

    if pip_result.returncode != 0:
        print(f"Install failed: {pip_result.stderr.strip()}")
        return

    print(f"Updated to devdash {latest_tag}")
