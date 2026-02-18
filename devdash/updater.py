from __future__ import annotations

import subprocess
import time
from pathlib import Path

_DATA_DIR = Path.home() / ".local" / "share" / "devdash"
_LAST_CHECK_FILE = _DATA_DIR / "last-update-check"
_CHECK_INTERVAL = 86400  # 24 hours


def _get_install_dir() -> Path | None:
    """Return the git repo root above this package, or None if not a git clone."""
    pkg_dir = Path(__file__).resolve().parent
    candidate = pkg_dir.parent
    if (candidate / ".git").is_dir():
        return candidate
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
    """Fetch origin/main and compare with HEAD. Returns a message or None."""
    repo = _get_install_dir()
    if repo is None:
        return None

    try:
        subprocess.run(
            ["git", "fetch", "origin", "main"],
            cwd=repo,
            capture_output=True,
            timeout=15,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None

    _touch_last_check()

    try:
        local = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()

        remote = subprocess.run(
            ["git", "rev-parse", "origin/main"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None

    if local != remote and remote:
        return "A new version of devdash is available. Run 'devdash --update' to update."

    return None


def perform_update() -> None:
    """Pull latest changes and reinstall."""
    repo = _get_install_dir()
    if repo is None:
        print("Not installed from git clone -- update not available.")
        return

    print("Pulling latest changes...")
    result = subprocess.run(
        ["git", "pull", "--ff-only"],
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:
        print(f"Git pull failed: {result.stderr.strip()}")
        return

    print(result.stdout.strip())
    print("Reinstalling...")

    pip_result = subprocess.run(
        ["pip", "install", "-e", "."],
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=120,
    )

    if pip_result.returncode != 0:
        print(f"Install failed: {pip_result.stderr.strip()}")
        return

    from devdash import __version__

    print(f"Updated to devdash {__version__}")
