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

struct DockerContainer: Decodable, Sendable, Identifiable, Hashable {
    let containerId: String
    let name: String
    let image: String
    let status: String
    let ports: String
    let created: String
    let composeProject: String
    let composeService: String

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

    var id: Int { pid }
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

struct ClaudeStats: Decodable, Sendable {
    let totalSessions: Int
    let totalMessages: Int
    let modelUsage: [ModelUsage]
    let dailyActivity: [LabeledValue]
    let hourCounts: [Int]
}

struct ClaudePayload: Decodable, Sendable {
    let instances: [ClaudeInstance]
    let projects: [ClaudeProject]
    let sessions: [ClaudeSession]
    let stats: ClaudeStats?
}

struct Snapshot: Decodable, Sendable {
    let timestamp: Double
    let system: SystemStats
    let node: [NodeProcess]
    let docker: [DockerContainer]
    let processes: [GeneralProcess]
    let cleanup: [CleanupSuggestion]
    let claude: ClaudePayload?
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
