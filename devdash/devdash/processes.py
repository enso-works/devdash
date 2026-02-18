from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field

import psutil


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


@dataclass
class DockerContainer:
    container_id: str
    name: str
    image: str
    status: str
    ports: str
    created: str


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

            results.append(NodeProcess(
                pid=pid,
                name=name,
                command=_shorten_command(cmdline),
                cpu_percent=cpu,
                memory_mb=mem,
                cwd=_shorten_cwd(cwd),
                ports=ports,
                uptime=_format_uptime(uptime),
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
                '{"id":"{{.ID}}","name":"{{.Names}}","image":"{{.Image}}","status":"{{.Status}}","ports":"{{.Ports}}","created":"{{.RunningFor}}"}'
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
            containers.append(DockerContainer(
                container_id=data["id"],
                name=data["name"],
                image=data["image"],
                status=data["status"],
                ports=ports,
                created=data["created"],
            ))
        except (json.JSONDecodeError, KeyError):
            continue

    return containers


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
