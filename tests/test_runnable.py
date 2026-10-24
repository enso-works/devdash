import json
from pathlib import Path

from devdash import runnable


def _package(folder: Path, scripts: dict, **extra) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "package.json").write_text(json.dumps({"name": folder.name, "scripts": scripts, **extra}))


def test_order_skips_lifecycle_and_hooks(tmp_path):
    _package(tmp_path, {
        "build": "vite build", "postinstall": "patch-package", "predev": "gen", "preview": "vite preview",
        "dev": "vite", "lint": "eslint .", "prepare": "husky",
    })
    assert [s.name for s in runnable.scripts(str(tmp_path))] == ["dev", "preview", "build", "lint"]


def test_package_manager_from_lockfile_and_field(tmp_path):
    for lockfile, manager in (("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("", "npm")):
        folder = tmp_path / (manager + lockfile)
        _package(folder, {"dev": "vite"})
        if lockfile:
            (folder / lockfile).touch()
        assert runnable.scripts(str(folder))[0].command == f"{manager} run dev"
    field = tmp_path / "field"
    _package(field, {"dev": "vite"}, packageManager="pnpm@9.12.0")
    assert runnable.scripts(str(field))[0].command == "pnpm run dev"


def test_workspaces_offer_server_scripts_of_each_package(tmp_path):
    _package(tmp_path, {"dev": "turbo dev", "build": "turbo build"}, workspaces=["apps/*"])
    (tmp_path / "yarn.lock").touch()
    _package(tmp_path / "apps" / "web", {"dev": "next dev", "build": "next build"})
    _package(tmp_path / "apps" / "api", {"start": "node server.js", "test": "vitest"})
    scripts = {s.id: s for s in runnable.scripts(str(tmp_path))}
    assert list(scripts) == ["dev", "build", "apps/api:start", "apps/web:dev"]
    web = scripts["apps/web:dev"]
    assert (web.command, web.cwd, web.package) == ("yarn run dev", str(tmp_path / "apps" / "web"), "web")


def test_pnpm_workspace_file(tmp_path):
    _package(tmp_path, {})
    (tmp_path / "pnpm-workspace.yaml").write_text("packages:\n  - 'packages/*'\n  - \"!packages/legacy\"\ncatalog:\n  - nope\n")
    (tmp_path / "pnpm-lock.yaml").touch()
    _package(tmp_path / "packages" / "site", {"dev": "astro dev"})
    assert [(s.id, s.command) for s in runnable.scripts(str(tmp_path))] == [("packages/site:dev", "pnpm run dev")]


def test_procfile_dev_wins_over_procfile(tmp_path):
    (tmp_path / "Procfile").write_text("web: bundle exec puma\n")
    (tmp_path / "Procfile.dev").write_text("# local\nweb: bin/rails server -p 3000\ncss: bin/rails tailwindcss:watch\n")
    scripts = runnable.scripts(str(tmp_path))
    assert [(s.id, s.command) for s in scripts] == [
        ("Procfile.dev:web", "bin/rails server -p 3000"),
        ("Procfile.dev:css", "bin/rails tailwindcss:watch"),
    ]


def test_default_is_last_run_else_first(tmp_path):
    _package(tmp_path, {"dev": "vite", "storybook": "storybook dev"})
    scripts = runnable.scripts(str(tmp_path))
    assert runnable.default_script(scripts, None).id == "dev"
    assert runnable.default_script(scripts, "storybook").id == "storybook"
    assert runnable.default_script(scripts, "gone").id == "dev"


def test_ports_in_commands():
    assert runnable.ports_in("vite --port 5174") == {5174}
    assert runnable.ports_in("storybook dev -p 6006") == {6006}
    assert runnable.ports_in("PORT=4000 node server.js") == {4000}
    assert runnable.ports_in("gunicorn app:app --bind 0.0.0.0:8001") == {8001}
    assert runnable.ports_in("rails server -b 0.0.0.0") == set()
    assert runnable.ports_in("next dev") == set()
