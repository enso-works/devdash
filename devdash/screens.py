from __future__ import annotations

import subprocess
import threading

from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, Center
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    DataTable,
    Label,
    Markdown,
    OptionList,
    RichLog,
    Static,
    TabbedContent,
    TabPane,
)
from textual.widgets.option_list import Option


class DependencyGraphScreen(ModalScreen[None]):
    CSS = """
    DependencyGraphScreen {
        align: center middle;
    }

    #depgraph-dialog {
        width: 90%;
        height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #depgraph-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #depgraph-output {
        height: 1fr;
    }
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
        Binding("q", "close", "Close", show=False),
    ]

    def __init__(self, node_procs: list, docker_containers: list) -> None:
        super().__init__()
        self._node_procs = node_procs
        self._docker_containers = docker_containers

    def compose(self) -> ComposeResult:
        with Vertical(id="depgraph-dialog"):
            yield Static("Dependency Graph", id="depgraph-title")
            yield RichLog(id="depgraph-output", highlight=True, markup=False)

    def on_mount(self) -> None:
        self._load_graph()

    @work(thread=True)
    def _load_graph(self) -> None:
        from devdash.processes import get_dependency_graph

        owners, edges = get_dependency_graph(self._node_procs, self._docker_containers)
        self.call_from_thread(self._render_graph, owners, edges)

    def _render_graph(self, owners: list, edges: list) -> None:
        from collections import defaultdict
        from rich.text import Text as RichText

        log = self.query_one("#depgraph-output", RichLog)

        if not owners:
            log.write("No running processes or containers detected.")
            log.write("")
            log.write("The dependency graph shows TCP connections between")
            log.write("Node.js processes and Docker containers.")
            log.write("Start some services to see their connections here.")
            return

        if not edges:
            log.write("No connections detected between services.")
            log.write("")
            log.write(RichText("  Running entities:", style="bold"))
            for owner in owners:
                kind_style = "cyan" if owner.kind == "node" else "yellow"
                ports = ", ".join(f":{p}" for p in owner.ports) if owner.ports else ""
                line = RichText()
                line.append(f"  {owner.label}", style=kind_style)
                if ports:
                    line.append(f" {ports}", style="green")
                if owner.group:
                    line.append(f" ({owner.group})", style="dim")
                log.write(line)
            return

        # Group edges by source group, then source label
        by_group: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))
        for edge in edges:
            group = edge.from_group or "(ungrouped)"
            by_group[group][edge.from_label].append(edge)

        for group in sorted(by_group):
            if len(by_group) > 1:
                log.write(RichText(f"  [{group}]", style="bold"))

            sources = by_group[group]
            source_list = sorted(sources.keys())
            for si, source in enumerate(source_list):
                source_edges = sorted(sources[source], key=lambda e: e.to_label)
                is_last_source = si == len(source_list) - 1
                prefix = "  \u2514\u2500\u2500 " if is_last_source else "  \u251c\u2500\u2500 "
                cont = "      " if is_last_source else "  \u2502   "

                kind_style = "cyan" if source_edges[0].from_kind == "node" else "yellow"
                header = RichText()
                header.append(prefix, style="dim")
                header.append(source, style=kind_style)
                log.write(header)

                for ei, edge in enumerate(source_edges):
                    is_last_edge = ei == len(source_edges) - 1
                    edge_prefix = cont + ("\u2514\u2500\u2500 " if is_last_edge else "\u251c\u2500\u2500 ")
                    target_style = "cyan" if edge.to_kind == "node" else "yellow"
                    line = RichText()
                    line.append(edge_prefix, style="dim")
                    line.append(edge.to_label, style=target_style)
                    line.append(f" :{edge.port}", style="green")
                    log.write(line)

            log.write("")

        # Show standalone owners not involved in any edge
        connected = set()
        for edge in edges:
            connected.add(edge.from_label)
            connected.add(edge.to_label)
        standalone = [o for o in owners if o.label not in connected]
        if standalone:
            log.write(RichText("  Standalone (no connections):", style="dim bold"))
            for owner in standalone:
                kind_style = "cyan" if owner.kind == "node" else "yellow"
                log.write(RichText(f"    {owner.label}", style=kind_style))

    def action_close(self) -> None:
        self.dismiss(None)


class ActivityHeatmapScreen(ModalScreen[None]):
    CSS = """
    ActivityHeatmapScreen {
        align: center middle;
    }

    #heatmap-dialog {
        width: 90%;
        height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #heatmap-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #heatmap-log, #timetrack-log, #timeline-log {
        height: 1fr;
    }
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
        Binding("q", "close", "Close", show=False),
    ]

    def compose(self) -> ComposeResult:
        with Vertical(id="heatmap-dialog"):
            yield Static("Activity Heatmap", id="heatmap-title")
            with TabbedContent():
                with TabPane("Heatmap", id="tab-heatmap"):
                    yield RichLog(id="heatmap-log", highlight=True, markup=False)
                with TabPane("Time Tracking", id="tab-timetrack"):
                    yield RichLog(id="timetrack-log", highlight=True, markup=False)
                with TabPane("Timeline", id="tab-timeline"):
                    yield RichLog(id="timeline-log", highlight=True, markup=False)

    def on_mount(self) -> None:
        self._load_data()

    @work(thread=True)
    def _load_data(self) -> None:
        from devdash.processes import get_activity_heatmap_data

        data = get_activity_heatmap_data()
        self.call_from_thread(self._render_all, data)

    def _render_all(self, data) -> None:
        if data is None:
            log = self.query_one("#heatmap-log", RichLog)
            log.write("No Claude activity data found.")
            log.write("")
            log.write("Activity data is collected from ~/.claude/ directory.")
            log.write("Use Claude Code to generate activity data.")
            return
        self._render_heatmap(data)
        self._render_time_tracking(data)
        self._render_timeline(data)

    def _render_heatmap(self, data) -> None:
        from rich.text import Text as RichText

        log = self.query_one("#heatmap-log", RichLog)

        # Header row with hour labels
        header = RichText("         ", style="dim")
        for h in range(24):
            header.append(f"{h:>2d} ", style="dim")
        log.write(header)

        max_val = max(
            (data.weekly_heatmap[d][h] for d in range(7) for h in range(24)),
            default=1,
        )
        if max_val == 0:
            max_val = 1

        def cell_style(val: int) -> tuple[str, str]:
            """Return (display_text, color) based on intensity."""
            if val == 0:
                return " .", "grey37"
            ratio = val / max_val
            text = f"{val:>2d}" if val < 100 else " +"
            if ratio <= 0.25:
                return text, "dark_green"
            elif ratio <= 0.6:
                return text, "green"
            else:
                return text, "bright_green"

        for d in range(7):
            row = RichText(f"  {data.week_day_labels[d]:>3s}  ", style="bold")
            for h in range(24):
                val = data.weekly_heatmap[d][h]
                text, style = cell_style(val)
                row.append(f"{text} ", style=style)
            log.write(row)

        log.write("")
        log.write(RichText(
            f"  Total: {data.total_messages} messages, {data.total_sessions} sessions, {data.total_hours:.1f}h",
            style="bold",
        ))

    def _render_time_tracking(self, data) -> None:
        from rich.text import Text as RichText

        log = self.query_one("#timetrack-log", RichLog)

        if not data.project_times:
            log.write("No per-project time data available.")
            return

        top = data.project_times[:20]
        max_hours = top[0][1] if top else 1
        if max_hours == 0:
            max_hours = 1
        bar_width = 30

        log.write(RichText("  Project Time (top 20)", style="bold"))
        log.write("")

        max_name = max(len(name) for name, _ in top) if top else 10
        max_name = min(max_name, 25)

        for name, hours in top:
            short_name = name[:max_name].ljust(max_name)
            filled = int(hours / max_hours * bar_width)
            empty = bar_width - filled
            hours_str = f"{hours:.1f}h" if hours >= 1 else f"{hours * 60:.0f}m"
            line = RichText()
            line.append(f"  {short_name}  ", style="bold")
            line.append("\u2588" * filled, style="green")
            line.append("\u2591" * empty, style="dim")
            line.append(f" {hours_str}", style="dim")
            log.write(line)

        log.write("")
        total = sum(h for _, h in data.project_times)
        log.write(RichText(f"  Total: {total:.1f}h across {len(data.project_times)} projects", style="dim"))

    def _render_timeline(self, data) -> None:
        from rich.text import Text as RichText

        log = self.query_one("#timeline-log", RichLog)
        blocks = " \u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"

        def sparkline(values: list[int]) -> str:
            if not values:
                return ""
            max_v = max(values) if values else 1
            if max_v == 0:
                return blocks[0] * len(values)
            return "".join(
                blocks[min(int(v / max_v * 7) + (1 if v > 0 else 0), 8)]
                for v in values
            )

        def stats_section(label: str, pairs: list[tuple[str, int]]) -> None:
            values = [v for _, v in pairs]
            if not values:
                return
            spark = sparkline(values)
            avg = sum(values) / len(values)
            mx = max(values)
            total = sum(values)
            log.write(RichText(f"  {label}", style="bold"))
            log.write(RichText(f"  {spark}", style="green"))
            log.write(RichText(
                f"  avg: {avg:.0f}  max: {mx}  total: {total:,}",
                style="dim",
            ))
            if len(pairs) > 1:
                log.write(RichText(f"  {pairs[0][0]} to {pairs[-1][0]}", style="dim"))
            log.write("")

        if not data.daily_messages and not data.daily_sessions and not data.daily_tokens:
            log.write("No timeline data available.")
            return

        log.write(RichText("  Activity Timeline", style="bold"))
        log.write("")

        stats_section("Messages / day", data.daily_messages)
        stats_section("Sessions / day", data.daily_sessions)

        if data.daily_tokens:
            token_values = [t for _, t in data.daily_tokens]
            token_k = [t // 1000 for t in token_values]
            if any(token_k):
                spark = sparkline(token_k)
                avg = sum(token_k) / len(token_k)
                mx = max(token_k)
                total = sum(token_k)
                log.write(RichText("  Tokens / day (K)", style="bold"))
                log.write(RichText(f"  {spark}", style="green"))
                log.write(RichText(
                    f"  avg: {avg:.0f}K  max: {mx}K  total: {total:,}K",
                    style="dim",
                ))
                if len(data.daily_tokens) > 1:
                    log.write(RichText(
                        f"  {data.daily_tokens[0][0]} to {data.daily_tokens[-1][0]}",
                        style="dim",
                    ))

    def action_close(self) -> None:
        self.dismiss(None)


class CleanupScreen(ModalScreen[list | None]):
    CSS = """
    CleanupScreen {
        align: center middle;
    }

    #cleanup-dialog {
        width: 90%;
        height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #cleanup-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #cleanup-table {
        height: 1fr;
    }

    #cleanup-footer {
        height: 1;
        color: $text-muted;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("space", "toggle_item", "Toggle", show=False, priority=True),
        Binding("a", "select_all", "Select All", show=False),
        Binding("n", "select_none", "Clear", show=False),
        Binding("enter", "execute", "Execute", show=False, priority=True),
        Binding("escape", "cancel", "Cancel", show=False),
        Binding("q", "cancel", "Cancel", show=False),
    ]

    def __init__(self, suggestions: list) -> None:
        super().__init__()
        self._suggestions = suggestions
        self._selected: set[int] = set(range(len(suggestions)))

    def compose(self) -> ComposeResult:
        with Vertical(id="cleanup-dialog"):
            yield Static(f"Cleanup Suggestions ({len(self._suggestions)} items)", id="cleanup-title")
            yield DataTable(id="cleanup-table")
            yield Static(
                "space=toggle  a=all  n=none  enter=execute  esc=cancel",
                id="cleanup-footer",
            )

    def on_mount(self) -> None:
        table = self.query_one("#cleanup-table", DataTable)
        table.cursor_type = "row"
        table.add_columns("Sel", "Category", "Name", "Reason", "Action")
        self._populate_table()

    def _category_text(self, category: str) -> str:
        labels = {
            "idle": "Idle",
            "zombie": "Zombie",
            "stale_container": "Stale Container",
            "orphan": "Orphan",
        }
        return labels.get(category, category)

    def _category_style(self, category: str) -> str:
        styles = {
            "idle": "yellow",
            "zombie": "red",
            "stale_container": "cyan",
            "orphan": "magenta",
        }
        return styles.get(category, "white")

    def _populate_table(self) -> None:
        from rich.text import Text as RichText

        table = self.query_one("#cleanup-table", DataTable)
        table.clear()
        for i, s in enumerate(self._suggestions):
            check = "[x]" if i in self._selected else "[ ]"
            cat_text = RichText(self._category_text(s.category), style=self._category_style(s.category))
            action = "Kill" if s.action_type == "kill" else "Stop"
            table.add_row(check, cat_text, s.label, s.reason, action, key=str(i))

    def action_toggle_item(self) -> None:
        table = self.query_one("#cleanup-table", DataTable)
        try:
            row_key, _ = table.coordinate_to_cell_key(table.cursor_coordinate)
            idx = int(row_key.value)
        except Exception:
            return
        if idx in self._selected:
            self._selected.discard(idx)
        else:
            self._selected.add(idx)
        self._populate_table()
        try:
            table.move_cursor(row=idx)
        except Exception:
            pass

    def action_select_all(self) -> None:
        self._selected = set(range(len(self._suggestions)))
        self._populate_table()

    def action_select_none(self) -> None:
        self._selected.clear()
        self._populate_table()

    def action_execute(self) -> None:
        if not self._selected:
            self.dismiss(None)
            return
        selected = [self._suggestions[i] for i in sorted(self._selected)]
        self.dismiss(selected)

    def action_cancel(self) -> None:
        self.dismiss(None)


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


class LogViewerScreen(ModalScreen[None]):
    CSS = """
    LogViewerScreen {
        align: center middle;
    }

    #log-dialog {
        width: 90%;
        height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #log-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #log-output {
        height: 1fr;
    }
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
        Binding("q", "close", "Close", show=False),
    ]

    def __init__(self, container_id: str, container_name: str) -> None:
        super().__init__()
        self._container_id = container_id
        self._container_name = container_name
        self._process: subprocess.Popen | None = None
        self._stop_event = threading.Event()

    def compose(self) -> ComposeResult:
        with Vertical(id="log-dialog"):
            yield Static(f"Logs: {self._container_name} ({self._container_id})", id="log-title")
            yield RichLog(id="log-output", highlight=True, markup=False)

    def on_mount(self) -> None:
        self._start_streaming()

    def _start_streaming(self) -> None:
        log_widget = self.query_one("#log-output", RichLog)
        try:
            self._process = subprocess.Popen(
                ["docker", "logs", "--tail", "100", "--follow", self._container_id],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except FileNotFoundError:
            log_widget.write("Error: docker not found")
            return

        def stream_logs():
            proc = self._process
            if not proc or not proc.stdout:
                return
            try:
                for line in proc.stdout:
                    if self._stop_event.is_set():
                        break
                    self.call_from_thread(log_widget.write, line.rstrip("\n"))
            except Exception:
                pass

        thread = threading.Thread(target=stream_logs, daemon=True)
        thread.start()

    def action_close(self) -> None:
        self._cleanup()
        self.dismiss(None)

    def _cleanup(self) -> None:
        self._stop_event.set()
        if self._process:
            try:
                self._process.kill()
                self._process.wait(timeout=2)
            except Exception:
                pass
            self._process = None


class ProcessDetailScreen(ModalScreen[None]):
    CSS = """
    ProcessDetailScreen {
        align: center middle;
    }

    #detail-dialog {
        width: 90%;
        height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #detail-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #detail-output {
        height: 1fr;
    }
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
        Binding("q", "close", "Close", show=False),
    ]

    def __init__(self, pid: int, name: str) -> None:
        super().__init__()
        self._pid = pid
        self._name = name

    def compose(self) -> ComposeResult:
        with Vertical(id="detail-dialog"):
            yield Static(f"Process Details: {self._name} (PID {self._pid})", id="detail-title")
            yield RichLog(id="detail-output", highlight=True, markup=False)

    def on_mount(self) -> None:
        self._load_details()

    def _load_details(self) -> None:
        import psutil
        log = self.query_one("#detail-output", RichLog)

        try:
            proc = psutil.Process(self._pid)
        except psutil.NoSuchProcess:
            log.write(f"Process {self._pid} no longer exists")
            return

        def _safe(func, default="N/A"):
            try:
                return func()
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                return default

        log.write(f"PID:     {self._pid}")
        log.write(f"Name:    {_safe(proc.name)}")
        log.write(f"Status:  {_safe(proc.status)}")
        log.write(f"User:    {_safe(proc.username)}")
        log.write(f"CWD:     {_safe(proc.cwd)}")
        log.write(f"CPU %:   {_safe(lambda: f'{proc.cpu_percent(interval=0.1):.1f}%')}")
        mem = _safe(lambda: proc.memory_info())
        if mem != "N/A":
            log.write(f"RSS:     {mem.rss / (1024*1024):.1f} MB")
            log.write(f"VMS:     {mem.vms / (1024*1024):.1f} MB")
        else:
            log.write(f"Memory:  {mem}")
        log.write(f"Threads: {_safe(proc.num_threads)}")
        log.write("")

        cmdline = _safe(lambda: " ".join(proc.cmdline()))
        log.write(f"Command: {cmdline}")
        log.write("")

        children = _safe(lambda: proc.children(recursive=True), [])
        if children and children != "N/A":
            log.write(f"Children ({len(children)}):")
            for child in children:
                try:
                    log.write(f"  PID {child.pid}: {child.name()}")
                except (psutil.AccessDenied, psutil.NoSuchProcess):
                    log.write(f"  PID {child.pid}: <access denied>")
            log.write("")

        connections = _safe(lambda: proc.net_connections(kind="inet"), [])
        if connections and connections != "N/A":
            log.write(f"Network Connections ({len(connections)}):")
            for conn in connections:
                laddr = f"{conn.laddr.ip}:{conn.laddr.port}" if conn.laddr else "-"
                raddr = f"{conn.raddr.ip}:{conn.raddr.port}" if conn.raddr else "-"
                log.write(f"  {conn.status:12s} {laddr:25s} -> {raddr}")
            log.write("")

        open_files = _safe(lambda: proc.open_files(), [])
        if open_files and open_files != "N/A":
            log.write(f"Open Files ({len(open_files)}, first 20):")
            for f in open_files[:20]:
                log.write(f"  {f.path}")
            log.write("")

        env = _safe(lambda: proc.environ(), {})
        if env and env != "N/A":
            log.write(f"Environment ({len(env)} vars, first 30):")
            for k, v in sorted(env.items())[:30]:
                val = v if len(v) <= 80 else v[:77] + "..."
                log.write(f"  {k}={val}")

    def action_close(self) -> None:
        self.dismiss(None)


class LaunchMenuScreen(ModalScreen[str | None]):
    CSS = """
    LaunchMenuScreen {
        align: center middle;
    }

    #launch-dialog {
        width: 50;
        height: auto;
        max-height: 20;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #launch-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #launch-options {
        height: auto;
        max-height: 14;
    }
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=False),
        Binding("n", "select_new", "", show=False),
        Binding("y", "select_skip_perms", "", show=False),
        Binding("p", "select_plan", "", show=False),
        Binding("c", "select_continue", "", show=False),
        Binding("r", "select_resume", "", show=False),
        Binding("v", "select_vscode", "", show=False),
        Binding("f", "select_finder", "", show=False),
    ]

    def __init__(self, project_name: str, editor_cmd: str | None = None) -> None:
        super().__init__()
        self._project_name = project_name
        self._editor_cmd = editor_cmd

    def compose(self) -> ComposeResult:
        items = [
            ("new", "[n] New session"),
            ("new_skip_perms", "[y] New session (skip permissions)"),
            ("new_plan", "[p] New session (plan mode)"),
            ("continue_session", "[c] Continue last session"),
            ("resume", "[r] Resume session picker"),
        ]
        if self._editor_cmd:
            label = "Cursor" if "cursor" in self._editor_cmd else "VS Code"
            items.append(("editor", f"[v] Open in {label}"))
        items.append(("finder", "[f] Open in Finder"))
        with Vertical(id="launch-dialog"):
            yield Static(f"Launch: {self._project_name}", id="launch-title")
            yield OptionList(
                *[Option(label, id=action_id) for action_id, label in items],
                id="launch-options",
            )

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(event.option.id)

    def action_cancel(self) -> None:
        self.dismiss(None)

    def action_select_new(self) -> None:
        self.dismiss("new")

    def action_select_skip_perms(self) -> None:
        self.dismiss("new_skip_perms")

    def action_select_plan(self) -> None:
        self.dismiss("new_plan")

    def action_select_continue(self) -> None:
        self.dismiss("continue_session")

    def action_select_resume(self) -> None:
        self.dismiss("resume")

    def action_select_vscode(self) -> None:
        self.dismiss("editor")

    def action_select_finder(self) -> None:
        self.dismiss("finder")


class SessionBrowserScreen(ModalScreen[str | None]):
    CSS = """
    SessionBrowserScreen {
        align: center middle;
    }

    #session-dialog {
        width: 90%;
        height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #session-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #session-table {
        height: 1fr;
    }

    #session-preview {
        height: 6;
        padding: 0 1;
        background: $panel;
        overflow-y: auto;
    }
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
        Binding("q", "close", "Close", show=False),
    ]

    def __init__(self, project_path: str, project_name: str) -> None:
        super().__init__()
        self._project_path = project_path
        self._project_name = project_name
        self._sessions: list = []

    def compose(self) -> ComposeResult:
        with Vertical(id="session-dialog"):
            yield Static(f"Sessions: {self._project_name}", id="session-title")
            yield DataTable(id="session-table")
            yield Static("", id="session-preview")

    def on_mount(self) -> None:
        table = self.query_one("#session-table", DataTable)
        table.cursor_type = "row"
        table.add_columns("Summary", "Msgs", "Branch", "Created", "Modified")
        self._load_sessions()

    @work(thread=True)
    def _load_sessions(self) -> None:
        from devdash.processes import get_project_sessions

        sessions = get_project_sessions(self._project_path)
        self.call_from_thread(self._populate_table, sessions)

    def _populate_table(self, sessions: list) -> None:
        self._sessions = sessions
        table = self.query_one("#session-table", DataTable)
        for s in sessions:
            summary = s.summary[:60] if s.summary else s.first_prompt[:60]
            if s.is_sidechain:
                summary = "[sidechain] " + summary
            table.add_row(
                summary,
                str(s.message_count),
                s.git_branch or "-",
                s.created,
                s.modified,
                key=s.session_id,
            )
        if sessions:
            self._update_preview(0)

    def on_data_table_cursor_moved(self, event: DataTable.CursorMoved) -> None:
        if event.data_table.id == "session-table":
            self._update_preview(event.cursor_row)

    def _update_preview(self, row: int) -> None:
        if 0 <= row < len(self._sessions):
            s = self._sessions[row]
            prompt = s.first_prompt[:300] if s.first_prompt else "(no prompt)"
            preview = self.query_one("#session-preview", Static)
            preview.update(f"First prompt: {prompt}")

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id == "session-table":
            self.dismiss(event.row_key.value)

    def action_close(self) -> None:
        self.dismiss(None)


class ClaudeProjectDetailScreen(ModalScreen[None]):
    CSS = """
    ClaudeProjectDetailScreen {
        align: center middle;
    }

    #project-detail-dialog {
        width: 90%;
        height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #project-detail-title {
        height: 1;
        text-style: bold;
        margin-bottom: 1;
    }

    #project-detail-header {
        height: 1;
        margin-bottom: 1;
        color: $text-muted;
    }

    #project-sessions-table {
        height: 1fr;
    }

    #project-stats-log {
        height: 1fr;
    }

    #project-memory {
        height: 1fr;
        overflow-y: auto;
    }
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
        Binding("q", "close", "Close", show=False),
    ]

    def __init__(self, project_path: str, project_name: str) -> None:
        super().__init__()
        self._project_path = project_path
        self._project_name = project_name

    def compose(self) -> ComposeResult:
        with Vertical(id="project-detail-dialog"):
            yield Static(f"Project: {self._project_name}", id="project-detail-title")
            yield Static("Loading...", id="project-detail-header")
            with TabbedContent():
                with TabPane("Sessions", id="tab-sessions"):
                    yield DataTable(id="project-sessions-table")
                with TabPane("Stats", id="tab-stats"):
                    yield RichLog(id="project-stats-log", highlight=True, markup=False)
                with TabPane("Memory", id="tab-memory"):
                    yield Markdown("Loading...", id="project-memory")

    def on_mount(self) -> None:
        table = self.query_one("#project-sessions-table", DataTable)
        table.cursor_type = "row"
        table.add_columns("Summary", "Msgs", "Branch", "Created", "Modified")
        self._load_detail()

    @work(thread=True)
    def _load_detail(self) -> None:
        from devdash.processes import get_project_detail

        detail = get_project_detail(self._project_path)
        self.call_from_thread(self._populate_detail, detail)

    def _populate_detail(self, detail) -> None:
        from devdash.processes import ClaudeProjectDetail

        header = self.query_one("#project-detail-header", Static)
        header.update(
            f"{detail.total_sessions} sessions | "
            f"{detail.total_messages} messages | "
            f"+{detail.total_lines_added}/-{detail.total_lines_removed} lines | "
            f"{detail.git_commits} commits"
        )

        # Sessions tab
        table = self.query_one("#project-sessions-table", DataTable)
        for s in detail.recent_sessions:
            summary = s.summary[:60] if s.summary else s.first_prompt[:60]
            if s.is_sidechain:
                summary = "[sidechain] " + summary
            table.add_row(
                summary,
                str(s.message_count),
                s.git_branch or "-",
                s.created,
                s.modified,
                key=s.session_id,
            )

        # Stats tab
        log = self.query_one("#project-stats-log", RichLog)
        if detail.languages:
            log.write("Languages:")
            for lang, count in sorted(detail.languages.items(), key=lambda x: x[1], reverse=True):
                log.write(f"  {lang}: {count}")
            log.write("")

        log.write(f"Files modified: {detail.total_files_modified}")
        log.write(f"Lines: +{detail.total_lines_added} / -{detail.total_lines_removed}")
        log.write(f"Git commits: {detail.git_commits}")
        log.write("")

        if detail.tools_used:
            log.write("Top tools:")
            sorted_tools = sorted(detail.tools_used.items(), key=lambda x: x[1], reverse=True)
            for tool, count in sorted_tools[:15]:
                log.write(f"  {tool}: {count}")

        # Memory tab
        memory = self.query_one("#project-memory", Markdown)
        if detail.memory_content:
            memory.update(detail.memory_content)
        else:
            memory.update("*No MEMORY.md found for this project.*")

    def action_close(self) -> None:
        self.dismiss(None)
