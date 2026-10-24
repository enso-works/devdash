import os
import socket
import subprocess
import sys
import time

import pytest

from devdash import supervisor as sup
from devdash.supervisor import PortConflict, Supervisor


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait(condition, timeout=5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


def _listening(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


@pytest.fixture
def project(tmp_path):
    port = _free_port()
    folder = tmp_path / "app"
    folder.mkdir()
    py = sys.executable
    (folder / "Procfile.dev").write_text(
        f"web: {py} -m http.server {port} --bind 127.0.0.1\n"
        # A shell with a child, like `npm run dev` starting node: stop has to reach both.
        f"pair: {py} -m http.server {port} --bind 127.0.0.1 & sleep 60\n"
        "crash: echo boom; exit 3\n"
    )
    return folder, port


@pytest.fixture
def supervisor(tmp_path):
    made = []

    def make():
        s = Supervisor(state_dir=tmp_path / "state", env=lambda: dict(os.environ))
        made.append(s)
        return s

    yield make
    for s in made:
        for run_id in list(s.runs):
            try:
                s.stop(run_id)
            except Exception:
                pass


def test_start_logs_and_stop(project, supervisor):
    folder, port = project
    s = supervisor()
    run = s.start(str(folder), "Procfile.dev:web")
    assert run.status == "running" and run.pid > 0
    assert _wait(lambda: _listening(port))
    assert s.run_for_pid(run.pid) == run.id
    s.stop(run.id)
    assert not _listening(port)
    assert run.id not in s.runs
    assert "devdash:" in open(run.log).read()
    assert s.last[str(folder)] == "Procfile.dev:web"


def test_stop_reaches_children_in_the_group(project, supervisor):
    folder, port = project
    s = supervisor()
    run = s.start(str(folder), "Procfile.dev:pair")
    assert _wait(lambda: _listening(port))
    s.stop(run.id)
    assert not sup._group_alive(run.pid)
    assert not _listening(port)


def test_restart_gets_a_new_process(project, supervisor):
    folder, port = project
    s = supervisor()
    first = s.start(str(folder), "Procfile.dev:web")
    assert _wait(lambda: _listening(port))
    old_pid = first.pid
    second = s.restart(first.id)
    assert second.pid != old_pid and second.status == "running"
    assert _wait(lambda: _listening(port))


def test_already_running_is_refused(project, supervisor):
    folder, _ = project
    s = supervisor()
    s.start(str(folder), "Procfile.dev:web")
    with pytest.raises(ValueError, match="already running"):
        s.start(str(folder), "Procfile.dev:web")


def test_crash_loop_gives_up(project, supervisor, monkeypatch):
    monkeypatch.setattr(sup, "CRASH_DELAY", 0.05)
    folder, _ = project
    s = supervisor()
    run = s.start(str(folder), "Procfile.dev:crash")
    assert _wait(lambda: run.status == "crashed")
    assert run.exit_code == 3 and not run.restarts

    s.set_restart_on_crash(run.id, True)
    run = s.start(str(folder), "Procfile.dev:crash")
    assert _wait(lambda: run.gave_up, timeout=8)
    assert run.status == "crashed" and len(run.restarts) == sup.CRASH_LIMIT


def test_reload_picks_up_running_servers(project, supervisor):
    folder, port = project
    first = supervisor()
    run = first.start(str(folder), "Procfile.dev:web")
    assert _wait(lambda: _listening(port))

    # A new bridge, as after the menu bar app restarts.
    second = supervisor()
    reloaded = second.runs[run.id]
    assert reloaded.status == "running" and second.run_for_pid(run.pid) == run.id
    second.stop(run.id)
    assert not _listening(port)
    first.runs.clear()


def test_reload_marks_runs_that_died_unwatched_as_exited(project, supervisor):
    folder, _ = project
    first = supervisor()
    dead = subprocess.Popen(["true"], start_new_session=True)
    dead.wait()
    run = sup.Run(id="x", project_root=str(folder), project_name="app", script_id="Procfile.dev:web", name="web",
                  command="true", cwd=str(folder), package="", log="", pid=dead.pid, status="running")
    first.runs[run.id] = run
    first._save()
    first.runs.clear()

    reloaded = supervisor().runs["x"]
    assert reloaded.status == "exited" and reloaded.exit_code is None


def test_port_held_by_another_process(project, supervisor, tmp_path):
    folder, port = project
    s = supervisor()
    run = s.start(str(folder), "Procfile.dev:web")
    assert _wait(lambda: _listening(port))
    s.poll([{"pid": run.pid, "ports": [port], "label": "http.server"}])
    assert s.runs[run.id].ports == [port]
    s.stop(run.id, forget=False)

    holder = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        assert _wait(lambda: _listening(port))
        servers = [{"pid": holder.pid, "ports": [port], "label": "http.server", "project_name": "other"}]
        with pytest.raises(PortConflict) as conflict:
            s.start(str(folder), "Procfile.dev:web", servers=servers)
        assert (conflict.value.port, conflict.value.pid) == (port, holder.pid)
        assert str(conflict.value) == f"Port {port} is held by PID {holder.pid} (http.server in other)"
    finally:
        holder.terminate()
        holder.wait()


def test_missing_folder_fails_without_a_phantom_run(project, supervisor, monkeypatch):
    folder, _ = project
    s = supervisor()
    # A workspace package runs in its own folder; one that was deleted can't start.
    gone = sup.runnable.Script(id="gone", name="gone", command="true", source="Procfile.dev", cwd=str(folder / "nope"))
    monkeypatch.setattr(sup.runnable, "find", lambda root, script_id: gone)
    with pytest.raises(ValueError, match="Could not start gone"):
        s.start(str(folder), "gone")
    assert not s.runs
