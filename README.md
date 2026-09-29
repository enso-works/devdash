# devdash

[![macOS app](https://github.com/enso-works/devdash/actions/workflows/macos-app.yml/badge.svg)](https://github.com/enso-works/devdash/actions/workflows/macos-app.yml)
[![Release](https://img.shields.io/github/v/release/enso-works/devdash)](https://github.com/enso-works/devdash/releases)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)

See and manage your dev servers, Docker containers and Claude Code sessions from one place. It comes as a terminal dashboard and a native macOS menu bar app.

![DevDash menu bar app](screenshots/app/hero.png)

## Why

If you use Claude Code (or any AI coding agent) across several projects, background processes pile up fast. You end up with orphaned `next dev` servers, runaway builds and forgotten Docker containers, and three copies of the same app fighting over port 3000 while your fan spins up.

devdash shows all of it on one screen:

- **Dev servers**: every process listening on a port, in any language (Node, Bun, Deno, Python, Ruby, Go, Rust and more), with its memory, CPU and the project it belongs to. Local databases such as Homebrew Postgres show up as services.
- **Docker**: containers grouped by Compose stack, with status, health and ports.
- **Cleanup**: flags idle, orphaned and zombie processes and long-running containers, and lets you remove them in one click.
- **Disk tree**: a treemap of your home folder that shows what takes up space and suggests what you can safely reclaim.
- **Claude Code**: running sessions, projects and recent sessions. Resume any of them in a new Terminal window.
- **Claude usage**: your plan limits (5-hour session and weekly) and what your usage would cost at API prices.
- **System**: CPU, memory, swap, disk, network and the heaviest processes.

## Install

### macOS menu bar app

Download `DevDash-<version>-macos.dmg` from the [latest release](https://github.com/enso-works/devdash/releases/latest) and drag DevDash to Applications, or use Homebrew:

```sh
brew install --cask enso-works/tap/devdash
```

The app is signed with a Developer ID and notarized by Apple, and it updates itself. It includes the devdash CLI with its own Python, so you don't need to install anything else. To use the terminal UI as well, open the app's Settings and click Install next to "Command line tool". This links `devdash` into `~/.local/bin`. Homebrew links it for you.

### Terminal UI (macOS and Linux)

Requires Python 3.10+ and git. On macOS this also installs the menu bar app.

```sh
curl -fsSL https://raw.githubusercontent.com/enso-works/devdash/main/install.sh | bash
```

Options go on the `bash` side of the pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/enso-works/devdash/main/install.sh | VERSION=0.2.0 bash  # pin a version
curl -fsSL https://raw.githubusercontent.com/enso-works/devdash/main/install.sh | NO_APP=1 bash       # CLI only
```

The installer:
- clones devdash to `~/.devdash`, creates a virtualenv, and links `devdash` into `~/.local/bin`;
- on macOS, puts `DevDash.app` in `~/Applications`.

Run it again to update. You can also run `devdash --update`, or use the prompt the app shows when it needs a newer CLI.

## Menu bar app (macOS)

```sh
open ~/Applications/DevDash.app
```

The menu bar shows how many dev servers and containers are running, plus your current Claude session usage (for example `9 · 42%`). The icon switches to a flame when CPU or memory goes over your configured threshold. Click it to open the dashboard.

| Running, by project | Project overview | System |
|---|---|---|
| ![Running](screenshots/app/running.png) | ![Project overview](screenshots/app/running-collapsed.png) | ![System](screenshots/app/system.png) |
| **Claude** | **Claude usage** | **Cleanup** |
| ![Claude](screenshots/app/claude.png) | ![Usage](screenshots/app/usage.png) | ![Cleanup](screenshots/app/cleanup.png) |
| **Claude project** | **Process details** | **Dependency graph** |
| ![Project](screenshots/app/project.png) | ![Details](screenshots/app/detail.png) | ![Graph](screenshots/app/graph.png) |

What you can do:

- **Needs you**: one list at the top for anything that wants your attention: cleanup suggestions, low disk space, disk space worth a look, and plan limits over 80%. Dismiss an item and it stays hidden until it changes. The list disappears when there is nothing to show.
- **Running**: dev servers, Docker containers and Claude sessions, grouped by project (the git repository they run in). Each project header shows the branch and has a menu to open the project in your editor, Finder or Terminal, start a Claude session there, or stop everything in it. Services, servers outside any project and Node processes without a port are grouped at the bottom. Choose **Type** next to the filter to group by dev servers, Compose stacks, Claude sessions, services and background processes instead.
  - Click a port chip to open `localhost:<port>`. Hover a row to open it in your editor or kill it (click twice to confirm). Right-click any row for all its actions.
  - Click a server for process details: command, children, network connections, open files and environment. Click a container to stream its logs in a separate window, with filtering, follow mode and copy.
- **System**: CPU, memory, disk, swap and network, the Disk tree summary, and the top processes sorted by memory or CPU. The header shows CPU and memory on every tab; click it to open this tab.
- **Claude**:
  - plan limits and API-equivalent cost;
  - running sessions, projects and recent sessions;
  - project pages with one-click launch: new session, continue, plan mode, resume picker, skip permissions, or a plain terminal in that folder.
- **Cleanup**: listed under Needs you when devdash finds idle, orphaned or zombie processes, or containers running longer than your stale threshold. Pick which ones to remove and clean them up together.
- **Footer**: Disk tree, dependency graph and activity heatmap. The `...` menu has JSON export, the terminal UI, What's new, Check for updates and Quit.
- **Keyboard**: Cmd+1 to Cmd+3 switch tabs, Cmd+F filters, Esc clears the filter.
- **Notifications**: a macOS notification when a dev server starts or exits, a container stops, or a watched port comes up.
- **Settings**: launch at login, editor (VS Code or Cursor), whether the menu bar shows the count and usage percentage, notifications, and a custom `devdash` path.

### Disk tree

![Disk tree](screenshots/app/disk-tree.png)

Open it from the Disk tree button in the popover footer, the Disk card on the System tab, or the Needs you row when devdash finds space worth a look.

- **Treemap**:
  - Every folder is a box sized by disk usage, nested up to the chosen depth.
  - Boxes are colored by what they hold: Code, Agent scratch (Codex/Claude worktrees, experiments), Toolchains, Synced, Git, Media, Documents, Cache.
  - Space you can reclaim is hatched.
- **Navigation**: click to select, double-click to zoom in, use the breadcrumb to go back up, right-click to reveal, copy the path, open a terminal or move to Trash.
- **Modes and options**:
  - Size, Files (sized by file count) and Age (colored from recently written to long untouched).
  - Toggles for hidden files and for apparent size versus size on disk.
  - Depth can be set from 1 to 8.
- **Worth a look**: cleanup suggestions ranked by size, each with a reason. Expand one to see exactly which folders it covers.
  - `node_modules`, Rust `target`, `.next`/`.turbo`, SwiftPM `.build`, Gradle, Pods and virtualenvs, in projects untouched for 14 days.
  - Agent worktrees idle for a week, and experiments (`tries`, `scratch`, `playground`) idle for 30 days.
  - Package manager and tool caches. These use the tool's own command where there is one: `brew cleanup`, `npm cache clean`, `pnpm store prune`, `uv cache clean`, `go clean -modcache`, `pod cache clean`, `docker system prune`, `xcrun simctl delete unavailable`.
  - Xcode DerivedData and DeviceSupport, Android emulators, large app caches, downloads older than 90 days, files over 1 GiB untouched for 6 months, and the Trash.
- **Safety**:
  - Nothing is deleted directly. Files go to the Trash, and every action first shows exactly what it will remove.
  - For cleanup commands the size shown is labeled "up to", since the tool decides what it removes.
  - After trashing agent worktrees, `git worktree prune` runs in their repository.
- **Speed and permissions**:
  - The scanner reads each directory's metadata in bulk and runs 8 threads. A home folder with about 9M files takes about a minute the first time.
  - Results are cached, so the window opens instantly, and they're refreshed in the background when older than six hours.
  - Without Full Disk Access, app containers (including Docker Desktop's disk image), Mail and cloud folders are skipped rather than triggering permission prompts. A banner links to the setting.
- **Low disk warning**: a notification when free space drops below 15 GiB or 5%.

### Claude usage and API-equivalent cost

The Claude tab has a usage card, and tapping it opens a detail page.

- **Plan limits**: the same 5-hour session and weekly limits (including per-model weekly limits) that Claude Code's `/usage` shows, with reset times and your plan name.
  - They're read with the Claude Code login already on your machine (the macOS keychain, or `~/.claude/.credentials.json` on other systems).
  - devdash never refreshes or stores that token. If it has expired, run Claude Code once.
- **API-equivalent cost**: what the tokens in your local Claude Code transcripts (`~/.claude/projects`) would cost at [Anthropic API list prices](https://platform.claude.com/docs/en/about-claude/pricing).
  - It accounts for per-model rates, 5-minute and 1-hour cache writes, cache reads, fast mode, web search and US-only inference.
  - It's shown for the current session, today, 7 days, 30 days and all time, broken down by model, project and token type.
  - Your subscription is billed separately; this number shows what the same work would cost on the API.

Everything is computed locally. The only network request is the plan-limits lookup to `api.anthropic.com`.

### How it works

The app is a small SwiftUI program that runs `devdash --serve` in the background. Release builds run the copy of devdash bundled inside the app. Local builds use the CLI from your checkout or `PATH`. That process sends a JSON snapshot every few seconds and accepts commands (kill, stop, details, usage and so on) over stdin/stdout, so the terminal UI and the app share the same data code. If the CLI is missing or too old, the app shows the command to fix it and can run it in Terminal.

## Terminal UI

```sh
devdash
```

![Dev tab](screenshots/dev-tab.svg)

| System tab | Claude tab |
|---|---|
| ![System tab](screenshots/system-tab.svg) | ![Claude tab](screenshots/claude-tab.svg) |

### Tabs

- **[1] Dev**: Node processes (PID, project, ports, memory, CPU, uptime, directory, command) and Docker containers (ID, name, image, status, ports, Compose project and service).
- **[2] System**: CPU, memory, swap and disk gauges, network rates, and the top processes by memory.
- **[3] Claude**: shown when Claude Code is installed.
  - Usage stats with a 14-day activity sparkline.
  - Running instances, projects, and the 50 most recent sessions.
  - Press `enter` on a project to open the launch menu: new session, skip permissions, plan mode, continue, resume, open in editor or Finder.

### Keybindings

| Key | Action |
|-----|--------|
| `1` / `2` / `3` | Dev / System / Claude tab |
| `tab` | Next table in the current tab |
| `/` | Filter across all columns |
| `k` | Kill process / stop container (with confirmation) |
| `space` | Select rows for batch kill/stop |
| `l` | Stream Docker container logs |
| `d` | Process details (environment, open files, connections, children) |
| `enter` | Claude project launch menu, or details |
| `s` | Browse and resume a Claude project's sessions |
| `c` | Cleanup suggestions |
| `g` | Dependency graph (which process talks to which port) |
| `h` | Claude activity heatmap |
| `e` | Export a JSON snapshot to `~/.local/share/devdash/` |
| `r` | Refresh |
| `ctrl+p` | Command palette |
| `Esc` | Close filter or modal |
| `q` | Quit |

Click a column header to sort, and click it again to reverse the order. Filters and sort order stay in place across refreshes, and the terminal UI shows a toast when a tracked process exits or a container disappears.

![Filter](screenshots/filter.svg)

## Configuration

Optional, at `~/.config/devdash/config.toml`. The terminal UI and the menu bar app both use it.

```toml
refresh_rate = 3.0                  # seconds between refreshes
process_limit = 80                  # processes shown in the System tab
watched_ports = [3000, 8080]        # notify when a process starts listening on these
color_threshold_low = 50.0          # green -> yellow (%)
color_threshold_high = 80.0         # yellow -> red (%), also the menu bar warning
cleanup_idle_threshold_cpu = 1.0    # a Node process below this CPU % counts as idle
cleanup_idle_threshold_minutes = 10 # ...after this many minutes
cleanup_docker_stale_days = 7       # containers running longer than this are suggested for cleanup
```

## CLI

```sh
devdash                          # terminal UI
devdash --config path/to/config  # custom config file
devdash --update                 # update to the latest release
devdash --version                # print version
devdash --serve                  # JSON-lines bridge used by the menu bar app
devdash --serve --demo           # same protocol with synthetic data
```

## Development

```sh
git clone https://github.com/enso-works/devdash && cd devdash
python3 -m venv .venv && .venv/bin/pip install -e .
./run.sh                                  # terminal UI from the checkout
macos/scripts/build-app.sh                # build DevDash.app against this checkout, install to ~/Applications
```

The app needs Xcode 16+ (Swift 6) and macOS 14+. Useful tools:

| Command | What it does |
|---------|--------------|
| `python -m devdash.claude_usage` | Print the usage payload (limits and costs) as JSON |
| `macos/.build/debug/DevDashBar --selftest` | Start the bridge and check every command decodes |
| `macos/.build/release/DevDashBar --scan <path>` | Run the disk scanner and print totals, timing and cleanup suggestions |
| `DEVDASH_DEMO=1 macos/.build/debug/DevDashBar --render <dir>` | Render every app screen to PNG using demo data |
| `scripts/screenshots.sh` | Regenerate all README screenshots from demo data |
| `EMBED_PYTHON=1 macos/scripts/build-app.sh` | Local build with the CLI and Python embedded, like a release |
| `swift macos/scripts/make-icon.swift` | Regenerate the app icon |

### Releases

`macos/scripts/build-app.sh --release` builds a universal (Apple Silicon and Intel) app and writes a zip, a DMG and checksums to `macos/dist/`. The release build also does the following:
- It embeds a universal CPython from [python-build-standalone](https://github.com/astral-sh/python-build-standalone), with devdash and its dependencies installed and precompiled (`macos/scripts/embed-python.sh`).
- It embeds Sparkle.
- It signs every binary, innermost first, with the hardened runtime.

Pushing a `v*` tag runs [the macOS workflow](.github/workflows/macos-app.yml). It self-tests the bridge, then builds, signs and notarizes the release. It writes the Sparkle `appcast.xml` and attaches everything to the GitHub release. The app checks `releases/latest/download/appcast.xml` for updates, and `install.sh` downloads the zip.

Repository secrets used by the workflow. Without them the build is ad-hoc signed and has no update feed.

| Secret | Value |
|--------|-------|
| `MACOS_CERT_P12` | base64 of the exported Developer ID Application certificate and key (.p12) |
| `MACOS_CERT_PASSWORD` | password of the .p12 |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `APPLE_API_KEY_P8` | base64 of an App Store Connect API key (.p8), used by `notarytool` |
| `APPLE_API_KEY_ID`, `APPLE_API_ISSUER` | the key ID and issuer ID of that key |
| `SPARKLE_PRIVATE_KEY` | EdDSA update signing key (`generate_keys --account devdash -x <file>`) |

Locally: `SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=<notarytool profile> macos/scripts/build-app.sh --release`, then `macos/scripts/make-appcast.py <zip> <version> <build>` for the feed. The public key in `build-app.sh` must match the private key.

### Project structure

```
devdash/
  app.py           # terminal UI: layout, bindings, data flow
  screens.py       # modal screens (logs, details, cleanup, graph, heatmap, launch menu)
  processes.py     # process, Docker, system and Claude Code data collection
  claude_usage.py  # plan limits and API-equivalent cost from transcripts
  bridge.py        # JSON-lines bridge for the menu bar app (--serve)
  demo.py          # synthetic data for --demo and screenshots
  cli.py           # command-line entry point
  config.py        # config file loading
  updater.py       # git-based self-update
macos/
  Sources/DevDashBar/   # SwiftUI menu bar app (bridge client, store, views)
    Disk/               # disk scanner, cache, cleanup rules, treemap and Disk window
  Resources/            # app icon
  scripts/              # build-app.sh, embed-python.sh, make-appcast.py, make-icon.swift
scripts/                # screenshot generation
.github/workflows/      # macOS build and release
install.sh              # one-line installer
```

## Uninstall

```sh
brew uninstall --cask devdash                                   # if installed with Homebrew
rm -rf /Applications/DevDash.app ~/Applications/DevDash.app     # the app
rm -rf ~/.devdash ~/.local/bin/devdash                          # the CLI from install.sh
```

If you turned on launch at login, turn it off in the app's Settings first, or remove DevDash under System Settings > General > Login Items.

## License

[MIT](LICENSE)
