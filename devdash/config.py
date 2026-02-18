from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

DEFAULT_CONFIG_PATH = Path.home() / ".config" / "devdash" / "config.toml"


@dataclass
class Config:
    refresh_rate: float = 3.0
    process_limit: int = 80
    watched_ports: list[int] = field(default_factory=list)
    color_threshold_low: float = 50.0
    color_threshold_high: float = 80.0

    @classmethod
    def load(cls, path: Path | None = None) -> Config:
        config_path = path or DEFAULT_CONFIG_PATH
        if not config_path.exists():
            return cls()
        if tomllib is None:
            return cls()
        try:
            with open(config_path, "rb") as f:
                data = tomllib.load(f)
        except Exception:
            return cls()
        return cls(
            refresh_rate=float(data.get("refresh_rate", cls.refresh_rate)),
            process_limit=int(data.get("process_limit", cls.process_limit)),
            watched_ports=list(data.get("watched_ports", [])),
            color_threshold_low=float(data.get("color_threshold_low", cls.color_threshold_low)),
            color_threshold_high=float(data.get("color_threshold_high", cls.color_threshold_high)),
        )
