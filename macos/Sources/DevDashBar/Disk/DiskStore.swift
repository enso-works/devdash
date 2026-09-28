import AppKit
import Foundation
import Observation

struct VolumeInfo: Sendable {
    let name: String
    let total: Int64
    let free: Int64

    var used: Int64 { total - free }

    static func forPath(_ path: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return VolumeInfo(name: values.volumeName ?? "Disk", total: Int64(total), free: free)
    }
}

enum TreemapMode: String, CaseIterable, Identifiable {
    case size = "Size"
    case files = "Files"
    case age = "Age"
    var id: String { rawValue }
}

/// A destructive step waiting for the user to confirm it.
struct PendingDiskAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let run: @MainActor () async -> Void
}

@MainActor
@Observable
final class DiskStore {
    private(set) var root: DiskNode?
    private(set) var scanDate: Date?
    private(set) var scanDuration: Double = 0
    private(set) var isScanning = false
    private(set) var progress = DiskScanner.Progress()
    private(set) var suggestions: [DiskSuggestion] = []
    private(set) var volume: VolumeInfo?
    private(set) var hasFullDiskAccess = DiskAccess.hasFullDiskAccess
    private(set) var revision = 0
    private(set) var running: Set<String> = []
    private(set) var message: Toast?

    var viewRoot: DiskNode? { didSet { revision += 1 } }
    var selection: DiskNode?
    var hovered: DiskNode?
    var mode: TreemapMode = .size { didSet { revision += 1 } }
    var showHidden = true { didSet { revision += 1 } }
    var apparentSize = false { didSet { revision += 1 } }
    var depth = 4 { didSet { revision += 1 } }
    var pendingAction: PendingDiskAction?

    @ObservationIgnored private var scanner: DiskScanner?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var lastLowDiskNotice: Date?
    @ObservationIgnored private var didLoadCache = false

    static let rootKey = "diskScanRoot"

    var rootPath: String {
        get { UserDefaults.standard.string(forKey: Self.rootKey) ?? NSHomeDirectory() }
        set { UserDefaults.standard.set(newValue, forKey: Self.rootKey) }
    }

    var reclaimableTotal: Int64 { suggestions.reduce(0) { $0 + $1.size } }
    var skippedFolders: [DiskNode] {
        var result: [DiskNode] = []
        root?.forEach { if $0.skippedReason == "Needs Full Disk Access" { result.append($0) } }
        return result
    }

    init() {
        refreshVolume()
        if DiskDemo.isEnabled { loadCache() }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                self?.refreshVolume()
            }
        }
    }

    // MARK: - Loading and scanning

    /// Called when the window opens: shows the cached scan and rescans if it is missing or stale.
    func prepare() {
        refreshVolume()
        hasFullDiskAccess = DiskAccess.hasFullDiskAccess
        if !didLoadCache {
            didLoadCache = true
            loadCache()
            return
        }
        if root == nil && !isScanning { scan() }
    }

    func loadCache() {
        if DiskDemo.isEnabled {
            let root = DiskDemo.tree()
            DiskClassifier.apply(to: root)
            install(root: root, date: .now.addingTimeInterval(-1_500), duration: 48, suggestions: DiskSuggestionEngine.suggestions(for: root))
            volume = VolumeInfo(name: "Macintosh HD", total: 994 * 1_073_741_824, free: 107 * 1_073_741_824)
            return
        }
        let path = rootPath
        Task.detached(priority: .userInitiated) {
            let cached = DiskCache.read(rootPath: path)
            let prepared = cached.map { root, header -> (DiskNode, DiskCache.Header, [DiskSuggestion]) in
                DiskClassifier.apply(to: root)
                return (root, header, DiskSuggestionEngine.suggestions(for: root))
            }
            await MainActor.run {
                if let (root, header, suggestions) = prepared {
                    self.install(root: root, date: header.date, duration: header.duration, suggestions: suggestions)
                    // Refresh scans older than six hours in the background.
                    if Date.now.timeIntervalSince(header.date) > 6 * 3600 { self.scan() }
                } else {
                    self.scan()
                }
            }
        }
    }

    func scan(path: String? = nil) {
        guard !DiskDemo.isEnabled else { return }
        if let path { rootPath = path }
        scanner?.cancel()
        let scanner = DiskScanner(rootPath: rootPath, skip: DiskAccess.protectedFolders(fullDiskAccess: hasFullDiskAccess))
        self.scanner = scanner
        isScanning = true
        progress = .init()
        let started = Date()
        let rootPath = rootPath

        Task.detached(priority: .userInitiated) {
            scanner.run()
            guard !scanner.isCancelled else { return }
            let root = scanner.root
            DiskClassifier.apply(to: root)
            let suggestions = DiskSuggestionEngine.suggestions(for: root)
            let duration = Date().timeIntervalSince(started)
            try? DiskCache.write(root, header: .init(rootPath: rootPath, date: .now, duration: duration))
            await MainActor.run {
                guard self.scanner === scanner else { return }
                self.install(root: root, date: .now, duration: duration, suggestions: suggestions)
                self.isScanning = false
                self.scanner = nil
            }
        }
        Task { [weak self] in
            while let self, self.isScanning, self.scanner === scanner {
                self.progress = scanner.currentProgress
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        isScanning = false
    }

    private func install(root: DiskNode, date: Date, duration: Double, suggestions: [DiskSuggestion]) {
        let previousPath = viewRoot?.path
        self.root = root
        self.scanDate = date
        self.scanDuration = duration
        self.suggestions = suggestions
        viewRoot = previousPath.flatMap { find(path: $0, in: root) } ?? root
        selection = nil
        refreshVolume()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath)
        panel.prompt = "Scan"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            root = nil
            viewRoot = nil
            suggestions = []
            scan(path: url.path)
        }
    }

    func refreshVolume() {
        guard !DiskDemo.isEnabled else { return }
        volume = VolumeInfo.forPath(rootPath)
        notifyIfLow()
    }

    private func notifyIfLow() {
        guard let volume, volume.total > 0 else { return }
        let lowBytes: Int64 = 15 * 1024 * 1024 * 1024
        guard volume.free < lowBytes || Double(volume.free) / Double(volume.total) < 0.05 else { return }
        if let last = lastLowDiskNotice, Date.now.timeIntervalSince(last) < 12 * 3600 { return }
        lastLowDiskNotice = .now
        guard UserDefaults.standard.object(forKey: SettingsKey.notifications) as? Bool ?? true else { return }
        var events = ["Low disk space: \(ByteFormat.string(volume.free)) free on \(volume.name)"]
        if reclaimableTotal > 0 { events.append("Disk tree found \(ByteFormat.string(reclaimableTotal)) worth a look") }
        Notifier.post(events)
    }

    // MARK: - Navigation

    func zoom(into node: DiskNode) {
        guard node.isDirectory else { return }
        viewRoot = node
        selection = node
    }

    func zoomOut() {
        if let parent = viewRoot?.parent { viewRoot = parent }
    }

    private func find(path: String, in root: DiskNode) -> DiskNode? {
        var result: DiskNode?
        root.forEach { if result == nil && $0.path == path { result = $0 } }
        return result
    }

    // MARK: - Actions

    func confirm(_ suggestion: DiskSuggestion) {
        let list = suggestion.nodes.prefix(6).map { "\($0.displayPath)  (\(ByteFormat.string($0.total.allocated)))" }
        var lines = list
        if suggestion.nodes.count > 6 { lines.append("and \(suggestion.nodes.count - 6) more") }
        var message: String
        switch suggestion.action {
        case .trash:
            message = "Moves \(suggestion.nodes.count) item\(suggestion.nodes.count == 1 ? "" : "s") to the Trash (\(ByteFormat.string(suggestion.size))):\n\n" + lines.joined(separator: "\n")
            if !suggestion.pruneRepos.isEmpty {
                message += "\n\nThen runs git worktree prune in \(Set(suggestion.pruneRepos).count) repositor\(Set(suggestion.pruneRepos).count == 1 ? "y" : "ies")."
            }
        case .command(let command):
            message = "Runs `\(command)`, which frees \(suggestion.sizeText) in \(suggestion.nodes.first?.displayPath ?? "")."
        case .emptyTrash:
            message = "Permanently deletes everything in the Trash (\(ByteFormat.string(suggestion.size)))."
        }
        if let risk = suggestion.risk { message += "\n\n\(risk)." }
        pendingAction = PendingDiskAction(
            title: suggestion.title, message: message, confirmLabel: suggestion.actionLabel
        ) { [weak self] in
            await self?.perform(suggestion)
        }
    }

    func confirmTrash(_ node: DiskNode) {
        pendingAction = PendingDiskAction(
            title: "Move \(node.name) to Trash?",
            message: "\(node.displayPath)\n\(ByteFormat.string(node.total.allocated)) · \(node.total.files.formatted()) files",
            confirmLabel: "Move to Trash"
        ) { [weak self] in
            await self?.trash([node], label: node.name)
        }
    }

    func isRunning(_ suggestion: DiskSuggestion) -> Bool { running.contains(suggestion.id) }

    private func perform(_ suggestion: DiskSuggestion) async {
        guard !DiskDemo.isEnabled else { return show("Demo mode: nothing was changed") }
        running.insert(suggestion.id)
        defer { running.remove(suggestion.id) }
        switch suggestion.action {
        case .trash:
            await trash(suggestion.nodes, label: suggestion.title)
            for repo in Set(suggestion.pruneRepos) {
                _ = await Shell.run("git -C \(Launcher.shellQuote(repo)) worktree prune")
            }
        case .command(let command):
            let result = await Shell.run(command, in: NSHomeDirectory())
            if result.status == 0 {
                show("Ran \(command)")
            } else {
                show("\(command) failed: \(result.output.suffix(160))", isError: true)
            }
            await rescan(suggestion.nodes)
        case .emptyTrash:
            let result = await Shell.run(#"osascript -e 'tell application "Finder" to empty trash'"#)
            show(result.status == 0 ? "Emptied the Trash" : "Could not empty the Trash", isError: result.status != 0)
            await rescan(suggestion.nodes)
        }
    }

    private func trash(_ nodes: [DiskNode], label: String) async {
        guard !DiskDemo.isEnabled else { return show("Demo mode: nothing was changed") }
        var freed: Int64 = 0
        var failures: [String] = []
        for node in nodes {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
                freed += node.total.allocated
                remove(node)
            } catch {
                failures.append(node.name)
            }
        }
        finishMutation()
        if failures.isEmpty {
            show("Moved \(ByteFormat.string(freed)) to the Trash")
        } else {
            show("Could not trash \(failures.prefix(3).joined(separator: ", "))", isError: true)
        }
    }

    private func remove(_ node: DiskNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        parent.aggregate()
        parent.reaggregateAncestors()
        if selection === node { selection = parent }
        if let viewRoot, viewRoot === node || viewRoot.ancestors.contains(where: { $0 === node }) { self.viewRoot = parent }
    }

    /// Re-scans the given folders after a command changed them, and splices the results in.
    private func rescan(_ nodes: [DiskNode]) async {
        for node in nodes where node.isDirectory {
            let skip = DiskAccess.protectedFolders(fullDiskAccess: hasFullDiskAccess)
            let fresh: DiskNode = await Task.detached(priority: .userInitiated) {
                let scanner = DiskScanner(replacing: node, skip: skip)
                scanner.run()
                return scanner.root
            }.value
            guard let parent = node.parent, let index = parent.children.firstIndex(where: { $0 === node }) else { continue }
            fresh.parent = parent
            fresh.children.forEach { $0.parent = fresh }
            parent.children[index] = fresh
            parent.aggregate()
            parent.reaggregateAncestors()
            if selection === node { selection = fresh }
            if viewRoot === node { viewRoot = fresh }
        }
        finishMutation()
    }

    private func finishMutation() {
        guard let root else { return }
        DiskClassifier.apply(to: root)
        suggestions = DiskSuggestionEngine.suggestions(for: root)
        revision += 1
        refreshVolume()
        let path = rootPath
        let duration = scanDuration
        let date = scanDate ?? .now
        Task.detached(priority: .utility) {
            try? DiskCache.write(root, header: .init(rootPath: path, date: date, duration: duration))
        }
    }

    func show(_ text: String, isError: Bool = false) {
        message = Toast(message: text, isError: isError)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    /// Runs a command through the login shell so tools installed with Homebrew, nvm etc. are found.
    static func run(_ command: String, in directory: String = NSHomeDirectory()) async -> Result {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = ShellEnvironment.childEnvironment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return Result(status: -1, output: error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
