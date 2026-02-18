from __future__ import annotations

from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, Center
from textual.reactive import reactive
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Label,
    Static,
    TabbedContent,
    TabPane,
)

from devdash.processes import (
    DockerContainer,
    GeneralProcess,
    NodeProcess,
    SystemStats,
    get_all_processes,
    get_docker_containers,
    get_node_processes,
    get_system_stats,
    kill_node_process,
    kill_process,
    stop_docker_container,
)

REFRESH_INTERVAL = 3.0


def _bar(percent: float, width: int = 20) -> str:
    filled = int(percent / 100 * width)
    empty = width - filled
    return f"[{'|' * filled}{' ' * empty}] {percent:.1f}%"


class StatusBar(Static):
    message: reactive[str] = reactive("")

    def watch_message(self, value: str) -> None:
        self.update(value)


class DevDashApp(App):
    CSS = """
    Screen {
        layout: vertical;
    }

    .section-header {
        height: 1;
        background: grey;
        color: $text;
        padding: 0 1;
        text-style: bold;
    }

    .section-header.active {
        background: dodgerblue;
    }

    #node-table, #docker-table {
        height: 1fr;
        min-height: 5;
    }

    #all-procs-table {
        height: 1fr;
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

    #sys-stats {
        height: auto;
        max-height: 6;
        padding: 0 1;
        background: $surface;
    }

    .stat-row {
        height: 1;
        padding: 0 1;
    }

    .stat-label {
        width: 10;
        text-style: bold;
        color: $text-muted;
    }

    .stat-bar {
        width: 1fr;
    }

    #stats-grid {
        layout: grid;
        grid-size: 2 2;
        grid-gutter: 0 2;
        height: auto;
        padding: 0 1;
        background: $surface;
        margin-bottom: 1;
    }

    .stat-cell {
        height: 1;
    }
    """

    TITLE = "devdash"
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("k", "kill", "Kill/Stop"),
        Binding("tab", "focus_next_table", "Next Table", show=True),
        Binding("1", "tab_dev", "Dev Tab"),
        Binding("2", "tab_system", "System Tab"),
    ]

    node_procs: list[NodeProcess] = []
    docker_containers: list[DockerContainer] = []
    all_procs: list[GeneralProcess] = []
    system_stats: SystemStats | None = None
    _current_tab: str = "dev"
    _active_table_id: str = "node-table"

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(id="tabs"):
            with TabPane("[1] Dev", id="dev"):
                yield Static(" Node Processes", id="node-header", classes="section-header active")
                yield DataTable(id="node-table")
                yield Static(" Docker Containers", id="docker-header", classes="section-header")
                yield DataTable(id="docker-table")
            with TabPane("[2] System", id="system"):
                yield Static("", id="sys-stats")
                yield Static(" All Processes (by memory)", id="procs-header", classes="section-header active")
                yield DataTable(id="all-procs-table")
        yield StatusBar("Loading...", id="status-bar")
        yield Footer()

    def on_mount(self) -> None:
        node_table = self.query_one("#node-table", DataTable)
        node_table.cursor_type = "row"
        node_table.add_columns("PID", "Port(s)", "Memory", "CPU", "Uptime", "Directory", "Command")

        docker_table = self.query_one("#docker-table", DataTable)
        docker_table.cursor_type = "row"
        docker_table.add_columns("ID", "Name", "Image", "Status", "Ports", "Running For")

        all_table = self.query_one("#all-procs-table", DataTable)
        all_table.cursor_type = "row"
        all_table.add_columns("PID", "Name", "CPU %", "Memory", "Mem %", "User", "Status", "Command")

        self._highlight_active_table()
        self.load_data()
        self.set_interval(REFRESH_INTERVAL, self.load_data)

    def _highlight_active_table(self) -> None:
        table_header_map = {
            "node-table": "node-header",
            "docker-table": "docker-header",
            "all-procs-table": "procs-header",
        }
        for table_id, header_id in table_header_map.items():
            try:
                header = self.query_one(f"#{header_id}", Static)
                if table_id == self._active_table_id:
                    header.add_class("active")
                    header.styles.background = "dodgerblue"
                else:
                    header.remove_class("active")
                    header.styles.background = "grey"
            except Exception:
                pass

        try:
            self.query_one(f"#{self._active_table_id}", DataTable).focus()
        except Exception:
            pass

    def action_tab_dev(self) -> None:
        tabs = self.query_one("#tabs", TabbedContent)
        tabs.active = "dev"
        self._current_tab = "dev"
        self._active_table_id = "node-table"
        self._highlight_active_table()

    def action_tab_system(self) -> None:
        tabs = self.query_one("#tabs", TabbedContent)
        tabs.active = "system"
        self._current_tab = "system"
        self._active_table_id = "all-procs-table"
        self._highlight_active_table()

    def on_tabbed_content_tab_activated(self, event: TabbedContent.TabActivated) -> None:
        tab_id = event.pane.id or ""
        self._current_tab = tab_id
        if tab_id == "dev":
            self._active_table_id = "node-table"
        else:
            self._active_table_id = "all-procs-table"
        self._highlight_active_table()

    def action_focus_next_table(self) -> None:
        if self._current_tab == "dev":
            if self._active_table_id == "node-table":
                self._active_table_id = "docker-table"
            else:
                self._active_table_id = "node-table"
        self._highlight_active_table()

    @work(thread=True, exclusive=True, group="loader")
    def load_data(self) -> None:
        node_procs = get_node_processes()
        docker_containers = get_docker_containers()
        all_procs = get_all_processes()
        stats = get_system_stats()
        self.call_from_thread(self._update_all, node_procs, docker_containers, all_procs, stats)

    def _update_all(
        self,
        node_procs: list[NodeProcess],
        docker_containers: list[DockerContainer],
        all_procs: list[GeneralProcess],
        stats: SystemStats,
    ) -> None:
        self.node_procs = node_procs
        self.docker_containers = docker_containers
        self.all_procs = all_procs
        self.system_stats = stats

        self._update_dev_tables(node_procs, docker_containers)
        self._update_system_tab(all_procs, stats)

        status = self.query_one("#status-bar", StatusBar)
        cpu = f"CPU {stats.cpu_percent:.0f}%"
        mem = f"Mem {stats.memory_used_gb:.1f}/{stats.memory_total_gb:.1f}GB"
        disk = f"Disk {stats.disk_percent:.0f}%"
        status.message = f" {cpu} | {mem} | {disk} | {len(node_procs)} node | {len(docker_containers)} docker | 1/2=tabs r=refresh k=kill q=quit"

    def _update_dev_tables(
        self, node_procs: list[NodeProcess], docker_containers: list[DockerContainer]
    ) -> None:
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

        node_header = self.query_one("#node-header", Static)
        node_header.update(f" Node Processes ({len(node_procs)})")
        docker_header = self.query_one("#docker-header", Static)
        docker_header.update(f" Docker Containers ({len(docker_containers)})")

    def _update_system_tab(self, all_procs: list[GeneralProcess], stats: SystemStats) -> None:
        sys_widget = self.query_one("#sys-stats", Static)
        lines = [
            f"  CPU   {_bar(stats.cpu_percent, 30)}   ({stats.cpu_count} cores)",
            f"  Mem   {_bar(stats.memory_percent, 30)}   {stats.memory_used_gb:.1f} / {stats.memory_total_gb:.1f} GB",
            f"  Swap  {_bar(stats.swap_percent, 30)}   {stats.swap_used_gb:.1f} / {stats.swap_total_gb:.1f} GB",
            f"  Disk  {_bar(stats.disk_percent, 30)}   {stats.disk_used_gb:.0f} / {stats.disk_total_gb:.0f} GB  ({stats.disk_free_gb:.0f} GB free)",
        ]
        sys_widget.update("\n".join(lines))

        table = self.query_one("#all-procs-table", DataTable)
        cursor = table.cursor_row

        table.clear()
        for proc in all_procs:
            table.add_row(
                str(proc.pid),
                proc.name,
                f"{proc.cpu_percent:.1f}",
                f"{proc.memory_mb:.0f} MB",
                f"{proc.memory_percent:.1f}%",
                proc.user,
                proc.status,
                proc.command,
                key=str(proc.pid),
            )

        if all_procs and cursor is not None:
            try:
                table.move_cursor(row=min(cursor, len(all_procs) - 1))
            except Exception:
                pass

        procs_header = self.query_one("#procs-header", Static)
        procs_header.update(f" All Processes ({len(all_procs)}, by memory)")

    def action_refresh(self) -> None:
        status = self.query_one("#status-bar", StatusBar)
        status.message = " Refreshing..."
        self.load_data()

    def action_kill(self) -> None:
        if self._active_table_id == "node-table":
            self._kill_node()
        elif self._active_table_id == "docker-table":
            self._stop_docker()
        elif self._active_table_id == "all-procs-table":
            self._kill_general()

    def _kill_node(self) -> None:
        node_table = self.query_one("#node-table", DataTable)
        if not self.node_procs:
            return
        try:
            row_key, _ = node_table.coordinate_to_cell_key(node_table.cursor_coordinate)
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
            row_key, _ = docker_table.coordinate_to_cell_key(docker_table.cursor_coordinate)
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

    def _kill_general(self) -> None:
        table = self.query_one("#all-procs-table", DataTable)
        if not self.all_procs:
            return
        try:
            row_key, _ = table.coordinate_to_cell_key(table.cursor_coordinate)
            pid = int(row_key.value)
        except Exception:
            return

        proc = next((p for p in self.all_procs if p.pid == pid), None)
        if not proc:
            return

        self.push_screen(
            ConfirmScreen(f"Kill process '{proc.name}' (PID {pid}, {proc.memory_mb:.0f} MB)?"),
            callback=lambda confirmed: self._on_general_kill_confirmed(confirmed, pid, proc.name),
        )

    @work(thread=True)
    def _on_kill_confirmed(self, confirmed: bool, pid: int) -> None:
        if not confirmed:
            return
        status = self.query_one("#status-bar", StatusBar)
        self.call_from_thread(setattr, status, "message", f" Killing PID {pid}...")
        success = kill_node_process(pid)
        msg = f" Killed PID {pid}" if success else f" Failed to kill PID {pid}"
        self.call_from_thread(setattr, status, "message", msg)
        self.call_from_thread(self.load_data)

    @work(thread=True)
    def _on_stop_confirmed(self, confirmed: bool, container_id: str, name: str) -> None:
        if not confirmed:
            return
        status = self.query_one("#status-bar", StatusBar)
        self.call_from_thread(setattr, status, "message", f" Stopping '{name}'...")
        success = stop_docker_container(container_id)
        msg = f" Stopped '{name}'" if success else f" Failed to stop '{name}'"
        self.call_from_thread(setattr, status, "message", msg)
        self.call_from_thread(self.load_data)

    @work(thread=True)
    def _on_general_kill_confirmed(self, confirmed: bool, pid: int, name: str) -> None:
        if not confirmed:
            return
        status = self.query_one("#status-bar", StatusBar)
        self.call_from_thread(setattr, status, "message", f" Killing '{name}' (PID {pid})...")
        success = kill_process(pid)
        msg = f" Killed '{name}'" if success else f" Failed to kill '{name}'"
        self.call_from_thread(setattr, status, "message", msg)
        self.call_from_thread(self.load_data)


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
