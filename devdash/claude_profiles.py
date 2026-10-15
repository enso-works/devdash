"""Claude Code profiles: separate config dirs (and accounts) picked by folder.

Reads the same ~/.config/claude-profiles as bin/claude-profile:

    # name    config dir       folders that use it
    work      ~/.claude-work   ~/Projects
    personal  ~/.claude        ~/PrivateProjects
    default   personal
    github    work             your-work-login

A `github` line names the GitHub account a profile's folders use with `gh` (bin/claude-profile gh).
Without that file there is one profile, ~/.claude.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DIR = Path.home() / ".claude"
KEYCHAIN_SERVICE = "Claude Code-credentials"


def _config_path() -> Path:
    return Path(os.environ.get("CLAUDE_PROFILES_CONFIG") or Path.home() / ".config" / "claude-profiles")


def _expand(path: str) -> Path:
    return Path(os.path.expanduser(path.rstrip("/") or "/"))


@dataclass(frozen=True)
class ClaudeProfile:
    name: str
    dir: Path
    folders: tuple[Path, ...] = ()
    # GitHub login its folders use with gh, from its `github` line
    github: str | None = None

    @property
    def is_default_dir(self) -> bool:
        return self.dir == DEFAULT_DIR

    @property
    def keychain_service(self) -> str:
        # Claude Code suffixes the service with a hash of CLAUDE_CONFIG_DIR whenever that is set.
        if self.is_default_dir:
            return KEYCHAIN_SERVICE
        digest = hashlib.sha256(unicodedata.normalize("NFC", str(self.dir)).encode()).hexdigest()
        return f"{KEYCHAIN_SERVICE}-{digest[:8]}"

    @property
    def state_file(self) -> Path:
        return Path.home() / ".claude.json" if self.is_default_dir else self.dir / ".claude.json"

    def email(self) -> str | None:
        try:
            account = json.loads(self.state_file.read_text(encoding="utf-8")).get("oauthAccount") or {}
        except (OSError, json.JSONDecodeError, AttributeError):
            return None
        return account.get("emailAddress")


@dataclass(frozen=True)
class Profiles:
    profiles: tuple[ClaudeProfile, ...]
    default: str

    def get(self, name: str | None) -> ClaudeProfile:
        for profile in self.profiles:
            if profile.name == name:
                return profile
        return self.get(self.default) if name != self.default else self.profiles[0]

    def route(self, path: str) -> str | None:
        """The profile that claims a folder; None when no folder rule matches."""
        if not path:
            return None
        target = Path(path)
        best, best_len = None, -1
        for profile in self.profiles:
            for folder in profile.folders:
                if (target == folder or folder in target.parents) and len(str(folder)) > best_len:
                    best, best_len = profile.name, len(str(folder))
        return best

    def for_config_dir(self, config_dir: str | None) -> str | None:
        current = _expand(config_dir) if config_dir else DEFAULT_DIR
        return next((p.name for p in self.profiles if p.dir == current), None)


def load_profiles() -> Profiles:
    profiles: list[ClaudeProfile] = []
    default = None
    github: dict[str, str] = {}
    try:
        lines = _config_path().read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    rows = [line.split() for line in lines]
    for parts in rows:
        if parts and parts[0] == "github" and len(parts) > 2:
            github[parts[1]] = parts[2]
    for parts in rows:
        if not parts or parts[0].startswith("#") or parts[0] == "github":
            continue
        if parts[0] == "default" and len(parts) > 1:
            default = parts[1]
        elif len(parts) >= 2:
            folders = tuple(_resolve(_expand(f)) for f in parts[2:])
            profiles.append(ClaudeProfile(parts[0], _expand(parts[1]), folders, github.get(parts[0])))
    if not profiles:
        profiles = [ClaudeProfile("default", DEFAULT_DIR)]
    names = [p.name for p in profiles]
    return Profiles(tuple(profiles), default if default in names else names[0])


def _resolve(path: Path) -> Path:
    try:
        return path.resolve()
    except OSError:
        return path


# --- GitHub logins -----------------------------------------------------------------------------------------------

GH_CHECK_SECONDS = 60
_gh_checked: dict[str, tuple[float, bool]] = {}


def _gh_binary() -> str | None:
    # The menu bar app's bridge may not have Homebrew on its PATH
    return shutil.which("gh") or next(
        (p for p in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh") if os.access(p, os.X_OK)), None
    )


def github_signed_in(login: str | None) -> bool | None:
    """Whether gh holds a login for this GitHub account; None without an account or gh. Checked once a minute."""
    if not login:
        return None
    gh = _gh_binary()
    if not gh:
        return None
    now = time.monotonic()
    cached = _gh_checked.get(login)
    if cached and now - cached[0] < GH_CHECK_SECONDS:
        return cached[1]
    try:
        # the token itself is discarded: only whether gh has one counts
        result = subprocess.run(
            [gh, "auth", "token", "--hostname", "github.com", "--user", login],
            capture_output=True,
            timeout=5,
            check=False,
        )
        signed_in = result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        signed_in = False
    _gh_checked[login] = (now, signed_in)
    return signed_in
