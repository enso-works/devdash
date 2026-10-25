import Foundation

// Mirrors the JSON emitted by `devdash --serve` (devdash/bridge.py).
// Keys arrive snake_case and are decoded with .convertFromSnakeCase.

struct BridgeConfig: Decodable, Sendable {
    var refreshRate: Double = 3
    var processLimit: Int = 80
    var watchedPorts: [Int] = []
    var colorThresholdLow: Double = 50
    var colorThresholdHigh: Double = 80
    var cleanupIdleThresholdCpu: Double = 1
    var cleanupIdleThresholdMinutes: Int = 10
    var cleanupDockerStaleDays: Int = 7
}

struct Hello: Decodable, Sendable {
    let version: String
    let hasClaude: Bool
    /// nil from a CLI older than 0.8.
    let hasCodex: Bool?
    let config: BridgeConfig
}

struct SystemStats: Decodable, Sendable {
    let cpuPercent: Double
    let cpuCount: Int
    let memoryTotalGb: Double
    let memoryUsedGb: Double
    let memoryPercent: Double
    let swapTotalGb: Double
    let swapUsedGb: Double
    let swapPercent: Double
    let diskTotalGb: Double
    let diskUsedGb: Double
    let diskFreeGb: Double
    let diskPercent: Double
    let netSentPerSec: Double?
    let netRecvPerSec: Double?
}

struct NodeProcess: Decodable, Sendable, Identifiable, Hashable {
    let pid: Int
    let name: String
    let command: String
    let cpuPercent: Double
    let memoryMb: Double
    let cwd: String
    let ports: [Int]
    let uptime: String
    let project: String
    let cwdFull: String

    var id: Int { pid }
    var displayName: String {
        if !project.isEmpty { return project }
        let folder = (cwdFull as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? name : folder
    }
}

/// Any process of the current user listening on a port, plus Node processes without one (`kind == "background"`).
struct Server: Decodable, Sendable, Identifiable, Hashable {
    let pid: Int
    let name: String
    let label: String
    let runtime: String
    let kind: String
    let command: String
    let cpuPercent: Double
    let memoryMb: Double
    let ports: [Int]
    let uptime: String
    let started: Double
    let cwd: String
    let cwdFull: String
    let projectRoot: String
    let projectName: String
    let package: String
    /// Nil from a devdash CLI older than 0.5.
    let urls: [ServerURL]?
    let exposeHint: String?
    /// The managed run this process belongs to, when devdash started it. Nil from a CLI older than 0.7.
    let runId: String?

    var id: Int { pid }
    var isManaged: Bool { runId != nil }
    var isBackground: Bool { kind == "background" }
    var isApp: Bool { kind == "app" }

    func url(for port: Int) -> ServerURL {
        urls?.first { $0.port == port } ?? ServerURL(port: port, local: "http://localhost:\(port)", lan: nil, exposed: false)
    }

    /// The URL for the first port, which is the app itself for most dev servers.
    var primaryURL: ServerURL? { ports.first.map(url(for:)) }
    var isService: Bool { kind == "service" }
    var displayName: String { label.isEmpty ? name : label }
    /// The command with paths shortened: relative to the working directory, `~` for home, and the
    /// interpreter by name only (`node node_modules/.bin/vite` instead of two absolute paths).
    var shortCommand: String {
        var text = command
        if cwdFull.count > 1 { text = text.replacingOccurrences(of: cwdFull + "/", with: "") }
        text = text.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")
        let parts = text.split(separator: " ", maxSplits: 1)
        guard let first = parts.first, first.contains("/") else { return text }
        let name = (String(first) as NSString).lastPathComponent
        return parts.count > 1 ? "\(name) \(parts[1])" : name
    }

    /// Name used in notifications, where there is no group header for context.
    var reportName: String { projectName.isEmpty ? displayName : "\(projectName) \(displayName)" }
}

extension Server {
    /// For a devdash CLI older than 0.3, which only reports Node processes.
    init(node: NodeProcess) {
        self.init(
            pid: node.pid, name: node.name, label: node.displayName, runtime: "node",
            kind: node.ports.isEmpty ? "background" : "app", command: node.command,
            cpuPercent: node.cpuPercent, memoryMb: node.memoryMb, ports: node.ports, uptime: node.uptime,
            started: 0, cwd: node.cwd, cwdFull: node.cwdFull, projectRoot: "", projectName: node.project, package: "",
            urls: nil, exposeHint: nil, runId: nil
        )
    }
}

/// A port's address on this Mac, and on the local network when other devices can reach it.
struct ServerURL: Decodable, Sendable, Hashable {
    let port: Int
    let local: String
    /// Nil when the port listens on loopback only, or the Mac isn't on a network.
    let lan: String?
    /// Whether the port listens beyond loopback.
    let exposed: Bool
}

/// A dev server devdash started (devdash/supervisor.py).
struct ManagedRun: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let projectRoot: String
    let projectName: String
    let scriptId: String
    let name: String
    let command: String
    let cwd: String
    let package: String
    let log: String
    /// Also the process group, which every process the script starts belongs to.
    let pid: Int
    let started: Double
    /// "running", "restarting" (waiting to restart after a crash), "exited" or "crashed".
    let status: String
    let exitCode: Int?
    let ended: Double
    let restartOnCrash: Bool
    let restarts: [Double]
    /// Crashed too often in a row, so restart on crash stopped.
    let gaveUp: Bool
    let ports: [Int]

    var isAlive: Bool { status == "running" || status == "restarting" }
    var isCrashed: Bool { status == "crashed" }
    /// "dev" or "web dev" for a script of a workspace package.
    var title: String { package.isEmpty ? name : "\(package) \(name)" }
    var startDate: Date { Date(timeIntervalSince1970: started) }
    var endDate: Date { Date(timeIntervalSince1970: ended) }
}

/// Something a project can run: a package.json script or a Procfile entry (devdash/runnable.py).
struct RunScript: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let command: String
    let source: String
    let cwd: String
    let package: String

    var title: String { package.isEmpty ? name : "\(package) \(name)" }
}

struct RunnableProject: Decodable, Sendable, Hashable, Identifiable {
    let root: String
    let name: String
    let scripts: [RunScript]
    /// What "Run" starts: the script run last time, else the first.
    let `default`: String?
    /// A recent Claude project with nothing on screen, offered under "Ready to run".
    let recent: Bool

    var id: String { root }
    var defaultScript: RunScript? { scripts.first { $0.id == `default` } ?? scripts.first }
}

struct PortConflict: Decodable, Sendable, Hashable {
    let port: Int
    let pid: Int
    let label: String
    let project: String
}

struct RunResult: Decodable, Sendable {
    let run: ManagedRun?
    let conflict: PortConflict?
}

/// A repository with linked worktrees (devdash/worktrees.py).
struct WorktreeRepo: Decodable, Sendable, Hashable, Identifiable {
    let root: String
    let name: String
    let defaultBranch: String
    let worktrees: [Worktree]

    var id: String { root }
}

struct Worktree: Decodable, Sendable, Hashable, Identifiable {
    let path: String
    let branch: String
    let head: String
    let isMain: Bool
    let locked: Bool
    let prunable: Bool
    let changes: Int
    let merged: Bool
    let upstreamGone: Bool
    let lastCommit: Double
    let subject: String
    let lastTouched: Double
    let createdBy: String
    /// "missing", "changes", "merged", "stale" or "active". Store.status(of:) adds "running".
    let status: String

    var id: String { path }
    var displayBranch: String { branch.isEmpty ? "detached at \(head)" : branch }
    var folder: String { (path as NSString).lastPathComponent }
    var lastActivity: Date { Date(timeIntervalSince1970: max(lastTouched, lastCommit)) }
}

struct RemoveWorktreeResult: Decodable, Sendable {
    let path: String
    let branch: String
    let branchDeleted: Bool
    let note: String
}

/// Name and git branch of a project root that appears in the snapshot.
struct ProjectInfo: Decodable, Sendable, Hashable {
    let root: String
    let name: String
    let branch: String
}

struct DockerContainer: Decodable, Sendable, Identifiable, Hashable {
    let containerId: String
    let name: String
    let image: String
    let status: String
    let ports: String
    let created: String
    let composeProject: String
    let composeService: String
    let projectRoot: String?
    let projectName: String?

    var id: String { containerId }
    var displayName: String { composeService.isEmpty ? name : composeService }
    var isHealthy: Bool { !status.localizedCaseInsensitiveContains("unhealthy") }

    /// Host-side ports parsed from strings like "0.0.0.0:5436->5432/tcp".
    var hostPorts: [Int] {
        let regex = #/:(\d+)->/#
        var seen = Set<Int>()
        return ports.matches(of: regex).compactMap { Int($0.1) }.filter { seen.insert($0).inserted }
    }
}

struct GeneralProcess: Decodable, Sendable, Identifiable, Hashable {
    let pid: Int
    let name: String
    let cpuPercent: Double
    let memoryMb: Double
    let memoryPercent: Double
    let status: String
    let user: String
    let command: String

    var id: Int { pid }
}

struct CleanupSuggestion: Codable, Sendable, Identifiable, Hashable {
    let category: String
    let label: String
    let reason: String
    let actionType: String
    let pid: Int?
    let containerId: String?

    var id: String { pid.map { "pid-\($0)" } ?? "ctr-\(containerId ?? label)" }
}

struct ClaudeInstance: Decodable, Sendable, Identifiable, Hashable {
    let pid: Int
    let project: String
    let cwd: String
    let tty: String
    let cpuPercent: Double
    let memoryMb: Double
    let uptime: String
    let cwdFull: String
    let projectRoot: String?
    let projectName: String?
    /// Claude profile the session runs as, nil when its environment is unreadable.
    let profile: String?
    /// Profile that claims the session's folder in ~/.config/claude-profiles.
    let expectedProfile: String?

    var id: Int { pid }
    var isWrongAccount: Bool {
        guard let profile, let expectedProfile else { return false }
        return profile != expectedProfile
    }
}

struct ClaudeProject: Decodable, Sendable, Identifiable, Hashable {
    let name: String
    let path: String
    let sessions: Int
    let messages: Int
    let lastActive: String
    let isRunning: Bool

    var id: String { path }
}

struct ClaudeSession: Decodable, Sendable, Identifiable, Hashable {
    let sessionId: String
    let summary: String
    let firstPrompt: String
    let messageCount: Int
    let gitBranch: String
    let created: String
    let modified: String
    let projectPath: String
    let isSidechain: Bool

    var id: String { sessionId }
    var title: String {
        let text = summary.isEmpty ? firstPrompt : summary
        return text.isEmpty ? "Untitled session" : text
    }
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

/// A `[label, value]` pair encoded as a JSON array.
struct LabeledValue: Decodable, Sendable, Hashable {
    let label: String
    let value: Double

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        label = try c.decode(String.self)
        value = try c.decode(Double.self)
    }
}

/// `[model, input, output, cache_read]`.
struct ModelUsage: Decodable, Sendable, Hashable {
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        model = try c.decode(String.self)
        input = try c.decode(Int.self)
        output = try c.decode(Int.self)
        cacheRead = try c.decode(Int.self)
    }
}

// MARK: - Codex (devdash/codex.py)

struct CodexInstance: Decodable, Sendable, Identifiable, Hashable {
    let pid: Int
    let project: String
    let cwd: String
    let tty: String
    let cpuPercent: Double
    let memoryMb: Double
    let uptime: String
    let cwdFull: String
    let projectRoot: String?
    let projectName: String?

    var id: Int { pid }
}

struct CodexProject: Decodable, Sendable, Identifiable, Hashable {
    let name: String
    let path: String
    let sessions: Int
    let tokens: Int
    let lastActive: String
    let isRunning: Bool

    var id: String { path }
}

struct CodexSession: Decodable, Sendable, Identifiable, Hashable {
    let sessionId: String
    let title: String
    let projectPath: String
    let gitBranch: String
    let model: String
    let tokens: Int
    /// "cli", or "vscode" for the Codex app and editor extensions.
    let source: String
    let modified: String
    let lastActive: String

    var id: String { sessionId }
    var displayTitle: String { title.isEmpty ? "Untitled thread" : title }
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

struct CodexPayload: Decodable, Sendable {
    let instances: [CodexInstance]
    let projects: [CodexProject]
    let sessions: [CodexSession]
}

struct ClaudeStats: Decodable, Sendable {
    let totalSessions: Int
    let totalMessages: Int
    let modelUsage: [ModelUsage]
    let dailyActivity: [LabeledValue]
    let hourCounts: [Int]
}

struct ClaudeProfile: Decodable, Sendable, Identifiable, Hashable {
    let name: String
    let email: String?
    let dir: String?
    /// ~/.claude, which Claude Code uses when CLAUDE_CONFIG_DIR is unset.
    let defaultDir: Bool?
    /// GitHub login the profile's folders use with gh (its `github` line in ~/.config/claude-profiles).
    let github: String?
    /// Whether gh holds a login for it; nil without a GitHub login or gh.
    let githubSignedIn: Bool?

    var id: String { name }
}

struct ClaudePayload: Decodable, Sendable {
    /// Profile whose projects, sessions and stats this payload holds.
    let profile: String?
    let profiles: [ClaudeProfile]?
    let instances: [ClaudeInstance]
    let projects: [ClaudeProject]
    let sessions: [ClaudeSession]
    let stats: ClaudeStats?
}

struct Snapshot: Decodable, Sendable {
    let timestamp: Double
    let system: SystemStats
    let node: [NodeProcess]
    let servers: [Server]?
    /// Dev servers devdash started, nil from a CLI older than 0.7.
    let runs: [ManagedRun]?
    /// Only sent when it changed.
    let runnable: [RunnableProject]?
    let projects: [ProjectInfo]?
    /// Only sent when the worktree scan changed, about once a minute at most.
    let worktrees: [WorktreeRepo]?
    let docker: [DockerContainer]
    let processes: [GeneralProcess]
    let cleanup: [CleanupSuggestion]
    let claude: ClaudePayload?
    let usage: AgentUsage?
    let codex: CodexPayload?
    let codexUsage: AgentUsage?
}

struct ProcessDetail: Decodable, Sendable {
    struct Child: Decodable, Sendable, Hashable { let pid: Int; let name: String }
    struct Connection: Decodable, Sendable, Hashable { let status: String; let laddr: String; let raddr: String }

    let pid: Int
    let name: String
    let status: String
    let user: String
    let cwd: String
    let cpuPercent: Double
    let rssMb: Double?
    let vmsMb: Double?
    let threads: Int?
    let command: String
    let children: [Child]
    let connections: [Connection]
    let openFiles: [String]
    let environment: [[String]]
}

struct PortOwner: Decodable, Sendable, Hashable {
    let kind: String
    let label: String
    let group: String
    let pid: Int?
    let containerId: String?
    let ports: [Int]
}

struct DependencyEdge: Decodable, Sendable, Hashable {
    let fromLabel: String
    let fromKind: String
    let fromGroup: String
    let toLabel: String
    let toKind: String
    let toGroup: String
    let port: Int
}

struct GraphData: Decodable, Sendable {
    let owners: [PortOwner]
    let edges: [DependencyEdge]
}

struct HeatmapData: Decodable, Sendable {
    let weeklyHeatmap: [[Int]]
    let weekDayLabels: [String]
    let projectTimes: [LabeledValue]
    let dailyMessages: [LabeledValue]
    let dailySessions: [LabeledValue]
    let dailyTokens: [LabeledValue]
    let totalSessions: Int
    let totalMessages: Int
    let totalHours: Double
}

struct ProjectDetail: Decodable, Sendable {
    let projectPath: String
    let name: String
    let totalSessions: Int
    let totalMessages: Int
    let totalLinesAdded: Int
    let totalLinesRemoved: Int
    let totalFilesModified: Int
    let gitCommits: Int
    let toolsUsed: [LabeledValue]
    let languages: [LabeledValue]
    let memoryContent: String?
    let recentSessions: [ClaudeSession]
}

struct ExportResult: Decodable, Sendable { let path: String }
struct CleanupResult: Decodable, Sendable { let killed: Int; let stopped: Int; let failed: Int }

// MARK: - Plan usage (devdash/claude_usage.py, devdash/codex_usage.py)

struct UsageTotals: Decodable, Sendable, Hashable {
    let cost: Double
    let input: Int
    /// Includes reasoning.
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    /// Codex only, nil from a CLI older than 0.8.
    let reasoning: Int?
    let requests: Int

    var tokens: Int { input + output + cacheWrite + cacheRead }
}

struct UsagePeriods: Decodable, Sendable {
    let today: UsageTotals
    let week: UsageTotals
    let month: UsageTotals
    let all: UsageTotals
}

struct ModelCost: Decodable, Sendable, Hashable, Identifiable {
    let model: String
    let cost: Double
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    let requests: Int

    var id: String { model }

    var displayName: String { Self.displayName(model) }

    /// "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5", "gpt-6.1-sol" -> "GPT-6.1-Sol".
    static func displayName(_ model: String) -> String {
        if !model.hasPrefix("claude-") {
            return model.split(separator: "-")
                .map { $0 == "gpt" ? "GPT" : $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: model.hasPrefix("gpt-") ? "-" : " ")
        }
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first(where: { Int($0) == nil }) else { return model }
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}

struct PlanLimit: Decodable, Sendable, Hashable, Identifiable {
    let label: String
    let group: String
    let percent: Double
    let severity: String
    let resetsAt: Double?
    let isActive: Bool

    var id: String { label }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
}

struct ExtraUsage: Decodable, Sendable {
    let used: Double?
    let limit: Double?
    let currency: String
    let utilization: Double?
}

struct Credits: Decodable, Sendable {
    let balance: Double
    let unlimited: Bool
}

/// Plan limits and API-equivalent cost of Claude Code or Codex.
struct AgentUsage: Decodable, Sendable {
    /// Claude profile; nil for Codex.
    let profile: String?
    let plan: String?
    let limits: [PlanLimit]
    let extraUsage: ExtraUsage?
    /// Codex credits, when the plan has any.
    let credits: Credits?
    let error: String?
    /// Something to know about the numbers, such as limits from the last local report.
    let note: String?
    let limitsUpdated: Double
    let periods: UsagePeriods
    let session: UsageTotals?
    let models: [ModelCost]
    let projects: [LabeledValue]
    let daily: [LabeledValue]
    let unpricedModels: [String]

    var sessionLimit: PlanLimit? { limits.first { $0.group == "session" } }
}
