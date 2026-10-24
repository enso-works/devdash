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
from devdash.claude_profiles import github_signed_in, load_profiles
from devdash.claude_usage import UsageTracker
from devdash.config import Config
from devdash.processes import (
    _parse_host_ports_from_string,
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
from devdash.network import lan_ip
from devdash.servers import get_servers, project_infos, resolve_project
from devdash.supervisor import PortConflict, Supervisor, shell_env
from devdash import runnable, worktrees

CLAUDE_REFRESH_EVERY = 5  # ticks
USAGE_REFRESH_SECONDS = 30.0
WORKTREES_REFRESH_SECONDS = 60.0
RECENT_PROJECTS = 10  # per Claude profile, offered under "Ready to run"


def _asdict(obj):
    if obj is None:
        return None
    return dataclasses.asdict(obj)


def _expand(path: str) -> str:
    return os.path.expanduser(path) if path.startswith("~") else path


def _with_project(d: dict, path: str) -> dict:
    project = resolve_project(path)
    d["project_root"] = project.root
    d["project_name"] = project.name
    return d


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
        self._profiles = load_profiles()
        self._profile = self._profiles.default
        self._has_claude = any(p.dir.is_dir() for p in self._profiles.profiles)
        self._node_procs = []
        self._docker = []
        self._all_procs = []
        self._stats = None
        self._claude_roots: set[str] = set()
        self._claude_cwds: list[str] = []
        self._usage_enabled = self._has_claude
        self._trackers: dict[str, UsageTracker] = {}
        self._usage_payload: dict | None = None
        self._usage_version = 0
        self._usage_sent = 0
        self._busy_cwds: list[str] = []  # where servers and Claude sessions run, for remove_worktree
        self._snapshot_roots: set[str] = set()
        self._worktrees_wake = threading.Event()
        self._worktrees_payload: list | None = None
        self._worktrees_version = 0
        self._worktrees_sent = 0
        self._supervisor = self._create_supervisor()
        self._servers: list[dict] = []  # last snapshot's servers, to check ports before a run
        self._recent_roots: set[str] = set()
        self._runnable_payload: list | None = None
        self._runnable_version = 0
        self._runnable_sent = 0

    def _create_supervisor(self) -> Supervisor | None:
        return Supervisor(on_change=self._wake.set)

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
        if self._usage_enabled:
            threading.Thread(target=self._usage_loop, daemon=True).start()
        threading.Thread(target=self._worktrees_loop, daemon=True).start()
        if self._supervisor is not None:
            threading.Thread(target=shell_env, daemon=True).start()  # takes a second or two, so read it early
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
        all_procs = get_all_processes(limit=self._config.process_limit)
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

        docker_ports = {port for c in docker for port in _parse_host_ports_from_string(c.ports)}
        servers = get_servers({p.pid for p in node_procs}, docker_ports)

        server_dicts = [_asdict(s) for s in servers]
        if self._supervisor is not None:
            self._supervisor.poll(server_dicts)
            for d in server_dicts:
                d["run_id"] = self._supervisor.run_for_pid(d["pid"])

        docker_dicts = [_with_project(_asdict(c), c.compose_working_dir) for c in docker]
        claude = self._claude_payload() if self._has_claude and self._tick % CLAUDE_REFRESH_EVERY == 0 else None
        roots = {s.project_root for s in servers} | {d["project_root"] for d in docker_dicts} | self._claude_roots
        with self._state_lock:
            self._snapshot_roots = roots - {""}
            self._busy_cwds = [s.cwd_full for s in servers] + list(self._claude_cwds)
            self._servers = server_dicts
        if self._tick % CLAUDE_REFRESH_EVERY == 0:
            self._refresh_runnable()

        snapshot = {
            "type": "snapshot",
            "timestamp": time.time(),
            "system": _asdict(stats),
            "node": node,
            "servers": server_dicts,
            "runs": self._supervisor.payload() if self._supervisor is not None else [],
            "lan_ip": lan_ip(),
            "projects": project_infos(roots - {""}),
            "docker": docker_dicts,
            "processes": [_asdict(p) for p in all_procs],
            "cleanup": [_asdict(s) for s in cleanup],
        }

        if claude is not None:
            snapshot["claude"] = claude
        with self._state_lock:
            if self._usage_version != self._usage_sent:
                snapshot["usage"] = self._usage_payload
                self._usage_sent = self._usage_version
            if self._worktrees_version != self._worktrees_sent:
                snapshot["worktrees"] = self._worktrees_payload
                self._worktrees_sent = self._worktrees_version
            if self._runnable_version != self._runnable_sent:
                snapshot["runnable"] = self._runnable_payload
                self._runnable_sent = self._runnable_version
        self._tick += 1
        return snapshot

    def _claude_dir(self) -> Path:
        return self._profiles.get(self._profile).dir

    def _claude_payload(self) -> dict:
        # Re-read so edits to ~/.config/claude-profiles show up without a restart.
        self._profiles = profiles = load_profiles()
        selected = profiles.get(self._profile)
        instances = []
        for inst in get_claude_instances():
            d = _asdict(inst)
            d["cwd_full"] = _expand(inst.cwd)
            d["profile"] = profiles.for_config_dir(inst.config_dir) if inst.config_dir is not None else None
            d["expected_profile"] = profiles.route(d["cwd_full"])
            instances.append(_with_project(d, d["cwd_full"]))
        self._claude_roots = {d["project_root"] for d in instances}
        self._claude_cwds = [d["cwd_full"] for d in instances]
        return {
            "profile": selected.name,
            "profiles": [
                {
                    "name": p.name,
                    "email": p.email(),
                    "dir": str(p.dir),
                    "default_dir": p.is_default_dir,
                    "github": p.github,
                    "github_signed_in": github_signed_in(p.github),
                }
                for p in profiles.profiles
            ],
            "instances": instances,
            "projects": [_asdict(p) for p in get_claude_projects(selected.dir)],
            "sessions": [_asdict(s) for s in get_all_recent_sessions(selected.dir)],
            "stats": _claude_stats_payload(get_claude_stats(selected.dir)),
        }

    # -- worktrees -----------------------------------------------------------

    def _worktree_candidates(self) -> set[str]:
        """Folders to look for repositories in: projects on screen, and the Claude projects of every
        profile. Also notes the most recent Claude projects, which are offered under "Ready to run"."""
        with self._state_lock:
            paths = set(self._snapshot_roots)
        recent: set[str] = set()
        for profile in self._profiles.profiles:
            if profile.dir.is_dir():
                try:
                    projects = get_claude_projects(profile.dir)
                except Exception:
                    continue
                paths |= {p.path for p in projects}
                recent |= {p.path for p in projects[:RECENT_PROJECTS]}
        with self._state_lock:
            self._recent_roots = {root for root in (resolve_project(p).root for p in recent) if root}
        return paths

    def _refresh_worktrees(self) -> None:
        payload = [_asdict(r) for r in worktrees.scan(self._worktree_candidates())]
        with self._state_lock:
            if payload != self._worktrees_payload:
                self._worktrees_payload = payload
                self._worktrees_version += 1

    def _worktrees_loop(self) -> None:
        time.sleep(2)  # let the first snapshot fill in the project roots
        while not self._stop.is_set():
            try:
                self._refresh_worktrees()
                self._refresh_runnable()  # the scan also updates the recent Claude projects
            except Exception as e:
                self.emit({"type": "error", "message": f"worktree scan failed: {e}"})
            self._worktrees_wake.wait(WORKTREES_REFRESH_SECONDS)
            self._worktrees_wake.clear()

    def _cmd_refresh_worktrees(self, cmd: dict):
        self._refresh_worktrees()
        self._wake.set()
        return None

    def _cmd_worktree_size(self, cmd: dict):
        return worktrees.size_bytes(str(cmd["path"]))

    def _cmd_remove_worktree(self, cmd: dict):
        with self._state_lock:
            busy = list(self._busy_cwds)
        result = worktrees.remove(str(cmd["path"]), bool(cmd.get("delete_branch")), busy)
        self._refresh_worktrees()
        self._wake.set()
        return result

    # -- running scripts -----------------------------------------------------

    def _refresh_runnable(self) -> None:
        """Scripts of every project on screen, every project with a run, and the recent Claude projects."""
        if self._supervisor is None:
            return
        with self._state_lock:
            on_screen = set(self._snapshot_roots)
            recent = set(self._recent_roots)
        runs = {r["project_root"] for r in self._supervisor.payload()}
        payload = []
        for root in sorted(on_screen | recent | runs):
            scripts = runnable.scripts(root)
            if not scripts:
                continue
            default = runnable.default_script(scripts, self._supervisor.last.get(root))
            payload.append({
                "root": root,
                "name": resolve_project(root).name or Path(root).name,
                "scripts": [_asdict(s) for s in scripts],
                "default": default.id if default else None,
                "recent": root in recent and root not in on_screen,
            })
        with self._state_lock:
            if payload != self._runnable_payload:
                self._runnable_payload = payload
                self._runnable_version += 1

    def _require_supervisor(self) -> Supervisor:
        if self._supervisor is None:
            raise RuntimeError("Running scripts isn't available")
        return self._supervisor

    def _cmd_run_script(self, cmd: dict):
        """Starts a script. With `stop_pid`, first stops the process holding its port."""
        supervisor = self._require_supervisor()
        if cmd.get("stop_pid"):
            pid = int(cmd["stop_pid"])
            if not kill_process(pid):
                raise RuntimeError(f"Could not stop PID {pid}")
        root = str(cmd["root"])
        with self._state_lock:
            servers = list(self._servers)
        try:
            run = supervisor.start(root, str(cmd["script"]), resolve_project(root).name, servers)
        except PortConflict as conflict:
            return {"run": None, "conflict": dataclasses.asdict(conflict)}
        self._refresh_runnable()
        return {"run": _asdict(run), "conflict": None}

    def _cmd_stop_run(self, cmd: dict):
        return _asdict(self._require_supervisor().stop(str(cmd["run"])))

    def _cmd_restart_run(self, cmd: dict):
        with self._state_lock:
            servers = list(self._servers)
        try:
            run = self._require_supervisor().restart(str(cmd["run"]), servers)
        except PortConflict as conflict:
            return {"run": None, "conflict": dataclasses.asdict(conflict)}
        return {"run": _asdict(run), "conflict": None}

    def _cmd_clear_run(self, cmd: dict):
        self._require_supervisor().clear(str(cmd["run"]))
        return None

    def _cmd_restart_on_crash(self, cmd: dict):
        return _asdict(self._require_supervisor().set_restart_on_crash(str(cmd["run"]), bool(cmd.get("on"))))

    # -- usage ---------------------------------------------------------------

    def _usage_loop(self) -> None:
        # Transcript parsing and the limits request are slow, so they run off the snapshot loop.
        while not self._stop.is_set():
            self._refresh_usage()
            self._stop.wait(USAGE_REFRESH_SECONDS)

    def _tracker(self) -> UsageTracker:
        profile = self._profiles.get(self._profile)
        tracker = self._trackers.get(profile.name)
        if tracker is None or tracker.profile != profile:
            tracker = self._trackers[profile.name] = UsageTracker(profile)
        return tracker

    def _refresh_usage(self, force_limits: bool = False) -> dict | None:
        try:
            payload = self._tracker().payload(force_limits=force_limits)
        except Exception as e:
            self.emit({"type": "error", "message": f"usage failed: {e}"})
            return None
        if payload["profile"] != self._profile:
            return None  # the selection changed while this was computing
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
        if not self._usage_enabled:
            return None
        return self._refresh_usage(force_limits=bool(cmd.get("force")))

    def _cmd_claude_profile(self, cmd: dict):
        """Switches which profile's projects, sessions and usage the Claude views show."""
        name = str(cmd["name"])
        if name not in {p.name for p in self._profiles.profiles}:
            raise RuntimeError(f"Unknown Claude profile {name}")
        self._profile = name
        if self._usage_enabled:
            self._pool.submit(self._refresh_usage)
        return self._claude_payload() if self._has_claude else None

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
        return _asdict(get_activity_heatmap_data(self._claude_dir()))

    def _cmd_project_detail(self, cmd: dict):
        detail = _asdict(get_project_detail(str(cmd["path"]), self._claude_dir()))
        detail["tools_used"] = _ranked(detail["tools_used"])
        detail["languages"] = _ranked(detail["languages"])
        return detail

    def _cmd_project_sessions(self, cmd: dict):
        return [_asdict(s) for s in get_project_sessions(str(cmd["path"]), self._claude_dir())]

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
        self._usage_enabled = False
        self._profile = "personal"
        from devdash import demo
        demo.write_run_logs()

    def _create_supervisor(self) -> Supervisor | None:
        return None  # never touch the real runs in demo mode

    def _snapshot(self) -> dict:
        from devdash import demo

        snapshot = {
            "type": "snapshot",
            "timestamp": time.time(),
            "system": demo.system(),
            "node": demo.node(),
            "servers": demo.servers(),
            "runs": demo.runs(),
            "lan_ip": demo.LAN_IP,
            "projects": demo.projects(),
            # Demo paths do not exist, so the Compose working dir stands in for the resolved project.
            "docker": [
                {**c, "project_root": c["compose_working_dir"], "project_name": c["compose_project"]}
                for c in demo.docker()
            ],
            "processes": demo.processes(),
            "cleanup": demo.cleanup(),
        }
        if self._tick % CLAUDE_REFRESH_EVERY == 0:
            snapshot["claude"] = self._cmd_refresh_claude({})
            snapshot["usage"] = demo.usage()
            snapshot["worktrees"] = demo.worktrees()
            snapshot["runnable"] = demo.runnable()
        self._tick += 1
        return snapshot

    def _cmd_refresh_claude(self, cmd: dict):
        from devdash import demo
        payload = demo.claude(self._profile)
        for inst in payload["instances"]:
            inst["project_root"], inst["project_name"] = inst["cwd_full"], inst["project"]
        return payload

    def _cmd_usage(self, cmd: dict):
        from devdash import demo
        return demo.usage()

    def _cmd_claude_profile(self, cmd: dict):
        self._profile = str(cmd["name"])
        return self._cmd_refresh_claude(cmd)

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

    def _worktrees_loop(self) -> None:
        pass  # never scan the real repositories in demo mode

    def _cmd_refresh_worktrees(self, cmd: dict):
        return None

    def _cmd_worktree_size(self, cmd: dict):
        from devdash import demo
        return demo.worktree_size(str(cmd["path"]))

    def _cmd_remove_worktree(self, cmd: dict):
        return {"path": cmd["path"], "branch": "", "branch_deleted": bool(cmd.get("delete_branch")), "note": ""}

    def _cmd_project_sessions(self, cmd: dict):
        from devdash import demo
        return demo.project_detail(str(cmd["path"]))["recent_sessions"]

    def _demo_run(self, run_id: str) -> dict:
        from devdash import demo
        run = next((r for r in demo.runs() if r["id"] == run_id), None)
        if run is None:
            raise RuntimeError("Not a run devdash started")
        return {**run, "status": "running", "exit_code": None}

    def _cmd_run_script(self, cmd: dict):
        from devdash import demo
        root, script = str(cmd["root"]), str(cmd["script"])
        entry = next((e for e in demo.runnable() if e["root"] == root), None)
        found = next((s for s in (entry or {}).get("scripts", []) if s["id"] == script), None)
        if entry is None or found is None:
            raise RuntimeError(f"No script {script} in {root}")
        if entry["name"] == "admin" and not cmd.get("stop_pid"):
            # Shows the port check: admin's dev server wants the port storefront's Next.js holds.
            return {"run": None, "conflict": {"port": 3000, "pid": 41822, "label": "next dev", "project": "storefront"}}
        return {"run": {
            "id": f"{root}#{script}", "project_root": root, "project_name": entry["name"], "script_id": script,
            "name": found["name"], "command": found["command"], "cwd": found["cwd"], "package": found["package"],
            "log": f"{demo.RUN_LOG_DIR}/storefront-dev.log", "pid": 70001, "started": time.time(), "status": "running",
            "exit_code": None, "ended": 0.0, "restart_on_crash": False, "restarts": [], "gave_up": False, "ports": [],
        }, "conflict": None}

    def _cmd_stop_run(self, cmd: dict):
        return self._demo_run(str(cmd["run"]))

    def _cmd_restart_run(self, cmd: dict):
        return {"run": self._demo_run(str(cmd["run"])), "conflict": None}

    def _cmd_clear_run(self, cmd: dict):
        return None

    def _cmd_restart_on_crash(self, cmd: dict):
        return {**self._demo_run(str(cmd["run"])), "restart_on_crash": bool(cmd.get("on"))}


def serve(config: Config, demo: bool = False) -> None:
    # DEVDASH_DEMO lets a parent process (the menu bar app) opt in without changing arguments.
    if demo or os.environ.get("DEVDASH_DEMO") == "1":
        DemoBridge(config).run()
    else:
        Bridge(config).run()
