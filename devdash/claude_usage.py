"""Claude Code usage: plan limits and API-equivalent cost from local transcripts.

Cost is what the same tokens would cost at Anthropic API list prices
(https://platform.claude.com/docs/en/about-claude/pricing), not what a
subscription is billed.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
PROJECTS_DIR = CLAUDE_DIR / "projects"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
LIMITS_TTL = 120.0  # seconds between plan-limit requests

CACHE_WRITE_5M = 1.25
CACHE_WRITE_1H = 2.0
WEB_SEARCH_PER_REQUEST = 10.0 / 1000
US_INFERENCE_MULTIPLIER = 1.1


@dataclass(frozen=True)
class Price:
    input: float  # $ per MTok
    output: float
    cache_read_multiplier: float = 0.1
    fast_input: float | None = None
    fast_output: float | None = None


# Longest prefix wins, so more specific ids must come first.
PRICES: list[tuple[str, Price]] = [
    ("claude-fable-5-1", Price(10, 50, 0.025)),
    ("claude-mythos-5-1", Price(10, 50, 0.025)),
    ("claude-fable-5", Price(10, 50)),
    ("claude-mythos-5", Price(10, 50)),
    ("claude-opus-5-5", Price(4, 20, 0.05, 8, 40)),
    ("claude-opus-5", Price(5, 25, 0.1, 10, 50)),
    ("claude-opus-4-8", Price(5, 25, 0.1, 10, 50)),
    ("claude-opus-4-7", Price(5, 25)),
    ("claude-opus-4-6", Price(5, 25)),
    ("claude-opus-4-5", Price(5, 25)),
    ("claude-opus-4-1", Price(15, 75)),
    ("claude-opus-4", Price(15, 75)),
    ("claude-sonnet-5", Price(2, 10)),
    ("claude-sonnet-4-6", Price(3, 15)),
    ("claude-sonnet-4-5", Price(3, 15)),
    ("claude-sonnet-4", Price(3, 15)),
    ("claude-haiku-4-5", Price(1, 5)),
    ("claude-3-5-haiku", Price(0.8, 4)),
    ("claude-haiku-3-5", Price(0.8, 4)),
]


def price_for(model: str) -> Price | None:
    for prefix, price in PRICES:
        if model == prefix or model.startswith(prefix + "-"):
            return price
    return None


@dataclass
class UsageEntry:
    timestamp: float  # epoch seconds
    model: str
    project: str
    input: int
    output: int
    cache_write_5m: int
    cache_write_1h: int
    cache_read: int
    web_searches: int
    fast: bool
    us_inference: bool

    @property
    def cache_write(self) -> int:
        return self.cache_write_5m + self.cache_write_1h

    def cost(self) -> float | None:
        price = price_for(self.model)
        if price is None:
            return None
        base_in = price.fast_input if self.fast and price.fast_input else price.input
        base_out = price.fast_output if self.fast and price.fast_output else price.output
        total = (
            self.input * base_in
            + self.cache_write_5m * base_in * CACHE_WRITE_5M
            + self.cache_write_1h * base_in * CACHE_WRITE_1H
            + self.cache_read * base_in * price.cache_read_multiplier
            + self.output * base_out
        ) / 1_000_000
        if self.us_inference:
            total *= US_INFERENCE_MULTIPLIER
        return total + self.web_searches * WEB_SEARCH_PER_REQUEST


def _parse_timestamp(value: str) -> float | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def _parse_line(line: bytes) -> tuple[str, UsageEntry] | None:
    if b'"usage"' not in line:
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    if record.get("type") != "assistant":
        return None
    message = record.get("message") or {}
    usage = message.get("usage")
    model = message.get("model") or ""
    if not usage or not model or model.startswith("<"):
        return None
    ts = _parse_timestamp(record.get("timestamp", ""))
    if ts is None:
        return None

    cache_total = usage.get("cache_creation_input_tokens") or 0
    split = usage.get("cache_creation") or {}
    write_1h = split.get("ephemeral_1h_input_tokens") or 0
    write_5m = split.get("ephemeral_5m_input_tokens") or 0
    if write_1h + write_5m != cache_total:
        write_5m = max(cache_total - write_1h, 0)

    cwd = record.get("cwd") or ""
    # Streamed responses are logged once per content block with identical usage.
    key = f"{message.get('id')}:{record.get('requestId')}"
    return key, UsageEntry(
        timestamp=ts,
        model=model,
        project=Path(cwd).name if cwd else "",
        input=usage.get("input_tokens") or 0,
        output=usage.get("output_tokens") or 0,
        cache_write_5m=write_5m,
        cache_write_1h=write_1h,
        cache_read=usage.get("cache_read_input_tokens") or 0,
        web_searches=(usage.get("server_tool_use") or {}).get("web_search_requests") or 0,
        fast=usage.get("speed") == "fast",
        us_inference=usage.get("inference_geo") == "us",
    )


class TranscriptIndex:
    """Parses transcripts once and re-reads only files whose size or mtime changed."""

    def __init__(self, root: Path = PROJECTS_DIR) -> None:
        self._root = root
        self._files: dict[str, tuple[int, float, dict[str, UsageEntry]]] = {}

    def entries(self) -> list[UsageEntry]:
        seen: set[str] = set()
        if self._root.is_dir():
            for path in self._root.rglob("*.jsonl"):
                key = str(path)
                seen.add(key)
                try:
                    stat = path.stat()
                except OSError:
                    continue
                cached = self._files.get(key)
                if cached and cached[0] == stat.st_size and cached[1] == stat.st_mtime:
                    continue
                self._files[key] = (stat.st_size, stat.st_mtime, self._parse_file(path))
        for key in list(self._files):
            if key not in seen:
                del self._files[key]

        merged: dict[str, UsageEntry] = {}
        for _, _, file_entries in self._files.values():
            merged.update(file_entries)
        return list(merged.values())

    @staticmethod
    def _parse_file(path: Path) -> dict[str, UsageEntry]:
        entries: dict[str, UsageEntry] = {}
        try:
            with open(path, "rb") as handle:
                for line in handle:
                    parsed = _parse_line(line)
                    if parsed:
                        entries[parsed[0]] = parsed[1]
        except OSError:
            pass
        return entries


# -- Aggregation --------------------------------------------------------------


def _bucket() -> dict:
    return {"cost": 0.0, "input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "requests": 0}


def _add(bucket: dict, entry: UsageEntry, cost: float) -> None:
    bucket["cost"] += cost
    bucket["input"] += entry.input
    bucket["output"] += entry.output
    bucket["cache_write"] += entry.cache_write
    bucket["cache_read"] += entry.cache_read
    bucket["requests"] += 1


def summarize(entries: list[UsageEntry], session_start: float | None = None, now: float | None = None) -> dict:
    now = now or time.time()
    today = date.fromtimestamp(now)
    starts = {
        "today": datetime.combine(today, datetime.min.time()).timestamp(),
        "week": datetime.combine(today - timedelta(days=6), datetime.min.time()).timestamp(),
        "month": datetime.combine(today - timedelta(days=29), datetime.min.time()).timestamp(),
        "all": 0.0,
    }
    periods = {name: _bucket() for name in starts}
    session = _bucket()
    models: dict[str, dict] = {}
    projects: dict[str, float] = {}
    daily: dict[str, float] = {}
    unpriced: set[str] = set()

    for entry in entries:
        cost = entry.cost()
        if cost is None:
            unpriced.add(entry.model)
            cost = 0.0
        for name, start in starts.items():
            if entry.timestamp >= start:
                _add(periods[name], entry, cost)
        if session_start is not None and entry.timestamp >= session_start:
            _add(session, entry, cost)
        if entry.timestamp >= starts["month"]:
            bucket = models.setdefault(entry.model, _bucket())
            _add(bucket, entry, cost)
            if entry.project:
                projects[entry.project] = projects.get(entry.project, 0.0) + cost
            day = date.fromtimestamp(entry.timestamp).isoformat()
            daily[day] = daily.get(day, 0.0) + cost

    days = [(today - timedelta(days=offset)).isoformat() for offset in range(29, -1, -1)]
    return {
        "periods": periods,
        "session": session if session_start is not None else None,
        "models": sorted(
            ({"model": model, **bucket} for model, bucket in models.items()),
            key=lambda m: m["cost"],
            reverse=True,
        ),
        "projects": [[name, cost] for name, cost in sorted(projects.items(), key=lambda kv: kv[1], reverse=True)[:8]],
        "daily": [[day, daily.get(day, 0.0)] for day in days],
        "unpriced_models": sorted(unpriced),
    }


# -- Plan limits --------------------------------------------------------------


def _read_credentials() -> dict | None:
    """Claude Code keeps its OAuth credentials in the macOS keychain, or a file elsewhere."""
    raw = None
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                raw = result.stdout
        except (OSError, subprocess.TimeoutExpired):
            pass
    if raw is None:
        path = CLAUDE_DIR / ".credentials.json"
        if path.is_file():
            try:
                raw = path.read_text(encoding="utf-8")
            except OSError:
                return None
    if not raw:
        return None
    try:
        return json.loads(raw).get("claudeAiOauth")
    except (json.JSONDecodeError, AttributeError):
        return None


def _plan_label(subscription: str | None, tier: str | None) -> str | None:
    if not subscription:
        return None
    label = subscription.replace("_", " ").title()
    if tier:
        for multiplier in ("20x", "5x"):
            if multiplier in tier:
                return f"{label} {multiplier}"
    return label


def _limit_label(limit: dict) -> str:
    kind = limit.get("kind", "")
    if kind == "session":
        return "Session (5h)"
    if kind == "weekly_all":
        return "Weekly, all models"
    scope = limit.get("scope") or {}
    name = ((scope.get("model") or {}).get("display_name")) or ((scope.get("surface") or {}).get("display_name"))
    if kind.startswith("weekly"):
        return f"Weekly, {name}" if name else "Weekly"
    return (name or kind.replace("_", " ")).capitalize()


def fetch_plan_limits() -> dict:
    """Returns {"plan", "limits", "extra_usage", "error"}; never raises."""
    creds = _read_credentials()
    if not creds or not creds.get("accessToken"):
        return {"plan": None, "limits": [], "extra_usage": None, "error": "Not signed in to Claude Code"}

    plan = _plan_label(creds.get("subscriptionType"), creds.get("rateLimitTier"))
    expires_at = creds.get("expiresAt")
    if expires_at and expires_at / 1000 < time.time():
        # Refreshing here would rotate Claude Code's tokens, so wait for Claude Code to do it.
        return {"plan": plan, "limits": [], "extra_usage": None, "error": "Token expired, run Claude Code to refresh it"}

    request = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {creds['accessToken']}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "devdash",
    })
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            data = json.loads(response.read())
    except urllib.error.HTTPError as e:
        return {"plan": plan, "limits": [], "extra_usage": None, "error": f"Usage API returned {e.code}"}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
        return {"plan": plan, "limits": [], "extra_usage": None, "error": f"Usage API unavailable: {e}"}

    limits = []
    for limit in data.get("limits") or []:
        limits.append({
            "label": _limit_label(limit),
            "group": limit.get("group") or "",
            "percent": float(limit.get("percent") or 0),
            "severity": limit.get("severity") or "normal",
            "resets_at": _parse_timestamp(limit.get("resets_at") or ""),
            "is_active": bool(limit.get("is_active")),
        })
    if not limits:
        # Older response shape without the normalized list.
        for key, label in (("five_hour", "Session (5h)"), ("seven_day", "Weekly, all models")):
            block = data.get(key)
            if block:
                limits.append({
                    "label": label, "group": "session" if key == "five_hour" else "weekly",
                    "percent": float(block.get("utilization") or 0), "severity": "normal",
                    "resets_at": _parse_timestamp(block.get("resets_at") or ""), "is_active": key == "five_hour",
                })

    extra = data.get("extra_usage") or {}
    extra_usage = None
    if extra.get("is_enabled"):
        extra_usage = {
            "used": extra.get("used_credits"),
            "limit": extra.get("monthly_limit"),
            "currency": extra.get("currency") or "USD",
            "utilization": extra.get("utilization"),
        }
    return {"plan": plan, "limits": limits, "extra_usage": extra_usage, "error": None}


class UsageTracker:
    """Thread-safe usage state: incremental transcript index plus throttled limit fetches."""

    def __init__(self) -> None:
        self._index = TranscriptIndex()
        self._lock = threading.Lock()
        self._limits: dict | None = None
        self._limits_at = 0.0

    def payload(self, force_limits: bool = False) -> dict:
        with self._lock:
            if force_limits or self._limits is None or time.time() - self._limits_at > LIMITS_TTL:
                self._limits = fetch_plan_limits()
                self._limits_at = time.time()
            limits = self._limits
            entries = self._index.entries()

        session_start = None
        for limit in limits["limits"]:
            if limit["group"] == "session" and limit["resets_at"]:
                session_start = limit["resets_at"] - 5 * 3600
                break
        return {
            **limits,
            "limits_updated": self._limits_at,
            **summarize(entries, session_start=session_start),
        }


if __name__ == "__main__":
    started = time.time()
    print(json.dumps(UsageTracker().payload(), indent=2, default=str))
    print(f"took {time.time() - started:.2f}s", file=sys.stderr)
