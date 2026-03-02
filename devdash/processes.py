from __future__ import annotations

import json
import re
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import psutil

_project_name_cache: dict[str, str] = {}


def _find_project_name(cwd: str) -> str:
    if not cwd:
        return ""
    if cwd in _project_name_cache:
        return _project_name_cache[cwd]
    try:
        path = Path(cwd).resolve()
        for directory in [path, *path.parents]:
            pkg = directory / "package.json"
            if pkg.is_file():
                try:
                    data = json.loads(pkg.read_text(encoding="utf-8"))
                    name = data.get("name", "")
                    _project_name_cache[cwd] = name
                    return name
                except (json.JSONDecodeError, OSError):
                    break
    except Exception:
        pass
    _project_name_cache[cwd] = ""
    return ""


@dataclass
class NodeProcess:
    pid: int
    name: str
    command: str
    cpu_percent: float
    memory_mb: float
    cwd: str
    ports: list[int] = field(default_factory=list)
    uptime: str = ""
    project: str = ""


@dataclass
class DockerContainer:
    container_id: str
    name: str
    image: str
    status: str
    ports: str
    created: str
    compose_project: str = ""
    compose_service: str = ""


def _format_uptime(seconds: float) -> str:
    if seconds < 60:
        return f"{int(seconds)}s"
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    if seconds < 86400:
        h = int(seconds // 3600)
        m = int((seconds % 3600) // 60)
        return f"{h}h {m}m"
    d = int(seconds // 86400)
    h = int((seconds % 86400) // 3600)
    return f"{d}d {h}h"


def _get_process_ports(pid: int) -> list[int]:
    ports = set()
    try:
        for conn in psutil.Process(pid).net_connections(kind="inet"):
            if conn.status == "LISTEN" and conn.laddr:
                ports.add(conn.laddr.port)
    except (psutil.AccessDenied, psutil.NoSuchProcess):
        pass
    return sorted(ports)


def _shorten_cwd(cwd: str) -> str:
    home = str(psutil.Path.home()) if hasattr(psutil, "Path") else ""
    try:
        from pathlib import Path
        home = str(Path.home())
        if cwd.startswith(home):
            cwd = "~" + cwd[len(home):]
    except Exception:
        pass
    return cwd


def _shorten_command(cmdline: list[str]) -> str:
    cmd = " ".join(cmdline)
    if len(cmd) > 120:
        cmd = cmd[:117] + "..."
    return cmd


def get_node_processes() -> list[NodeProcess]:
    results = []
    import time

    for proc in psutil.process_iter(["pid", "name", "cmdline", "cwd", "create_time"]):
        try:
            info = proc.info
            cmdline = info.get("cmdline") or []
            name = info.get("name", "")

            is_node = False
            if name and "node" in name.lower():
                is_node = True
            elif cmdline and any("node" in part.lower().split("/")[-1] for part in cmdline[:1]):
                is_node = True

            if not is_node:
                continue

            pid = info["pid"]
            cwd = info.get("cwd") or ""
            create_time = info.get("create_time") or 0
            uptime = time.time() - create_time if create_time else 0

            try:
                cpu = proc.cpu_percent(interval=0)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                cpu = 0.0

            try:
                mem = proc.memory_info().rss / (1024 * 1024)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                mem = 0.0

            ports = _get_process_ports(pid)
            project = _find_project_name(cwd)

            results.append(NodeProcess(
                pid=pid,
                name=name,
                command=_shorten_command(cmdline),
                cpu_percent=cpu,
                memory_mb=mem,
                cwd=_shorten_cwd(cwd),
                ports=ports,
                uptime=_format_uptime(uptime),
                project=project,
            ))
        except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
            continue

    results.sort(key=lambda p: p.memory_mb, reverse=True)
    return results


def get_docker_containers() -> list[DockerContainer]:
    try:
        result = subprocess.run(
            [
                "docker", "ps", "--format",
                '{"id":"{{.ID}}","name":"{{.Names}}","image":"{{.Image}}","status":"{{.Status}}","ports":"{{.Ports}}","created":"{{.RunningFor}}","labels":"{{.Labels}}"}'
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return []
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []

    containers = []
    for line in result.stdout.strip().splitlines():
        if not line.strip():
            continue
        try:
            data = json.loads(line)
            ports = data.get("ports", "")
            if len(ports) > 60:
                ports = ports[:57] + "..."
            labels_str = data.get("labels", "")
            labels = {}
            if labels_str:
                for part in labels_str.split(","):
                    if "=" in part:
                        k, v = part.split("=", 1)
                        labels[k.strip()] = v.strip()
            containers.append(DockerContainer(
                container_id=data["id"],
                name=data["name"],
                image=data["image"],
                status=data["status"],
                ports=ports,
                created=data["created"],
                compose_project=labels.get("com.docker.compose.project", ""),
                compose_service=labels.get("com.docker.compose.service", ""),
            ))
        except (json.JSONDecodeError, KeyError):
            continue

    containers.sort(key=lambda c: (c.compose_project, c.compose_service, c.name))
    return containers


@dataclass
class CleanupSuggestion:
    category: str  # "idle", "zombie", "stale_container", "orphan"
    label: str
    reason: str
    action_type: str  # "kill" or "stop_container"
    pid: int | None = None
    container_id: str | None = None


def _parse_docker_age_days(running_for: str) -> float:
    text = running_for.lower().strip()
    total_days = 0.0
    for match in re.finditer(r"(\d+)\s*(second|minute|hour|day|week|month|year)s?", text):
        value = int(match.group(1))
        unit = match.group(2)
        if unit == "second":
            total_days += value / 86400
        elif unit == "minute":
            total_days += value / 1440
        elif unit == "hour":
            total_days += value / 24
        elif unit == "day":
            total_days += value
        elif unit == "week":
            total_days += value * 7
        elif unit == "month":
            total_days += value * 30
        elif unit == "year":
            total_days += value * 365
    if total_days == 0 and re.search(r"about\s+(an?|one)\s+hour", text):
        total_days = 1.0 / 24
    return total_days


def get_cleanup_suggestions(
    node_procs: list[NodeProcess],
    docker_containers: list[DockerContainer],
    idle_tracker: dict[int, float],
    idle_threshold_cpu: float = 1.0,
    idle_threshold_minutes: int = 10,
    docker_stale_days: int = 7,
) -> list[CleanupSuggestion]:
    suggestions: list[CleanupSuggestion] = []
    flagged_pids: set[int] = set()
    now = time.monotonic()

    # Idle node processes
    for proc in node_procs:
        if proc.pid in idle_tracker:
            idle_seconds = now - idle_tracker[proc.pid]
            if idle_seconds >= idle_threshold_minutes * 60:
                idle_min = int(idle_seconds // 60)
                suggestions.append(CleanupSuggestion(
                    category="idle",
                    label=f"PID {proc.pid} ({proc.project or proc.name})",
                    reason=f"CPU < {idle_threshold_cpu}% for {idle_min}m",
                    action_type="kill",
                    pid=proc.pid,
                ))
                flagged_pids.add(proc.pid)

    # Zombie processes (from node procs list)
    for proc in node_procs:
        if proc.pid in flagged_pids:
            continue
        try:
            p = psutil.Process(proc.pid)
            if p.status() == psutil.STATUS_ZOMBIE:
                suggestions.append(CleanupSuggestion(
                    category="zombie",
                    label=f"PID {proc.pid} ({proc.project or proc.name})",
                    reason="Zombie process",
                    action_type="kill",
                    pid=proc.pid,
                ))
                flagged_pids.add(proc.pid)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    # Orphan node processes (ppid=1 or parent doesn't exist)
    for proc in node_procs:
        if proc.pid in flagged_pids:
            continue
        try:
            p = psutil.Process(proc.pid)
            ppid = p.ppid()
            if ppid <= 1:
                suggestions.append(CleanupSuggestion(
                    category="orphan",
                    label=f"PID {proc.pid} ({proc.project or proc.name})",
                    reason="Orphan process (parent exited)",
                    action_type="kill",
                    pid=proc.pid,
                ))
                flagged_pids.add(proc.pid)
            else:
                if not psutil.pid_exists(ppid):
                    suggestions.append(CleanupSuggestion(
                        category="orphan",
                        label=f"PID {proc.pid} ({proc.project or proc.name})",
                        reason=f"Parent PID {ppid} no longer exists",
                        action_type="kill",
                        pid=proc.pid,
                    ))
                    flagged_pids.add(proc.pid)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    # Stale Docker containers
    for container in docker_containers:
        age = _parse_docker_age_days(container.created)
        if age >= docker_stale_days:
            age_str = f"{int(age)}d" if age >= 1 else f"{int(age * 24)}h"
            suggestions.append(CleanupSuggestion(
                category="stale_container",
                label=f"{container.name} ({container.image})",
                reason=f"Running for {age_str}",
                action_type="stop_container",
                container_id=container.container_id,
            ))

    return suggestions


@dataclass
class PortOwner:
    kind: str  # "node" or "docker"
    label: str
    group: str
    pid: int | None = None
    container_id: str | None = None
    ports: list[int] = field(default_factory=list)


@dataclass
class DependencyEdge:
    from_label: str
    from_kind: str
    from_group: str
    to_label: str
    to_kind: str
    to_group: str
    port: int


def _parse_host_ports_from_string(ports_str: str) -> list[int]:
    """Extract host-side ports from Docker port strings like '0.0.0.0:5436->5432/tcp'."""
    host_ports = []
    for match in re.finditer(r"(?:\d+\.\d+\.\d+\.\d+)?:(\d+)->", ports_str):
        try:
            host_ports.append(int(match.group(1)))
        except ValueError:
            continue
    return host_ports


def _get_docker_host_ports(containers: list[DockerContainer]) -> dict[str, list[int]]:
    """Get accurate host port mappings via docker inspect, fall back to string parsing."""
    if not containers:
        return {}
    ids = [c.container_id for c in containers]
    try:
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{json .NetworkSettings.Ports}}"] + ids,
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            port_map: dict[str, list[int]] = {}
            lines = result.stdout.strip().splitlines()
            for cid, line in zip(ids, lines):
                try:
                    ports_data = json.loads(line)
                    host_ports: list[int] = []
                    for bindings in (ports_data or {}).values():
                        for b in bindings or []:
                            hp = b.get("HostPort")
                            if hp:
                                host_ports.append(int(hp))
                    port_map[cid] = host_ports
                except (json.JSONDecodeError, ValueError, TypeError):
                    port_map[cid] = []
            return port_map
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return {c.container_id: _parse_host_ports_from_string(c.ports) for c in containers}


def get_dependency_graph(
    node_procs: list[NodeProcess],
    docker_containers: list[DockerContainer],
) -> tuple[list[PortOwner], list[DependencyEdge]]:
    """Return (port_owners, edges) by scanning TCP connections."""
    docker_ports = _get_docker_host_ports(docker_containers)

    port_to_owner: dict[int, PortOwner] = {}
    owners: list[PortOwner] = []

    for proc in node_procs:
        label = proc.project or proc.name
        group = proc.project or ""
        owner = PortOwner(kind="node", label=label, group=group, pid=proc.pid, ports=proc.ports)
        owners.append(owner)
        for port in proc.ports:
            port_to_owner[port] = owner

    for container in docker_containers:
        label = container.compose_service or container.name
        group = container.compose_project or ""
        host_ports = docker_ports.get(container.container_id, [])
        owner = PortOwner(
            kind="docker", label=label, group=group,
            container_id=container.container_id, ports=host_ports,
        )
        owners.append(owner)
        for port in host_ports:
            if port not in port_to_owner:
                port_to_owner[port] = owner

    seen: set[tuple[str, str, int]] = set()
    edges: list[DependencyEdge] = []

    for proc in node_procs:
        source_label = proc.project or proc.name
        source_group = proc.project or ""
        try:
            connections = psutil.Process(proc.pid).net_connections(kind="tcp")
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
        for conn in connections:
            if conn.status != "ESTABLISHED" or not conn.raddr:
                continue
            remote_port = conn.raddr.port
            if remote_port not in port_to_owner:
                continue
            target = port_to_owner[remote_port]
            if target.pid == proc.pid:
                continue
            key = (source_label, target.label, remote_port)
            if key in seen:
                continue
            seen.add(key)
            edges.append(DependencyEdge(
                from_label=source_label,
                from_kind="node",
                from_group=source_group,
                to_label=target.label,
                to_kind=target.kind,
                to_group=target.group,
                port=remote_port,
            ))

    edges.sort(key=lambda e: (e.from_group, e.from_label, e.to_label))
    return owners, edges


@dataclass
class ActivityHeatmapData:
    weekly_heatmap: list[list[int]]  # 7 (Mon=0) x 24 hours -> message count
    week_day_labels: list[str]
    project_times: list[tuple[str, float]]  # (project_name, hours) sorted desc
    daily_messages: list[tuple[str, int]]  # full history (date, count)
    daily_sessions: list[tuple[str, int]]  # full history (date, count)
    daily_tokens: list[tuple[str, int]]  # full history (date, count)
    total_sessions: int
    total_messages: int
    total_hours: float


def get_activity_heatmap_data() -> ActivityHeatmapData | None:
    """Build activity heatmap from Claude stats and session data."""
    from datetime import timedelta

    claude_dir = Path.home() / ".claude"
    projects_dir = claude_dir / "projects"
    stats_file = claude_dir / "stats-cache.json"

    if not stats_file.is_file() and not projects_dir.is_dir():
        return None

    # 1. Parse stats-cache.json for full daily activity and tokens
    daily_messages: list[tuple[str, int]] = []
    daily_sessions: list[tuple[str, int]] = []
    daily_tokens: list[tuple[str, int]] = []
    total_sessions = 0
    total_messages = 0

    if stats_file.is_file():
        try:
            data = json.loads(stats_file.read_text(encoding="utf-8"))
            total_sessions = data.get("totalSessions", 0)
            total_messages = data.get("totalMessages", 0)
            for entry in data.get("dailyActivity") or []:
                date = entry.get("date", "")
                daily_messages.append((date, entry.get("messageCount", 0)))
                daily_sessions.append((date, entry.get("sessionCount", 0)))
            for entry in data.get("dailyModelTokens") or []:
                date = entry.get("date", "")
                tokens = entry.get("inputTokens", 0) + entry.get("outputTokens", 0)
                daily_tokens.append((date, tokens))
        except (json.JSONDecodeError, OSError):
            pass

    # 2. Build current-week 7x24 heatmap from session timestamps
    weekly_heatmap = [[0] * 24 for _ in range(7)]
    week_day_labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    now = datetime.now(timezone.utc)
    week_start = now - timedelta(days=now.weekday())
    week_start = week_start.replace(hour=0, minute=0, second=0, microsecond=0)

    project_hours_map: dict[str, float] = {}
    total_hours = 0.0

    if projects_dir.is_dir():
        for proj_dir in projects_dir.iterdir():
            if not proj_dir.is_dir():
                continue
            index_file = proj_dir / "sessions-index.json"
            if not index_file.is_file():
                continue
            try:
                idx_data = json.loads(index_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            for entry in idx_data.get("entries") or []:
                created_str = entry.get("created", "")
                modified_str = entry.get("modified", "")
                msg_count = entry.get("messageCount", 0)
                proj_path = entry.get("projectPath", "")
                proj_name = Path(proj_path).name if proj_path else proj_dir.name

                try:
                    created = datetime.fromisoformat(created_str.replace("Z", "+00:00"))
                except (ValueError, AttributeError):
                    continue

                # Current week heatmap only
                if created >= week_start:
                    dow = created.weekday()
                    hour = created.hour
                    weekly_heatmap[dow][hour] += msg_count

                # Project hours from session duration
                try:
                    modified = datetime.fromisoformat(modified_str.replace("Z", "+00:00"))
                    duration_hours = max((modified - created).total_seconds() / 3600, 0)
                except (ValueError, AttributeError):
                    duration_hours = 0.0
                if proj_name:
                    project_hours_map[proj_name] = project_hours_map.get(proj_name, 0) + duration_hours
                total_hours += duration_hours

    # 3. Scan session-meta for per-project duration_minutes (more accurate if available)
    meta_dir = claude_dir / "usage-data" / "session-meta"
    if meta_dir.is_dir():
        meta_project_hours: dict[str, float] = {}
        for meta_file in meta_dir.iterdir():
            if meta_file.suffix != ".json":
                continue
            try:
                meta = json.loads(meta_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            proj_path = meta.get("project_path", "")
            duration_min = meta.get("duration_minutes", 0)
            if proj_path and duration_min:
                proj_name = Path(proj_path).name
                meta_project_hours[proj_name] = meta_project_hours.get(proj_name, 0) + duration_min / 60
        if meta_project_hours:
            project_hours_map = meta_project_hours
            total_hours = sum(meta_project_hours.values())

    project_times = sorted(project_hours_map.items(), key=lambda x: x[1], reverse=True)

    if not daily_messages and not any(any(row) for row in weekly_heatmap) and not project_times:
        return None

    return ActivityHeatmapData(
        weekly_heatmap=weekly_heatmap,
        week_day_labels=week_day_labels,
        project_times=project_times,
        daily_messages=daily_messages,
        daily_sessions=daily_sessions,
        daily_tokens=daily_tokens,
        total_sessions=total_sessions,
        total_messages=total_messages,
        total_hours=total_hours,
    )


def kill_node_process(pid: int) -> bool:
    try:
        proc = psutil.Process(pid)
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except psutil.TimeoutExpired:
            proc.kill()
        return True
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False


def stop_docker_container(container_id: str) -> bool:
    try:
        result = subprocess.run(
            ["docker", "stop", container_id],
            capture_output=True,
            text=True,
            timeout=15,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


@dataclass
class SystemStats:
    cpu_percent: float
    cpu_count: int
    memory_total_gb: float
    memory_used_gb: float
    memory_percent: float
    swap_total_gb: float
    swap_used_gb: float
    swap_percent: float
    disk_total_gb: float
    disk_used_gb: float
    disk_free_gb: float
    disk_percent: float
    net_sent_per_sec: float | None = None
    net_recv_per_sec: float | None = None


_prev_net: tuple[float, float, float] | None = None  # (time, bytes_sent, bytes_recv)


@dataclass
class GeneralProcess:
    pid: int
    name: str
    cpu_percent: float
    memory_mb: float
    memory_percent: float
    status: str
    user: str
    command: str


def _format_bytes_rate(bps: float) -> str:
    if bps < 1024:
        return f"{bps:.0f} B/s"
    if bps < 1024 * 1024:
        return f"{bps / 1024:.1f} KB/s"
    return f"{bps / (1024 * 1024):.1f} MB/s"


def get_system_stats() -> SystemStats:
    global _prev_net
    cpu = psutil.cpu_percent(interval=0)
    cpu_count = psutil.cpu_count() or 1
    mem = psutil.virtual_memory()
    swap = psutil.swap_memory()
    disk = psutil.disk_usage("/")

    net_sent_ps: float | None = None
    net_recv_ps: float | None = None
    try:
        net = psutil.net_io_counters()
        now = time.monotonic()
        if _prev_net is not None:
            dt = now - _prev_net[0]
            if dt > 0:
                net_sent_ps = (net.bytes_sent - _prev_net[1]) / dt
                net_recv_ps = (net.bytes_recv - _prev_net[2]) / dt
        _prev_net = (now, net.bytes_sent, net.bytes_recv)
    except Exception:
        pass

    return SystemStats(
        cpu_percent=cpu,
        cpu_count=cpu_count,
        memory_total_gb=mem.total / (1024 ** 3),
        memory_used_gb=mem.used / (1024 ** 3),
        memory_percent=mem.percent,
        swap_total_gb=swap.total / (1024 ** 3),
        swap_used_gb=swap.used / (1024 ** 3),
        swap_percent=swap.percent,
        disk_total_gb=disk.total / (1024 ** 3),
        disk_used_gb=disk.used / (1024 ** 3),
        disk_free_gb=disk.free / (1024 ** 3),
        disk_percent=disk.percent,
        net_sent_per_sec=net_sent_ps,
        net_recv_per_sec=net_recv_ps,
    )


def get_all_processes(limit: int = 80) -> list[GeneralProcess]:
    results = []
    for proc in psutil.process_iter(["pid", "name", "username", "status", "cmdline"]):
        try:
            info = proc.info
            pid = info["pid"]
            name = info.get("name") or ""
            user = info.get("username") or ""
            status = info.get("status") or ""
            cmdline = info.get("cmdline") or []

            try:
                cpu = proc.cpu_percent(interval=0)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                cpu = 0.0

            try:
                mem_info = proc.memory_info()
                mem_mb = mem_info.rss / (1024 * 1024)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                mem_mb = 0.0

            try:
                mem_pct = proc.memory_percent()
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                mem_pct = 0.0

            cmd = _shorten_command(cmdline) if cmdline else name

            results.append(GeneralProcess(
                pid=pid,
                name=name,
                cpu_percent=cpu,
                memory_mb=mem_mb,
                memory_percent=mem_pct,
                status=status,
                user=user,
                command=cmd,
            ))
        except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
            continue

    results.sort(key=lambda p: p.memory_mb, reverse=True)
    return results[:limit]


def kill_process(pid: int) -> bool:
    try:
        proc = psutil.Process(pid)
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except psutil.TimeoutExpired:
            proc.kill()
        return True
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False


@dataclass
class ClaudeInstance:
    pid: int
    project: str
    cwd: str
    tty: str
    cpu_percent: float
    memory_mb: float
    uptime: str


@dataclass
class ClaudeProject:
    name: str
    path: str
    sessions: int
    messages: int
    last_active: str
    is_running: bool


def _format_relative_time(ts_ms: float) -> str:
    diff = time.time() - ts_ms / 1000
    if diff < 60:
        return "just now"
    if diff < 3600:
        return f"{int(diff // 60)}m ago"
    if diff < 86400:
        h = int(diff // 3600)
        return f"{h}h ago"
    d = int(diff // 86400)
    if d == 1:
        return "1d ago"
    if d < 30:
        return f"{d}d ago"
    return f"{d // 30}mo ago"


def get_claude_instances() -> list[ClaudeInstance]:
    results = []
    for proc in psutil.process_iter(["pid", "name", "cwd", "create_time"]):
        try:
            info = proc.info
            name = info.get("name") or ""
            if name != "claude":
                continue

            try:
                exe = proc.exe()
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                exe = ""
            if "/Applications/" in exe:
                continue

            try:
                terminal = proc.terminal()
            except (psutil.AccessDenied, psutil.NoSuchProcess, AttributeError):
                terminal = None
            if not terminal:
                continue

            pid = info["pid"]
            cwd = info.get("cwd") or ""
            create_time = info.get("create_time") or 0
            uptime = time.time() - create_time if create_time else 0

            try:
                cpu = proc.cpu_percent(interval=0)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                cpu = 0.0

            try:
                mem = proc.memory_info().rss / (1024 * 1024)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                mem = 0.0

            project = Path(cwd).name if cwd else ""

            results.append(ClaudeInstance(
                pid=pid,
                project=project,
                cwd=_shorten_cwd(cwd),
                tty=terminal,
                cpu_percent=cpu,
                memory_mb=mem,
                uptime=_format_uptime(uptime),
            ))
        except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
            continue

    results.sort(key=lambda p: p.memory_mb, reverse=True)
    return results


def get_claude_projects() -> list[ClaudeProject]:
    claude_dir = Path.home() / ".claude"
    history_file = claude_dir / "history.jsonl"
    projects_dir = claude_dir / "projects"

    # Parse history.jsonl for message counts and last active times per project
    project_messages: dict[str, int] = {}
    project_last_active: dict[str, float] = {}
    if history_file.is_file():
        try:
            for line in history_file.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    proj = entry.get("project", "")
                    ts = entry.get("timestamp", 0)
                    if proj:
                        project_messages[proj] = project_messages.get(proj, 0) + 1
                        if ts > project_last_active.get(proj, 0):
                            project_last_active[proj] = ts
                except (json.JSONDecodeError, KeyError):
                    continue
        except OSError:
            pass

    # Get running instance CWDs for status
    try:
        running_instances = get_claude_instances()
    except Exception:
        running_instances = []
    running_cwds: set[str] = set()
    for inst in running_instances:
        # Expand ~ back to home for comparison
        cwd = inst.cwd
        if cwd.startswith("~"):
            cwd = str(Path.home()) + cwd[1:]
        running_cwds.add(cwd)

    # Build project list from history entries
    seen_paths: set[str] = set()
    results = []
    for proj_path in project_messages:
        if proj_path in seen_paths:
            continue
        seen_paths.add(proj_path)

        name = Path(proj_path).name
        # Count session files in projects dir
        encoded = proj_path.replace("/", "-")
        proj_dir = projects_dir / encoded
        sessions = 0
        if proj_dir.is_dir():
            sessions = sum(1 for f in proj_dir.iterdir() if f.suffix == ".jsonl")

        messages = project_messages.get(proj_path, 0)
        last_ts = project_last_active.get(proj_path, 0)
        last_active = _format_relative_time(last_ts) if last_ts else "unknown"
        is_running = proj_path in running_cwds

        results.append(ClaudeProject(
            name=name,
            path=proj_path,
            sessions=sessions,
            messages=messages,
            last_active=last_active,
            is_running=is_running,
        ))

    # Sort by last active descending
    results.sort(
        key=lambda p: project_last_active.get(p.path, 0),
        reverse=True,
    )
    return results


@dataclass
class ClaudeSessionEntry:
    session_id: str
    summary: str
    first_prompt: str
    message_count: int
    git_branch: str
    created: str
    modified: str
    project_path: str
    is_sidechain: bool


@dataclass
class ClaudeStats:
    total_sessions: int
    total_messages: int
    model_usage: dict[str, tuple[int, int, int]]  # model -> (input, output, cache_read)
    daily_activity: list[tuple[str, int]]  # last 14 days: (date, message_count)
    hour_counts: dict[int, int]  # hour 0-23 -> count


@dataclass
class ClaudeProjectDetail:
    project_path: str
    name: str
    total_sessions: int
    total_messages: int
    total_lines_added: int
    total_lines_removed: int
    total_files_modified: int
    git_commits: int
    tools_used: dict[str, int]
    languages: dict[str, int]
    memory_content: str | None
    recent_sessions: list[ClaudeSessionEntry]


def _format_iso_datetime(iso: str) -> str:
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.strftime("%b %d %H:%M")
    except (ValueError, AttributeError):
        return iso[:16] if iso else ""


def _format_iso_sortable(iso: str) -> str:
    """Format ISO datetime as YYYY-MM-DD HH:MM for correct lexicographic sorting."""
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M")
    except (ValueError, AttributeError):
        return iso[:16] if iso else ""


def get_claude_stats() -> ClaudeStats | None:
    stats_file = Path.home() / ".claude" / "stats-cache.json"
    if not stats_file.is_file():
        return None
    try:
        data = json.loads(stats_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None

    model_usage: dict[str, tuple[int, int, int]] = {}
    for model, info in (data.get("modelUsage") or {}).items():
        model_usage[model] = (
            info.get("inputTokens", 0),
            info.get("outputTokens", 0),
            info.get("cacheReadInputTokens", 0),
        )

    daily = data.get("dailyActivity") or []
    daily_activity = [
        (entry.get("date", ""), entry.get("messageCount", 0))
        for entry in daily[-14:]
    ]

    raw_hours = data.get("hourCounts") or {}
    hour_counts = {int(k): v for k, v in raw_hours.items()}

    return ClaudeStats(
        total_sessions=data.get("totalSessions", 0),
        total_messages=data.get("totalMessages", 0),
        model_usage=model_usage,
        daily_activity=daily_activity,
        hour_counts=hour_counts,
    )


def get_project_sessions(project_path: str) -> list[ClaudeSessionEntry]:
    encoded = project_path.replace("/", "-")
    index_file = Path.home() / ".claude" / "projects" / encoded / "sessions-index.json"
    if not index_file.is_file():
        return []
    try:
        data = json.loads(index_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []

    entries = []
    for e in data.get("entries") or []:
        entries.append(ClaudeSessionEntry(
            session_id=e.get("sessionId", ""),
            summary=e.get("summary", ""),
            first_prompt=e.get("firstPrompt", ""),
            message_count=e.get("messageCount", 0),
            git_branch=e.get("gitBranch", ""),
            created=_format_iso_datetime(e.get("created", "")),
            modified=_format_iso_datetime(e.get("modified", "")),
            project_path=e.get("projectPath", project_path),
            is_sidechain=e.get("isSidechain", False),
        ))

    entries.sort(key=lambda x: x.modified, reverse=True)
    return entries


def get_all_recent_sessions() -> list[ClaudeSessionEntry]:
    """Return the 50 most recent sessions across all projects."""
    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.is_dir():
        return []

    raw_entries: list[tuple[str, ClaudeSessionEntry]] = []

    for index_file in projects_dir.glob("*/sessions-index.json"):
        try:
            data = json.loads(index_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue

        for e in data.get("entries") or []:
            raw_modified = e.get("modified", "")
            entry = ClaudeSessionEntry(
                session_id=e.get("sessionId", ""),
                summary=e.get("summary", ""),
                first_prompt=e.get("firstPrompt", ""),
                message_count=e.get("messageCount", 0),
                git_branch=e.get("gitBranch", ""),
                created=_format_iso_sortable(e.get("created", "")),
                modified=_format_iso_sortable(raw_modified),
                project_path=e.get("projectPath", ""),
                is_sidechain=e.get("isSidechain", False),
            )
            raw_entries.append((raw_modified, entry))

    raw_entries.sort(key=lambda x: x[0], reverse=True)
    return [entry for _, entry in raw_entries[:50]]


def get_project_detail(project_path: str) -> ClaudeProjectDetail:
    name = Path(project_path).name

    # Aggregate session-meta files for this project
    meta_dir = Path.home() / ".claude" / "usage-data" / "session-meta"
    total_messages = 0
    total_lines_added = 0
    total_lines_removed = 0
    total_files_modified = 0
    git_commits = 0
    tools_used: dict[str, int] = {}
    languages: dict[str, int] = {}
    session_count = 0

    if meta_dir.is_dir():
        for meta_file in meta_dir.iterdir():
            if not meta_file.suffix == ".json":
                continue
            try:
                meta = json.loads(meta_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            if meta.get("project_path") != project_path:
                continue
            session_count += 1
            total_messages += meta.get("user_message_count", 0) + meta.get("assistant_message_count", 0)
            total_lines_added += meta.get("lines_added", 0)
            total_lines_removed += meta.get("lines_removed", 0)
            total_files_modified += meta.get("files_modified", 0)
            git_commits += meta.get("git_commits", 0)
            for tool, count in (meta.get("tool_counts") or {}).items():
                tools_used[tool] = tools_used.get(tool, 0) + count
            for lang, count in (meta.get("languages") or {}).items():
                languages[lang] = languages.get(lang, 0) + count

    # Read MEMORY.md
    encoded = project_path.replace("/", "-")
    memory_file = Path.home() / ".claude" / "projects" / encoded / "memory" / "MEMORY.md"
    memory_content = None
    if memory_file.is_file():
        try:
            memory_content = memory_file.read_text(encoding="utf-8")
        except OSError:
            pass

    # Get recent sessions
    recent_sessions = get_project_sessions(project_path)[:10]

    return ClaudeProjectDetail(
        project_path=project_path,
        name=name,
        total_sessions=session_count,
        total_messages=total_messages,
        total_lines_added=total_lines_added,
        total_lines_removed=total_lines_removed,
        total_files_modified=total_files_modified,
        git_commits=git_commits,
        tools_used=tools_used,
        languages=languages,
        memory_content=memory_content,
        recent_sessions=recent_sessions,
    )
