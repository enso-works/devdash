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
