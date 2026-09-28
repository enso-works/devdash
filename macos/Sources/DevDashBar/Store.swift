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
    case dev, docker, system, claude

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dev: "Dev"
        case .docker: "Docker"
        case .system: "System"
        case .claude: "Claude"
        }
    }
    var symbol: String {
        switch self {
        case .dev: "chevron.left.forwardslash.chevron.right"
        case .docker: "shippingbox"
        case .system: "gauge.with.dots.needle.33percent"
        case .claude: "sparkle"
        }
    }
}

enum Route: Hashable {
    case processDetail(pid: Int, name: String)
    case claudeProject(path: String)
    case cleanup
    case graph
    case heatmap
    case usage
    case settings
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
}

@MainActor
@Observable
final class Store {
    // Data from the bridge
    private(set) var hello: Hello?
    private(set) var system: SystemStats?
    private(set) var node: [NodeProcess] = []
    private(set) var docker: [DockerContainer] = []
    private(set) var processes: [GeneralProcess] = []
    private(set) var cleanup: [CleanupSuggestion] = []
    private(set) var claude: ClaudePayload?
    private(set) var usage: ClaudeUsage?
    private(set) var lastUpdate: Date?
    private(set) var connection: ConnectionState = .starting
    /// The devdash CLI the bridge runs, also used to open the terminal UI.
    private(set) var executable: URL?
    private(set) var cpuHistory: [Double] = []

    // UI state
    var tab: Tab = .dev {
        didSet { if tab == .claude { refreshClaude() } }
    }
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

    var config: BridgeConfig { hello?.config ?? BridgeConfig() }
    var hasClaude: Bool { hello?.hasClaude ?? false }
    var servers: [NodeProcess] { node.filter { !$0.ports.isEmpty } }
    var backgroundNode: [NodeProcess] { node.filter { $0.ports.isEmpty } }
    var activeCount: Int { servers.count + docker.count }
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
        docker = snapshot.docker
        processes = snapshot.processes
        cleanup = snapshot.cleanup
        if let usage = snapshot.usage {
            self.usage = usage
        }
        if let claude = snapshot.claude {
            self.claude = claude
            lastClaudeUpdate = .now
        }
        lastUpdate = Date(timeIntervalSince1970: snapshot.timestamp)
        cpuHistory.append(snapshot.system.cpuPercent)
        if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }

        let events = tracker.diff(node: snapshot.node, docker: snapshot.docker, watchedPorts: config.watchedPorts)
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

    /// Re-reads transcripts now; `force` also re-fetches plan limits instead of using the cached ones.
    func refreshUsage(force: Bool = false) {
        guard hasClaude, !pending.contains("usage") else { return }
        pending.insert("usage")
        Task {
            defer { pending.remove("usage") }
            if let payload = try? await bridge.request("usage", ["force": force], as: ClaudeUsage?.self) {
                usage = payload
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

/// Detects servers and containers appearing or disappearing between snapshots.
struct ChangeTracker {
    private var initialized = false
    private var nodePorts: [Int: (name: String, ports: [Int])] = [:]
    private var containers: [String: String] = [:]

    mutating func diff(node: [NodeProcess], docker: [DockerContainer], watchedPorts: [Int]) -> [String] {
        let currentPorts = Dictionary(uniqueKeysWithValues: node.map { ($0.pid, (name: $0.displayName, ports: $0.ports)) })
        let currentContainers = Dictionary(docker.map { ($0.containerId, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        defer {
            nodePorts = currentPorts
            containers = currentContainers
            initialized = true
        }
        guard initialized else { return [] }

        var events: [String] = []
        for (pid, previous) in nodePorts where currentPorts[pid] == nil && !previous.ports.isEmpty {
            events.append("\(previous.name) on \(portList(previous.ports)) exited")
        }
        for (id, name) in containers where currentContainers[id] == nil {
            events.append("Container \(name) stopped")
        }
        for proc in node where !proc.ports.isEmpty {
            let previous = nodePorts[proc.pid]?.ports ?? []
            if nodePorts[proc.pid] == nil {
                events.append("\(proc.displayName) started on \(portList(proc.ports))")
            } else {
                for port in proc.ports where watchedPorts.contains(port) && !previous.contains(port) {
                    events.append("Watched port :\(port) active (\(proc.displayName))")
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
