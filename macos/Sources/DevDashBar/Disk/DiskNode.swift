import Foundation

/// Totals for a subtree (or a directory's own files), split so hidden entries can be excluded.
struct DiskTotals: Sendable {
    var allocated: Int64 = 0
    var apparent: Int64 = 0
    var files: Int64 = 0
    var dirs: Int64 = 0
    var hiddenAllocated: Int64 = 0
    var hiddenApparent: Int64 = 0
    var hiddenFiles: Int64 = 0
    var newest: Double = 0 // epoch seconds of the most recent modification

    mutating func add(_ other: DiskTotals, hidden: Bool) {
        allocated += other.allocated
        apparent += other.apparent
        files += other.files
        dirs += other.dirs
        if hidden {
            hiddenAllocated += other.allocated
            hiddenApparent += other.apparent
            hiddenFiles += other.files
        } else {
            hiddenAllocated += other.hiddenAllocated
            hiddenApparent += other.hiddenApparent
            hiddenFiles += other.hiddenFiles
        }
        newest = max(newest, other.newest)
    }

    func size(apparent useApparent: Bool, includeHidden: Bool) -> Int64 {
        if useApparent { return includeHidden ? apparent : apparent - hiddenApparent }
        return includeHidden ? allocated : allocated - hiddenAllocated
    }

    func fileCount(includeHidden: Bool) -> Int64 {
        includeHidden ? files : files - hiddenFiles
    }
}

struct ProjectMarkers: OptionSet, Sendable {
    let rawValue: UInt16
    static let git = ProjectMarkers(rawValue: 1 << 0)
    static let packageJSON = ProjectMarkers(rawValue: 1 << 1)
    static let cargo = ProjectMarkers(rawValue: 1 << 2)
    static let swiftPackage = ProjectMarkers(rawValue: 1 << 3)
    static let python = ProjectMarkers(rawValue: 1 << 4)
    static let gradle = ProjectMarkers(rawValue: 1 << 5)
    static let podfile = ProjectMarkers(rawValue: 1 << 6)
    static let goMod = ProjectMarkers(rawValue: 1 << 7)
    static let xcodeProject = ProjectMarkers(rawValue: 1 << 8)

    /// Byte lengths of the names checked by forFile, so most files skip String creation.
    static let candidateLengths: Set<Int> = [4, 6, 7, 8, 10, 12, 13, 14, 15, 16, 18, 19]

    static func forFile(_ name: String) -> ProjectMarkers {
        switch name {
        case "package.json": .packageJSON
        case "Cargo.toml": .cargo
        case "Package.swift": .swiftPackage
        case "pyproject.toml", "requirements.txt", "setup.py", "Pipfile": .python
        case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts": .gradle
        case "Podfile": .podfile
        case "go.mod": .goMod
        case ".git": .git // worktrees and submodules use a .git file
        default: []
        }
    }
}

/// One directory (or large file) in a scan. Small files are folded into their directory's `own` totals.
final class DiskNode: @unchecked Sendable, Identifiable {
    let name: String
    weak var parent: DiskNode?
    var children: [DiskNode] = []
    let isDirectory: Bool
    let isHidden: Bool
    var own = DiskTotals()
    var total = DiskTotals()
    var markers: ProjectMarkers = []
    var denied = false        // could not be read (permissions)
    var skippedReason: String? // intentionally not scanned
    var category: DiskCategory = .other
    var reclaimable = false   // part of a cleanup suggestion

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, parent: DiskNode?, isDirectory: Bool, isHidden: Bool) {
        self.name = name
        self.parent = parent
        self.isDirectory = isDirectory
        self.isHidden = isHidden
    }

    var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// Short label: "~" for the home folder, the folder name for other scan roots.
    var label: String {
        guard parent == nil else { return name }
        return name == NSHomeDirectory() ? "~" : (name as NSString).lastPathComponent
    }

    var displayPath: String {
        let home = NSHomeDirectory()
        let full = path
        return full.hasPrefix(home) ? "~" + full.dropFirst(home.count) : full
    }

    var ancestors: [DiskNode] {
        var result: [DiskNode] = []
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }

    var isInsideReclaimable: Bool {
        reclaimable || ancestors.contains { $0.reclaimable }
    }

    func child(named name: String) -> DiskNode? {
        children.first { $0.name == name }
    }

    /// Recomputes `total` for this subtree, bottom-up.
    func aggregate() {
        var result = own
        for child in children {
            child.aggregate()
            result.add(child.total, hidden: child.isHidden)
        }
        if isDirectory { result.dirs += 1 }
        total = result
    }

    /// Recomputes totals on the path from this node to the root, after a subtree changed.
    func reaggregateAncestors() {
        var node = parent
        while let current = node {
            var result = current.own
            for child in current.children { result.add(child.total, hidden: child.isHidden) }
            result.dirs += 1
            current.total = result
            node = current.parent
        }
    }

    /// Folds children smaller than `threshold` into `own` to keep large trees light in memory.
    func prune(below threshold: Int64) {
        var kept: [DiskNode] = []
        for child in children {
            if child.total.allocated < threshold && !child.reclaimable {
                own.add(child.total, hidden: child.isHidden)
            } else {
                child.prune(below: threshold)
                kept.append(child)
            }
        }
        children = kept
    }

    /// Visits every node depth-first.
    func forEach(_ body: (DiskNode) -> Void) {
        body(self)
        for child in children { child.forEach(body) }
    }
}

enum DiskCategory: String, CaseIterable, Sendable {
    case code, agent, toolchains, synced, git, media, documents, cache, other

    var label: String {
        switch self {
        case .code: "Code"
        case .agent: "Agent scratch"
        case .toolchains: "Toolchains"
        case .synced: "Synced"
        case .git: "Git"
        case .media: "Media"
        case .documents: "Documents"
        case .cache: "Cache"
        case .other: "Other"
        }
    }
}

enum ByteFormat {
    /// Binary units like the screenshot: 881 GiB, 9.7 GiB, 512 MiB.
    static func string(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return value >= 100 ? String(format: "%.0f %@", value, units[unit]) : String(format: "%.1f %@", value, units[unit])
    }

    static func compact(_ bytes: Int64) -> String {
        string(bytes).replacingOccurrences(of: " ", with: "")
    }
}
