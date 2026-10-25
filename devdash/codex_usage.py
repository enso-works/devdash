"""Codex usage: plan limits and API-equivalent cost from local rollouts.

Cost is what the same tokens would cost at OpenAI API list prices
(https://developers.openai.com/api/docs/pricing), not what a ChatGPT plan is billed.
"""
from __future__ import annotations

import base64
import json
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from devdash.claude_usage import summarize
from devdash.codex import CODEX_HOME

USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
NOT_SIGNED_IN = "Not signed in to Codex"
LIMITS_TTL = 120.0  # seconds between plan-limit requests

CACHE_WRITE = 1.25  # 30-minute cache writes, the default
LONG_CONTEXT = 272_000  # input tokens above which the whole request costs the long-context rate
LONG_INPUT = 2.0
LONG_OUTPUT = 1.5


@dataclass(frozen=True)
class Price:
    input: float  # $ per MTok
    cached: float
    output: float
    long_context: bool = False
    fast: float = 2.0  # Fast (priority) multiplier


PRICES: dict[str, Price] = {
    "gpt-6.1-sol": Price(2, 0.10, 10, True),
    "gpt-6-sol": Price(2, 0.20, 10, True),
    "gpt-6-astra": Price(10, 1.00, 50, True),
    "gpt-6-luna": Price(0.10, 0.01, 0.50, True),
    "gpt-5.6-sol": Price(4, 0.40, 20, True),
    "gpt-5.6-terra": Price(2, 0.20, 12, True),
    "gpt-5.6-luna": Price(0.20, 0.02, 1.20, True),
    "gpt-5.5": Price(5, 0.50, 30, True, 2.5),
    "gpt-5.4": Price(2.5, 0.25, 15, True),
    "gpt-5.3-codex": Price(1.75, 0.175, 14),
    "gpt-5.2-codex": Price(1.75, 0.175, 14),
    "gpt-5.2": Price(1.75, 0.175, 14),
    "gpt-5.1-codex-max": Price(1.25, 0.125, 10),
    "gpt-5.1-codex-mini": Price(0.25, 0.025, 2),
    "gpt-5.1-codex": Price(1.25, 0.125, 10),
    "gpt-5.1": Price(1.25, 0.125, 10),
    "gpt-5-codex": Price(1.25, 0.125, 10),
    "gpt-5-mini": Price(0.25, 0.025, 2),
    "gpt-5-nano": Price(0.05, 0.005, 0.40),
    "gpt-5": Price(1.25, 0.125, 10),
    "codex-mini-latest": Price(1.5, 0.375, 6),
}
_SNAPSHOT = re.compile(r"-\d{4}-\d{2}-\d{2}$")


def price_for(model: str) -> Price | None:
    # Exact ids only (plus dated snapshots), so a new -mini never gets its big sibling's price.
    return PRICES.get(_SNAPSHOT.sub("", model))


@dataclass
class UsageEntry:
    timestamp: float  # epoch seconds
    model: str
    project: str
    input: int  # uncached input
    output: int  # includes reasoning
    cache_write: int
    cache_read: int
    reasoning: int
    fast: bool

    def cost(self) -> float | None:
        price = price_for(self.model)
        if price is None:
            return None
        base_in, cached, base_out = price.input, price.cached, price.output
        if price.long_context and self.input + self.cache_read + self.cache_write > LONG_CONTEXT:
            base_in, cached, base_out = base_in * LONG_INPUT, cached * LONG_INPUT, base_out * LONG_OUTPUT
        if self.fast:
            base_in, cached, base_out = base_in * price.fast, cached * price.fast, base_out * price.fast
        return (
            self.input * base_in
            + self.cache_write * base_in * CACHE_WRITE
            + self.cache_read * cached
            + self.output * base_out
        ) / 1_000_000


def _parse_timestamp(value: str) -> float | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def _entry(usage: dict, ts: float, context: dict) -> UsageEntry:
    total_in = usage.get("input_tokens") or 0
    cached = usage.get("cached_input_tokens") or 0
    written = usage.get("cache_write_input_tokens") or 0
    cwd = context.get("cwd") or ""
    return UsageEntry(
        timestamp=ts,
        model=context.get("model") or "",
        project=Path(cwd).name if cwd else "",
        # input_tokens counts cached and cache-write tokens too
        input=max(total_in - cached - written, 0),
        output=usage.get("output_tokens") or 0,
        cache_write=written,
        cache_read=cached,
        reasoning=usage.get("reasoning_output_tokens") or 0,
        fast=context.get("service_tier") in ("priority", "fast"),
    )


@dataclass
class RolloutUsage:
    entries: dict[str, UsageEntry]
    # Latest rate-limit snapshot in the file: (timestamp, rate_limits)
    limits: tuple[float, dict] | None


def parse_rollout(lines) -> RolloutUsage:
    """Newer rollouts log a `token_usage_record` per response; older ones only `token_count`
    events, which repeat when nothing changed, so those count only when the total moves."""
    records: dict[str, UsageEntry] = {}
    counts: dict[str, UsageEntry] = {}
    turns: dict[str, dict] = {}
    context: dict = {}
    limits: tuple[float, dict] | None = None
    previous_total = None
    for line in lines:
        if b'"turn_context"' not in line and b'"token_' not in line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = record.get("type")
        payload = record.get("payload") or {}
        if kind == "turn_context":
            context = {
                "model": payload.get("model") or ((payload.get("collaboration_mode") or {}).get("settings") or {}).get("model"),
                "cwd": payload.get("cwd"),
                "service_tier": payload.get("service_tier"),
            }
            if payload.get("turn_id"):
                turns[payload["turn_id"]] = context
            continue
        ts = _parse_timestamp(record.get("timestamp", ""))
        if ts is None:
            continue
        if kind == "token_usage_record":
            usage = payload.get("usage")
            if usage:
                key = payload.get("response_id") or f"{payload.get('thread_id')}:{record.get('timestamp')}"
                records[key] = _entry(usage, ts, turns.get(payload.get("turn_id"), context))
        elif kind == "event_msg" and payload.get("type") == "token_count":
            if payload.get("rate_limits") and (limits is None or ts >= limits[0]):
                limits = (ts, payload["rate_limits"])
            info = payload.get("info") or {}
            total, last = info.get("total_token_usage"), info.get("last_token_usage")
            if not last or total == previous_total:
                continue
            previous_total = total
            # Forked threads copy their parent's events, timestamps included.
            counts[f"{record.get('timestamp')}:{(total or {}).get('total_tokens')}"] = _entry(last, ts, context)
    return RolloutUsage(records or counts, limits)


def _zstd_binary() -> str | None:
    # The menu bar app's bridge may not have Homebrew on its PATH
    return shutil.which("zstd") or next(
        (p for p in ("/opt/homebrew/bin/zstd", "/usr/local/bin/zstd") if Path(p).is_file()), None
    )


def _read_lines(path: Path) -> list[bytes] | None:
    """Lines of a rollout; archived ones are zstd-compressed. None when they can't be read."""
    if path.suffix != ".zst":
        try:
            return path.read_bytes().splitlines()
        except OSError:
            return None
    try:
        from compression import zstd  # Python 3.14+

        return zstd.decompress(path.read_bytes()).splitlines()
    except ImportError:
        pass
    except Exception:  # OSError or a corrupt frame
        return None
    binary = _zstd_binary()
    if binary is None:
        return None
    try:
        result = subprocess.run([binary, "-dcq", str(path)], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.splitlines() if result.returncode == 0 else None


class RolloutIndex:
    """Parses rollouts once and re-reads only files whose size or mtime changed."""

    def __init__(self, home: Path) -> None:
        self._home = home
        self._files: dict[str, tuple[int, float, RolloutUsage | None]] = {}

    def _paths(self):
        for folder in ("sessions", "archived_sessions"):
            root = self._home / folder
            if root.is_dir():
                yield from root.rglob("rollout-*.jsonl")
                yield from root.rglob("rollout-*.jsonl.zst")

    def scan(self) -> tuple[list[UsageEntry], tuple[float, dict] | None, int]:
        """Usage entries, the latest rate-limit snapshot, and how many rollouts couldn't be read."""
        seen: set[str] = set()
        for path in self._paths():
            key = str(path)
            seen.add(key)
            try:
                stat = path.stat()
            except OSError:
                continue
            cached = self._files.get(key)
            if cached and cached[0] == stat.st_size and cached[1] == stat.st_mtime:
                continue
            lines = _read_lines(path)
            self._files[key] = (stat.st_size, stat.st_mtime, parse_rollout(lines) if lines is not None else None)
        for key in list(self._files):
            if key not in seen:
                del self._files[key]

        merged: dict[str, UsageEntry] = {}
        latest: tuple[float, dict] | None = None
        unreadable = 0
        for _, _, parsed in self._files.values():
            if parsed is None:
                unreadable += 1
                continue
            merged.update(parsed.entries)
            if parsed.limits and (latest is None or parsed.limits[0] > latest[0]):
                latest = parsed.limits
        return list(merged.values()), latest, unreadable


# -- Plan limits --------------------------------------------------------------


def _read_auth(home: Path) -> dict | None:
    try:
        return json.loads((home / "auth.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _token_expired(token: str) -> bool:
    try:
        claims = token.split(".")[1]
        exp = json.loads(base64.urlsafe_b64decode(claims + "=" * (-len(claims) % 4))).get("exp")
    except (IndexError, ValueError, AttributeError):
        return False
    return bool(exp) and exp < time.time()


def _plan_label(plan_type: str | None) -> str | None:
    if not plan_type:
        return None
    return {"edu": "Edu", "enterprise": "Enterprise", "business": "Business"}.get(plan_type, plan_type.replace("_", " ").title())


def _window_label(seconds: float | None) -> tuple[str, str]:
    """(label, group) for a limit window: 5 hours is the session, a week the weekly limit."""
    if not seconds:
        return "Limit", "other"
    hours = seconds / 3600
    if hours < 24:
        return f"Session ({hours:g}h)", "session"
    if round(hours / 24) == 7:
        return "Weekly", "weekly"
    return f"{hours / 24:g}-day", "weekly"


def _limit(window: dict | None, prefix: str, reached: bool, now: float) -> dict | None:
    if not window:
        return None
    seconds = window.get("limit_window_seconds") or (window.get("window_minutes") or 0) * 60
    resets_at = window.get("reset_at") or window.get("resets_at")
    if not resets_at and window.get("reset_after_seconds") is not None:
        resets_at = now + window["reset_after_seconds"]
    percent = float(window.get("used_percent") or 0)
    if resets_at and resets_at < now:
        percent = 0.0  # the window reset since this was reported
    label, group = _window_label(seconds)
    return {
        "label": f"{prefix}, {label.lower()}" if prefix else label,
        "group": group if not prefix else "other",
        "percent": percent,
        "severity": "critical" if reached and percent >= 100 else "normal",
        "resets_at": float(resets_at) if resets_at else None,
        "is_active": group == "session" and not prefix,
        "window_seconds": seconds or None,
    }


def _limits(primary: dict | None, secondary: dict | None, prefix: str, reached: bool, now: float) -> list[dict]:
    return [l for l in (_limit(primary, prefix, reached, now), _limit(secondary, prefix, reached, now)) if l]


def _credits(block: dict | None) -> dict | None:
    if not block or not block.get("has_credits"):
        return None
    try:
        balance = float(block.get("balance") or 0)
    except (TypeError, ValueError):
        balance = 0.0
    return {"balance": balance, "unlimited": bool(block.get("unlimited"))}


def limits_from_api(data: dict, now: float) -> dict:
    rate = data.get("rate_limit") or {}
    reached = bool(rate.get("limit_reached"))
    limits = _limits(rate.get("primary_window"), rate.get("secondary_window"), "", reached, now)
    review = data.get("code_review_rate_limit") or {}
    limits += _limits(review.get("primary_window"), review.get("secondary_window"), "Code review", bool(review.get("limit_reached")), now)
    for extra in data.get("additional_rate_limits") or []:
        block = extra.get("rate_limit") or {}
        name = extra.get("limit_name") or extra.get("metered_feature") or "Other"
        limits += _limits(block.get("primary_window"), block.get("secondary_window"), name, bool(block.get("limit_reached")), now)
    return {"plan": _plan_label(data.get("plan_type")), "limits": limits, "credits": _credits(data.get("credits"))}


def limits_from_rollout(snapshot: dict, now: float) -> dict:
    reached = bool(snapshot.get("rate_limit_reached_type"))
    return {
        "plan": _plan_label(snapshot.get("plan_type")),
        "limits": _limits(snapshot.get("primary"), snapshot.get("secondary"), "", reached, now),
        "credits": _credits(snapshot.get("credits")),
    }


def fetch_plan_limits(home: Path = CODEX_HOME) -> dict:
    """Returns {"plan", "limits", "credits", "error"} from the live API; never raises."""
    empty = {"plan": None, "limits": [], "credits": None}
    auth = _read_auth(home)
    tokens = (auth or {}).get("tokens") or {}
    if not tokens.get("access_token"):
        if auth and auth.get("OPENAI_API_KEY"):
            return {**empty, "error": "Signed in with an API key, which has no plan limits"}
        return {**empty, "error": NOT_SIGNED_IN}
    if _token_expired(tokens["access_token"]):
        # Refreshing here would rotate Codex's tokens, so wait for Codex to do it.
        return {**empty, "error": "Sign-in expired, run Codex to refresh it"}

    headers = {"Authorization": f"Bearer {tokens['access_token']}", "User-Agent": "devdash"}
    if tokens.get("account_id"):
        headers["ChatGPT-Account-Id"] = tokens["account_id"]
    try:
        with urllib.request.urlopen(urllib.request.Request(USAGE_URL, headers=headers), timeout=10) as response:
            data = json.loads(response.read())
    except urllib.error.HTTPError as e:
        return {**empty, "error": f"Usage API returned {e.code}"}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
        return {**empty, "error": f"Usage API unavailable: {e}"}
    return {**limits_from_api(data, time.time()), "error": None}


class CodexUsageTracker:
    """Thread-safe usage state: incremental rollout index plus throttled limit fetches."""

    def __init__(self, home: Path = CODEX_HOME) -> None:
        self.home = home
        self._index = RolloutIndex(home)
        self._lock = threading.Lock()
        self._limits: dict | None = None
        self._limits_at = 0.0

    def payload(self, force_limits: bool = False) -> dict:
        with self._lock:
            stale = self._limits is None or self._limits["error"] == NOT_SIGNED_IN or time.time() - self._limits_at > LIMITS_TTL
            if force_limits or stale:
                self._limits = fetch_plan_limits(self.home)
                self._limits_at = time.time()
            limits, limits_at = dict(self._limits), self._limits_at
            entries, snapshot, unreadable = self._index.scan()

        note = None
        if limits["error"] and snapshot:
            # Codex reports its limits with every response, so fall back to the last report.
            local = limits_from_rollout(snapshot[1], time.time())
            if local["limits"]:
                note = f"{limits['error']}. Showing what Codex last reported."
                limits = {**local, "plan": local["plan"] or limits["plan"], "error": None}
                limits_at = snapshot[0]

        session_start = None
        for limit in limits["limits"]:
            if limit["group"] == "session" and limit["resets_at"]:
                session_start = limit["resets_at"] - (limit["window_seconds"] or 5 * 3600)
                break
        if unreadable:
            skipped = f"{unreadable} archived session{'s' if unreadable != 1 else ''} skipped: install zstd to read them"
            note = f"{note} {skipped}." if note else f"{skipped}."
        return {
            "profile": None,
            **limits,
            "extra_usage": None,
            "note": note,
            "limits_updated": limits_at,
            **summarize(entries, session_start=session_start),
        }


if __name__ == "__main__":
    started = time.time()
    print(json.dumps(CodexUsageTracker().payload(), indent=2, default=str))
    print(f"took {time.time() - started:.2f}s", file=sys.stderr)
