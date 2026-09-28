"""Renders terminal UI screenshots (SVG) from devdash.demo data.

Usage: .venv/bin/python scripts/tui_screenshots.py [output_dir]
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from devdash import app as tui
from devdash import demo
from devdash.processes import (
    ClaudeInstance,
    ClaudeProject,
    ClaudeSessionEntry,
    ClaudeStats,
    DockerContainer,
    GeneralProcess,
    NodeProcess,
    SystemStats,
)


def _node() -> list[NodeProcess]:
    return [NodeProcess(**{k: v for k, v in p.items() if k != "cwd_full"}) for p in demo.node()]


def _claude_stats() -> ClaudeStats:
    stats = demo.claude()["stats"]
    return ClaudeStats(
        total_sessions=stats["total_sessions"],
        total_messages=stats["total_messages"],
        model_usage={m: (i, o, c) for m, i, o, c in stats["model_usage"]},
        daily_activity=[(d, int(n)) for d, n in stats["daily_activity"]],
        hour_counts=dict(enumerate(stats["hour_counts"])),
    )


# The TUI imports collectors by name, so patch them on the app module.
tui.get_node_processes = _node
tui.get_docker_containers = lambda: [DockerContainer(**c) for c in demo.docker()]
tui.get_all_processes = lambda limit=80: [GeneralProcess(**p) for p in demo.processes()]
tui.get_system_stats = lambda: SystemStats(**demo.system())
tui.get_claude_instances = lambda: [
    ClaudeInstance(**{k: v for k, v in i.items() if k != "cwd_full"}) for i in demo.claude()["instances"]
]
tui.get_claude_projects = lambda: [ClaudeProject(**p) for p in demo.claude()["projects"]]
tui.get_claude_stats = _claude_stats
tui.get_all_recent_sessions = lambda: [ClaudeSessionEntry(**s) for s in demo.claude()["sessions"]]


async def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    app = tui.DevDashApp()
    app._has_claude = True
    async with app.run_test(size=(150, 42)) as pilot:
        await pilot.pause(2.0)
        shots = [
            ("dev-tab", ["1"]),
            ("system-tab", ["2"]),
            ("claude-tab", ["3"]),
            ("filter", ["1", "slash", *"store"]),
        ]
        for name, keys in shots:
            for key in keys:
                await pilot.press(key)
            await pilot.pause(1.0)
            app.save_screenshot(filename=f"{name}.svg", path=str(out))
            print(f"rendered {name}.svg")
            if "slash" in keys:
                await pilot.press("escape")


if __name__ == "__main__":
    asyncio.run(main(Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")))
