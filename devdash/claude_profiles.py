"""Claude Code profiles: separate config dirs (and accounts) picked by folder.

Reads the same ~/.config/claude-profiles as bin/claude-profile:

    # name    config dir       folders that use it
    work      ~/.claude-work   ~/Projects
    personal  ~/.claude        ~/PrivateProjects
    default   personal

Without that file there is one profile, ~/.claude.
"""
from __future__ import annotations

import hashlib
import json
import os
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
    try:
        lines = _config_path().read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    for line in lines:
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        if parts[0] == "default" and len(parts) > 1:
            default = parts[1]
        elif len(parts) >= 2:
            folders = tuple(_resolve(_expand(f)) for f in parts[2:])
            profiles.append(ClaudeProfile(parts[0], _expand(parts[1]), folders))
    if not profiles:
        profiles = [ClaudeProfile("default", DEFAULT_DIR)]
    names = [p.name for p in profiles]
    return Profiles(tuple(profiles), default if default in names else names[0])


def _resolve(path: Path) -> Path:
    try:
        return path.resolve()
    except OSError:
        return path
