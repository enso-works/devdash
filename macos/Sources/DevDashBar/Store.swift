import Foundation
import Observation
import UserNotifications

enum ConnectionState: Equatable {
    case starting
    case connected
    case missingBinary
    case failed(String)
}

enum Tab: String, CaseIterable, Identifiable {
    case running, claude, codex, system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .running: "Running"
        case .claude: "Claude"
        case .codex: "Codex"
        case .system: "System"
        }
    }
    var symbol: String {
        switch self {
        case .running: "play.circle"
        case .claude: "sparkle"
        case .codex: "terminal"
        case .system: "gauge.with.dots.needle.33percent"
        }
    }
}

/// A coding agent whose plan usage devdash shows.
enum Agent: String, Hashable {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
    /// Key of the pending refresh, also the bridge command.
    var usageCommand: String { self == .claude ? "usage" : "codex_usage" }
}

/// How the Running tab groups its rows.
enum Grouping: String, CaseIterable, Identifiable {
    case project, type

    var id: String { rawValue }
    var title: String { self == .project ? "Project" : "Type" }
}

enum Route: Hashable {
    case processDetail(pid: Int, name: String)
    case serverURL(pid: Int, port: Int)
    /// All repositories, or one; `cleanup` shows only merged worktrees nothing runs in.
    case worktrees(repo: String?, cleanup: Bool)
    case claudeProject(path: String)
    case codexProject(path: String)
    case cleanup
    case graph
    case heatmap
    case usage(Agent)
    case settings
    case whatsNew
}

/// A run that didn't start because a process devdash didn't start holds its port.
struct PendingConflict: Equatable {
    let conflict: PortConflict
    let root: String
    let scriptId: String
    let title: String
    let projectName: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

enum SettingsKey {
    static let devdashPath = "devdashPath"
    static let showCount = "showCountInMenuBar"
    static let showUsage = "showUsageInMenuBar"
    static let notifications = "notificationsEnabled"
    static let editor = "editor"
    static let tab = "selectedTab"
    static let grouping = "runningGrouping"
    static let toggledGroups = "toggledRunningGroups"
    static let claudeProfile = "claudeProfile"
}

@MainActor
@Observable
final class Store {
    // Data from the bridge
    private(set) var hello: Hello?
    private(set) var system: SystemStats?
    private(set) var node: [NodeProcess] = []
    private(set) var servers: [Server] = []
    private(set) var runs: [ManagedRun] = []
    /// What each project can run, by project root.
    private(set) var runnable: [String: RunnableProject] = [:]
    private(set) var portConflict: PendingConflict?
    private(set) var worktreeRepos: [WorktreeRepo] = []
    private(set) var worktreeSizes: [String: Int64] = [:]
    private(set) var projects: [String: ProjectInfo] = [:]
    private(set) var docker: [DockerContainer] = []
    private(set) var processes: [GeneralProcess] = []
    private(set) var cleanup: [CleanupSuggestion] = []
    private(set) var claude: ClaudePayload?
    private(set) var usage: AgentUsage?
    private(set) var codex: CodexPayload?
    private(set) var codexUsage: AgentUsage?
    private(set) var lastUpdate: Date?
    private(set) var connection: ConnectionState = .starting
    /// The devdash CLI the bridge runs, also used to open the terminal UI.
    private(set) var executable: URL?
    private(set) var cpuHistory: [Double] = []

    // UI state
    var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: SettingsKey.tab) ?? "") ?? .running {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsKey.tab)
            if tab == .claude { refreshClaude() }
            if tab == .codex { refreshCodex() }
        }
    }
    var grouping: Grouping = Grouping(rawValue: UserDefaults.standard.string(forKey: SettingsKey.grouping) ?? "") ?? .project {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: SettingsKey.grouping) }
    }
    /// Groups whose collapsed state differs from their default.
    private(set) var toggledGroups = Set(UserDefaults.standard.stringArray(forKey: SettingsKey.toggledGroups) ?? []) {
        didSet { UserDefaults.standard.set(Array(toggledGroups), forKey: SettingsKey.toggledGroups) }
    }
    /// Dismissed "Needs you" items: id to the signature they had when dismissed.
    private(set) var dismissed: [String: String] = [:]
    private(set) var whatsNewSeen = UserDefaults.standard.string(forKey: WhatsNew.seenKey)
    /// Bumped to move keyboard focus into the filter field.
    private(set) var searchFocusRequest = 0
    var routes: [Route] = []
    var query = ""
    private(set) var toast: Toast?
    private(set) var pending: Set<String> = []

    @ObservationIgnored private let bridge = BridgeClient()
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var restartDelay: Double = 1
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var tracker = ChangeTracker()
    @ObservationIgnored private var lastClaudeUpdate: Date?
    @ObservationIgnored private var lastCodexUpdate: Date?

    var config: BridgeConfig { hello?.config ?? BridgeConfig() }
    var hasClaude: Bool { hello?.hasClaude ?? false }
    var hasCodex: Bool { hello?.hasCodex ?? false }
    var codexInstances: [CodexInstance] { codex?.instances ?? [] }

    func usage(for agent: Agent) -> AgentUsage? { agent == .claude ? usage : codexUsage }
    var appServers: [Server] { servers.filter { $0.kind == "app" } }
    var activeCount: Int { appServers.count + docker.count }
    var claudeInstances: [ClaudeInstance] { claude?.instances ?? [] }
    var claudeProfiles: [ClaudeProfile] { claude?.profiles ?? [] }
    /// The picked profile while the bridge switches, then the one it actually serves.
    var selectedClaudeProfile: String? {
        if let claudeProfile, claudeProfiles.contains(where: { $0.name == claudeProfile }) { return claudeProfile }
        return claude?.profile
    }
    /// Profile the Claude tab shows; nil until the user picks one, which means the configured default.
    private(set) var claudeProfile = UserDefaults.standard.string(forKey: SettingsKey.claudeProfile) {
        didSet { UserDefaults.standard.set(claudeProfile, forKey: SettingsKey.claudeProfile) }
    }
    var isUnderPressure: Bool {
        guard let system else { return false }
        return system.cpuPercent >= config.colorThresholdHigh || system.memoryPercent >= config.colorThresholdHigh
    }

    init() {
        bridge.onMessage = { [weak self] in self?.handle($0) }
        bridge.onExit = { [weak self] in self?.bridgeExited($0) }
        Notifier.requestAuthorization()
        start()
    }

    // MARK: - Bridge lifecycle

    func start() {
        restartTask?.cancel()
        let custom = UserDefaults.standard.string(forKey: SettingsKey.devdashPath) ?? ""
        executable = BridgeLocator.resolve(customPath: custom)
        guard let executable else {
            connection = .missingBinary
            return
        }
        connection = .starting
        do {
            try bridge.start(executable: executable)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func shutdown() {
        restartTask?.cancel()
        bridge.stop()
    }

    private func bridgeExited(_ reason: String) {
        connection = .failed(reason)
        restartTask?.cancel()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func handle(_ message: BridgeMessage) {
        switch message {
        case .hello(let hello):
            self.hello = hello
            connection = .connected
            restartDelay = 1
            if hello.hasClaude, let claudeProfile { sendClaudeProfile(claudeProfile) }
        case .snapshot(let snapshot):
            apply(snapshot)
        case .error(let message):
            NSLog("devdash bridge: %@", message)
        case .result:
            break
        }
    }

    private func apply(_ snapshot: Snapshot) {
        connection = .connected
        system = snapshot.system
        node = snapshot.node
        servers = snapshot.servers ?? snapshot.node.map(Server.init(node:))
        if let worktrees = snapshot.worktrees { worktreeRepos = worktrees }
        runs = snapshot.runs ?? []
        if let runnable = snapshot.runnable {
            self.runnable = Dictionary(runnable.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        }
        projects = Dictionary((snapshot.projects ?? []).map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        docker = snapshot.docker
        processes = snapshot.processes
        cleanup = snapshot.cleanup
        if let usage = snapshot.usage, isCurrentProfile(usage.profile) {
            self.usage = usage
        }
        if let claude = snapshot.claude {
            self.claude = claude
            lastClaudeUpdate = .now
        }
        if let codexUsage = snapshot.codexUsage { self.codexUsage = codexUsage }
        if let codex = snapshot.codex {
            self.codex = codex
            lastCodexUpdate = .now
        }
        lastUpdate = Date(timeIntervalSince1970: snapshot.timestamp)
        cpuHistory.append(snapshot.system.cpuPercent)
        if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }

        let events = tracker.diff(servers: servers, docker: snapshot.docker, runs: runs, watchedPorts: config.watchedPorts)
        if UserDefaults.standard.object(forKey: SettingsKey.notifications) as? Bool ?? true {
            Notifier.post(events)
        }
    }

    // MARK: - Commands

    func refresh() {
        Task { try? await bridge.send("refresh") }
    }

    func refreshClaude() {
        guard hasClaude else { return }
        if let lastClaudeUpdate, Date.now.timeIntervalSince(lastClaudeUpdate) < 5 { return }
        Task {
            guard let payload = try? await bridge.request("refresh_claude", as: ClaudePayload.self) else { return }
            claude = payload
            lastClaudeUpdate = .now
        }
    }

    func refreshCodex() {
        guard hasCodex else { return }
        if let lastCodexUpdate, Date.now.timeIntervalSince(lastCodexUpdate) < 5 { return }
        Task {
            guard let payload = try? await bridge.request("refresh_codex", as: CodexPayload.self) else { return }
            codex = payload
            lastCodexUpdate = .now
        }
    }

    /// Shows another profile's projects, sessions and usage in the Claude tab.
    func selectClaudeProfile(_ name: String) {
        guard name != selectedClaudeProfile else { return }
        claudeProfile = name
        usage = nil
        sendClaudeProfile(name)
    }

    private func sendClaudeProfile(_ name: String) {
        Task {
            guard let payload = try? await bridge.request("claude_profile", ["name": name], as: ClaudePayload?.self) else { return }
            claude = payload
            lastClaudeUpdate = .now
        }
    }

    private func isCurrentProfile(_ profile: String?) -> Bool {
        guard let profile, let current = selectedClaudeProfile ?? claudeProfile else { return true }
        return profile == current
    }

    /// Re-reads transcripts now; `force` also re-fetches plan limits instead of using the cached ones.
    func refreshUsage(_ agent: Agent, force: Bool = false) {
        let key = agent.usageCommand
        guard agent == .claude ? hasClaude : hasCodex, !pending.contains(key) else { return }
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            guard let payload = try? await bridge.request(key, ["force": force], as: AgentUsage?.self) else { return }
            switch agent {
            case .claude: if isCurrentProfile(payload.profile) { usage = payload }
            case .codex: codexUsage = payload
            }
        }
    }

    func isPending(_ key: String) -> Bool { pending.contains(key) }

    func kill(pid: Int, label: String) {
        let key = "pid-\(pid)"
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            do {
                try await bridge.send("kill", ["pid": pid])
                showToast("Killed \(label)")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func stop(_ container: DockerContainer) {
        let key = "ctr-\(container.containerId)"
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            do {
                try await bridge.send("stop_container", ["container_id": container.containerId])
                showToast("Stopped \(container.displayName)")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func stopStack(_ project: String) {
        let containers = docker.filter { $0.composeProject == project }
        let key = "stack-\(project)"
        pending.insert(key)
        containers.forEach { pending.insert("ctr-\($0.containerId)") }
        Task {
            defer {
                pending.remove(key)
                containers.forEach { pending.remove("ctr-\($0.containerId)") }
            }
            let items: [[String: Any]] = containers.map { ["action_type": "stop_container", "container_id": $0.containerId] }
            do {
                let result = try await bridge.request("cleanup", ["items": items], as: CleanupResult.self)
                showToast("Stopped \(result.stopped) of \(containers.count) in \(project)", isError: result.failed > 0)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    /// Kills every server and stops every container of a Running group.
    func stopGroup(_ group: RunningGroup) {
        let key = "group-\(group.id)"
        // Servers devdash started stop with their whole run, which also ends the script that started them.
        let runIds = Set(group.servers.compactMap(\.runId) + group.runs.filter(\.isAlive).map(\.id))
        let targets = group.servers.filter { !$0.isBackground && $0.runId == nil }
        pending.insert(key)
        targets.forEach { pending.insert("pid-\($0.pid)") }
        group.containers.forEach { pending.insert("ctr-\($0.containerId)") }
        Task {
            defer {
                pending.remove(key)
                targets.forEach { pending.remove("pid-\($0.pid)") }
                group.containers.forEach { pending.remove("ctr-\($0.containerId)") }
            }
            var stoppedRuns = 0
            for id in runIds where (try? await bridge.send("stop_run", ["run": id])) != nil { stoppedRuns += 1 }
            let items: [[String: Any]] = targets.map { ["action_type": "kill", "pid": $0.pid] }
                + group.containers.map { ["action_type": "stop_container", "container_id": $0.containerId] }
            do {
                let result = items.isEmpty
                    ? CleanupResult(killed: 0, stopped: 0, failed: 0)
                    : try await bridge.request("cleanup", ["items": items], as: CleanupResult.self)
                let done = result.killed + result.stopped + stoppedRuns
                let total = items.count + runIds.count
                showToast("Stopped \(done) of \(total) in \(group.name)", isError: result.failed > 0 || stoppedRuns < runIds.count)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func runCleanup(_ items: [CleanupSuggestion]) async {
        let payload: [[String: Any]] = items.map { item in
            var dict: [String: Any] = ["action_type": item.actionType]
            if let pid = item.pid { dict["pid"] = pid }
            if let containerId = item.containerId { dict["container_id"] = containerId }
            return dict
        }
        do {
            let result = try await bridge.request("cleanup", ["items": payload], as: CleanupResult.self)
            var parts: [String] = []
            if result.killed > 0 { parts.append("killed \(result.killed) process\(result.killed == 1 ? "" : "es")") }
            if result.stopped > 0 { parts.append("stopped \(result.stopped) container\(result.stopped == 1 ? "" : "s")") }
            if result.failed > 0 { parts.append("\(result.failed) failed") }
            showToast(parts.isEmpty ? "Nothing cleaned up" : "Cleanup: " + parts.joined(separator: ", "), isError: result.failed > 0)
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func export() {
        Task {
            do {
                let result = try await bridge.request("export", as: ExportResult.self)
                showToast("Exported snapshot")
                Launcher.revealInFinder(result.path)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Running scripts

    /// Whether the bridge can start scripts (a devdash CLI from 0.7 on).
    var canRun: Bool { !runnable.isEmpty }

    func run(id: String) -> ManagedRun? { runs.first { $0.id == id } }

    /// The run a script has, while it's running or waiting to restart.
    func liveRun(root: String, scriptId: String) -> ManagedRun? {
        runs.first { $0.projectRoot == root && $0.scriptId == scriptId && $0.isAlive }
    }

    /// Runs without a server row of their own: still starting, without a port (a worker), or ended.
    func runsWithoutServers() -> [ManagedRun] {
        let shown = Set(servers.compactMap(\.runId))
        return runs.filter { !shown.contains($0.id) }
    }

    var crashedRuns: [ManagedRun] { runs.filter(\.isCrashed) }

    /// Projects that can run something and have nothing on screen: the recent Claude and Codex projects.
    var readyToRun: [RunnableProject] {
        var busy = Set(servers.map(\.projectRoot))
        busy.formUnion(docker.compactMap(\.projectRoot))
        busy.formUnion(claudeInstances.compactMap(\.projectRoot))
        busy.formUnion(codexInstances.compactMap(\.projectRoot))
        busy.formUnion(runs.map(\.projectRoot))
        return runnable.values
            .filter { !busy.contains($0.root) && !$0.scripts.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Starts a script. With `stopping`, first stops the process that holds its port.
    func run(_ script: RunScript, in project: RunnableProject, stopping pid: Int? = nil) {
        start(root: project.root, scriptId: script.id, title: script.title, projectName: project.name, stopping: pid)
    }

    private func start(root: String, scriptId: String, title: String, projectName: String, stopping pid: Int? = nil) {
        let key = "run-\(root)#\(scriptId)"
        guard !pending.contains(key) else { return }
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            var args: [String: Any] = ["root": root, "script": scriptId]
            if let pid { args["stop_pid"] = pid }
            do {
                let result = try await bridge.request("run_script", args, as: RunResult.self)
                handle(result, root: root, scriptId: scriptId, title: title, projectName: projectName, verb: "Started")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func handle(_ result: RunResult, root: String, scriptId: String, title: String, projectName: String, verb: String) {
        if let conflict = result.conflict {
            portConflict = PendingConflict(conflict: conflict, root: root, scriptId: scriptId, title: title, projectName: projectName)
            showToast("Port \(conflict.port) is in use by \(conflict.label)", isError: true)
        } else if let run = result.run {
            if portConflict?.root == root && portConflict?.scriptId == scriptId { portConflict = nil }
            runs.removeAll { $0.id == run.id }
            runs.append(run)
            showToast("\(verb) \(title) in \(projectName)")
        }
    }

    /// Stops the process holding the port, then starts the run that wanted it.
    func resolvePortConflict() {
        guard let pending = portConflict else { return }
        portConflict = nil
        start(root: pending.root, scriptId: pending.scriptId, title: pending.title, projectName: pending.projectName,
              stopping: pending.conflict.pid)
    }

    func dismissPortConflict() { portConflict = nil }

    func stopRun(_ run: ManagedRun) {
        let key = "run-\(run.id)"
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            do {
                try await bridge.send("stop_run", ["run": run.id])
                runs.removeAll { $0.id == run.id }
                showToast("Stopped \(run.title) in \(run.projectName)")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func restartRun(_ run: ManagedRun) {
        let key = "run-\(run.id)"
        guard !pending.contains(key) else { return }
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            do {
                let result = try await bridge.request("restart_run", ["run": run.id], as: RunResult.self)
                handle(result, root: run.projectRoot, scriptId: run.scriptId, title: run.title, projectName: run.projectName,
                       verb: run.isAlive ? "Restarted" : "Started")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    /// Removes an ended run from the list.
    func clearRun(_ run: ManagedRun) {
        runs.removeAll { $0.id == run.id }
        Task { try? await bridge.send("clear_run", ["run": run.id]) }
    }

    func setRestartOnCrash(_ run: ManagedRun, _ on: Bool) {
        Task {
            do {
                let updated = try await bridge.request("restart_on_crash", ["run": run.id, "on": on], as: ManagedRun.self)
                if let index = runs.firstIndex(where: { $0.id == updated.id }) { runs[index] = updated }
                showToast(on ? "\(run.title) restarts when it crashes" : "\(run.title) stays down when it crashes")
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Worktrees

    /// The worktree a folder is in: the deepest match, since agent worktrees often live inside the
    /// main checkout (`<repo>/.claude/worktrees/...`).
    func worktree(containing path: String) -> Worktree? {
        worktreeRepos.lazy.flatMap(\.worktrees)
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    func repo(of worktree: Worktree) -> WorktreeRepo? {
        worktreeRepos.first { $0.worktrees.contains(worktree) }
    }

    /// The repository a project root belongs to, when it has linked worktrees.
    func worktreeRepo(containing root: String) -> WorktreeRepo? {
        worktreeRepos.first { $0.worktrees.contains { $0.path == root } }
    }

    /// Dev servers and Claude and Codex sessions running inside a worktree.
    func activity(in worktree: Worktree) -> (servers: [Server], sessions: [ClaudeInstance], codex: [CodexInstance]) {
        (servers.filter { self.worktree(containing: $0.cwdFull)?.path == worktree.path },
         claudeInstances.filter { self.worktree(containing: $0.cwdFull)?.path == worktree.path },
         codexInstances.filter { self.worktree(containing: $0.cwdFull)?.path == worktree.path })
    }

    func status(of worktree: Worktree) -> String {
        let activity = activity(in: worktree)
        return activity.servers.isEmpty && activity.sessions.isEmpty && activity.codex.isEmpty ? worktree.status : "running"
    }

    /// Merged worktrees with nothing running and no edits for a day: safe to remove.
    var idleMergedWorktrees: [Worktree] {
        let dayAgo = Date().addingTimeInterval(-86_400)
        return worktreeRepos.flatMap(\.worktrees).filter { status(of: $0) == "merged" && $0.lastActivity < dayAgo }
    }

    func refreshWorktrees() {
        Task { try? await bridge.send("refresh_worktrees") }
    }

    /// Sizes one at a time, since `du` over node_modules is slow and the bridge has few workers.
    func loadSizes(for worktrees: [Worktree]) async {
        for worktree in worktrees where !worktree.prunable && worktreeSizes[worktree.path] == nil {
            // try? flattens the optional result, so null (du failed) and errors both skip.
            guard let size = try? await bridge.request("worktree_size", ["path": worktree.path], as: Int64?.self) else { continue }
            worktreeSizes[worktree.path] = size
        }
    }

    func remove(_ worktree: Worktree, deleteBranch: Bool) {
        let key = "wt-\(worktree.path)"
        pending.insert(key)
        Task {
            defer { pending.remove(key) }
            do {
                let result = try await bridge.request(
                    "remove_worktree", ["path": worktree.path, "delete_branch": deleteBranch], as: RemoveWorktreeResult.self
                )
                worktreeSizes[worktree.path] = nil
                if result.branchDeleted {
                    showToast("Removed \(worktree.folder) and branch \(result.branch)")
                } else if deleteBranch, !result.note.isEmpty {
                    showToast("Removed \(worktree.folder), kept branch \(result.branch) (\(result.note))")
                } else {
                    showToast("Removed \(worktree.folder)")
                }
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func processDetail(pid: Int) async throws -> ProcessDetail {
        try await bridge.request("process_detail", ["pid": pid], as: ProcessDetail.self)
    }

    func graph() async throws -> GraphData {
        try await bridge.request("graph", as: GraphData.self)
    }

    func heatmap() async throws -> HeatmapData? {
        try await bridge.request("heatmap", as: HeatmapData?.self)
    }

    func projectDetail(path: String) async throws -> ProjectDetail {
        try await bridge.request("project_detail", ["path": path], as: ProjectDetail.self)
    }

    func projectSessions(path: String) async throws -> [ClaudeSession] {
        try await bridge.request("project_sessions", ["path": path], as: [ClaudeSession].self)
    }

    // MARK: - Navigation and feedback

    func push(_ route: Route) { routes.append(route) }
    func pop() { _ = routes.popLast() }

    func focusSearch() { searchFocusRequest += 1 }

    func isCollapsed(_ group: RunningGroup) -> Bool {
        isCollapsed(id: group.id, byDefault: group.collapsedByDefault)
    }

    func isCollapsed(id: String, byDefault: Bool) -> Bool {
        toggledGroups.contains(id) ? !byDefault : byDefault
    }

    func toggleCollapsed(_ group: RunningGroup) { toggleCollapsed(id: group.id) }

    func toggleCollapsed(id: String) {
        if toggledGroups.contains(id) { toggledGroups.remove(id) } else { toggledGroups.insert(id) }
    }

    /// The welcome tour on a fresh install, or release notes for versions not seen yet.
    var whatsNew: (welcome: Bool, releases: [WhatsNew.Release])? {
        guard let current = WhatsNew.currentVersion, whatsNewSeen != current else { return nil }
        if UserDefaults.standard.bool(forKey: WhatsNew.welcomeKey) { return (true, []) }
        let releases = WhatsNew.releases(after: whatsNewSeen)
        return releases.isEmpty ? nil : (false, releases)
    }

    func markWhatsNewSeen() {
        guard let current = WhatsNew.currentVersion else { return }
        UserDefaults.standard.set(current, forKey: WhatsNew.seenKey)
        UserDefaults.standard.removeObject(forKey: WhatsNew.welcomeKey)
        whatsNewSeen = current
    }

    func dismiss(_ item: AttentionItem) { dismissed[item.id] = item.signature }
    func isDismissed(_ item: AttentionItem) -> Bool { dismissed[item.id] == item.signature }

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    var editor: Editor {
        Editor(rawValue: UserDefaults.standard.string(forKey: SettingsKey.editor) ?? "") ?? .auto
    }

    func openInEditor(_ path: String) {
        if let name = Launcher.openInEditor(path, editor: editor) {
            showToast("Opening in \(name)")
        } else {
            showToast("No editor CLI found (code or cursor)", isError: true)
        }
    }
}

/// Detects dev servers and containers appearing or disappearing between snapshots.
/// Services and background processes are not reported.
struct ChangeTracker {
    private var initialized = false
    private var serverPorts: [Int: (name: String, ports: [Int])] = [:]
    private var containers: [String: String] = [:]
    private var runStatuses: [String: String] = [:]

    mutating func diff(servers: [Server], docker: [DockerContainer], runs: [ManagedRun], watchedPorts: [Int]) -> [String] {
        // Servers devdash started come and go on Run, Stop and Restart; their crashes are reported below.
        let apps = servers.filter { $0.kind == "app" && !$0.isManaged }
        let currentPorts = Dictionary(apps.map { ($0.pid, (name: $0.reportName, ports: $0.ports)) }, uniquingKeysWith: { a, _ in a })
        let currentContainers = Dictionary(docker.map { ($0.containerId, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let currentRuns = Dictionary(runs.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        defer {
            serverPorts = currentPorts
            containers = currentContainers
            runStatuses = currentRuns
            initialized = true
        }
        guard initialized else { return [] }

        var events: [String] = []
        for run in runs where runStatuses[run.id] == "running" && run.status != "running" {
            switch run.status {
            case "restarting": events.append("\(run.title) crashed in \(run.projectName), restarting")
            case "crashed" where run.gaveUp: events.append("\(run.title) in \(run.projectName) keeps crashing, stopped restarting it")
            case "crashed": events.append("\(run.title) crashed in \(run.projectName) (exit code \(run.exitCode.map(String.init) ?? "?"))")
            default: break
            }
        }
        for (pid, previous) in serverPorts where currentPorts[pid] == nil && !previous.ports.isEmpty {
            events.append("\(previous.name) on \(portList(previous.ports)) exited")
        }
        for (id, name) in containers where currentContainers[id] == nil {
            events.append("Container \(name) stopped")
        }
        for server in apps where !server.ports.isEmpty {
            let previous = serverPorts[server.pid]?.ports ?? []
            if serverPorts[server.pid] == nil {
                events.append("\(server.reportName) started on \(portList(server.ports))")
            } else {
                for port in server.ports where watchedPorts.contains(port) && !previous.contains(port) {
                    events.append("Watched port :\(port) active (\(server.reportName))")
                }
            }
        }
        return events
    }

    private func portList(_ ports: [Int]) -> String {
        ports.map { ":\($0)" }.joined(separator: ", ")
    }
}

enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ events: [String]) {
        guard available, !events.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if events.count <= 2 {
            content.title = "devdash"
            content.body = events.joined(separator: "\n")
        } else {
            content.title = "devdash: \(events.count) changes"
            content.body = events.prefix(4).joined(separator: "\n")
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
