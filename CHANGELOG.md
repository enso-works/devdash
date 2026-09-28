# Changelog

## 0.2.0

### Added
- **macOS menu bar app** (`DevDash.app`): native SwiftUI dashboard with Dev, Docker, System and Claude tabs, cleanup review, process details, dependency graph, activity heatmap, streaming container logs, notifications, launch at login and one-click Claude session launching.
- **Claude usage**: plan limits (5-hour session and weekly, with reset times) and API-equivalent cost of your Claude Code usage at list prices, by period, model, project and token type. The session percentage can be shown in the menu bar.
- `devdash --serve`: JSON-lines bridge that the menu bar app uses. `--demo` serves synthetic data.
- The installer puts `DevDash.app` in `~/Applications` on macOS (`NO_APP=1` to skip).
- Universal release builds (zip and DMG) with optional Developer ID signing and notarization, built and attached to releases by CI.
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
