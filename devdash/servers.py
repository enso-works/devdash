"""Dev servers in any language, and the project each process or container belongs to.

Used by the menu bar bridge. The terminal UI still reads Node processes from devdash.processes.
"""
from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

import psutil

from devdash.config import tomllib
from devdash.processes import _format_uptime, _shorten_command, _shorten_cwd

HOME = Path.home()

# A folder with any of these is a project (or a package inside one).
PROJECT_MARKERS = (
    ".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile", "composer.json",
    "deno.json", "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml",
)

SERVICE_RUNTIMES = {"postgres", "redis", "mysql", "mongo", "memcached"}

# GUI apps are skipped, except these, which exist to run a local service.
SERVICE_APPS = ("Postgres.app", "DBngin.app", "Herd.app", "MongoDB.app", "Redis.app")

SYSTEM_PREFIXES = ("/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/")
APP_BUNDLE = re.compile(r"\.app(\.bundle)?/")
HOMEBREW_PREFIXES = ("/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/")

RUNTIME_NAMES = {
    "node": "node", "nodejs": "node", "bun": "bun", "deno": "deno",
    "ruby": "ruby", "puma": "ruby", "unicorn": "ruby", "java": "java",
    "php": "php", "php-fpm": "php", "frankenphp": "php",
    "postgres": "postgres", "postmaster": "postgres", "redis-server": "redis", "valkey-server": "redis",
    "mysqld": "mysql", "mariadbd": "mysql", "mongod": "mongo", "memcached": "memcached",
    "dotnet": "dotnet", "beam.smp": "elixir", "elixir": "elixir",
}

# Launchers whose first real argument names what is actually running.
INTERPRETERS = {"node", "bun", "deno", "python", "ruby", "php", "java"}


@dataclass
class Project:
    root: str = ""
    name: str = ""
    package: str = ""  # workspace package inside the project, if the path is in one


@dataclass
class Server:
    pid: int
    name: str
    label: str
    runtime: str
    kind: str  # "app", "service" or "background"
    command: str
    cpu_percent: float
    memory_mb: float
    ports: list[int] = field(default_factory=list)
    uptime: str = ""
    started: float = 0.0
    cwd: str = ""
    cwd_full: str = ""
    project_root: str = ""
    project_name: str = ""
    package: str = ""


# -- projects ----------------------------------------------------------------

_project_cache: dict[str, Project] = {}


def _manifest_name(folder: Path) -> str:
    try:
        pkg = folder / "package.json"
        if pkg.is_file():
            return str(json.loads(pkg.read_text(encoding="utf-8")).get("name") or "")
        if tomllib is not None:
            for filename, table in (("pyproject.toml", "project"), ("Cargo.toml", "package")):
                path = folder / filename
                if path.is_file():
                    with open(path, "rb") as f:
                        return str(tomllib.load(f).get(table, {}).get("name") or "")
    except Exception:
        pass
    return ""


def resolve_project(path: str) -> Project:
    """The repository a path belongs to, or the nearest project folder when it is not in a repository.

    Stops below the home folder, so the home folder itself is never a project.
    """
    if not path:
        return Project()
    if path in _project_cache:
        return _project_cache[path]

    project = Project()
    try:
        start = Path(os.path.expanduser(path)).resolve()
        if start != HOME and HOME in start.parents:
            package_dir: Path | None = None
            repo_dir: Path | None = None
            for folder in [start, *start.parents]:
                if folder == HOME:
                    break
                if package_dir is None and any((folder / m).exists() for m in PROJECT_MARKERS):
                    package_dir = folder
                if (folder / ".git").exists():
                    repo_dir = folder
                    break
            root = repo_dir or package_dir
            if root is not None:
                project.root = str(root)
                project.name = _manifest_name(root) or root.name
                if package_dir is not None and package_dir != root:
                    project.package = _manifest_name(package_dir) or package_dir.name
    except Exception:
        project = Project()

    _project_cache[path] = project
    return project


def read_branch(root: str) -> str:
    """The checked-out branch, or the short commit when detached. Handles worktrees, whose `.git` is a file."""
    try:
        git = Path(root) / ".git"
        if git.is_file():
            text = git.read_text(encoding="utf-8").strip()
            if not text.startswith("gitdir:"):
                return ""
            git = (Path(root) / text[len("gitdir:"):].strip()).resolve()
        head = (git / "HEAD").read_text(encoding="utf-8").strip()
    except OSError:
        return ""
    if head.startswith("ref: refs/heads/"):
        return head[len("ref: refs/heads/"):]
    return head[:7]


def project_infos(roots: set[str]) -> list[dict]:
    """Name and branch for each project root in the snapshot."""
    result = []
    for root in sorted(roots):
        project = resolve_project(root)
        result.append({"root": root, "name": project.name or Path(root).name, "branch": read_branch(root)})
    return result


# -- servers -----------------------------------------------------------------

def _runtime(name: str, exe: str, cmdline: list[str]) -> str:
    base = os.path.basename(cmdline[0]) if cmdline else name
    for candidate in (name.lower(), base.lower()):
        if candidate in RUNTIME_NAMES:
            return RUNTIME_NAMES[candidate]
        if candidate.startswith("python") or candidate in ("uvicorn", "gunicorn", "hypercorn", "granian"):
            return "python"
        if candidate.startswith("node"):
            return "node"
    if "/go-build" in exe or "/go/bin/" in exe:
        return "go"
    if "/target/debug/" in exe or "/target/release/" in exe:
        return "rust"
    return "other"


def _script_name(arg: str) -> str:
    """`.../node_modules/.bin/vite` -> vite, `.../node_modules/@scope/pkg/dist/x.js` -> @scope/pkg."""
    if "node_modules/" in arg:
        rest = arg.rsplit("node_modules/", 1)[1].split("/")
        if rest[0] == ".bin" and len(rest) > 1:
            return rest[1]
        if rest[0].startswith("@") and len(rest) > 1:
            return f"{rest[0]}/{rest[1]}"
        return rest[0]
    return os.path.basename(arg.rstrip("/"))


def _label(name: str, runtime: str, cmdline: list[str]) -> str:
    """The most recognizable name: the script or module an interpreter runs, else the process name."""
    cmdline = [arg for arg in cmdline if arg]
    if runtime not in INTERPRETERS or not cmdline:
        return name
    # Processes that set their own title (`npm exec x`) keep it in argv[0] and blank the rest.
    head = cmdline[0]
    if not os.path.basename(head.split(" ")[0]).lower().startswith(runtime):
        for prefix in ("npm exec ", "npx ", "pnpm dlx ", "bunx "):
            head = head.removeprefix(prefix)
        return re.sub(r"(?<=.)@(latest|[\d.]+)$", "", head.split(" --")[0])
    args = cmdline[1:]
    for i, arg in enumerate(args):
        if arg == "-m" and i + 1 < len(args):
            return args[i + 1]
        if arg.startswith("-"):
            continue
        # `bun run dev`, `deno task dev`: the task name is the useful part.
        if arg in ("run", "task", "x", "exec") and i + 1 < len(args):
            return f"{arg} {args[i + 1]}"
        return _script_name(arg)
    return name


def _kind(runtime: str, exe: str, ppid: int, ports: list[int], project: Project) -> str:
    if not ports:
        return "background"
    if runtime in SERVICE_RUNTIMES or any(app in exe for app in SERVICE_APPS):
        return "service"
    if not project.root and ppid == 1 and exe.startswith(HOMEBREW_PREFIXES):
        return "service"
    return "app"


def _excluded(exe: str, runtime: str) -> bool:
    """System daemons and GUI apps. Known runtimes stay even inside a bundle: framework builds of
    Python run from `Python.framework/.../Python.app`."""
    if not exe or exe.startswith(SYSTEM_PREFIXES):
        return True
    if runtime != "other":
        return False
    return bool(APP_BUNDLE.search(exe)) and not any(app in exe for app in SERVICE_APPS)


def get_servers(node_pids: set[int], docker_ports: set[int]) -> list[Server]:
    """Processes of the current user listening on a TCP port, plus Node processes without one.

    Processes whose ports are all published Docker ports are port forwarders (Colima, Lima),
    and the containers are listed separately, so they are skipped.
    """
    uid = os.getuid()
    now = time.time()
    results: list[Server] = []
    for proc in psutil.process_iter(["pid", "name", "uids"]):
        try:
            info = proc.info
            uids = info.get("uids")
            if uids is None or uids.real != uid:
                continue
            pid = info["pid"]
            ports = sorted({
                c.laddr.port for c in proc.net_connections(kind="inet")
                if c.status == psutil.CONN_LISTEN and c.laddr
            })
            if not ports and pid not in node_pids:
                continue
            if ports and docker_ports and set(ports) <= docker_ports:
                continue

            exe = proc.exe()
            name = info.get("name") or ""
            cmdline = proc.cmdline()
            runtime = _runtime(name, exe, cmdline)
            if pid not in node_pids and _excluded(exe, runtime):
                continue

            cwd = proc.cwd() or ""
            started = proc.create_time()
            project = resolve_project(cwd)
            try:
                cpu = proc.cpu_percent(interval=0)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                cpu = 0.0

            results.append(Server(
                pid=pid,
                name=name,
                label=_label(name, runtime, cmdline),
                runtime=runtime,
                kind=_kind(runtime, exe, proc.ppid(), ports, project),
                command=_shorten_command(cmdline),
                cpu_percent=cpu,
                memory_mb=proc.memory_info().rss / (1024 * 1024),
                ports=ports,
                uptime=_format_uptime(now - started),
                started=started,
                cwd=_shorten_cwd(cwd),
                cwd_full=cwd,
                project_root=project.root,
                project_name=project.name,
                package=project.package,
            ))
        except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess, OSError):
            continue

    results.sort(key=lambda s: (s.ports[0] if s.ports else 1 << 20, s.pid))
    return results
