# Changelog

## 0.8.0

### Added
- **Codex tab**: Codex running in a terminal, projects and recent threads from the CLI and the Codex app, read from Codex's own state database. Click a thread to resume it in Terminal (`codex resume <id>`); project pages have new session, continue last, read-only and the resume picker.
- **Codex usage**: the 5-hour and weekly Codex limits of your ChatGPT plan with reset times, plan and credits, from the same endpoint Codex's `/status` uses. When the login has expired or the request fails, the limits Codex last reported in your sessions are shown instead, with a note.
- **Codex API-equivalent cost** at OpenAI list prices for today, 7 days, 30 days, all time and the current session, by model, project and token type (cached input, uncached input, output and reasoning). Covers Fast mode, cache writes and long-context requests; models without a public price are listed as unpriced.
- Archived Codex sessions (`.jsonl.zst`) are read with the `zstd` command.
- Codex sessions show up in Running, grouped by project, and keep a worktree from being removed while they run in it.
- Needs you warns when a Codex limit goes over 80%, like Claude's.
- The menu bar shows both session percentages when Claude and Codex are both used, for example `C 42% · X 71%`.
- Project and worktree menus have **New Codex Session**.
- Recent Codex projects are offered under Ready to run.
- `devdash --serve` sends `has_codex` in hello, `codex` and `codex_usage` in snapshots, and has `refresh_codex` and `codex_usage` commands.

### Changed
- Tabs size to their titles, so Running, Claude, Codex and System fit side by side. Cmd+1 to Cmd+4 switch tabs.

## 0.7.0

### Added
- **Run dev servers**: a project's menu in Running has **Run dev** (the script you ran last, else `dev`, `start`, `serve` or `preview`) and a **Run** submenu with every package.json script, the dev scripts of workspace packages and the entries of `Procfile.dev` or `Procfile`. The package manager comes from the lockfile or the `packageManager` field.
- **Ready to run**: recent Claude Code projects with nothing running are listed at the bottom of Running, each with a play button.
- Servers devdash started get a chip with the script name, and Restart, Stop and Logs buttons. Stop ends the script's whole process group, so the servers `npm run dev` or turbo started stop with it.
- **Logs**: output goes to `~/.local/share/devdash/runs/<project>/<script>.log` (kept under 5 MB) and opens in the logs window, with filter, follow, Restart and Stop.
- **Restart when it crashes**, per server, off by default: restarts after 2 seconds, at most 3 times in 5 minutes.
- A crash shows up in Needs you with the exit code and a notification. Runs without a port (workers, watchers) and runs that ended keep a row in their project.
- When a port the script used last time is held by another process, the run doesn't start; Needs you names the process and offers **Stop and run**.
- Servers keep running when the menu bar app quits, like servers started in a terminal, and devdash picks them up again on the next launch.
- `devdash --serve` sends `runs`, `runnable` (when it changes) and each server's `run_id`, and has `run_script`, `stop_run`, `restart_run`, `clear_run` and `restart_on_crash` commands.

### Changed
- Stop All in a project stops the runs devdash started as a whole.
- Notifications for servers devdash started are about crashes only, not every start and stop.

## 0.6.0

### Added
- **Worktrees**: a page with every linked git worktree of the repositories devdash knows about (projects with something running and the Claude Code projects of every account), with the branch, who created it, when it was last touched, its size, and whether it's running, has changes, is merged, or is stale. Open it from the footer or from **Worktrees** in a project's menu.
- Remove a worktree from its row: `git worktree remove`, `git worktree prune`, and `git branch -d` for merged branches. Worktrees with changes, with a server or Claude session running in them, and the main checkout can't be removed.
- Branches count as merged when they are merged into the default branch or their remote branch is gone, so squash-merged pull requests are caught too.
- Needs you lists merged worktrees nothing has touched for a day.
- Projects that are linked worktrees get a stacked icon on their branch chip in Running.
- `devdash --serve` sends a `worktrees` list when it changes (scanned once a minute) and has `refresh_worktrees`, `worktree_size` and `remove_worktree` commands.

## 0.5.0

### Added
- **Server URLs and QR codes**: the QR button on a dev server, or Show QR Code in its menu, opens a page with the server's network URL as a QR code, so a phone on the same Wi-Fi opens it in one scan. It also lists the localhost and network URLs with copy and open buttons, and a port picker for servers with several ports.
- Servers that listen on localhost only say "Only this Mac can open it" and show how to fix that for their runtime, such as `--host` for Vite or `--host 0.0.0.0` for uvicorn.
- Server menus have Copy Network URL and Show QR Code. Option-click a port chip to copy its URL.
- `devdash --serve` reports each server's `urls` (port, localhost URL, network URL and whether other devices can reach it), an `expose_hint`, and the Mac's `lan_ip`.

### Changed
- Port chips, Open and Copy URL use https for servers that speak TLS, such as Vite with `--https`.

## 0.4.0

### Added
- **Separate Claude accounts**: `bin/claude-profile` runs Claude Code with the account that owns the current folder, from `~/.config/claude-profiles`, and its `guard` hook blocks prompts sent from the wrong account.
- The Claude tab has an account switcher for projects, sessions, cost and plan limits, and running Claude sessions show which account they use.
- **GitHub accounts per folder**: `claude-profile gh` runs `gh` as the GitHub login a profile names in a `github` line of `~/.config/claude-profiles`; the account switcher shows each profile's login, or a "Sign in to GitHub" button.
- **Keep awake**: a cup button in the menu bar app header stops the Mac from sleeping and, after 50 seconds idle, nudges the cursor one point and back so chat apps keep you active. The menu bar icon turns into a cup while it is on. The nudge needs Accessibility access.

## 0.3.0

### Added
- **Needs you**: cleanup suggestions, low disk space, disk space worth a look and plan limits over 80% now appear in one list at the top of the menu bar app. Dismissed items stay hidden until they change.
- **Running tab**, replacing the Dev and Docker tabs: dev servers, containers and Claude sessions grouped by project (the git repository they run in), with the branch and a project menu (open in editor, Finder or Terminal, new Claude session, stop all). Services, servers outside a project and background Node processes are grouped at the bottom. "Group by Type" gives the previous layout.
- Dev servers in any language: every process of yours listening on a port (Node, Bun, Deno, Python, Ruby, Go, Rust, Java, PHP and more), with a runtime badge. Local databases such as Homebrew Postgres or MySQL appear as services. GUI apps and Docker port forwarders are left out.
- Right-click menus on every row and project header.
- Keyboard shortcuts: Cmd+1 to Cmd+3 switch tabs, Cmd+F filters.
- What's new after an update and a short welcome on first launch, also available from the footer menu.

### Changed
- The CPU, memory and disk tiles moved to the System tab; the header shows CPU and memory on every tab.
- The footer has labeled Disk tree, Graph and Activity buttons, and a menu for export, the terminal UI, updates and quit.
- Notifications cover dev servers in any language.

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
