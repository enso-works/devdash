from __future__ import annotations

import argparse
from pathlib import Path

from devdash.app import DevDashApp
from devdash.config import Config


def main() -> None:
    parser = argparse.ArgumentParser(description="Developer dashboard for Node and Docker")
    parser.add_argument("--config", type=Path, default=None, help="Path to config file")
    args = parser.parse_args()

    config = Config.load(args.config)
    app = DevDashApp(config=config)
    app.run()


if __name__ == "__main__":
    main()
