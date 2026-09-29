# Changelog

## 0.2.0

### Added
- **macOS menu bar app** (`DevDash.app`): native SwiftUI dashboard with Dev, Docker, System and Claude tabs, cleanup review, process details, dependency graph, activity heatmap, streaming container logs, notifications, launch at login and one-click Claude session launching.
- **Claude usage**: plan limits (5-hour session and weekly, with reset times) and API-equivalent cost of your Claude Code usage at list prices, by period, model, project and token type. The session percentage can be shown in the menu bar.
- `devdash --serve`: JSON-lines bridge that the menu bar app uses. `--demo` serves synthetic data.
- The installer puts `DevDash.app` in `~/Applications` on macOS (`NO_APP=1` to skip).
- The app is signed with a Developer ID and notarized, and ships as a universal (Apple Silicon and Intel) DMG and zip.
- The app bundles the devdash CLI with its own Python, so it works without a separate install. Settings > Command line tool links `devdash` into `~/.local/bin`.
- Automatic updates via Sparkle, with a "Check for updates" button in Settings.
- Homebrew cask: `brew install --cask enso-works/tap/devdash`.
- **Disk tree** in the menu bar app: a treemap of your home folder colored by category, with Size, Files and Age modes, zoom, hidden-file and apparent-size toggles, and adjustable depth.
- "Worth a look" cleanup suggestions: idle build artifacts, agent worktrees, old experiments, package manager caches (using each tool's own cleanup command), Xcode and Android data, old downloads and large stale files. Files go to the Trash after confirmation.
- Fast parallel scanner with a scan cache, background refresh and handling for folders that need Full Disk Access.
- Disk card on the System tab and a low disk space notification.
- Terminal UI: recent sessions panel on the Claude tab.

### Fixed
- README install examples now pass `VERSION` to the installer instead of to `curl`.

## 0.1.1

### Added
- Claude tab: running Claude Code instances, projects, usage stats and a launch menu (new, plan mode, continue, resume, open in editor or Finder).
- Session browser to resume any past Claude session.
- Cleanup suggestions for idle, orphaned and zombie Node processes and long-running containers.
- Dependency graph of TCP connections between Node processes and containers.
- Claude activity heatmap.

## 0.1.0

### Added
- Terminal dashboard with Dev (Node and Docker) and System tabs.
- Kill and stop with confirmation, batch selection, container log streaming, process details.
- Filter, column sorting, JSON export, crash notifications, command palette.
- One-line installer and self-update.
