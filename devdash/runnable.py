"""What a project can run: package.json scripts and Procfile entries.

Used by the supervisor to start dev servers, and by the menu bar app to list them.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

# Scripts that usually start a server come first, in this order. The rest keep their file order.
PREFERRED = ("dev", "start", "serve", "preview")

# npm lifecycle scripts: they run on install and publish, not by hand.
LIFECYCLE = {
    "preinstall", "install", "postinstall", "prepare", "prepublish", "prepublishOnly", "prepack",
    "postpack", "publish", "postpublish", "preversion", "version", "postversion", "dependencies",
}

LOCKFILES = (
    ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun"),
    ("package-lock.json", "npm"),
)

PROCFILES = ("Procfile.dev", "Procfile")
MAX_PACKAGES = 30


@dataclass
class Script:
    id: str  # unique within the project: "dev", "apps/web:dev", "Procfile.dev:web"
    name: str
    command: str  # what runs, through the shell
    source: str  # "package.json", "Procfile.dev" or "Procfile"
    cwd: str
    package: str = ""  # workspace package name, for scripts of a package inside the project


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def package_manager(folder: Path, root: Path) -> str:
    """From the `packageManager` field, else the nearest lockfile between the folder and the
    project root (workspaces keep one lockfile at the root), else npm."""
    for candidate in [folder, *folder.parents]:
        field = str(_read_json(candidate / "package.json").get("packageManager") or "")
        if field:
            name = field.split("@", 1)[0]
            if name in ("npm", "pnpm", "yarn", "bun"):
                return name
        for filename, manager in LOCKFILES:
            if (candidate / filename).exists():
                return manager
        if candidate == root or root not in candidate.parents:
            break
    return "npm"


def _ordered(names: list[str]) -> list[str]:
    names = [n for n in names if n not in LIFECYCLE]
    present = set(names)
    # `predev` and `postdev` run around `dev` on their own.
    names = [n for n in names if not (re.match(r"^(pre|post)", n) and re.sub(r"^(pre|post)", "", n) in present)]
    first = [n for n in PREFERRED if n in present]
    return first + [n for n in names if n not in first]


def _package_scripts(folder: Path, root: Path, only_preferred: bool) -> list[Script]:
    data = _read_json(folder / "package.json")
    scripts = data.get("scripts")
    if not isinstance(scripts, dict):
        return []
    manager = package_manager(folder, root)
    names = _ordered([str(k) for k, v in scripts.items() if isinstance(v, str)])
    if only_preferred:
        names = [n for n in names if n in PREFERRED]
    rel = "" if folder == root else str(folder.relative_to(root))
    package = "" if folder == root else str(data.get("name") or folder.name)
    return [
        Script(
            id=f"{rel}:{name}" if rel else name,
            name=name,
            command=f"{manager} run {name}",
            source="package.json",
            cwd=str(folder),
            package=package,
        )
        for name in names
    ]


def _workspace_globs(root: Path) -> list[str]:
    globs: list[str] = []
    workspaces = _read_json(root / "package.json").get("workspaces")
    if isinstance(workspaces, dict):  # yarn's {"packages": [...]}
        workspaces = workspaces.get("packages")
    if isinstance(workspaces, list):
        globs += [str(w) for w in workspaces]
    try:
        # pnpm-workspace.yaml: a "packages:" list. Read by hand to avoid a YAML dependency.
        in_packages = False
        for line in (root / "pnpm-workspace.yaml").read_text(encoding="utf-8").splitlines():
            if re.match(r"^\S", line):
                in_packages = line.startswith("packages:")
                continue
            match = re.match(r"^\s*-\s*['\"]?([^'\"#]+?)['\"]?\s*(#.*)?$", line)
            if in_packages and match:
                globs.append(match.group(1))
    except OSError:
        pass
    return [g for g in globs if not g.startswith("!")]


def workspace_packages(root: Path) -> list[Path]:
    """Folders of the workspace packages, from package.json `workspaces` or pnpm-workspace.yaml."""
    found: list[Path] = []
    for pattern in _workspace_globs(root):
        pattern = pattern.rstrip("/")
        try:
            matches = sorted(root.glob(pattern)) if any(c in pattern for c in "*?[") else [root / pattern]
        except (ValueError, NotImplementedError):
            continue
        for folder in matches:
            if "node_modules" in folder.parts or folder == root or folder in found:
                continue
            if (folder / "package.json").is_file():
                found.append(folder)
            if len(found) >= MAX_PACKAGES:
                return found
    return found


def _procfile_scripts(root: Path) -> list[Script]:
    for filename in PROCFILES:
        try:
            lines = (root / filename).read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        scripts = []
        for line in lines:
            match = re.match(r"^([A-Za-z0-9_-]+):\s*(.+)$", line.strip())
            if match:
                name, command = match.groups()
                scripts.append(Script(
                    id=f"{filename}:{name}", name=name, command=command.strip(), source=filename, cwd=str(root),
                ))
        return scripts  # the first Procfile found wins, like foreman
    return []


def scripts(root: str) -> list[Script]:
    """Everything a project can run: the root package.json scripts, the server scripts of its
    workspace packages, and the entries of Procfile.dev or Procfile."""
    path = Path(root)
    if not path.is_dir():
        return []
    result = _package_scripts(path, path, only_preferred=False)
    for folder in workspace_packages(path):
        result += _package_scripts(folder, path, only_preferred=True)
    result += _procfile_scripts(path)
    return result


def find(root: str, script_id: str) -> Script | None:
    return next((s for s in scripts(root) if s.id == script_id), None)


def default_script(available: list[Script], last: str | None) -> Script | None:
    """The script "Run" starts: the one run last time, else the first."""
    if last:
        for script in available:
            if script.id == last:
                return script
    return available[0] if available else None


_PORT_PATTERNS = (
    re.compile(r"(?:--port|-p)[ =](\d{2,5})\b"),
    re.compile(r"\bPORT=(\d{2,5})\b"),
    re.compile(r"(?:--bind|-b)[ =][\w.\[\]]*:(\d{2,5})\b"),
)


def ports_in(text: str) -> set[int]:
    """Ports named in a command: `--port 3000`, `-p 3000`, `PORT=3000`, `--bind 0.0.0.0:8000`."""
    return {int(m) for pattern in _PORT_PATTERNS for m in pattern.findall(text) if 0 < int(m) < 65536}


def script_body(script: Script) -> str:
    """The command a package.json script actually runs, to look for a port in it."""
    if script.source != "package.json":
        return script.command
    body = (_read_json(Path(script.cwd) / "package.json").get("scripts") or {}).get(script.name)
    return body if isinstance(body, str) else ""
