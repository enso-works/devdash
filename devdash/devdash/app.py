from __future__ import annotations

from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.reactive import reactive
from textual.widgets import DataTable, Footer, Header, Static

from devdash.processes import (
    DockerContainer,
    NodeProcess,
    get_docker_containers,
    get_node_processes,
    kill_node_process,
    stop_docker_container,
)

REFRESH_INTERVAL = 3.0


class StatusBar(Static):
    message: reactive[str] = reactive("")

    def watch_message(self, value: str) -> None:
        self.update(value)


class DevDashApp(App):
    CSS = """
    Screen {
        layout: vertical;
    }

    #node-header {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        padding: 0 1;
        text-style: bold;
    }

    #docker-header {
        height: 1;
        background: $primary-darken-2;
        color: $text;
        padding: 0 1;
        text-style: bold;
        margin-top: 1;
    }

    #node-table {
        height: 1fr;
        min-height: 5;
    }

    #docker-table {
        height: 1fr;
        min-height: 5;
    }

    #status-bar {
        height: 1;
        background: $surface;
        color: $warning;
        padding: 0 1;
    }

    DataTable {
        height: 1fr;
    }

    DataTable > .datatable--cursor {
        background: $accent;
        color: $text;
    }
    """

    TITLE = "devdash"
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("k", "kill", "Kill/Stop"),
        Binding("tab", "switch_panel", "Switch Panel"),
    ]

    active_panel: reactive[str] = reactive("node")
    node_procs: list[NodeProcess] = []
    docker_containers: list[DockerContainer] = []

    def compose(self) -> ComposeResult:
        yield Header()
        with Vertical():
            yield Static(" Node Processes", id="node-header")
            yield DataTable(id="node-table")
            yield Static(" Docker Containers", id="docker-header")
            yield DataTable(id="docker-table")
        yield StatusBar("Loading...", id="status-bar")
        yield Footer()

    def on_mount(self) -> None:
        node_table = self.query_one("#node-table", DataTable)
        node_table.cursor_type = "row"
        node_table.add_columns("PID", "Port(s)", "Memory", "CPU", "Uptime", "Directory", "Command")

        docker_table = self.query_one("#docker-table", DataTable)
        docker_table.cursor_type = "row"
        docker_table.add_columns("ID", "Name", "Image", "Status", "Ports", "Running For")

        self._highlight_active_panel()
        self.load_data()
        self.set_interval(REFRESH_INTERVAL, self.load_data)

    def _highlight_active_panel(self) -> None:
        node_header = self.query_one("#node-header", Static)
        docker_header = self.query_one("#docker-header", Static)
        node_table = self.query_one("#node-table", DataTable)
        docker_table = self.query_one("#docker-table", DataTable)

        if self.active_panel == "node":
            node_header.styles.background = "dodgerblue"
            docker_header.styles.background = "grey"
            node_table.focus()
        else:
            node_header.styles.background = "grey"
            docker_header.styles.background = "dodgerblue"
            docker_table.focus()

    def watch_active_panel(self, value: str) -> None:
        try:
            self._highlight_active_panel()
        except Exception:
            pass

    def action_switch_panel(self) -> None:
        self.active_panel = "docker" if self.active_panel == "node" else "node"

    @work(thread=True, exclusive=True, group="loader")
    def load_data(self) -> None:
        node_procs = get_node_processes()
        docker_containers = get_docker_containers()
        self.call_from_thread(self._update_tables, node_procs, docker_containers)

    def _update_tables(
        self, node_procs: list[NodeProcess], docker_containers: list[DockerContainer]
    ) -> None:
        self.node_procs = node_procs
        self.docker_containers = docker_containers

        node_table = self.query_one("#node-table", DataTable)
        docker_table = self.query_one("#docker-table", DataTable)

        node_cursor = node_table.cursor_row
        docker_cursor = docker_table.cursor_row

        node_table.clear()
        for proc in node_procs:
            ports = ", ".join(str(p) for p in proc.ports) if proc.ports else "-"
            node_table.add_row(
                str(proc.pid),
                ports,
                f"{proc.memory_mb:.0f} MB",
                f"{proc.cpu_percent:.1f}%",
                proc.uptime,
                proc.cwd,
                proc.command,
                key=str(proc.pid),
            )

        docker_table.clear()
        for container in docker_containers:
            docker_table.add_row(
                container.container_id,
                container.name,
                container.image,
                container.status,
                container.ports or "-",
                container.created,
                key=container.container_id,
            )

        if node_procs and node_cursor is not None:
            try:
                node_table.move_cursor(row=min(node_cursor, len(node_procs) - 1))
            except Exception:
                pass
        if docker_containers and docker_cursor is not None:
            try:
                docker_table.move_cursor(row=min(docker_cursor, len(docker_containers) - 1))
            except Exception:
                pass

        status = self.query_one("#status-bar", StatusBar)
        status.message = f" {len(node_procs)} node process(es) | {len(docker_containers)} docker container(s) | r=refresh k=kill tab=switch q=quit"

        node_header = self.query_one("#node-header", Static)
        node_header.update(f" Node Processes ({len(node_procs)})")
        docker_header = self.query_one("#docker-header", Static)
        docker_header.update(f" Docker Containers ({len(docker_containers)})")

    def action_refresh(self) -> None:
        status = self.query_one("#status-bar", StatusBar)
        status.message = " Refreshing..."
        self.load_data()

    def action_kill(self) -> None:
        if self.active_panel == "node":
            self._kill_node()
        else:
            self._stop_docker()

    def _kill_node(self) -> None:
        node_table = self.query_one("#node-table", DataTable)
        if not self.node_procs:
            return

        try:
            row_key, _ = node_table.coordinate_to_cell_key(
                node_table.cursor_coordinate
            )
            pid = int(row_key.value)
        except Exception:
            return

        proc = next((p for p in self.node_procs if p.pid == pid), None)
        if not proc:
            return

        label = f"PID {pid}"
        if proc.ports:
            label += f" (port {', '.join(str(p) for p in proc.ports)})"

        self.push_screen(
            ConfirmScreen(f"Kill node process {label}?"),
            callback=lambda confirmed: self._on_kill_confirmed(confirmed, pid),
        )

    def _stop_docker(self) -> None:
        docker_table = self.query_one("#docker-table", DataTable)
        if not self.docker_containers:
            return

        try:
            row_key, _ = docker_table.coordinate_to_cell_key(
                docker_table.cursor_coordinate
            )
            container_id = row_key.value
        except Exception:
            return

        container = next(
            (c for c in self.docker_containers if c.container_id == container_id), None
        )
        if not container:
            return

        self.push_screen(
            ConfirmScreen(f"Stop container '{container.name}' ({container.image})?"),
            callback=lambda confirmed: self._on_stop_confirmed(confirmed, container_id, container.name),
        )

    @work(thread=True)
    def _on_kill_confirmed(self, confirmed: bool, pid: int) -> None:
        if not confirmed:
            return
        status = self.query_one("#status-bar", StatusBar)
        self.call_from_thread(setattr, status, "message", f" Killing PID {pid}...")
        success = kill_node_process(pid)
        if success:
            self.call_from_thread(setattr, status, "message", f" Killed PID {pid}")
        else:
            self.call_from_thread(setattr, status, "message", f" Failed to kill PID {pid}")
        self.call_from_thread(self.load_data)

    @work(thread=True)
    def _on_stop_confirmed(self, confirmed: bool, container_id: str, name: str) -> None:
        if not confirmed:
            return
        status = self.query_one("#status-bar", StatusBar)
        self.call_from_thread(setattr, status, "message", f" Stopping '{name}'...")
        success = stop_docker_container(container_id)
        if success:
            self.call_from_thread(setattr, status, "message", f" Stopped '{name}'")
        else:
            self.call_from_thread(setattr, status, "message", f" Failed to stop '{name}'")
        self.call_from_thread(self.load_data)


from textual.screen import ModalScreen
from textual.widgets import Button, Label
from textual.containers import Horizontal, Center


class ConfirmScreen(ModalScreen[bool]):
    CSS = """
    ConfirmScreen {
        align: center middle;
    }

    #confirm-dialog {
        width: 60;
        height: auto;
        max-height: 12;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #confirm-label {
        width: 100%;
        text-align: center;
        margin-bottom: 1;
    }

    #confirm-buttons {
        width: 100%;
        align: center middle;
        height: 3;
    }

    #confirm-buttons Button {
        margin: 0 2;
    }
    """

    BINDINGS = [
        Binding("y", "confirm", "Yes", show=False),
        Binding("n", "cancel", "No", show=False),
        Binding("escape", "cancel", "Cancel", show=False),
    ]

    def __init__(self, message: str) -> None:
        super().__init__()
        self._message = message

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-dialog"):
            yield Label(self._message, id="confirm-label")
            with Center():
                with Horizontal(id="confirm-buttons"):
                    yield Button("[y] Yes", variant="error", id="yes-btn")
                    yield Button("[n] No", variant="default", id="no-btn")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes-btn")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)
