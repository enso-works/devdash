"""Git worktrees across the repositories devdash knows about.

Coding agents create a worktree per task and rarely remove them. This lists every linked worktree with
whether it has changes, whether its branch is merged, and how long since it was touched, and removes
the ones that are safe to remove.
"""
from __future__ import annotations

import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

GIT_TIMEOUT = 10
STALE_DAYS = 7

# Path fragments that tell which tool created a worktree, first match wins.
CREATORS = (
    ("/.claude/worktrees/", "claude"),
    ("/.codex/", "codex"),
    ("/conductor/", "conductor"),
    ("/.cursor/", "cursor"),
    ("/.superset/", "superset"),
    ("/.t3/", "t3code"),
)


@dataclass
class Worktree:
    path: str
    branch: str  # empty when detached
    head: str  # short commit
    is_main: bool = False
    locked: bool = False
    prunable: bool = False  # the folder is gone
    changes: int = 0  # changed and untracked files
    merged: bool = False
    upstream_gone: bool = False
    last_commit: float = 0.0
    subject: str = ""
    last_touched: float = 0.0
    created_by: str = ""
    # "missing", "changes", "merged", "stale" or "active". The menu bar app adds "running" on top.
    status: str = "active"


@dataclass
class Repo:
    root: str  # the main worktree
    name: str
    default_branch: str
    worktrees: list[Worktree] = field(default_factory=list)


def _git(cwd: str, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", cwd, *args],
        capture_output=True, text=True, timeout=GIT_TIMEOUT,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"},
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {args[0]} failed")
    return result.stdout


def parse_porcelain(text: str) -> list[Worktree]:
    """`git worktree list --porcelain`: blocks separated by blank lines, the main worktree first."""
    worktrees: list[Worktree] = []
    for block in text.strip().split("\n\n"):
        fields: dict[str, str] = {}
        for line in block.splitlines():
            key, _, value = line.partition(" ")
            fields[key] = value
        if "worktree" not in fields:
            continue
        branch = fields.get("branch", "")
        worktrees.append(Worktree(
            path=fields["worktree"],
            branch=branch.removeprefix("refs/heads/"),
            head=fields.get("HEAD", "")[:7],
            locked="locked" in fields,
            prunable="prunable" in fields,
        ))
    if worktrees and "bare" not in text.split("\n\n", 1)[0]:
        worktrees[0].is_main = True
    return worktrees


def created_by(path: str) -> str:
    for fragment, tool in CREATORS:
        if fragment in path + "/":
            return tool
    return ""


def status(wt: Worktree, now: float) -> str:
    """Priority order: a missing folder, then uncommitted changes, then merged, then age."""
    if wt.prunable:
        return "missing"
    if wt.changes:
        return "changes"
    if wt.merged and not wt.is_main:
        return "merged"
    if now - max(wt.last_touched, wt.last_commit) > STALE_DAYS * 86400:
        return "stale"
    return "active"


def _last_touched(path: str) -> float:
    """Newest modification time among the worktree's top-level entries. Cheap, and enough to tell a
    worktree someone is working in from one that sat for a week."""
    newest = 0.0
    try:
        with os.scandir(path) as entries:
            for entry in entries:
                try:
                    newest = max(newest, entry.stat(follow_symlinks=False).st_mtime)
                except OSError:
                    continue
    except OSError:
        pass
    return newest


def _default_branch(root: str) -> str:
    """The branch merged work lands on: origin's default branch, else origin/main or origin/master,
    else a local main or master. The remote one first, since the local copy is often behind."""
    try:
        return _git(root, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD").strip().removeprefix("refs/remotes/")
    except (RuntimeError, subprocess.TimeoutExpired):
        pass
    for ref in ("refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"):
        try:
            _git(root, "rev-parse", "--verify", "--quiet", ref)
            return ref.removeprefix("refs/remotes/").removeprefix("refs/heads/")
        except (RuntimeError, subprocess.TimeoutExpired):
            continue
    return ""


_common_dirs: dict[str, str | None] = {}


def common_dir(path: str) -> str | None:
    """The shared `.git` folder of the repository a path is in, so a worktree and its main checkout
    count as one repository. Cached: a folder doesn't move between repositories."""
    if path in _common_dirs:
        return _common_dirs[path]
    result = None
    if os.path.isdir(path):
        try:
            out = _git(path, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
            result = out or None
        except (RuntimeError, subprocess.TimeoutExpired, OSError):
            result = None
    _common_dirs[path] = result
    return result


def scan_repo(git_dir: str, now: float | None = None) -> Repo | None:
    """Every worktree of one repository, or None when it has no linked worktrees."""
    now = now or time.time()
    try:
        worktrees = parse_porcelain(_git(git_dir, "worktree", "list", "--porcelain"))
    except (RuntimeError, subprocess.TimeoutExpired, OSError):
        return None
    if len(worktrees) < 2:
        return None
    main = worktrees[0]
    root = main.path
    default = _default_branch(root)

    merged: set[str] = set()
    tracking: dict[str, tuple[bool, float, str]] = {}
    try:
        if default:
            merged = set(_git(root, "branch", "--merged", default, "--format=%(refname:short)").split())
        for line in _git(
            root, "for-each-ref", "refs/heads", "--format=%(refname:short)\t%(upstream:track)\t%(committerdate:unix)\t%(subject)",
        ).splitlines():
            name, track, date, subject = (line.split("\t", 3) + ["", "", ""])[:4]
            tracking[name] = (track == "[gone]", float(date or 0), subject)
    except (RuntimeError, subprocess.TimeoutExpired):
        pass
    default_local = default.split("/", 1)[-1]

    for wt in worktrees:
        wt.created_by = created_by(wt.path)
        if wt.branch in tracking:
            wt.upstream_gone, wt.last_commit, wt.subject = tracking[wt.branch]
        # A branch that was squash-merged on GitHub isn't an ancestor of main, but its remote branch is gone.
        wt.merged = bool(wt.branch) and wt.branch != default_local and (wt.branch in merged or wt.upstream_gone)
        if not wt.prunable:
            wt.last_touched = _last_touched(wt.path)
            try:
                wt.changes = len(_git(wt.path, "status", "--porcelain", "--no-renames").splitlines())
            except (RuntimeError, subprocess.TimeoutExpired, OSError):
                wt.changes = 0
        wt.status = status(wt, now)

    return Repo(root=root, name=Path(root).name, default_branch=default, worktrees=worktrees)


def scan(paths: set[str]) -> list[Repo]:
    """Repositories with linked worktrees among the given folders, deduplicated by repository."""
    git_dirs = {d for d in (common_dir(p) for p in paths if p) if d}
    repos = [repo for repo in (scan_repo(d) for d in sorted(git_dirs)) if repo]
    return sorted(repos, key=lambda r: r.name.lower())


# -- size --------------------------------------------------------------------

_sizes: dict[str, tuple[float, int]] = {}


def size_bytes(path: str) -> int | None:
    """Disk usage of a worktree, cached until its top level changes. Slow with node_modules, so
    only computed on request."""
    touched = _last_touched(path)
    cached = _sizes.get(path)
    if cached and cached[0] == touched:
        return cached[1]
    try:
        out = subprocess.run(["du", "-sk", path], capture_output=True, text=True, timeout=120).stdout
        size = int(out.split()[0]) * 1024
    except (subprocess.TimeoutExpired, ValueError, IndexError, OSError):
        return None
    _sizes[path] = (touched, size)
    return size


# -- removing ----------------------------------------------------------------

def _is_inside(path: str, folder: str) -> bool:
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def remove(path: str, delete_branch: bool, busy_cwds: list[str]) -> dict:
    """`git worktree remove`, which refuses worktrees with changes, then `git branch -d` (never -D)
    when asked and the branch is merged, then `git worktree prune`.

    Refuses the main worktree and worktrees something is running in (`busy_cwds`).
    """
    path = os.path.realpath(path)
    git_dir = common_dir(path)
    if git_dir is None:
        raise ValueError(f"{path} is not in a git repository")
    repo = scan_repo(git_dir)
    wt = next((w for w in (repo.worktrees if repo else []) if os.path.realpath(w.path) == path), None)
    if repo is None or wt is None:
        raise ValueError(f"{path} is not a linked worktree")
    if wt.is_main:
        raise ValueError("The main checkout can't be removed")
    for cwd in busy_cwds:
        if cwd and _is_inside(os.path.realpath(cwd), path):
            raise ValueError("Something is still running in this worktree. Stop it first.")
    if wt.changes:
        raise ValueError(f"The worktree has {wt.changes} uncommitted change{'s' if wt.changes != 1 else ''}")

    if not wt.prunable:
        _git(repo.root, "worktree", "remove", path)
    _git(repo.root, "worktree", "prune")
    _common_dirs.pop(path, None)

    branch_deleted = False
    note = ""
    if delete_branch and wt.branch:
        try:
            _git(repo.root, "branch", "-d", wt.branch)
            branch_deleted = True
        except RuntimeError as e:
            # -d refuses branches that aren't merged into HEAD; squash merges land here.
            message = re.sub(r"^error: ", "", str(e)).splitlines()[0]
            note = "not fully merged" if "not fully merged" in message else message
    return {"path": path, "branch": wt.branch, "branch_deleted": branch_deleted, "note": note}
