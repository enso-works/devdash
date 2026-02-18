from __future__ import annotations

import argparse
import sys
import threading
from pathlib import Path

from devdash import __version__
from devdash.config import Config


def main() -> None:
    parser = argparse.ArgumentParser(description="Developer dashboard for Node and Docker")
    parser.add_argument("--config", type=Path, default=None, help="Path to config file")
    parser.add_argument("--version", action="version", version=f"devdash {__version__}")
    parser.add_argument("--update", action="store_true", help="Update devdash to the latest version")
    args = parser.parse_args()

    if args.update:
        from devdash.updater import perform_update

        perform_update()
        sys.exit(0)

    update_event = threading.Event()
    update_message: list[str | None] = [None]

    def _bg_update_check() -> None:
        from devdash.updater import check_for_update, should_check_for_update

        if not should_check_for_update():
            update_event.set()
            return
        msg = check_for_update()
        update_message[0] = msg
        update_event.set()

    thread = threading.Thread(target=_bg_update_check, daemon=True)
    thread.start()

    config = Config.load(args.config)

    from devdash.app import DevDashApp

    app = DevDashApp(
        config=config,
        update_check_event=update_event,
        get_update_message=lambda: update_message[0],
    )
    app.run()


if __name__ == "__main__":
    main()
