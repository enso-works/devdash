"""JSON-lines bridge used by the macOS menu bar app.

stdout: one JSON object per line ("hello", "snapshot", "result").
stdin:  one JSON command per line: {"id": "...", "cmd": "...", ...}.
"""
from __future__ import annotations

import dataclasses
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import psutil

from devdash import __version__
from devdash.claude_usage import UsageTracker
from devdash.config import Config
from devdash.processes import (
    get_activity_heatmap_data,
    get_all_processes,
    get_all_recent_sessions,
    get_claude_instances,
    get_claude_projects,
    get_claude_stats,
    get_cleanup_suggestions,
    get_dependency_graph,
    get_docker_containers,
    get_node_processes,
    get_project_detail,
    get_project_sessions,
    get_system_stats,
    kill_process,
    stop_docker_container,
)

CLAUDE_REFRESH_EVERY = 5  # ticks
SYSTEM_PROCESS_LIMIT = 40
USAGE_REFRESH_SECONDS = 30.0


def _asdict(obj):
    if obj is None:
        return None
    return dataclasses.asdict(obj)


def _expand(path: str) -> str:
    return os.path.expanduser(path) if path.startswith("~") else path


class Bridge:
    def __init__(self, config: Config) -> None:
        self._config = config
        self._out_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._pool = ThreadPoolExecutor(max_workers=4)
        self._idle_tracker: dict[int, float] = {}
        self._tick = 0
        self._has_claude = (Path.home() / ".claude").is_dir()
        self._node_procs = []
        self._docker = []
        self._all_procs = []
        self._stats = None
        self._usage = UsageTracker() if self._has_claude else None
        self._usage_payload: dict | None = None
        self._usage_version = 0
        self._usage_sent = 0

    # -- output --------------------------------------------------------------

    def emit(self, payload: dict) -> None:
        line = json.dumps(payload, default=str)
        with self._out_lock:
            try:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                self._stop.set()

    # -- snapshot loop -------------------------------------------------------

    def run(self) -> None:
        self.emit({
            "type": "hello",
            "version": __version__,
            "has_claude": self._has_claude,
            "config": _asdict(self._config),
        })
        # Prime psutil cpu_percent so the first real snapshot has values.
        psutil.cpu_percent(interval=0)
        get_node_processes()
        threading.Thread(target=self._read_commands, daemon=True).start()
        if self._usage is not None:
            threading.Thread(target=self._usage_loop, daemon=True).start()
        time.sleep(0.5)
        while not self._stop.is_set():
            try:
                self.emit(self._snapshot())
            except Exception as e:  # keep the bridge alive on collector errors
                self.emit({"type": "error", "message": f"snapshot failed: {e}"})
            self._wake.wait(self._config.refresh_rate)
            self._wake.clear()
        self._pool.shutdown(wait=False, cancel_futures=True)

    def _update_idle_tracker(self, node_procs) -> None:
        now = time.monotonic()
        threshold = self._config.cleanup_idle_threshold_cpu
        current = {p.pid for p in node_procs}
        for proc in node_procs:
            if proc.cpu_percent < threshold:
                self._idle_tracker.setdefault(proc.pid, now)
            else:
                self._idle_tracker.pop(proc.pid, None)
        for pid in list(self._idle_tracker):
            if pid not in current:
                del self._idle_tracker[pid]

    def _snapshot(self) -> dict:
        node_procs = get_node_processes()
        docker = get_docker_containers()
        all_procs = get_all_processes(limit=SYSTEM_PROCESS_LIMIT)
        stats = get_system_stats()
        self._update_idle_tracker(node_procs)
        cleanup = get_cleanup_suggestions(
            node_procs=node_procs,
            docker_containers=docker,
            idle_tracker=self._idle_tracker,
            idle_threshold_cpu=self._config.cleanup_idle_threshold_cpu,
            idle_threshold_minutes=self._config.cleanup_idle_threshold_minutes,
            docker_stale_days=self._config.cleanup_docker_stale_days,
        )
        with self._state_lock:
            self._node_procs, self._docker, self._all_procs, self._stats = node_procs, docker, all_procs, stats

        node = []
        for p in node_procs:
            d = _asdict(p)
            d["cwd_full"] = _expand(p.cwd)
            node.append(d)

        snapshot = {
            "type": "snapshot",
            "timestamp": time.time(),
            "system": _asdict(stats),
            "node": node,
            "docker": [_asdict(c) for c in docker],
            "processes": [_asdict(p) for p in all_procs],
            "cleanup": [_asdict(s) for s in cleanup],
        }

        if self._has_claude and self._tick % CLAUDE_REFRESH_EVERY == 0:
            snapshot["claude"] = self._claude_payload()
        with self._state_lock:
            if self._usage_version != self._usage_sent:
                snapshot["usage"] = self._usage_payload
                self._usage_sent = self._usage_version
        self._tick += 1
        return snapshot

    def _claude_payload(self) -> dict:
        instances = []
        for inst in get_claude_instances():
            d = _asdict(inst)
            d["cwd_full"] = _expand(inst.cwd)
            instances.append(d)
        return {
            "instances": instances,
            "projects": [_asdict(p) for p in get_claude_projects()],
            "sessions": [_asdict(s) for s in get_all_recent_sessions()],
            "stats": _claude_stats_payload(get_claude_stats()),
        }

    # -- usage ---------------------------------------------------------------

    def _usage_loop(self) -> None:
        # Transcript parsing and the limits request are slow, so they run off the snapshot loop.
        while not self._stop.is_set():
            self._refresh_usage()
            self._stop.wait(USAGE_REFRESH_SECONDS)

    def _refresh_usage(self, force_limits: bool = False) -> dict | None:
        try:
            payload = self._usage.payload(force_limits=force_limits)
        except Exception as e:
            self.emit({"type": "error", "message": f"usage failed: {e}"})
            return None
        with self._state_lock:
            self._usage_payload = payload
            self._usage_version += 1
        return payload

    # -- commands ------------------------------------------------------------

    def _read_commands(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except json.JSONDecodeError:
                self.emit({"type": "error", "message": f"bad command: {line[:80]}"})
                continue
            self._pool.submit(self._dispatch, cmd)
        # stdin closed: parent app went away
        self._stop.set()
        self._wake.set()

    def _dispatch(self, cmd: dict) -> None:
        cid = cmd.get("id")
        name = cmd.get("cmd", "")
        handler = getattr(self, f"_cmd_{name}", None)
        if handler is None:
            self.emit({"type": "result", "id": cid, "ok": False, "error": f"unknown command {name}"})
            return
        try:
            data = handler(cmd)
            self.emit({"type": "result", "id": cid, "ok": True, "data": data})
        except Exception as e:
            self.emit({"type": "result", "id": cid, "ok": False, "error": str(e)})

    def _cmd_refresh(self, cmd: dict):
        self._wake.set()
        return None

    def _cmd_refresh_claude(self, cmd: dict):
        if not self._has_claude:
            return None
        return self._claude_payload()

    def _cmd_usage(self, cmd: dict):
        if self._usage is None:
            return None
        return self._refresh_usage(force_limits=bool(cmd.get("force")))

    def _cmd_kill(self, cmd: dict):
        pid = int(cmd["pid"])
        ok = kill_process(pid)
        self._wake.set()
        if not ok:
            raise RuntimeError(f"Could not kill PID {pid}")
        return {"pid": pid}

    def _cmd_stop_container(self, cmd: dict):
        container_id = str(cmd["container_id"])
        ok = stop_docker_container(container_id)
        self._wake.set()
        if not ok:
            raise RuntimeError(f"Could not stop container {container_id[:12]}")
        return {"container_id": container_id}

    def _cmd_cleanup(self, cmd: dict):
        killed = stopped = failed = 0
        for item in cmd.get("items") or []:
            if item.get("action_type") == "kill" and item.get("pid") is not None:
                if kill_process(int(item["pid"])):
                    killed += 1
                else:
                    failed += 1
            elif item.get("action_type") == "stop_container" and item.get("container_id"):
                if stop_docker_container(str(item["container_id"])):
                    stopped += 1
                else:
                    failed += 1
        self._wake.set()
        return {"killed": killed, "stopped": stopped, "failed": failed}

    def _cmd_process_detail(self, cmd: dict):
        return _process_detail(int(cmd["pid"]))

    def _cmd_graph(self, cmd: dict):
        with self._state_lock:
            node_procs, docker = list(self._node_procs), list(self._docker)
        owners, edges = get_dependency_graph(node_procs, docker)
        return {"owners": [_asdict(o) for o in owners], "edges": [_asdict(e) for e in edges]}

    def _cmd_heatmap(self, cmd: dict):
        return _asdict(get_activity_heatmap_data())

    def _cmd_project_detail(self, cmd: dict):
        detail = _asdict(get_project_detail(str(cmd["path"])))
        detail["tools_used"] = _ranked(detail["tools_used"])
        detail["languages"] = _ranked(detail["languages"])
        return detail

    def _cmd_project_sessions(self, cmd: dict):
        return [_asdict(s) for s in get_project_sessions(str(cmd["path"]))]

    def _cmd_export(self, cmd: dict):
        with self._state_lock:
            snapshot = {
                "timestamp": datetime.now().isoformat(),
                "node_processes": [_asdict(p) for p in self._node_procs],
                "docker_containers": [_asdict(c) for c in self._docker],
                "all_processes": [_asdict(p) for p in self._all_procs],
                "system_stats": _asdict(self._stats),
            }
        export_dir = Path.home() / ".local" / "share" / "devdash"
        export_dir.mkdir(parents=True, exist_ok=True)
        filepath = export_dir / f"snapshot-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
        filepath.write_text(json.dumps(snapshot, indent=2, default=str))
        return {"path": str(filepath)}


def _ranked(counts: dict[str, int]) -> list[list]:
    # Arbitrary-keyed dicts become [key, value] lists so clients need no key mangling.
    return [[k, v] for k, v in sorted(counts.items(), key=lambda kv: kv[1], reverse=True)]


def _claude_stats_payload(stats) -> dict | None:
    if stats is None:
        return None
    return {
        "total_sessions": stats.total_sessions,
        "total_messages": stats.total_messages,
        "model_usage": [[m, *usage] for m, usage in stats.model_usage.items()],
        "daily_activity": [list(d) for d in stats.daily_activity],
        "hour_counts": [stats.hour_counts.get(h, 0) for h in range(24)],
    }


def _process_detail(pid: int) -> dict:
    try:
        proc = psutil.Process(pid)
    except psutil.NoSuchProcess:
        raise RuntimeError(f"Process {pid} no longer exists")

    def safe(func, default=None):
        try:
            return func()
        except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
            return default

    mem = safe(proc.memory_info)
    children = []
    for child in safe(lambda: proc.children(recursive=True), []) or []:
        children.append({"pid": child.pid, "name": safe(child.name, "<access denied>")})
    connections = []
    for conn in safe(lambda: proc.net_connections(kind="inet"), []) or []:
        connections.append({
            "status": conn.status,
            "laddr": f"{conn.laddr.ip}:{conn.laddr.port}" if conn.laddr else "",
            "raddr": f"{conn.raddr.ip}:{conn.raddr.port}" if conn.raddr else "",
        })
    open_files = [f.path for f in (safe(proc.open_files, []) or [])[:50]]
    env = safe(proc.environ, {}) or {}

    return {
        "pid": pid,
        "name": safe(proc.name, ""),
        "status": safe(proc.status, ""),
        "user": safe(proc.username, ""),
        "cwd": safe(proc.cwd, ""),
        "cpu_percent": safe(lambda: proc.cpu_percent(interval=0.1), 0.0),
        "rss_mb": mem.rss / (1024 * 1024) if mem else None,
        "vms_mb": mem.vms / (1024 * 1024) if mem else None,
        "threads": safe(proc.num_threads),
        "command": " ".join(safe(proc.cmdline, []) or []),
        "children": children,
        "connections": connections,
        "open_files": open_files,
        "environment": sorted(env.items()),
    }


class DemoBridge(Bridge):
    """Serves devdash.demo fixtures through the real protocol (screenshots, UI work)."""

    def __init__(self, config: Config) -> None:
        super().__init__(config)
        self._has_claude = True
        self._usage = None

    def _snapshot(self) -> dict:
        from devdash import demo

        snapshot = {
            "type": "snapshot",
            "timestamp": time.time(),
            "system": demo.system(),
            "node": demo.node(),
            "docker": demo.docker(),
            "processes": demo.processes(),
            "cleanup": demo.cleanup(),
        }
        if self._tick % CLAUDE_REFRESH_EVERY == 0:
            snapshot["claude"] = demo.claude()
            snapshot["usage"] = demo.usage()
        self._tick += 1
        return snapshot

    def _cmd_refresh_claude(self, cmd: dict):
        from devdash import demo
        return demo.claude()

    def _cmd_usage(self, cmd: dict):
        from devdash import demo
        return demo.usage()

    def _cmd_kill(self, cmd: dict):
        return {"pid": int(cmd["pid"])}

    def _cmd_stop_container(self, cmd: dict):
        return {"container_id": str(cmd["container_id"])}

    def _cmd_cleanup(self, cmd: dict):
        items = cmd.get("items") or []
        kills = sum(1 for i in items if i.get("action_type") == "kill")
        return {"killed": kills, "stopped": len(items) - kills, "failed": 0}

    def _cmd_process_detail(self, cmd: dict):
        from devdash import demo
        return demo.process_detail(int(cmd["pid"]))

    def _cmd_graph(self, cmd: dict):
        from devdash import demo
        return demo.graph()

    def _cmd_heatmap(self, cmd: dict):
        from devdash import demo
        return demo.heatmap()

    def _cmd_project_detail(self, cmd: dict):
        from devdash import demo
        return demo.project_detail(str(cmd["path"]))

    def _cmd_project_sessions(self, cmd: dict):
        from devdash import demo
        return demo.project_detail(str(cmd["path"]))["recent_sessions"]


def serve(config: Config, demo: bool = False) -> None:
    # DEVDASH_DEMO lets a parent process (the menu bar app) opt in without changing arguments.
    if demo or os.environ.get("DEVDASH_DEMO") == "1":
        DemoBridge(config).run()
    else:
        Bridge(config).run()
