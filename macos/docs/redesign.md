# DevDash.app redesign

The menu bar app is the primary product. The terminal UI keeps working but does not drive design decisions.

## Goals

- Answer "what needs me right now?" in one glance, before any tab or click.
- Organize around projects, because that is how developers think: one project owns its dev servers, containers, Claude sessions, ports and repo state.
- Every feature is reachable by a visible label or a right-click, never only by an unlabeled icon.
- Room to add features (Claude alerts, repo health, stacks, sharing) without new banners or tabs piling up.

## Two surfaces

| Surface | Job | Contents |
|---|---|---|
| Popover | Glance and act in seconds | Needs you, Running, Projects, Claude, System |
| Dashboard window | Explore and manage | Overview, Projects, Claude, Disk tree, Dependency graph, Activity |

The Disk tree window already works this way. The Dashboard window absorbs it in phase 5.

## Popover layout

```
devdash  * live    CPU 23%  Mem 61%                  [refresh]
+- Needs you -----------------------------------------------+
| Claude in api-server is waiting for input          Open   |
| Session limit reached around 14:20 at this pace    72%    |
| 4 cleanup suggestions, 12 GB worth a look        Review   |
+-----------------------------------------------------------+
  Running  |  Projects  |  Claude  |  System
  [ Filter...                                    ] [Group v]
  v api-server  ~/code/api  main               [...]
      vite       node    :5173           180 MB   2%
      uvicorn    python  :8000            95 MB   0%
      postgres   docker  :5432            healthy
      Claude     running 12m
  v web  ...
  > Services (2)          homebrew postgres, redis
  > Background (5)        node processes without a port
  [Disk tree] [Graph] [Activity]              [...] [Settings]
```

## Roadmap

1. **Restructure the popover** (this spec): Needs you, Running grouped by project, dev servers in any language, labeled footer, What's new card.
2. **Claude session status**: working, waiting for input, done, via an opt-in Claude Code hook with transcript fallback. Usage pace forecast. Both feed Needs you and the menu bar icon.
3. **Projects tab**: every known project, running or not. Repo health (dirty, unpushed, stale worktrees, CI status, tags without a release) and project stacks (start, stop, restore after reboot).
4. **Share and link**: Share a port through a `cloudflared` quick tunnel. Link Claude sessions to the processes and containers they started, and suggest cleaning them up when the session ends. The filter field also runs actions ("share 3000", "stop web").
5. **Dashboard window**: sidebar window that takes in the Disk tree, Dependency graph and Activity heatmap.

---

## Phase 1 spec

### 1. Dev servers in any language (bridge)

Replace Node-only detection with a `servers` list: every process owned by the current user that listens on a TCP port, plus Node processes without a port (kept as background, as today).

**Included**
- Any user-owned process with a LISTEN socket, except those excluded below.
- Node processes without a port (background group).

**Excluded**
- Executables inside a `.app` bundle (Spotify, Figma, Raycast, Docker Desktop and OrbStack port forwarders; containers are listed separately).
- Executables under `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`.
- Processes owned by other users.

**Fields per server**

| Field | Example | Notes |
|---|---|---|
| `runtime` | `node`, `bun`, `deno`, `python`, `ruby`, `go`, `java`, `php`, `rust`, `postgres`, `redis`, `mysql`, `other` | From process name and argv[0]; drives the row icon |
| `kind` | `app`, `service`, `background` | `service` for database and cache servers (postgres, redis, mysql, mongod, memcached) and anything under Homebrew `opt/*/bin` started by launchd; `background` for Node processes with no port |
| `label` | `vite`, `uvicorn`, `next dev` | Most useful name: script or module from argv (`vite`, `-m uvicorn`, `rails server`), else process name |
| `project_root` | `/Users/x/code/api` | See project resolution |
| `project_name` | `api-server` | |
| existing Node fields | `pid`, `command`, `cpu_percent`, `memory_mb`, `ports`, `uptime`, `cwd`, `cwd_full` | |

**Project resolution** (shared by servers, containers and Claude instances, in `devdash/servers.py`)
- The project is the git repository the working directory is in. Outside a repository, it is the nearest folder with any of: `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`, `composer.json`, `deno.json`, `compose.yaml`, `docker-compose.yml`. Never go above the home folder.
- Name: `name` from `package.json`, `pyproject.toml` or `Cargo.toml` at the project root if present, else the folder name.
- Monorepos: the whole repository is one project, so a Compose file at the root and servers in `apps/web` land in the same group. A server inside a workspace package reports it as `package` (e.g. `web`), shown next to its name.
- Git worktrees are separate projects, since they are separate checkouts.
- Cached per directory, as `_find_project_name` does today.
- Containers: `project_root` comes from the `com.docker.compose.project.working_dir` label, resolved the same way. Containers without Compose labels have no project.
- Claude instances: `project_root` from their working directory.

**Snapshot changes**
- Add `servers`. Keep `node` unchanged so the terminal UI and older app builds keep working. The app falls back to `node` when talking to an older CLI.
- Add `projects`: name and git branch for every project root in the snapshot, read by the bridge so demo data can supply them too.
- Add `project_root` and `project_name` to each Docker container and Claude instance.
- Cleanup suggestions, idle tracking and the dependency graph stay Node-based in phase 1.
- Update `demo.py` so demo data covers several runtimes, a service, a multi-part project (servers, containers and a Claude session) and the Other and Background groups. README screenshots come only from demo data.

### 2. Needs you

A single list at the top of the popover, above the tabs, visible on every tab. It replaces the cleanup and disk banners.

**Item model:** `id`, `severity` (critical, warning, info), `symbol`, `title`, `detail`, primary action label and action, optional dismiss.

**Phase 1 sources**

| Source | When | Action |
|---|---|---|
| Bridge stopped | Bridge failed and data is stale | Retry |
| Cleanup | Any suggestions | Review (opens Cleanup) |
| Low disk | Below the existing low disk threshold (15 GiB or 5%) | Open Disk tree |
| Reclaimable space | Disk tree found more than 5 GB worth a look | Open Disk tree |
| Session limit | 5-hour or weekly limit at 80% or more | Open Usage |
| What's new | First launch after an update | See what's new, dismiss |

**Behavior**
- Sorted by severity, then by source order above.
- At most 3 rows; "N more" expands the rest.
- Hidden entirely when empty. No "all clear" row, because space in the popover is limited.
- Dismissing hides an item until its content changes (for example the cleanup count goes up). Stored in memory, reset on relaunch, except What's new, which is stored per version.
- Phases 2 to 4 add their own sources (Claude waiting, usage pace, CI failing, tag without a release) with no layout change.

### 3. Tabs

`Running`, `Claude`, `System` in phase 1. `Projects` appears in phase 3. The Claude tab stays hidden when Claude Code is not installed.

- `Cmd+1` to `Cmd+4` switch tabs. `Cmd+F` focuses the filter. `Esc` clears the filter, then closes the popover.
- The selected tab is remembered between openings.
- The CPU, memory and disk tiles move from the top of the popover to the System tab. The header shows compact `CPU 23%  Mem 61%` text instead, colored by the existing thresholds; clicking it opens the System tab.

### 4. Running tab

Merges today's Dev and Docker tabs.

**Group by project (default)**
- One group per `project_root` that has at least one server, container or Claude instance.
- Group order: groups with a Claude session waiting first (phase 2), then by most recently started item.
- Group header: project name, git branch, short path, item count. `...` menu: Open in editor, Reveal in Finder, Open in Terminal, New Claude session, Stop all.
- Stop all stops every server and container in the group and needs a second click to confirm, like the current kill button.
- Rows inside a group: servers (by first port), then containers, then Claude instances.
- Special groups at the bottom, collapsed by default:
  - **Services**: `kind == service` without a project (Homebrew postgres, redis).
  - **Other**: servers and containers without a project.
  - **Background**: Node processes without a port, with total memory, as today.
- Groups remember their collapsed state per project.

**Group by type**
- The `Group` menu next to the filter switches to: Servers, Containers (grouped by Compose project, as today), Claude, Services, Background. Stored in `@AppStorage`.

**Rows**
- Server row: runtime icon, label, project-relative path when different from the root, port chips (click opens `localhost:<port>`), memory, CPU. Click opens process detail as today.
- Container row: as today, plus port chips.
- Claude row: status, uptime. Click opens the Claude project view.
- Every row has a right-click menu with all its actions (Open port, Copy URL, Reveal, Open in editor, Show logs, Kill or Stop). Hover keeps showing the main action inline.

**Filter**
- Matches project name, label, command, path, port, PID, container name and image.
- If a project name matches, the whole group shows. Otherwise only matching rows show, inside their groups.
- Empty result: "No matches for 'x'" with a Clear button.

**Empty state**
- No servers or containers: "Nothing running", with a hint that dev servers in any language, containers and Claude sessions appear here.

### 5. Footer

```
[Disk tree] [Graph] [Activity]                  [...] [Settings]
```

- Labeled buttons for the three tools. Activity is hidden when Claude Code is not installed.
- `...` menu: Export JSON snapshot, Open terminal UI, What's new, Check for updates, Quit devdash.

### 6. What's new

- A bundled list of highlights per version (`WhatsNew.swift`, a few one-line entries each).
- On the first launch after the version changes, a What's new item appears in Needs you. Opening it shows the entries for every version since the last one seen.
- Not shown on a fresh install. First launch gets a short welcome item instead: what the tabs are and that Settings has notifications and launch at login. A fresh install is detected by an empty user defaults domain at startup, before anything writes to it.

### 7. Notifications

- `ChangeTracker` uses `servers` instead of `node`, so starts and exits of any dev server are reported. Services and background processes are not reported.

### 8. Not in phase 1

- Claude status and alerts, usage pace, repo health, stacks, Share, command actions in the filter, Dashboard window.
- Changes to the terminal UI beyond keeping `node` in the snapshot.
- Cleanup for non-Node servers.

### Acceptance

- With the demo bridge, the popover shows Needs you, grouped Running, Services, Other and Background groups, and the labeled footer. Screenshots rendered with `--render` from demo data.
- On a real machine: a Vite server, a Python server, a Compose stack started from the same repo and a Claude session there all appear in one group. Homebrew postgres appears under Services. Docker Desktop, OrbStack and GUI app ports do not appear.
- `--selftest` passes and checks `servers`, `project_root` on containers and Claude instances.
- The terminal UI still runs unchanged.
- No banner remains above the Running list. Every footer tool has a visible label.
