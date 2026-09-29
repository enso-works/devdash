"""Synthetic data for `devdash --serve --demo`, used for screenshots and UI work.

Every payload matches what devdash/bridge.py sends for real data.
"""
from __future__ import annotations

import math
import random
import time
from datetime import date, datetime, timedelta

HOME = "/Users/demo"
_START = time.time()


def _wave(base: float, spread: float, period: float = 30.0, phase: float = 0.0) -> float:
    t = time.time() - _START
    return max(0.0, base + spread * math.sin(t / period * 2 * math.pi + phase) + random.uniform(-spread, spread) * 0.3)


NODE = [
    # pid, project, command, cwd, ports, uptime, mem, cpu
    (41822, "storefront", "next dev --turbo", "~/code/storefront/apps/web", [3000], "2h 14m", 612.0, 6.0),
    (41907, "storefront-api", "node --watch src/server.ts", "~/code/storefront/apps/api", [4000], "2h 14m", 188.0, 1.5),
    (52310, "design-system", "storybook dev -p 6006", "~/code/design-system", [6006], "48m", 402.0, 0.8),
    (60114, "docs", "astro dev", "~/code/docs", [4321], "12m", 142.0, 0.4),
    (38001, "", "node ~/.npm/_npx/mcp-server-github/dist/index.js", "~", [], "1d 3h", 96.0, 0.0),
    (38012, "", "node ~/.npm/_npx/chrome-devtools-mcp/build/index.js", "~", [], "1d 3h", 131.0, 0.0),
    (27640, "old-prototype", "vite --port 5173", "~/code/old-prototype", [], "4d 6h", 88.0, 0.0),
]

SERVERS = [
    # pid, label, runtime, kind, command, cwd, ports, uptime, mem, cpu, project_root, project_name, package
    (41822, "next dev", "node", "app", "next dev --turbo", "~/code/storefront/apps/web", [3000], "2h 14m", 612.0, 6.0, "~/code/storefront", "storefront", "web"),
    (41907, "server.ts", "node", "app", "node --watch src/server.ts", "~/code/storefront/apps/api", [4000], "2h 14m", 188.0, 1.5, "~/code/storefront", "storefront", "api"),
    (52310, "storybook", "node", "app", "storybook dev -p 6006", "~/code/design-system", [6006], "48m", 402.0, 0.8, "~/code/design-system", "design-system", ""),
    (53877, "uvicorn", "python", "app", "python -m uvicorn app.main:app --reload --port 8000", "~/code/analytics", [8000], "3h 40m", 96.0, 0.6, "~/code/analytics", "analytics", ""),
    (58120, "gateway", "go", "app", "/var/folders/x/go-build123/b001/exe/gateway", "~/code/gateway", [8080], "25m", 34.0, 0.2, "~/code/gateway", "gateway", ""),
    (60114, "astro", "node", "app", "astro dev", "~/code/docs", [4321], "12m", 142.0, 0.4, "~/code/docs", "docs", ""),
    (1204, "mysqld", "mysql", "service", "/opt/homebrew/opt/mysql/bin/mysqld", "/opt/homebrew/var/mysql", [3306, 33060], "6d 2h", 410.0, 0.3, "", "", ""),
    (33410, "cloudflared", "other", "app", "cloudflared tunnel --url http://localhost:3000", "~", [20241], "1h 10m", 22.0, 0.1, "", "", ""),
    (38001, "mcp-server-github", "node", "background", "node ~/.npm/_npx/mcp-server-github/dist/index.js", "~", [], "1d 3h", 96.0, 0.0, "", "", ""),
    (38012, "chrome-devtools-mcp", "node", "background", "node ~/.npm/_npx/chrome-devtools-mcp/build/index.js", "~", [], "1d 3h", 131.0, 0.0, "", "", ""),
    (27640, "vite", "node", "background", "vite --port 5173", "~/code/old-prototype", [], "4d 6h", 88.0, 0.0, "~/code/old-prototype", "old-prototype", ""),
]

DOCKER = [
    ("a1b2c3d4e5f6", "storefront-postgres-1", "postgres:17", "Up 2 hours (healthy)", "0.0.0.0:5432->5432/tcp", "2 hours ago", "storefront", "postgres"),
    ("b2c3d4e5f6a7", "storefront-redis-1", "redis:7-alpine", "Up 2 hours", "0.0.0.0:6379->6379/tcp", "2 hours ago", "storefront", "redis"),
    ("c3d4e5f6a7b8", "storefront-mailpit-1", "axllent/mailpit", "Up 2 hours", "0.0.0.0:8025->8025/tcp", "2 hours ago", "storefront", "mailpit"),
    ("d4e5f6a7b8c9", "analytics-clickhouse-1", "clickhouse/clickhouse-server:25", "Up 9 days (unhealthy)", "0.0.0.0:8123->8123/tcp", "9 days ago", "analytics", "clickhouse"),
    ("e5f6a7b8c9d0", "minio", "minio/minio", "Up 3 days", "0.0.0.0:9000->9000/tcp", "3 days ago", "", ""),
]

PROCESSES = [
    ("Google Chrome", 1.8, 1240.0, "running"), ("Code Helper (Renderer)", 4.2, 980.0, "running"),
    ("next-server", 6.0, 612.0, "running"), ("Docker VM", 3.1, 2048.0, "running"),
    ("Slack Helper (Renderer)", 0.6, 402.0, "sleeping"), ("claude", 2.4, 356.0, "running"),
    ("Figma Helper", 0.3, 310.0, "sleeping"), ("WindowServer", 5.5, 290.0, "running"),
    ("postgres", 0.4, 210.0, "sleeping"), ("Spotlight", 0.2, 120.0, "sleeping"),
]

PROJECTS = [
    ("storefront", 42, 1830, "12m ago", True), ("design-system", 18, 640, "2h ago", True),
    ("docs", 9, 210, "1d ago", False), ("analytics", 14, 505, "3d ago", False),
    ("mobile-app", 23, 911, "5d ago", False), ("infra", 6, 140, "1w ago", False),
]

SESSIONS = [
    ("Add checkout flow with Stripe payment intents", "storefront", "feat/checkout", 86),
    ("Fix flaky cart tests in CI", "storefront", "fix/cart-tests", 34),
    ("Tokenize spacing scale and update Button variants", "design-system", "main", 52),
    ("Write migration guide for v3 API", "docs", "docs/v3", 21),
    ("Investigate slow ClickHouse queries on events table", "analytics", "perf/events", 47),
    ("Set up EAS build profiles for staging", "mobile-app", "chore/eas", 29),
]

MODELS = [("claude-opus-5-5", 0.46), ("claude-fable-5-1", 0.28), ("claude-sonnet-5", 0.18), ("claude-haiku-4-5", 0.08)]


def node() -> list[dict]:
    result = []
    for pid, project, command, cwd, ports, uptime, mem, cpu in NODE:
        result.append({
            "pid": pid, "name": "node", "command": command,
            "cpu_percent": round(_wave(cpu, cpu * 0.6, phase=pid), 1),
            "memory_mb": mem + random.uniform(-4, 4), "cwd": cwd, "ports": ports,
            "uptime": uptime, "project": project, "cwd_full": cwd.replace("~", HOME, 1),
        })
    return result


def _full(path: str) -> str:
    return path.replace("~", HOME, 1) if path.startswith("~") else path


def servers() -> list[dict]:
    now = time.time()
    result = []
    for i, (pid, label, runtime, kind, command, cwd, ports, uptime, mem, cpu, root, project, package) in enumerate(SERVERS):
        result.append({
            "pid": pid, "name": runtime if runtime != "other" else label, "label": label, "runtime": runtime,
            "kind": kind, "command": command, "cpu_percent": round(_wave(cpu, cpu * 0.6, phase=pid), 1),
            "memory_mb": mem + random.uniform(-4, 4), "ports": ports, "uptime": uptime,
            "started": now - 600 * (i + 1), "cwd": cwd, "cwd_full": _full(cwd),
            "project_root": _full(root), "project_name": project, "package": package,
        })
    return result


BRANCHES = {"storefront": "feat/checkout", "design-system": "main", "analytics": "perf/events", "gateway": "main", "docs": "docs/v3"}


def projects() -> list[dict]:
    return [{"root": f"{HOME}/code/{name}", "name": name, "branch": branch} for name, branch in BRANCHES.items()]


def docker() -> list[dict]:
    return [
        {"container_id": cid, "name": name, "image": image, "status": status, "ports": ports,
         "created": created, "compose_project": project, "compose_service": service,
         "compose_working_dir": f"{HOME}/code/{project}" if project else ""}
        for cid, name, image, status, ports, created, project, service in DOCKER
    ]


def processes() -> list[dict]:
    return [
        {"pid": 500 + i * 37, "name": name, "cpu_percent": round(_wave(cpu, cpu * 0.5, phase=i), 1),
         "memory_mb": mem, "memory_percent": mem / 24576 * 100, "status": status, "user": "demo", "command": name}
        for i, (name, cpu, mem, status) in enumerate(PROCESSES)
    ]


def system() -> dict:
    return {
        "cpu_percent": round(_wave(22, 12), 1), "cpu_count": 12,
        "memory_total_gb": 24.0, "memory_used_gb": 15.1, "memory_percent": 62.9,
        "swap_total_gb": 4.0, "swap_used_gb": 0.9, "swap_percent": 22.5,
        "disk_total_gb": 994.7, "disk_used_gb": 512.3, "disk_free_gb": 482.4, "disk_percent": 51.5,
        "net_sent_per_sec": _wave(180_000, 60_000), "net_recv_per_sec": _wave(1_400_000, 500_000),
    }


def cleanup() -> list[dict]:
    return [
        {"category": "orphan", "label": "PID 27640 (old-prototype)", "reason": "Orphan process (parent exited)",
         "action_type": "kill", "pid": 27640, "container_id": None},
        {"category": "idle", "label": "PID 38012 (node)", "reason": "CPU < 1.0% for 42m",
         "action_type": "kill", "pid": 38012, "container_id": None},
        {"category": "stale_container", "label": "analytics-clickhouse-1 (clickhouse/clickhouse-server:25)",
         "reason": "Running for 9d", "action_type": "stop_container", "pid": None, "container_id": "d4e5f6a7b8c9"},
    ]


def _session(i: int, title: str, project: str, branch: str, messages: int) -> dict:
    modified = datetime.now() - timedelta(hours=i * 5 + 1)
    return {
        "session_id": f"demo-session-{i}", "summary": title, "first_prompt": title,
        "message_count": messages, "git_branch": branch,
        "created": (modified - timedelta(hours=2)).strftime("%Y-%m-%d %H:%M"),
        "modified": modified.strftime("%Y-%m-%d %H:%M"),
        "project_path": f"{HOME}/code/{project}", "is_sidechain": False,
    }


def claude() -> dict:
    today = date.today()
    return {
        "instances": [
            {"pid": 71002, "project": "storefront", "cwd": "~/code/storefront", "tty": "/dev/ttys004",
             "cpu_percent": round(_wave(8, 6), 1), "memory_mb": 356.0, "uptime": "1h 02m", "cwd_full": f"{HOME}/code/storefront"},
            {"pid": 71388, "project": "design-system", "cwd": "~/code/design-system", "tty": "/dev/ttys007",
             "cpu_percent": 0.4, "memory_mb": 288.0, "uptime": "38m", "cwd_full": f"{HOME}/code/design-system"},
        ],
        "projects": [
            {"name": name, "path": f"{HOME}/code/{name}", "sessions": sessions, "messages": messages,
             "last_active": active, "is_running": running}
            for name, sessions, messages, active, running in PROJECTS
        ],
        "sessions": [_session(i, *s) for i, s in enumerate(SESSIONS)],
        "stats": {
            "total_sessions": 112, "total_messages": 18_420,
            "model_usage": [[m, 4_000_000, int(9_000_000 * share), 80_000_000] for m, share in MODELS],
            "daily_activity": [[(today - timedelta(days=13 - d)).isoformat(), 180 + 140 * math.sin(d / 2) ** 2] for d in range(14)],
            "hour_counts": [0] * 8 + [20, 45, 60, 52, 30, 48, 66, 70, 58, 40, 22, 12, 6, 2, 0, 0],
        },
    }


def _day_cost(offset: int) -> float:
    weekday = (date.today() - timedelta(days=offset)).weekday()
    base = 14 if weekday >= 5 else 46
    return round(base + 22 * math.sin(offset * 1.7) ** 2, 2)


def usage() -> dict:
    today = date.today()
    daily = [[(today - timedelta(days=offset)).isoformat(), _day_cost(offset)] for offset in range(29, -1, -1)]

    def totals(days: int, scale: float = 1.0) -> dict:
        cost = sum(c for _, c in daily[-days:]) * scale
        return {"cost": cost, "input": int(cost * 900), "output": int(cost * 9_000),
                "cache_write": int(cost * 45_000), "cache_read": int(cost * 420_000), "requests": int(cost * 6)}

    month = totals(30)
    now = time.time()
    return {
        "plan": "Max 5x",
        "limits": [
            {"label": "Session (5h)", "group": "session", "percent": 42.0, "severity": "normal", "resets_at": now + 2 * 3600 + 17 * 60, "is_active": True},
            {"label": "Weekly, all models", "group": "weekly", "percent": 31.0, "severity": "normal", "resets_at": now + 3 * 86400 + 5 * 3600, "is_active": False},
            {"label": "Weekly, Fable", "group": "weekly", "percent": 12.0, "severity": "normal", "resets_at": now + 3 * 86400 + 5 * 3600, "is_active": False},
        ],
        "extra_usage": None,
        "error": None,
        "limits_updated": now,
        "periods": {"today": totals(1), "week": totals(7), "month": month, "all": totals(30, 2.6)},
        "session": totals(1, 0.55),
        "models": [
            {"model": model, "cost": month["cost"] * share, "input": int(month["input"] * share),
             "output": int(month["output"] * share), "cache_write": int(month["cache_write"] * share),
             "cache_read": int(month["cache_read"] * share), "requests": int(month["requests"] * share)}
            for model, share in MODELS
        ],
        "projects": [[name, month["cost"] * share] for name, share in
                     (("storefront", 0.41), ("design-system", 0.22), ("analytics", 0.16), ("mobile-app", 0.12), ("docs", 0.06), ("infra", 0.03))],
        "daily": daily,
        "unpriced_models": [],
    }


def process_detail(pid: int) -> dict:
    proc = next((p for p in NODE if p[0] == pid), NODE[0])
    port = proc[4][0] if proc[4] else 3000
    return {
        "pid": pid, "name": "node", "status": "running", "user": "demo", "cwd": proc[3].replace("~", HOME, 1),
        "cpu_percent": proc[7], "rss_mb": proc[6], "vms_mb": 411_000.0, "threads": 14,
        "command": f"node {proc[2]}",
        "children": [{"pid": pid + 3, "name": "node"}, {"pid": pid + 9, "name": "esbuild"}],
        "connections": [
            {"status": "LISTEN", "laddr": f"127.0.0.1:{port}", "raddr": ""},
            {"status": "ESTABLISHED", "laddr": "127.0.0.1:52144", "raddr": "127.0.0.1:5432"},
            {"status": "ESTABLISHED", "laddr": "127.0.0.1:52150", "raddr": "127.0.0.1:6379"},
        ],
        "open_files": [f"{HOME}/code/storefront/.next/cache/webpack/client-development/0.pack"],
        "environment": [["NODE_ENV", "development"], ["PORT", str(port)], ["DATABASE_URL", "postgres://localhost:5432/storefront"]],
    }


def graph() -> dict:
    owners = [
        {"kind": "node", "label": "storefront", "group": "storefront", "pid": 41822, "container_id": None, "ports": [3000]},
        {"kind": "node", "label": "storefront-api", "group": "storefront-api", "pid": 41907, "container_id": None, "ports": [4000]},
        {"kind": "docker", "label": "postgres", "group": "storefront", "pid": None, "container_id": "a1b2c3d4e5f6", "ports": [5432]},
        {"kind": "docker", "label": "redis", "group": "storefront", "pid": None, "container_id": "b2c3d4e5f6a7", "ports": [6379]},
        {"kind": "docker", "label": "mailpit", "group": "storefront", "pid": None, "container_id": "c3d4e5f6a7b8", "ports": [8025]},
    ]
    edges = [
        ("storefront", "node", "storefront-api", "node", 4000),
        ("storefront-api", "node", "postgres", "docker", 5432),
        ("storefront-api", "node", "redis", "docker", 6379),
        ("storefront-api", "node", "mailpit", "docker", 8025),
    ]
    return {"owners": owners, "edges": [
        {"from_label": a, "from_kind": ak, "from_group": "", "to_label": b, "to_kind": bk, "to_group": "", "port": port}
        for a, ak, b, bk, port in edges
    ]}


def heatmap() -> dict:
    today = date.today()
    grid = [[0] * 24 for _ in range(7)]
    for day in range(today.weekday() + 1):
        for hour in range(9, 19):
            grid[day][hour] = int(10 + 30 * math.sin((hour - 9) / 3 + day) ** 2)
    days = [(today - timedelta(days=offset)).isoformat() for offset in range(59, -1, -1)]
    return {
        "weekly_heatmap": grid,
        "week_day_labels": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        "project_times": [[name, hours] for name, hours in (("storefront", 64.5), ("design-system", 31.2), ("analytics", 22.8), ("mobile-app", 18.4), ("docs", 7.9))],
        "daily_messages": [[d, 120 + 180 * math.sin(i / 4) ** 2] for i, d in enumerate(days)],
        "daily_sessions": [[d, 3 + i % 5] for i, d in enumerate(days)],
        "daily_tokens": [[d, 2_000_000 + 900_000 * (i % 7)] for i, d in enumerate(days)],
        "total_sessions": 112, "total_messages": 18_420, "total_hours": 144.8,
    }


def project_detail(path: str) -> dict:
    name = path.rstrip("/").split("/")[-1]
    return {
        "project_path": path, "name": name, "total_sessions": 42, "total_messages": 1830,
        "total_lines_added": 18_240, "total_lines_removed": 6_512, "total_files_modified": 311, "git_commits": 57,
        "tools_used": [["Edit", 1204], ["Bash", 980], ["Read", 860], ["Grep", 310], ["Write", 122]],
        "languages": [["TypeScript", 1420], ["CSS", 210], ["Markdown", 96]],
        "memory_content": "# Memory\n\n- Checkout uses Stripe payment intents, not charges.\n- Run `pnpm test --filter web` before pushing.\n",
        "recent_sessions": [_session(i, *s) for i, s in enumerate(SESSIONS) if s[1] == name] or [_session(0, *SESSIONS[0])],
    }
