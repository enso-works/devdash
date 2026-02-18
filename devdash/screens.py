from __future__ import annotations

import subprocess
import threading

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, Center
from textual.screen import ModalScreen
from textual.widgets import Button, Label, RichLog, Static


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
