from __future__ import annotations

from rich.text import Text
from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.command import Hit, Hits, Provider
from textual.containers import Horizontal
from textual.reactive import reactive
from textual.widgets import (
    DataTable,
    Footer,
    Header,
    Input,
    Static,
    TabbedContent,
    TabPane,
)

from devdash.config import Config
from devdash.screens import (
    ConfirmScreen,
    ClaudeProjectDetailScreen,
    LaunchMenuScreen,
    LogViewerScreen,
    ProcessDetailScreen,
    SessionBrowserScreen,
)
from devdash.processes import (
    ClaudeInstance,
    ClaudeProject,
    ClaudeStats,
    DockerContainer,
    GeneralProcess,
    NodeProcess,
    SystemStats,
    _format_bytes_rate,
    get_all_processes,
    get_claude_instances,
    get_claude_projects,
    get_claude_stats,
    get_docker_containers,
    get_node_processes,
    get_system_stats,
    kill_node_process,
    kill_process,
    stop_docker_container,
)

import dataclasses
import json
import re
import shlex
import shutil
import threading
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

_color_low = 50.0
_color_high = 80.0


def _shell_quote(path: str) -> str:
    return shlex.quote(path)


def _severity_style(percent: float) -> str:
    if percent < _color_low:
        return "green"
    if percent < _color_high:
        return "yellow"
    return "red"


def _colored_percent(value: float, suffix: str = "%") -> Text:
    style = _severity_style(value)
    return Text(f"{value:.1f}{suffix}", style=style)


def _colored_memory(mb: float) -> Text:
    percent = min(mb / 1024 * 100, 100)
    style = _severity_style(percent)
    return Text(f"{mb:.0f} MB", style=style)


def _colored_bar(percent: float, width: int = 30) -> Text:
    filled = int(percent / 100 * width)
    empty = width - filled
    style = _severity_style(percent)
    bar_str = f"[{'|' * filled}{' ' * empty}] {percent:.1f}%"
    return Text(bar_str, style=style)


class StatusBar(Static):
    message: reactive[str] = reactive("")

    def watch_message(self, value: str) -> None:
        self.update(value)


class DevDashCommands(Provider):
    def _get_commands(self) -> list[tuple[str, str, str]]:
        cmds = [
            ("Refresh data", "Reload all process and system data", "action_refresh"),
            ("Switch to Dev tab", "Show node processes and docker containers", "action_tab_dev"),
            ("Switch to System tab", "Show all processes and system stats", "action_tab_system"),
            ("Toggle filter", "Show/hide the process filter bar", "action_toggle_filter"),
            ("Kill/Stop selected", "Kill the selected process or stop container", "action_kill"),
            ("View logs", "View Docker container logs", "action_logs"),
            ("Process details", "View detailed process information", "action_details"),
            ("Export snapshot", "Export current data to JSON", "action_export"),
            ("Toggle selection", "Select/deselect current row", "action_toggle_select"),
            ("Quit", "Exit devdash", "action_quit"),
        ]
        app = self.app
        if isinstance(app, DevDashApp) and app._has_claude:
            cmds.extend([
                ("Switch to Claude tab", "Show Claude Code instances and projects", "action_tab_claude"),
                ("Launch menu", "Open launch menu for selected project", "action_launch_or_details"),
                ("Session browser", "Browse sessions for selected project", "action_session_browser"),
            ])
        return cmds

    def _make_callback(self, action: str):
        def callback() -> None:
            method = getattr(self.app, action, None)
            if method:
                method()
        return callback

    async def search(self, query: str) -> Hits:
        matcher = self.matcher(query)
        for name, help_text, action in self._get_commands():
            score = matcher.match(name)
            if score > 0:
                yield Hit(
                    score,
                    matcher.highlight(name),
                    self._make_callback(action),
                    help=help_text,
                )

    async def discover(self) -> Hits:
        for name, help_text, action in self._get_commands():
            yield Hit(0, name, self._make_callback(action), help=help_text)


class DevDashApp(App):
    COMMANDS = {DevDashCommands}

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

    #node-table, #docker-table, #claude-instances-table, #claude-projects-table {
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
        max-height: 7;
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

    #filter-bar {
        height: auto;
        display: none;
        padding: 0 1;
        background: $surface;
    }

    #filter-bar.visible {
        display: block;
    }

    #filter-input {
        width: 100%;
    }

    #claude-stats-bar {
        height: auto;
        max-height: 4;
        padding: 0 1;
        background: $surface;
        color: $text-muted;
    }
    """

    TITLE = "devdash"
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("k", "kill", "Kill/Stop"),
        Binding("space", "toggle_select", "Select", show=True),
        Binding("l", "logs", "Logs"),
        Binding("d", "details", "Details"),
        Binding("e", "export", "Export"),
        Binding("slash", "toggle_filter", "Filter", show=True),
        Binding("tab", "focus_next_table", "Next Table", show=True),
        Binding("1", "tab_dev", "Dev Tab"),
        Binding("2", "tab_system", "System Tab"),
        Binding("3", "tab_claude", "Claude Tab"),
        Binding("enter", "launch_or_details", "Open", show=False, priority=False),
        Binding("s", "session_browser", "Sessions", show=False),
    ]

    node_procs: list[NodeProcess] = []
    docker_containers: list[DockerContainer] = []
    all_procs: list[GeneralProcess] = []
    system_stats: SystemStats | None = None
    claude_instances: list[ClaudeInstance] = []
    claude_projects: list[ClaudeProject] = []
    claude_stats: ClaudeStats | None = None
    _current_tab: str = "dev"
    _active_table_id: str = "node-table"
    _sort_state: dict[str, tuple[int, bool]] = {}  # table_id -> (col_index, reverse)
    _filter_text: str = ""
    _prev_node_pids: set[int] = set()
    _prev_node_ports: dict[int, list[int]] = {}
    _prev_docker_ids: set[str] = set()
    _tracking_initialized: bool = False
    _selected_pids: set[int] = set()
    _selected_containers: set[str] = set()

    def __init__(
        self,
        config: Config | None = None,
        update_check_event: threading.Event | None = None,
        get_update_message: Callable[[], str | None] | None = None,
    ) -> None:
        super().__init__()
        self._config = config or Config()
        self._update_check_event = update_check_event
        self._get_update_message = get_update_message
        self._has_claude = (
            shutil.which("claude") is not None
            or (Path.home() / ".claude").is_dir()
        )
        global _color_low, _color_high
        _color_low = self._config.color_threshold_low
        _color_high = self._config.color_threshold_high

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="filter-bar"):
            yield Input(placeholder="Filter processes... (Esc to close)", id="filter-input")
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
            if self._has_claude:
                with TabPane("[3] Claude", id="claude"):
                    yield Static("", id="claude-stats-bar")
                    yield Static(" Running Instances", id="claude-instances-header", classes="section-header active")
                    yield DataTable(id="claude-instances-table")
                    yield Static(" Projects", id="claude-projects-header", classes="section-header")
                    yield DataTable(id="claude-projects-table")
        yield StatusBar("Loading...", id="status-bar")
        yield Footer()

    def on_mount(self) -> None:
        node_table = self.query_one("#node-table", DataTable)
        node_table.cursor_type = "row"
        node_table.add_columns("PID", "Project", "Port(s)", "Memory", "CPU", "Uptime", "Directory", "Command")

        docker_table = self.query_one("#docker-table", DataTable)
        docker_table.cursor_type = "row"
        docker_table.add_columns("ID", "Name", "Image", "Status", "Ports", "Running For", "Compose", "Service")

        all_table = self.query_one("#all-procs-table", DataTable)
        all_table.cursor_type = "row"
        all_table.add_columns("PID", "Name", "CPU %", "Memory", "Mem %", "User", "Status", "Command")

        if self._has_claude:
            claude_inst_table = self.query_one("#claude-instances-table", DataTable)
            claude_inst_table.cursor_type = "row"
            claude_inst_table.add_columns("PID", "Project", "TTY", "Memory", "CPU", "Uptime", "Directory")

            claude_proj_table = self.query_one("#claude-projects-table", DataTable)
            claude_proj_table.cursor_type = "row"
            claude_proj_table.add_columns("Project", "Sessions", "Messages", "Last Active", "Status", "Path")

        self._highlight_active_table()
        self.load_data()
        self.set_interval(self._config.refresh_rate, self.load_data)

        if self._update_check_event is not None:
            self.set_timer(2, self._schedule_update_check)

    def _schedule_update_check(self) -> None:
        self._show_update_notification()

    @work(thread=True)
    def _show_update_notification(self) -> None:
        if self._update_check_event is None:
            return
        self._update_check_event.wait(timeout=8)
        if self._get_update_message is not None:
            msg = self._get_update_message()
            if msg:
                self.call_from_thread(self.notify, msg, severity="information", timeout=8)

    def _highlight_active_table(self) -> None:
        table_header_map = {
            "node-table": "node-header",
            "docker-table": "docker-header",
            "all-procs-table": "procs-header",
            "claude-instances-table": "claude-instances-header",
            "claude-projects-table": "claude-projects-header",
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

    def action_tab_claude(self) -> None:
        if not self._has_claude:
            return
        tabs = self.query_one("#tabs", TabbedContent)
        tabs.active = "claude"
        self._current_tab = "claude"
        self._active_table_id = "claude-instances-table"
        self._highlight_active_table()

    def on_tabbed_content_tab_activated(self, event: TabbedContent.TabActivated) -> None:
        tab_id = event.pane.id or ""
        self._current_tab = tab_id
        if tab_id == "dev":
            self._active_table_id = "node-table"
        elif tab_id == "claude":
            self._active_table_id = "claude-instances-table"
        else:
            self._active_table_id = "all-procs-table"
        self._highlight_active_table()

    def action_focus_next_table(self) -> None:
        if self._current_tab == "dev":
            if self._active_table_id == "node-table":
                self._active_table_id = "docker-table"
            else:
                self._active_table_id = "node-table"
        elif self._current_tab == "claude":
            if self._active_table_id == "claude-instances-table":
                self._active_table_id = "claude-projects-table"
            else:
                self._active_table_id = "claude-instances-table"
        self._highlight_active_table()

    def action_toggle_filter(self) -> None:
        bar = self.query_one("#filter-bar", Horizontal)
        inp = self.query_one("#filter-input", Input)
        if bar.has_class("visible"):
            bar.remove_class("visible")
            self._filter_text = ""
            inp.value = ""
            try:
                self.query_one(f"#{self._active_table_id}", DataTable).focus()
            except Exception:
                pass
            self.load_data()
        else:
            bar.add_class("visible")
            inp.focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "filter-input":
            self._filter_text = event.value
            self._apply_filter_to_all_tables()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "filter-input":
            try:
                self.query_one(f"#{self._active_table_id}", DataTable).focus()
            except Exception:
                pass

    def key_escape(self) -> None:
        bar = self.query_one("#filter-bar", Horizontal)
        if bar.has_class("visible"):
            self.action_toggle_filter()

    def _row_matches_filter(self, cells: list) -> bool:
        if not self._filter_text:
            return True
        query = self._filter_text.lower()
        for cell in cells:
            text = cell.plain if isinstance(cell, Text) else str(cell)
            if query in text.lower():
                return True
        return False

    def _apply_filter_to_all_tables(self) -> None:
        if self.node_procs:
            self._update_dev_tables(self.node_procs, self.docker_containers)
        if self.all_procs and self.system_stats:
            self._update_system_tab(self.all_procs, self.system_stats)
        if self._has_claude:
            self._update_claude_tab(self.claude_instances, self.claude_projects)

    @staticmethod
    def _parse_sort_value(cell: object) -> object:
        text = cell.plain if isinstance(cell, Text) else str(cell)
        text = text.strip().rstrip("%")
        match = re.match(r"^([\d.]+)", text)
        if match:
            try:
                return float(match.group(1))
            except ValueError:
                pass
        return text.lower()

    def on_data_table_header_selected(self, event: DataTable.HeaderSelected) -> None:
        table = event.data_table
        table_id = table.id or ""
        col_index = event.column_index
        prev = self._sort_state.get(table_id)
        if prev and prev[0] == col_index:
            reverse = not prev[1]
        else:
            reverse = False
        self._sort_state[table_id] = (col_index, reverse)
        self._sort_table(table, col_index, reverse)

    def _sort_table(self, table: DataTable, col_index: int, reverse: bool) -> None:
        rows = []
        for row_key in table.rows:
            cells = [table.get_cell(row_key, col) for col in table.columns]
            rows.append((row_key, cells))
        rows.sort(key=lambda r: self._parse_sort_value(r[1][col_index]), reverse=reverse)
        cursor_key = None
        try:
            cursor_key, _ = table.coordinate_to_cell_key(table.cursor_coordinate)
        except Exception:
            pass
        table.clear()
        for row_key, cells in rows:
            table.add_row(*cells, key=row_key.value)
        if cursor_key:
            try:
                row_idx = next(i for i, (rk, _) in enumerate(rows) if rk.value == cursor_key.value)
                table.move_cursor(row=row_idx)
            except (StopIteration, Exception):
                pass

    def _apply_sort(self, table_id: str) -> None:
        sort = self._sort_state.get(table_id)
        if sort:
            try:
                table = self.query_one(f"#{table_id}", DataTable)
                self._sort_table(table, sort[0], sort[1])
            except Exception:
                pass

    @work(thread=True, exclusive=True, group="loader")
    def load_data(self) -> None:
        node_procs = get_node_processes()
        docker_containers = get_docker_containers()
        all_procs = get_all_processes(limit=self._config.process_limit)
        stats = get_system_stats()
        claude_instances = None
        claude_projects = None
        claude_stats = None
        if self._has_claude:
            claude_instances = get_claude_instances()
            claude_projects = get_claude_projects()
            claude_stats = get_claude_stats()
        self.call_from_thread(self._update_all, node_procs, docker_containers, all_procs, stats, claude_instances, claude_projects, claude_stats)

    def _update_all(
        self,
        node_procs: list[NodeProcess],
        docker_containers: list[DockerContainer],
        all_procs: list[GeneralProcess],
        stats: SystemStats,
        claude_instances: list[ClaudeInstance] | None = None,
        claude_projects: list[ClaudeProject] | None = None,
        claude_stats: ClaudeStats | None = None,
    ) -> None:
        self._check_notifications(node_procs, docker_containers)

        self.node_procs = node_procs
        self.docker_containers = docker_containers
        self.all_procs = all_procs
        self.system_stats = stats
        if claude_instances is not None:
            self.claude_instances = claude_instances
        if claude_projects is not None:
            self.claude_projects = claude_projects
        if claude_stats is not None:
            self.claude_stats = claude_stats

        self._update_dev_tables(node_procs, docker_containers)
        self._update_system_tab(all_procs, stats)
        if self._has_claude:
            self._update_claude_tab(self.claude_instances, self.claude_projects)
            self._update_claude_stats_bar(self.claude_stats)

        status = self.query_one("#status-bar", StatusBar)
        cpu = f"CPU {stats.cpu_percent:.0f}%"
        mem = f"Mem {stats.memory_used_gb:.1f}/{stats.memory_total_gb:.1f}GB"
        disk = f"Disk {stats.disk_percent:.0f}%"
        parts = f" {cpu} | {mem} | {disk} | {len(node_procs)} node | {len(docker_containers)} docker"
        if self._has_claude:
            parts += f" | {len(self.claude_instances)} claude"
        tabs_hint = "1/2/3=tabs" if self._has_claude else "1/2=tabs"
        status.message = f"{parts} | {tabs_hint} q=quit"

    def _check_notifications(
        self,
        node_procs: list[NodeProcess],
        docker_containers: list[DockerContainer],
    ) -> None:
        current_pids = {p.pid for p in node_procs}
        current_docker_ids = {c.container_id for c in docker_containers}
        current_ports = {p.pid: p.ports for p in node_procs}

        if not self._tracking_initialized:
            self._prev_node_pids = current_pids
            self._prev_node_ports = current_ports
            self._prev_docker_ids = current_docker_ids
            self._tracking_initialized = True
            return

        vanished_pids = self._prev_node_pids - current_pids
        for pid in vanished_pids:
            ports = self._prev_node_ports.get(pid, [])
            port_str = f" (port {', '.join(str(p) for p in ports)})" if ports else ""
            self.notify(f"Node process PID {pid}{port_str} exited", severity="warning", timeout=5)

        vanished_containers = self._prev_docker_ids - current_docker_ids
        for cid in vanished_containers:
            self.notify(f"Docker container {cid[:12]} stopped", severity="warning", timeout=5)

        for proc in node_procs:
            if proc.pid not in self._prev_node_pids and proc.ports:
                port_str = ", ".join(str(p) for p in proc.ports)
                self.notify(f"New node process PID {proc.pid} on port {port_str}", severity="information", timeout=5)
            elif self._config.watched_ports and proc.ports:
                for port in proc.ports:
                    if port in self._config.watched_ports:
                        prev_ports = self._prev_node_ports.get(proc.pid, [])
                        if port not in prev_ports:
                            self.notify(f"Watched port {port} active (PID {proc.pid})", severity="information", timeout=5)

        self._prev_node_pids = current_pids
        self._prev_node_ports = current_ports
        self._prev_docker_ids = current_docker_ids

    def _update_dev_tables(
        self, node_procs: list[NodeProcess], docker_containers: list[DockerContainer]
    ) -> None:
        node_table = self.query_one("#node-table", DataTable)
        docker_table = self.query_one("#docker-table", DataTable)

        node_cursor = node_table.cursor_row
        docker_cursor = docker_table.cursor_row

        node_table.clear()
        node_count = 0
        for proc in node_procs:
            ports = ", ".join(str(p) for p in proc.ports) if proc.ports else "-"
            cells = [
                str(proc.pid),
                proc.project or "-",
                ports,
                _colored_memory(proc.memory_mb),
                _colored_percent(proc.cpu_percent),
                proc.uptime,
                proc.cwd,
                proc.command,
            ]
            if self._row_matches_filter(cells):
                node_table.add_row(*cells, key=str(proc.pid))
                node_count += 1

        docker_table.clear()
        docker_count = 0
        for container in docker_containers:
            cells = [
                container.container_id,
                container.name,
                container.image,
                container.status,
                container.ports or "-",
                container.created,
                container.compose_project or "-",
                container.compose_service or "-",
            ]
            if self._row_matches_filter(cells):
                docker_table.add_row(*cells, key=container.container_id)
                docker_count += 1

        if node_count and node_cursor is not None:
            try:
                node_table.move_cursor(row=min(node_cursor, node_count - 1))
            except Exception:
                pass
        if docker_count and docker_cursor is not None:
            try:
                docker_table.move_cursor(row=min(docker_cursor, docker_count - 1))
            except Exception:
                pass

        self._apply_sort("node-table")
        self._apply_sort("docker-table")

        node_header = self.query_one("#node-header", Static)
        node_header.update(f" Node Processes ({len(node_procs)})")
        docker_header = self.query_one("#docker-header", Static)
        docker_header.update(f" Docker Containers ({len(docker_containers)})")

    def _update_system_tab(self, all_procs: list[GeneralProcess], stats: SystemStats) -> None:
        sys_widget = self.query_one("#sys-stats", Static)
        output = Text()
        output.append("  CPU   ")
        output.append_text(_colored_bar(stats.cpu_percent))
        output.append(f"   ({stats.cpu_count} cores)\n")
        output.append("  Mem   ")
        output.append_text(_colored_bar(stats.memory_percent))
        output.append(f"   {stats.memory_used_gb:.1f} / {stats.memory_total_gb:.1f} GB\n")
        output.append("  Swap  ")
        output.append_text(_colored_bar(stats.swap_percent))
        output.append(f"   {stats.swap_used_gb:.1f} / {stats.swap_total_gb:.1f} GB\n")
        output.append("  Disk  ")
        output.append_text(_colored_bar(stats.disk_percent))
        output.append(f"   {stats.disk_used_gb:.0f} / {stats.disk_total_gb:.0f} GB  ({stats.disk_free_gb:.0f} GB free)\n")
        if stats.net_sent_per_sec is not None and stats.net_recv_per_sec is not None:
            up = _format_bytes_rate(stats.net_sent_per_sec)
            down = _format_bytes_rate(stats.net_recv_per_sec)
            output.append(f"  Net   Up: {up}  Down: {down}")
        else:
            output.append("  Net   N/A")
        sys_widget.update(output)

        table = self.query_one("#all-procs-table", DataTable)
        cursor = table.cursor_row

        table.clear()
        proc_count = 0
        for proc in all_procs:
            cells = [
                str(proc.pid),
                proc.name,
                _colored_percent(proc.cpu_percent),
                _colored_memory(proc.memory_mb),
                _colored_percent(proc.memory_percent),
                proc.user,
                proc.status,
                proc.command,
            ]
            if self._row_matches_filter(cells):
                table.add_row(*cells, key=str(proc.pid))
                proc_count += 1

        if proc_count and cursor is not None:
            try:
                table.move_cursor(row=min(cursor, proc_count - 1))
            except Exception:
                pass

        self._apply_sort("all-procs-table")

        procs_header = self.query_one("#procs-header", Static)
        procs_header.update(f" All Processes ({proc_count}, by memory)")

    def _update_claude_tab(
        self, claude_instances: list[ClaudeInstance], claude_projects: list[ClaudeProject]
    ) -> None:
        inst_table = self.query_one("#claude-instances-table", DataTable)
        proj_table = self.query_one("#claude-projects-table", DataTable)

        inst_cursor = inst_table.cursor_row
        proj_cursor = proj_table.cursor_row

        inst_table.clear()
        inst_count = 0
        for inst in claude_instances:
            cells = [
                str(inst.pid),
                inst.project or "-",
                inst.tty,
                _colored_memory(inst.memory_mb),
                _colored_percent(inst.cpu_percent),
                inst.uptime,
                inst.cwd,
            ]
            if self._row_matches_filter(cells):
                inst_table.add_row(*cells, key=str(inst.pid))
                inst_count += 1

        proj_table.clear()
        proj_count = 0
        for proj in claude_projects:
            status = Text("running", style="bold green") if proj.is_running else Text("-", style="dim")
            cells = [
                proj.name,
                str(proj.sessions),
                str(proj.messages),
                proj.last_active,
                status,
                proj.path,
            ]
            if self._row_matches_filter(cells):
                proj_table.add_row(*cells, key=proj.path)
                proj_count += 1

        if inst_count and inst_cursor is not None:
            try:
                inst_table.move_cursor(row=min(inst_cursor, inst_count - 1))
            except Exception:
                pass
        if proj_count and proj_cursor is not None:
            try:
                proj_table.move_cursor(row=min(proj_cursor, proj_count - 1))
            except Exception:
                pass

        self._apply_sort("claude-instances-table")
        self._apply_sort("claude-projects-table")

        inst_header = self.query_one("#claude-instances-header", Static)
        inst_header.update(f" Running Instances ({inst_count})")
        proj_header = self.query_one("#claude-projects-header", Static)
        proj_header.update(f" Projects ({proj_count})")

    def _get_claude_selected_path(self) -> str | None:
        if self._current_tab != "claude":
            return None
        table_id = self._active_table_id
        table = self.query_one(f"#{table_id}", DataTable)
        try:
            row_key, _ = table.coordinate_to_cell_key(table.cursor_coordinate)
        except Exception:
            return None

        if table_id == "claude-projects-table":
            return row_key.value
        elif table_id == "claude-instances-table":
            try:
                pid = int(row_key.value)
            except ValueError:
                return None
            inst = next((i for i in self.claude_instances if i.pid == pid), None)
            if not inst:
                return None
            path = inst.cwd
            if path.startswith("~"):
                path = str(Path.home()) + path[1:]
            return path
        return None

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        table_id = event.data_table.id or ""
        if table_id == "claude-projects-table":
            path = event.row_key.value
            if path:
                self._open_launch_menu(path)
        elif table_id == "claude-instances-table":
            try:
                pid = int(event.row_key.value)
            except ValueError:
                return
            inst = next((i for i in self.claude_instances if i.pid == pid), None)
            if not inst:
                return
            path = inst.cwd
            if path.startswith("~"):
                path = str(Path.home()) + path[1:]
            self._open_launch_menu(path)

    def action_launch_or_details(self) -> None:
        if self._current_tab == "claude":
            path = self._get_claude_selected_path()
            if path:
                self._open_launch_menu(path)
        else:
            self.action_details()

    def _open_launch_menu(self, path: str) -> None:
        name = Path(path).name
        self.push_screen(
            LaunchMenuScreen(name),
            callback=lambda action: self._on_launch_menu_selected(action, path),
        )

    def _on_launch_menu_selected(self, action: str | None, path: str) -> None:
        if not action:
            return
        import subprocess as sp
        name = Path(path).name

        if action == "vscode":
            try:
                sp.Popen(["code", path])
                self.notify(f"Opening {name} in VS Code", timeout=3)
            except Exception as e:
                self.notify(f"Failed: {e}", severity="error", timeout=5)
            return

        if action == "finder":
            try:
                sp.Popen(["open", path])
                self.notify(f"Opening {name} in Finder", timeout=3)
            except Exception as e:
                self.notify(f"Failed: {e}", severity="error", timeout=5)
            return

        cmd_map = {
            "new": "claude",
            "new_skip_perms": "claude --dangerously-skip-permissions",
            "new_plan": "claude --permission-mode plan",
            "continue_session": "claude --continue",
            "resume": "claude --resume",
        }
        cmd = cmd_map.get(action)
        if not cmd:
            return
        script = f'cd {_shell_quote(path)} && {cmd}'
        try:
            sp.Popen(["osascript", "-e",
                f'tell application "Terminal" to do script "{script}"'])
            self.notify(f"{cmd} in {name}", timeout=3)
        except Exception as e:
            self.notify(f"Failed: {e}", severity="error", timeout=5)

    def action_session_browser(self) -> None:
        if self._current_tab != "claude" or self._active_table_id != "claude-projects-table":
            return
        path = self._get_claude_selected_path()
        if not path:
            return
        name = Path(path).name
        self.push_screen(
            SessionBrowserScreen(path, name),
            callback=lambda session_id: self._on_session_selected(session_id, path),
        )

    def _on_session_selected(self, session_id: str | None, path: str) -> None:
        if not session_id:
            return
        import subprocess as sp
        name = Path(path).name
        script = f'cd {_shell_quote(path)} && claude --resume {session_id}'
        try:
            sp.Popen(["osascript", "-e",
                f'tell application "Terminal" to do script "{script}"'])
            self.notify(f"Resuming session in {name}", timeout=3)
        except Exception as e:
            self.notify(f"Failed: {e}", severity="error", timeout=5)

    def action_refresh(self) -> None:
        status = self.query_one("#status-bar", StatusBar)
        status.message = " Refreshing..."
        self.load_data()

    @staticmethod
    def _build_sparkline(values: list[int], width: int | None = None) -> str:
        blocks = " \u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"
        if not values:
            return ""
        if width and len(values) < width:
            values = [0] * (width - len(values)) + values
        max_val = max(values) if values else 1
        if max_val == 0:
            return blocks[0] * len(values)
        return "".join(
            blocks[min(int(v / max_val * 7) + (1 if v > 0 else 0), 8)]
            for v in values
        )

    @staticmethod
    def _build_hour_bar(hour_counts: dict[int, int]) -> str:
        blocks = " \u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"
        values = [hour_counts.get(h, 0) for h in range(24)]
        max_val = max(values) if values else 1
        if max_val == 0:
            return blocks[0] * 24
        return "".join(
            blocks[min(int(v / max_val * 7) + (1 if v > 0 else 0), 8)]
            for v in values
        )

    def _format_tokens(self, n: int) -> str:
        if n >= 1_000_000:
            return f"{n / 1_000_000:.1f}M"
        if n >= 1_000:
            return f"{n / 1_000:.0f}k"
        return str(n)

    def _update_claude_stats_bar(self, stats: ClaudeStats | None) -> None:
        bar = self.query_one("#claude-stats-bar", Static)
        if not stats:
            bar.update("")
            return

        total_tokens = sum(
            inp + out + cache for inp, out, cache in stats.model_usage.values()
        )
        line1 = (
            f"  Sessions: {stats.total_sessions}  "
            f"Messages: {stats.total_messages}  "
            f"Tokens: {self._format_tokens(total_tokens)}"
        )

        model_parts = []
        for model, (inp, out, cache) in sorted(
            stats.model_usage.items(),
            key=lambda x: sum(x[1]),
            reverse=True,
        ):
            short_name = model.replace("claude-", "")
            total = inp + out + cache
            model_parts.append(f"{short_name}: {self._format_tokens(total)}")
        line2 = "  " + "  ".join(model_parts) if model_parts else ""

        daily_values = [count for _, count in stats.daily_activity]
        sparkline = self._build_sparkline(daily_values, width=14)
        hour_bar = self._build_hour_bar(stats.hour_counts)
        line3 = f"  14d activity: {sparkline}   Hour (0-23): {hour_bar}"

        bar.update(f"{line1}\n{line2}\n{line3}")

    def action_toggle_select(self) -> None:
        table = self.query_one(f"#{self._active_table_id}", DataTable)
        try:
            row_key, _ = table.coordinate_to_cell_key(table.cursor_coordinate)
        except Exception:
            return
        key = row_key.value
        if self._active_table_id == "docker-table":
            if key in self._selected_containers:
                self._selected_containers.discard(key)
            else:
                self._selected_containers.add(key)
        else:
            try:
                pid = int(key)
            except ValueError:
                return
            if pid in self._selected_pids:
                self._selected_pids.discard(pid)
            else:
                self._selected_pids.add(pid)
        self._refresh_selection_display()

    def _refresh_selection_display(self) -> None:
        for table_id, selected, is_pid in [
            ("node-table", self._selected_pids, True),
            ("all-procs-table", self._selected_pids, True),
            ("docker-table", self._selected_containers, False),
        ]:
            try:
                table = self.query_one(f"#{table_id}", DataTable)
            except Exception:
                continue
            for row_key in table.rows:
                key_val = row_key.value
                match = (int(key_val) in selected) if is_pid else (key_val in selected)
                try:
                    first_col = list(table.columns.keys())[0]
                    cell = table.get_cell(row_key, first_col)
                    text = cell.plain if isinstance(cell, Text) else str(cell)
                    if match and not text.startswith("*"):
                        table.update_cell(row_key, first_col, Text(f"* {text}", style="bold cyan"))
                    elif not match and text.startswith("* "):
                        table.update_cell(row_key, first_col, text[2:])
                except Exception:
                    pass

    def action_kill(self) -> None:
        has_selected = bool(self._selected_pids) or bool(self._selected_containers)
        if has_selected:
            self._batch_kill()
            return
        if self._active_table_id == "node-table":
            self._kill_node()
        elif self._active_table_id == "docker-table":
            self._stop_docker()
        elif self._active_table_id == "all-procs-table":
            self._kill_general()

    def _batch_kill(self) -> None:
        items = []
        if self._selected_pids:
            items.append(f"{len(self._selected_pids)} process(es)")
        if self._selected_containers:
            items.append(f"{len(self._selected_containers)} container(s)")
        msg = f"Kill/stop {', '.join(items)}?"
        self.push_screen(
            ConfirmScreen(msg),
            callback=self._on_batch_kill_confirmed,
        )

    @work(thread=True)
    def _on_batch_kill_confirmed(self, confirmed: bool) -> None:
        if not confirmed:
            return
        status = self.query_one("#status-bar", StatusBar)
        killed = 0
        for pid in list(self._selected_pids):
            self.call_from_thread(setattr, status, "message", f" Killing PID {pid}...")
            if kill_process(pid):
                killed += 1
        stopped = 0
        for cid in list(self._selected_containers):
            self.call_from_thread(setattr, status, "message", f" Stopping container {cid[:12]}...")
            if stop_docker_container(cid):
                stopped += 1
        self.call_from_thread(setattr, status, "message", f" Killed {killed} process(es), stopped {stopped} container(s)")
        self._selected_pids.clear()
        self._selected_containers.clear()
        self.call_from_thread(self.load_data)

    def action_logs(self) -> None:
        if self._active_table_id != "docker-table":
            self.notify("Select a Docker container first", severity="warning")
            return
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
        if container:
            self.push_screen(LogViewerScreen(container_id, container.name))

    def action_details(self) -> None:
        if self._active_table_id == "docker-table":
            self.notify("Details not available for Docker containers", severity="warning")
            return
        if self._active_table_id == "claude-projects-table":
            path = self._get_claude_selected_path()
            if path:
                name = Path(path).name
                self.push_screen(ClaudeProjectDetailScreen(path, name))
            return
        table_id = self._active_table_id
        table = self.query_one(f"#{table_id}", DataTable)
        try:
            row_key, _ = table.coordinate_to_cell_key(table.cursor_coordinate)
            pid = int(row_key.value)
        except Exception:
            return
        if table_id == "node-table":
            proc = next((p for p in self.node_procs if p.pid == pid), None)
            name = proc.name if proc else str(pid)
        else:
            proc = next((p for p in self.all_procs if p.pid == pid), None)
            name = proc.name if proc else str(pid)
        self.push_screen(ProcessDetailScreen(pid, name))

    def action_export(self) -> None:
        snapshot = {
            "timestamp": datetime.now().isoformat(),
            "node_processes": [dataclasses.asdict(p) for p in self.node_procs],
            "docker_containers": [dataclasses.asdict(c) for c in self.docker_containers],
            "all_processes": [dataclasses.asdict(p) for p in self.all_procs],
            "system_stats": dataclasses.asdict(self.system_stats) if self.system_stats else None,
        }
        export_dir = Path.home() / ".local" / "share" / "devdash"
        export_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        filepath = export_dir / f"snapshot-{ts}.json"
        filepath.write_text(json.dumps(snapshot, indent=2, default=str))
        self.notify(f"Exported to {filepath}", timeout=5)

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


