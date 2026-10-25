import json
import sqlite3
import time

import pytest

from devdash import codex, codex_usage
from devdash.codex_usage import UsageEntry, limits_from_api, limits_from_rollout, parse_rollout, price_for


def line(kind, payload, ts="2026-10-24T12:00:00.000Z"):
    return json.dumps({"timestamp": ts, "type": kind, "payload": payload}).encode()


def usage(inp, cached=0, out=0, reasoning=0, written=0):
    return {"input_tokens": inp, "cached_input_tokens": cached, "cache_write_input_tokens": written,
            "output_tokens": out, "reasoning_output_tokens": reasoning, "total_tokens": inp + out}


def token_count(last, total, rate_limits=None, ts="2026-10-24T12:00:01.000Z"):
    return line("event_msg", {"type": "token_count", "info": {"total_token_usage": total, "last_token_usage": last},
                              "rate_limits": rate_limits}, ts)


def turn(turn_id, model="gpt-6.1-sol", cwd="/code/app", tier="default"):
    return line("turn_context", {"turn_id": turn_id, "model": model, "cwd": cwd, "service_tier": tier})


def test_usage_records_win_and_take_the_model_of_their_turn():
    lines = [
        turn("t1"),
        line("token_usage_record", {"turn_id": "t1", "response_id": "r1", "usage": usage(1000, 600, 50, 20)}),
        token_count(usage(1000, 600, 50, 20), usage(1000, 600, 50, 20)),
        turn("t2", model="gpt-6-astra", tier="priority"),
        line("token_usage_record", {"turn_id": "t2", "response_id": "r2", "usage": usage(2000, 0, 10)}),
    ]
    parsed = parse_rollout(lines)
    assert set(parsed.entries) == {"r1", "r2"}
    first, second = parsed.entries["r1"], parsed.entries["r2"]
    assert (first.model, first.project, first.input, first.cache_read, first.output, first.reasoning) == (
        "gpt-6.1-sol", "app", 400, 600, 50, 20)
    assert second.model == "gpt-6-astra" and second.fast


def test_older_rollouts_count_token_count_events_once():
    total = usage(100, 0, 10)
    lines = [
        turn("t1", model="gpt-5-codex"),
        token_count(usage(100, 0, 10), total),
        token_count(usage(100, 0, 10), total, ts="2026-10-24T12:00:02.000Z"),  # repeated, nothing changed
        token_count(usage(50, 0, 5), usage(150, 0, 15), ts="2026-10-24T12:00:03.000Z"),
    ]
    entries = list(parse_rollout(lines).entries.values())
    assert [(e.input, e.output, e.model) for e in entries] == [(100, 10, "gpt-5-codex"), (50, 5, "gpt-5-codex")]


def test_latest_rate_limits_are_kept():
    old = {"primary": {"used_percent": 10}}
    new = {"primary": {"used_percent": 40}}
    lines = [
        token_count(usage(1), usage(1), old, ts="2026-10-24T12:00:01.000Z"),
        token_count(usage(1), usage(2), new, ts="2026-10-24T13:00:01.000Z"),
    ]
    assert parse_rollout(lines).limits[1] == new


def entry(**kw):
    base = dict(timestamp=0, model="gpt-6.1-sol", project="", input=0, output=0, cache_write=0, cache_read=0, reasoning=0, fast=False)
    return UsageEntry(**{**base, **kw})


def test_cost_at_list_prices():
    # $2 input, $0.10 cached, $10 output per MTok
    assert entry(input=100_000, cache_read=100_000, output=100_000).cost() == pytest.approx(1.21)
    assert entry(input=100_000, fast=True).cost() == pytest.approx(0.4)
    assert entry(cache_write=100_000).cost() == pytest.approx(0.25)


def test_long_context_requests_cost_more():
    # Over 272K input tokens: input x2, output x1.5, for the whole request
    cost = entry(input=200_000, cache_read=100_000, output=1_000_000).cost()
    assert cost == pytest.approx((200_000 * 4 + 100_000 * 0.2 + 1_000_000 * 15) / 1_000_000)
    assert entry(model="gpt-5.3-codex", input=300_000).cost() == pytest.approx(300_000 * 1.75 / 1_000_000)


def test_prices_match_exact_ids_only():
    assert price_for("gpt-5-2025-08-07") == price_for("gpt-5")
    assert price_for("gpt-5.4-mini") is None
    assert price_for("codex-auto-review") is None
    assert entry(model="codex-auto-review", input=1000).cost() is None


def test_limits_from_the_api():
    now = time.time()
    data = {
        "plan_type": "plus",
        "rate_limit": {
            "limit_reached": False,
            "primary_window": {"used_percent": 71, "limit_window_seconds": 18000, "reset_at": now + 600},
            "secondary_window": {"used_percent": 21, "limit_window_seconds": 604800, "reset_after_seconds": 3600},
        },
        "credits": {"has_credits": True, "unlimited": False, "balance": "120"},
    }
    result = limits_from_api(data, now)
    assert result["plan"] == "Plus"
    assert result["credits"] == {"balance": 120.0, "unlimited": False}
    session, weekly = result["limits"]
    assert (session["label"], session["group"], session["percent"], session["is_active"]) == ("Session (5h)", "session", 71.0, True)
    assert (weekly["label"], weekly["group"], weekly["resets_at"]) == ("Weekly", "weekly", pytest.approx(now + 3600))


def test_rollout_limits_reset_when_their_window_passed():
    now = time.time()
    snapshot = {"plan_type": "team", "primary": {"used_percent": 90, "window_minutes": 300, "resets_at": now - 60},
                "secondary": {"used_percent": 30, "window_minutes": 10080, "resets_at": now + 86400}}
    result = limits_from_rollout(snapshot, now)
    assert [l["percent"] for l in result["limits"]] == [0.0, 30.0]
    assert result["plan"] == "Team"


def test_expired_token_is_not_used(tmp_path, monkeypatch):
    import base64
    claims = base64.urlsafe_b64encode(json.dumps({"exp": time.time() - 10}).encode()).decode().rstrip("=")
    (tmp_path / "auth.json").write_text(json.dumps({"tokens": {"access_token": f"x.{claims}.y"}}))
    monkeypatch.setattr(codex_usage.urllib.request, "urlopen", lambda *a, **k: pytest.fail("must not call the API"))
    assert "expired" in codex_usage.fetch_plan_limits(tmp_path)["error"]


def test_tracker_falls_back_to_the_last_reported_limits(tmp_path):
    folder = tmp_path / "sessions" / "2026" / "10" / "24"
    folder.mkdir(parents=True)
    limits = {"plan_type": "plus", "primary": {"used_percent": 55, "window_minutes": 300, "resets_at": time.time() + 600}}
    (folder / "rollout-a.jsonl").write_bytes(b"\n".join([
        turn("t1"),
        line("token_usage_record", {"turn_id": "t1", "response_id": "r1", "usage": usage(1000, 0, 100)}),
        token_count(usage(1000, 0, 100), usage(1000, 0, 100), limits),
    ]))
    payload = codex_usage.CodexUsageTracker(tmp_path).payload()
    assert payload["plan"] == "Plus"
    assert [l["percent"] for l in payload["limits"]] == [55.0]
    assert "Not signed in" in payload["note"]
    assert payload["periods"]["all"]["requests"] == 1
    assert payload["models"][0]["model"] == "gpt-6.1-sol"


def test_threads_from_the_state_database(tmp_path):
    db = sqlite3.connect(tmp_path / "state_5.sqlite")
    db.execute("CREATE TABLE threads (id TEXT, title TEXT, name TEXT, cwd TEXT, git_branch TEXT, model TEXT,"
               " tokens_used INTEGER, source TEXT, archived INTEGER, updated_at INTEGER)")
    now = int(time.time())
    db.executemany("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)", [
        ("a", "Fix the build", None, "/code/app", "main", "gpt-6.1-sol", 100, "cli", 0, now - 60),
        ("b", "Old idea", "Renamed", "/code/app", "", "gpt-6-sol", 50, "vscode", 0, now - 7200),
        ("c", "Guardian review", None, "/code/app", "", "codex-auto-review", 999, '{"subagent":"review"}', 0, now),
        ("d", "Archived", None, "/code/other", "", "gpt-6-sol", 5, "cli", 1, now),
        ("e", "Elsewhere", None, "/code/site", "", "gpt-6-sol", 7, "cli", 0, now - 30),
    ])
    db.commit()
    db.close()

    sessions = codex.get_codex_sessions(tmp_path)
    assert [s.session_id for s in sessions] == ["e", "a", "b"]
    assert sessions[2].title == "Renamed"
    projects = codex.get_codex_projects(tmp_path, running_cwds={"/code/site"})
    assert [(p.name, p.sessions, p.tokens, p.is_running) for p in projects] == [("site", 1, 7, True), ("app", 2, 150, False)]


def test_no_state_database(tmp_path):
    assert codex.get_codex_sessions(tmp_path) == []
