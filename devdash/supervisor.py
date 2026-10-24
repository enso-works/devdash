"""Dev servers devdash starts itself ("managed" runs): start, stop, restart, logs, restart on crash.

Runs start detached in their own process group, so they keep running when the menu bar app quits,
like servers started from a terminal. Their output goes to a log file, and what is running is kept in
a state file, so a new bridge picks them up again.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable

from devdash import runnable

STATE_DIR = Path.home() / ".local" / "share" / "devdash" / "runs"
LOG_MAX_BYTES = 5 * 1024 * 1024
STOP_TIMEOUT = 5.0
CRASH_DELAY = 2.0
CRASH_LIMIT = 3  # restarts per window, then devdash gives up
CRASH_WINDOW = 300.0
SHELL_ENV_TIMEOUT = 10.0

# Exit codes of a process that was asked to stop (SIGINT, SIGTERM, SIGHUP, directly or through a shell).
STOPPED_CODES = {-signal.SIGINT, -signal.SIGTERM, -signal.SIGHUP, 128 + signal.SIGINT, 128 + signal.SIGTERM, 128 + signal.SIGHUP}

# The bridge's own environment that must not leak into a dev server.
DROPPED_ENV = ("PYTHONHOME", "PYTHONPATH", "PYTHONEXECUTABLE", "PYTHONUNBUFFERED", "__PYVENV_LAUNCHER__", "VIRTUAL_ENV")


@dataclass
class Run:
    id: str  # project root and script id, so running a script again replaces its old run
    project_root: str
    project_name: str
    script_id: str
    name: str
    command: str
    cwd: str
    package: str
    log: str
    pid: int = 0  # also the process group id
    started: float = 0.0
    # "running", "restarting" (waiting to restart after a crash), "exited" or "crashed".
    status: str = "running"
    exit_code: int | None = None
    ended: float = 0.0
    restart_on_crash: bool = False
    restarts: list[float] = field(default_factory=list)
    gave_up: bool = False  # crashed too often, restart on crash stopped
    ports: list[int] = field(default_factory=list)  # ports seen listening, checked before the next start


@dataclass
class PortConflict(Exception):
    port: int
    pid: int
    label: str
    project: str

    def __str__(self) -> str:
        where = f" in {self.project}" if self.project else ""
        return f"Port {self.port} is held by PID {self.pid} ({self.label}{where})"


def _slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-") or "run"


def _group_alive(pgid: int) -> bool:
    if pgid <= 0:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _signal_group(pgid: int, sig: int) -> None:
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def _rotate(log: Path) -> None:
    """Keeps a log under LOG_MAX_BYTES: the old part goes to `.1`. Runs write with O_APPEND, so
    truncating in place is safe while they keep writing."""
    try:
        if log.stat().st_size <= LOG_MAX_BYTES:
            return
        shutil.copyfile(log, log.with_name(log.name + ".1"))
        os.truncate(log, 0)
    except OSError:
        pass


_shell_env: dict[str, str] | None = None
_shell_env_lock = threading.Lock()


def shell_env() -> dict[str, str]:
    """The environment of the user's login shell, so version managers (nvm, fnm, mise, asdf) put the
    right node and python on PATH, as in a terminal. Read once; the bridge's own env if that fails."""
    global _shell_env
    with _shell_env_lock:
        if _shell_env is not None:
            return dict(_shell_env)
        base = {k: v for k, v in os.environ.items() if k not in DROPPED_ENV and not k.startswith("DEVDASH_")}
        env = dict(base)
        shell = os.environ.get("SHELL") or "/bin/zsh"
        marker = "__devdash_env__"
        try:
            out = subprocess.run(
                [shell, "-l", "-i", "-c", f"printf {marker}; command env -0"],
                capture_output=True, timeout=SHELL_ENV_TIMEOUT, stdin=subprocess.DEVNULL, env=base,
            ).stdout.decode("utf-8", "replace")
            if marker in out:
                pairs = (item.partition("=") for item in out.rsplit(marker, 1)[1].split("\0") if "=" in item)
                parsed = {k: v for k, _, v in pairs if k and k not in DROPPED_ENV and not k.startswith("DEVDASH_")}
                if parsed.get("PATH"):
                    env = parsed
        except (OSError, subprocess.TimeoutExpired):
            pass
        for key in ("SHLVL", "_", "OLDPWD", "PWD"):
            env.pop(key, None)
        _shell_env = env
        return dict(env)


class Supervisor:
    def __init__(self, state_dir: Path = STATE_DIR, on_change: Callable[[], None] | None = None,
                 env: Callable[[], dict[str, str]] = shell_env) -> None:
        self.state_dir = state_dir
        self._on_change = on_change or (lambda: None)
        self._env = env
        self._lock = threading.RLock()
        self.runs: dict[str, Run] = {}
        self.last: dict[str, str] = {}  # project root to the script id run last
        self._procs: dict[str, subprocess.Popen] = {}
        self._stopping: set[str] = set()
        self._load()

    # -- state ---------------------------------------------------------------

    @property
    def _state_file(self) -> Path:
        return self.state_dir / "state.json"

    def _load(self) -> None:
        try:
            data = json.loads(self._state_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        fields = set(Run.__dataclass_fields__)
        for item in data.get("runs", []):
            try:
                run = Run(**{k: v for k, v in item.items() if k in fields})
            except TypeError:
                continue
            # Not our child any more: no exit code, and no restart on crash until it is started again.
            if run.status in ("running", "restarting") and not _group_alive(run.pid):
                run.status, run.ended = "exited", run.ended or time.time()
            self.runs[run.id] = run
        self.last = {str(k): str(v) for k, v in (data.get("last") or {}).items()}

    def _save(self) -> None:
        with self._lock:
            data = {"runs": [asdict(r) for r in self.runs.values()], "last": self.last}
        try:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            tmp = self._state_file.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=1), encoding="utf-8")
            tmp.replace(self._state_file)
        except OSError:
            pass

    def payload(self) -> list[dict]:
        with self._lock:
            return [asdict(r) for r in sorted(self.runs.values(), key=lambda r: r.started)]

    # -- starting ------------------------------------------------------------

    @staticmethod
    def run_id(root: str, script_id: str) -> str:
        return f"{root}#{script_id}"

    def start(self, root: str, script_id: str, project_name: str = "", servers: list[dict] | None = None) -> Run:
        """Starts a script of a project. Raises PortConflict when a port the script used before (or
        names in its command) is held by a process devdash didn't start, and ValueError when the
        script is unknown or already running."""
        script = runnable.find(root, script_id)
        if script is None:
            raise ValueError(f"No script {script_id} in {root}")
        run_id = self.run_id(root, script_id)
        with self._lock:
            old = self.runs.get(run_id)
            if old and old.status in ("running", "restarting") and _group_alive(old.pid):
                raise ValueError(f"{script.name} is already running")
            self._check_ports(old, script, servers or [])
            run = Run(
                id=run_id, project_root=root, project_name=project_name or Path(root).name,
                script_id=script.id, name=script.name, command=script.command, cwd=script.cwd,
                package=script.package,
                log=str(self.state_dir / _slug(Path(root).name) / f"{_slug(script.id)}.log"),
                restart_on_crash=old.restart_on_crash if old else False,
                ports=old.ports if old else [],
            )
            try:
                self._spawn(run)
            except OSError as e:
                raise ValueError(f"Could not start {script.name}: {e.strerror or e}") from e
            self.runs[run_id] = run
            self.last[root] = script.id
        self._save()
        self._on_change()
        return run

    def _check_ports(self, old: Run | None, script: runnable.Script, servers: list[dict]) -> None:
        wanted = set(old.ports if old else []) | runnable.ports_in(runnable.script_body(script))
        if not wanted:
            return
        managed = {r.pid for r in self.runs.values()}
        for server in servers:
            group = self._group_of(int(server["pid"]))
            if not group:
                continue  # exited since the snapshot, for example a run that was just stopped
            for port in server.get("ports") or []:
                if port in wanted and group not in managed:
                    raise PortConflict(port, int(server["pid"]), server.get("label") or server.get("name") or "",
                                       server.get("project_name") or "")

    def _spawn(self, run: Run) -> None:
        log = Path(run.log)
        log.parent.mkdir(parents=True, exist_ok=True)
        _rotate(log)
        env = self._env()
        env["BROWSER"] = "none"  # don't open a browser tab on every restart (Vite, CRA, Next)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(log, "ab") as out:
            out.write(f"\n--- devdash: {run.command} in {run.cwd} at {stamp} ---\n".encode())
            out.flush()
            proc = subprocess.Popen(
                ["/bin/sh", "-c", run.command], cwd=run.cwd, env=env,
                stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, start_new_session=True,
            )
        run.pid, run.started, run.status = proc.pid, time.time(), "running"
        run.exit_code, run.ended = None, 0.0
        self._procs[run.id] = proc
        threading.Thread(target=self._watch, args=(run.id, proc), daemon=True).start()

    # -- exits ---------------------------------------------------------------

    def _watch(self, run_id: str, proc: subprocess.Popen) -> None:
        code = proc.wait()
        with self._lock:
            run = self.runs.get(run_id)
            if run is None or self._procs.get(run_id) is not proc:
                return
            self._procs.pop(run_id, None)
            if run_id in self._stopping:
                return
            run.exit_code = code
            # The shell is gone, but what it started may still be running in the group (npm's child
            # node, say). poll() finishes the run once the group is empty.
            if _group_alive(run.pid):
                return
        self._finish(run_id)

    def _finish(self, run_id: str) -> None:
        with self._lock:
            run = self.runs.get(run_id)
            if run is None or run.status != "running":
                return
            run.ended = time.time()
            code = run.exit_code
            if code is None or code == 0 or code in STOPPED_CODES:
                run.status = "exited"
            else:
                run.status = "crashed"
                # Only runs this bridge started have an exit code, so reloaded runs never get here.
                if run.restart_on_crash:
                    now = time.time()
                    run.restarts = [t for t in run.restarts if now - t < CRASH_WINDOW]
                    if len(run.restarts) < CRASH_LIMIT:
                        run.restarts.append(now)
                        run.status = "restarting"
                        timer = threading.Timer(CRASH_DELAY, self._respawn, args=(run_id,))
                        timer.daemon = True
                        timer.start()
                    else:
                        run.gave_up = True
        self._save()
        self._on_change()

    def _respawn(self, run_id: str) -> None:
        with self._lock:
            run = self.runs.get(run_id)
            if run is None or run.status != "restarting":
                return
            try:
                self._spawn(run)
            except OSError:
                run.status, run.gave_up = "crashed", True
        self._save()
        self._on_change()

    def poll(self, servers: list[dict] | None = None) -> bool:
        """Called on every snapshot: finishes runs whose process group is gone, remembers the ports
        each run listens on, and keeps logs small. Returns whether anything changed."""
        changed = False
        finished = []
        with self._lock:
            for run in self.runs.values():
                if run.status == "running" and not _group_alive(run.pid):
                    if run.id not in self._procs:  # our own children are finished by _watch
                        finished.append(run.id)
                if run.status in ("running", "restarting"):
                    _rotate(Path(run.log))
            by_group: dict[int, set[int]] = {}
            for server in servers or []:
                if server.get("ports"):
                    group = self._group_of(int(server["pid"]))
                    if group:
                        by_group.setdefault(group, set()).update(server["ports"])
            for run in self.runs.values():
                ports = by_group.get(run.pid)
                if run.status == "running" and ports and sorted(ports) != run.ports:
                    run.ports = sorted(ports)
                    changed = True
        for run_id in finished:
            self._finish(run_id)
        if changed:
            self._save()
        return changed or bool(finished)

    # -- stopping ------------------------------------------------------------

    def stop(self, run_id: str, forget: bool = True) -> Run:
        """SIGTERM to the run's process group, SIGKILL after STOP_TIMEOUT. That reaches the children
        `npm run dev` starts. The run leaves the list unless `forget` is False."""
        with self._lock:
            run = self.runs.get(run_id)
            if run is None:
                raise ValueError("Not a run devdash started")
            self._stopping.add(run_id)
            proc = self._procs.pop(run_id, None)
            pgid = run.pid
        try:
            if run.status in ("running", "restarting"):
                _signal_group(pgid, signal.SIGTERM)
                deadline = time.monotonic() + STOP_TIMEOUT
                while _group_alive(pgid) and time.monotonic() < deadline:
                    if proc is not None:
                        proc.poll()  # reap the shell so it doesn't linger as a zombie
                    time.sleep(0.1)
                if _group_alive(pgid):
                    _signal_group(pgid, signal.SIGKILL)
                    time.sleep(0.2)
                if proc is not None:
                    try:
                        proc.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        pass
            with self._lock:
                if forget:
                    self.runs.pop(run_id, None)
                else:
                    run.status, run.ended, run.exit_code = "exited", time.time(), None
        finally:
            with self._lock:
                self._stopping.discard(run_id)
        self._save()
        self._on_change()
        return run

    def restart(self, run_id: str, servers: list[dict] | None = None) -> Run:
        with self._lock:
            run = self.runs.get(run_id)
            if run is None:
                raise ValueError("Not a run devdash started")
            root, script_id, name = run.project_root, run.script_id, run.project_name
        self.stop(run_id, forget=False)
        return self.start(root, script_id, name, servers)

    def clear(self, run_id: str) -> None:
        """Removes an exited or crashed run from the list."""
        with self._lock:
            run = self.runs.get(run_id)
            if run is not None and run.status in ("running", "restarting"):
                raise ValueError(f"{run.name} is still running")
            self.runs.pop(run_id, None)
        self._save()
        self._on_change()

    def set_restart_on_crash(self, run_id: str, on: bool) -> Run:
        with self._lock:
            run = self.runs.get(run_id)
            if run is None:
                raise ValueError("Not a run devdash started")
            run.restart_on_crash = on
            run.gave_up = False
            run.restarts = []
        self._save()
        self._on_change()
        return run

    # -- matching servers to runs ---------------------------------------------

    @staticmethod
    def _group_of(pid: int) -> int:
        try:
            return os.getpgid(pid)
        except (ProcessLookupError, PermissionError, OSError):
            return 0

    def run_for_pid(self, pid: int) -> str | None:
        """The run a process belongs to, by process group."""
        group = self._group_of(pid)
        if not group:
            return None
        with self._lock:
            for run in self.runs.values():
                if run.pid == group and run.status in ("running", "restarting"):
                    return run.id
        return None
