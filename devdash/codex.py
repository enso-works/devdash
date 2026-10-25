"""Codex: running terminal sessions, and projects and threads from Codex's own state database."""
from __future__ import annotations

import json
import os
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

import psutil

from devdash.processes import _format_relative_time, _format_uptime, _shorten_cwd

CODEX_HOME = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
SESSION_LIMIT = 50


@dataclass
class CodexInstance:
    pid: int
    project: str
    cwd: str
    tty: str
    cpu_percent: float
    memory_mb: float
    uptime: str


@dataclass
class CodexProject:
    name: str
    path: str
    sessions: int
    tokens: int
    last_active: str
    is_running: bool


@dataclass
class CodexSession:
    session_id: str
    title: str
    project_path: str
    git_branch: str
    model: str
    tokens: int
    source: str  # "cli", or "vscode" for the Codex app and editor extensions
    modified: str  # YYYY-MM-DD HH:MM, sorts as text
    last_active: str


def get_codex_instances() -> list[CodexInstance]:
    """Codex running in a terminal; the Codex app's own processes have none."""
    results = []
    for proc in psutil.process_iter(["pid", "name", "cwd", "create_time"]):
        try:
            info = proc.info
            if info.get("name") != "codex":
                continue
            try:
                terminal = proc.terminal()
            except (psutil.AccessDenied, psutil.NoSuchProcess, AttributeError):
                terminal = None
            if not terminal:
                continue
            cwd = info.get("cwd") or ""
            create_time = info.get("create_time") or 0
            try:
                cpu = proc.cpu_percent(interval=0)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                cpu = 0.0
            try:
                mem = proc.memory_info().rss / (1024 * 1024)
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                mem = 0.0
            results.append(CodexInstance(
                pid=info["pid"],
                project=Path(cwd).name if cwd else "",
                cwd=_shorten_cwd(cwd),
                tty=terminal,
                cpu_percent=cpu,
                memory_mb=mem,
                uptime=_format_uptime(time.time() - create_time if create_time else 0),
            ))
        except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
            continue
    results.sort(key=lambda p: p.memory_mb, reverse=True)
    return results


def _state_db(home: Path) -> Path | None:
    """The newest state_<n>.sqlite: Codex bumps the number when the schema changes."""
    best, best_n = None, -1
    for path in home.glob("state_*.sqlite"):
        try:
            n = int(path.stem.split("_", 1)[1])
        except ValueError:
            continue
        if n > best_n:
            best, best_n = path, n
    return best


def _threads(home: Path) -> list[sqlite3.Row]:
    """Threads people started, newest first: not archived, and not subagents such as reviews."""
    path = _state_db(home)
    if path is None:
        return []
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return []
    try:
        db.row_factory = sqlite3.Row
        columns = {row[1] for row in db.execute("PRAGMA table_info(threads)")}
        name = "COALESCE(NULLIF(name, ''), title)" if "name" in columns else "title"
        model = "model" if "model" in columns else "''"
        return db.execute(
            f"SELECT id, {name} AS title, cwd, git_branch, {model} AS model, tokens_used, source, updated_at"
            " FROM threads WHERE archived = 0 AND source IN ('cli', 'vscode', 'exec')"
            " ORDER BY updated_at DESC"
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        db.close()


def _modified(epoch: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(epoch))


def get_codex_sessions(home: Path = CODEX_HOME, threads: list[sqlite3.Row] | None = None) -> list[CodexSession]:
    rows = _threads(home) if threads is None else threads
    return [
        CodexSession(
            session_id=row["id"],
            title=" ".join((row["title"] or "").split())[:200],
            project_path=row["cwd"] or "",
            git_branch=row["git_branch"] or "",
            model=row["model"] or "",
            tokens=row["tokens_used"] or 0,
            source=row["source"],
            modified=_modified(row["updated_at"]),
            last_active=_format_relative_time(row["updated_at"] * 1000),
        )
        for row in rows[:SESSION_LIMIT]
    ]


def get_codex_projects(
    home: Path = CODEX_HOME, threads: list[sqlite3.Row] | None = None, running_cwds: set[str] = frozenset()
) -> list[CodexProject]:
    rows = _threads(home) if threads is None else threads
    projects: dict[str, CodexProject] = {}
    for row in rows:  # newest first, so the first row of a folder is its last activity
        path = row["cwd"] or ""
        if not path:
            continue
        project = projects.get(path)
        if project is None:
            projects[path] = CodexProject(
                name=Path(path).name or path,
                path=path,
                sessions=1,
                tokens=row["tokens_used"] or 0,
                last_active=_format_relative_time(row["updated_at"] * 1000),
                is_running=path in running_cwds,
            )
        else:
            project.sessions += 1
            project.tokens += row["tokens_used"] or 0
    return list(projects.values())


def codex_payload(home: Path = CODEX_HOME) -> dict:
    """Running sessions, projects and recent threads, for the bridge."""
    instances = get_codex_instances()
    running = {os.path.expanduser(i.cwd) for i in instances}
    threads = _threads(home)
    return {
        "instances": instances,
        "projects": get_codex_projects(home, threads, running),
        "sessions": get_codex_sessions(home, threads),
    }


if __name__ == "__main__":
    from dataclasses import asdict

    payload = codex_payload()
    print(json.dumps({k: [asdict(v) for v in vs] for k, vs in payload.items()}, indent=2)[:4000])
