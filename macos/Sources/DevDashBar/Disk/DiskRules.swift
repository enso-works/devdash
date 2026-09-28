import Foundation

// MARK: - Categories

enum DiskClassifier {
    private static let home = NSHomeDirectory()

    private static let agentNames: Set<String> = [
        ".codex", ".claude", ".herdr", ".cursor", ".gemini", ".microsandbox", ".opencode", ".windsurf",
        ".continue", ".aider", ".amp", ".goose", ".roo", ".cline", "worktrees", "tries",
    ]
    private static let toolchainNames: Set<String> = [
        ".cargo", ".rustup", ".nvm", ".bun", ".deno", ".pyenv", ".rbenv", ".sdkman", ".platformio",
        ".volta", ".m2", ".gradle", ".android", ".cocoapods", ".gem", ".colima", ".docker", ".espressif",
        ".swiftpm", ".dotnet", ".julia", ".elan", ".opam", ".ghcup", ".conda", "miniconda3", "anaconda3",
        ".rye", ".fnm", ".asdf", ".mise", ".foundry", ".solana", ".rustup-toolchains",
    ]
    private static let cacheNames: Set<String> = [".cache", "Caches", "cache", "Cache", ".npm", ".pnpm-store", "DerivedData"]
    private static let syncedNames: Set<String> = ["Dropbox", "Google Drive", "OneDrive", "Sync", "iCloud Drive", "Nextcloud", "pCloud Drive"]
    private static let codeRoots: Set<String> = [
        "src", "code", "Code", "Projects", "PrivateProjects", "Developer", "dev", "repos", "workspace", "work", "git",
    ]
    private static let mediaExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "m4v", "webm", "mp3", "wav", "flac", "aac", "m4a", "aiff",
        "jpg", "jpeg", "png", "heic", "raw", "cr2", "arw", "dng", "psd", "tiff",
    ]

    private static let pathRules: [(String, DiskCategory)] = [
        (home + "/Library/Caches", .cache),
        (home + "/Library/Logs", .cache),
        (home + "/Library/CloudStorage", .synced),
        (home + "/Library/Mobile Documents", .synced),
        (home + "/Library/Developer", .toolchains),
        (home + "/Library/Android", .toolchains),
        (home + "/Library/pnpm", .cache),
        (home + "/Library/Application Support/Steam", .media),
        (home + "/.local/share/mise", .toolchains),
        (home + "/.local/share/pnpm", .cache),
        (home + "/.local/share/Steam", .media),
        (home + "/go", .toolchains),
        (home + "/Movies", .media),
        (home + "/Music", .media),
        (home + "/Pictures", .media),
        (home + "/Documents", .documents),
        (home + "/Desktop", .documents),
        (home + "/Downloads", .documents),
    ]

    static func apply(to root: DiskNode) {
        visit(root, path: root.path, inherited: .other)
    }

    private static func visit(_ node: DiskNode, path: String, inherited: DiskCategory) {
        node.category = category(for: node, path: path, inherited: inherited)
        for child in node.children {
            visit(child, path: path.hasSuffix("/") ? path + child.name : path + "/" + child.name, inherited: node.category)
        }
    }

    private static func category(for node: DiskNode, path: String, inherited: DiskCategory) -> DiskCategory {
        if let rule = pathRules.first(where: { $0.0 == path }) { return rule.1 }
        let name = node.name
        if name == ".git" { return .git }
        if !node.isDirectory {
            let ext = (name as NSString).pathExtension.lowercased()
            if mediaExtensions.contains(ext) { return .media }
            return inherited
        }
        if agentNames.contains(name) { return .agent }
        if cacheNames.contains(name) { return .cache }
        if toolchainNames.contains(name) { return inherited == .agent ? .agent : .toolchains }
        if name == "Steam" || name == "steamapps" { return .media }
        if name.hasSuffix(".photoslibrary") { return .media }
        if node.parent?.path == home, syncedNames.contains(name) { return .synced }
        if node.parent?.path == home, codeRoots.contains(name) { return .code }
        switch inherited {
        case .agent, .cache, .toolchains, .git, .synced, .media:
            return inherited
        default:
            return node.markers.contains(.git) ? .code : inherited
        }
    }
}

// MARK: - Suggestions

struct DiskSuggestion: Identifiable, Sendable {
    enum Action: Sendable {
        case trash
        case command(String)
        case emptyTrash
    }

    let id: String
    let title: String
    let detail: String
    let kind: String
    let nodes: [DiskNode]
    let action: Action
    var risk: String?
    /// Git repositories to `git worktree prune` after the worktrees are trashed.
    var pruneRepos: [String] = []

    var size: Int64 { nodes.reduce(0) { $0 + $1.total.allocated } }
    /// Commands free only part of what they manage, so their size is an upper bound.
    var isEstimate: Bool {
        if case .command = action { return true }
        return false
    }
    var sizeText: String { (isEstimate ? "up to " : "") + ByteFormat.string(size) }
    var category: DiskCategory { nodes.first?.category ?? .other }

    var actionLabel: String {
        switch action {
        case .trash: "Move to Trash"
        case .command(let command): "Run \(command)"
        case .emptyTrash: "Empty Trash"
        }
    }
}

enum DiskSuggestionEngine {
    static let minimumSize: Int64 = 100 * 1024 * 1024
    static let idleDays: Double = 14

    private struct Artifact {
        let names: Set<String>
        let marker: ProjectMarkers
        let group: String
        let kind: String
    }

    private static let artifacts: [Artifact] = [
        Artifact(names: ["node_modules"], marker: .packageJSON, group: "node_modules", kind: "npm dependencies, reinstalled by your package manager"),
        Artifact(names: ["target"], marker: .cargo, group: "Rust target", kind: "Rust build output, rebuilt by cargo"),
        Artifact(names: [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".expo", ".vercel", ".output"], marker: .packageJSON, group: "JS build caches", kind: "framework build cache, rebuilt on next run"),
        Artifact(names: [".build"], marker: .swiftPackage, group: "SwiftPM .build", kind: "Swift build output, rebuilt by swift build"),
        Artifact(names: [".gradle", "build"], marker: .gradle, group: "Gradle build", kind: "Gradle build output, rebuilt by gradle"),
        Artifact(names: ["Pods"], marker: .podfile, group: "CocoaPods", kind: "CocoaPods dependencies, restored by pod install"),
        Artifact(names: [".venv", "venv", ".tox", ".nox"], marker: .python, group: "Python virtualenvs", kind: "Python virtualenv, recreated from your lockfile"),
    ]

    private struct CacheRule {
        let path: String
        let title: String
        let action: DiskSuggestion.Action
        let kind: String
        var risk: String?
    }

    private static func cacheRules(home: String) -> [CacheRule] {
        [
            CacheRule(path: home + "/Library/Caches/Homebrew", title: "Homebrew downloads", action: .command("brew cleanup --prune=all"), kind: "old formula downloads"),
            CacheRule(path: home + "/.npm/_cacache", title: "npm cache", action: .command("npm cache clean --force"), kind: "package cache, re-downloaded when needed"),
            CacheRule(path: home + "/Library/pnpm/store", title: "pnpm store", action: .command("pnpm store prune"), kind: "removes packages no project uses"),
            CacheRule(path: home + "/.local/share/pnpm/store", title: "pnpm store", action: .command("pnpm store prune"), kind: "removes packages no project uses"),
            CacheRule(path: home + "/.pnpm-store", title: "pnpm store", action: .command("pnpm store prune"), kind: "removes packages no project uses"),
            CacheRule(path: home + "/Library/Caches/Yarn", title: "Yarn cache", action: .command("yarn cache clean"), kind: "package cache, re-downloaded when needed"),
            CacheRule(path: home + "/.bun/install/cache", title: "Bun cache", action: .command("bun pm cache rm"), kind: "package cache, re-downloaded when needed"),
            CacheRule(path: home + "/Library/Caches/pip", title: "pip cache", action: .trash, kind: "package cache, re-downloaded when needed"),
            CacheRule(path: home + "/.cache/uv", title: "uv cache", action: .command("uv cache clean"), kind: "package cache, re-downloaded when needed"),
            CacheRule(path: home + "/go/pkg/mod", title: "Go module cache", action: .command("go clean -modcache"), kind: "module cache, re-downloaded when needed"),
            CacheRule(path: home + "/Library/Caches/CocoaPods", title: "CocoaPods cache", action: .command("pod cache clean --all"), kind: "pod cache, re-downloaded when needed"),
            CacheRule(path: home + "/.gradle/caches", title: "Gradle caches", action: .trash, kind: "dependency cache, re-downloaded when needed"),
            CacheRule(path: home + "/.cargo/registry", title: "Cargo registry", action: .trash, kind: "crate cache, re-downloaded when needed"),
            CacheRule(path: home + "/Library/Developer/Xcode/DerivedData", title: "Xcode DerivedData", action: .trash, kind: "Xcode build cache, rebuilt on next build"),
            CacheRule(path: home + "/Library/Developer/Xcode/iOS DeviceSupport", title: "iOS DeviceSupport", action: .trash, kind: "debug symbols, recreated when a device connects"),
            CacheRule(path: home + "/Library/Developer/Xcode/watchOS DeviceSupport", title: "watchOS DeviceSupport", action: .trash, kind: "debug symbols, recreated when a device connects"),
            CacheRule(path: home + "/Library/Developer/CoreSimulator/Caches", title: "Simulator caches", action: .trash, kind: "simulator caches, regenerated"),
            CacheRule(path: home + "/Library/Developer/CoreSimulator/Devices", title: "iOS simulators", action: .command("xcrun simctl delete unavailable"), kind: "deletes simulators whose runtime is no longer installed; manage the rest in Xcode"),
            CacheRule(path: home + "/.colima", title: "Colima Docker VM", action: .command("docker system prune -f"), kind: "stopped containers, dangling images, build cache",
                      risk: "Removes stopped containers and unused build cache"),
            CacheRule(path: home + "/Library/Containers/com.docker.docker/Data/vms/0/data", title: "Docker Desktop disk", action: .command("docker system prune -f"), kind: "stopped containers, dangling images, build cache",
                      risk: "Removes stopped containers and unused build cache"),
            CacheRule(path: home + "/.android/avd", title: "Android emulators", action: .trash, kind: "emulator images",
                      risk: "Emulators have to be recreated in Android Studio"),
            CacheRule(path: home + "/.Trash", title: "Trash", action: .emptyTrash, kind: "already deleted files",
                      risk: "Emptying the Trash cannot be undone"),
        ]
    }

    private static let experimentNames: Set<String> = ["tries", "experiments", "scratch", "playground", "sandbox", "sandboxes"]
    private static let modelCaches: Set<String> = ["huggingface", "torch", "whisper", "ollama", "lm-studio", "llama.cpp"]

    static func suggestions(for root: DiskNode, now: Date = .now) -> [DiskSuggestion] {
        root.forEach { $0.reclaimable = false }
        let home = NSHomeDirectory()
        var index: [String: DiskNode] = [:]
        var claimed = Set<ObjectIdentifier>()
        var result: [DiskSuggestion] = []

        root.forEach { node in
            if node.isDirectory { index[node.path] = node }
        }

        func isFree(_ node: DiskNode) -> Bool {
            !claimed.contains(node.id) && !node.ancestors.contains { claimed.contains($0.id) }
        }
        func claim(_ nodes: [DiskNode]) {
            for node in nodes {
                claimed.insert(node.id)
                node.reclaimable = true
            }
        }
        func days(_ timestamp: Double) -> Int {
            timestamp > 0 ? max(0, Int(now.timeIntervalSince1970 - timestamp) / 86_400) : 0
        }
        func ageText(_ nodes: [DiskNode]) -> String {
            let oldest = nodes.map { days($0.total.newest) }.max() ?? 0
            return oldest > 0 ? "oldest \(oldest)d" : "recent"
        }

        // 1. Agent worktrees older than a week.
        root.forEach { node in
            guard node.name == "worktrees", node.category == .agent, isFree(node) else { return }
            let stale = node.children.filter { $0.isDirectory && days($0.total.newest) >= 7 }
            guard !stale.isEmpty else { return }
            var suggestion = DiskSuggestion(
                id: "worktrees:" + node.path,
                title: shortPath(node, home: home),
                detail: "\(stale.count) worktree\(stale.count == 1 ? "" : "s") · \(ageText(stale))",
                kind: "agent worktrees untouched for a week",
                nodes: stale,
                action: .trash
            )
            suggestion.pruneRepos = stale.compactMap { mainRepository(ofWorktree: $0.path) }
            result.append(suggestion)
            claim(stale)
        }

        // 2. Old experiments.
        root.forEach { node in
            guard node.isDirectory, experimentNames.contains(node.name), isFree(node) else { return }
            let stale = node.children.filter { $0.isDirectory && days($0.total.newest) >= 30 && isFree($0) }
            guard !stale.isEmpty else { return }
            result.append(DiskSuggestion(
                id: "experiments:" + node.path,
                title: shortPath(node, home: home) + " > 30 days",
                detail: "\(stale.count) experiment\(stale.count == 1 ? "" : "s") untouched · \(ageText(stale))",
                kind: "old experiments",
                nodes: stale,
                action: .trash
            ))
            claim(stale)
        }

        // 3. Known caches and tool data, with the tool's own cleanup command where there is one.
        for rule in cacheRules(home: home) {
            guard let node = index[rule.path], isFree(node) else { continue }
            var suggestion = DiskSuggestion(
                id: "cache:" + rule.path, title: rule.title, detail: shortPath(node, home: home),
                kind: rule.kind, nodes: [node], action: rule.action
            )
            suggestion.risk = rule.risk
            result.append(suggestion)
            claim([node])
        }

        // 4. Build artifacts in projects idle for two weeks, grouped by type.
        var artifactGroups: [String: [DiskNode]] = [:]
        root.forEach { node in
            guard node.isDirectory, let parent = node.parent else { return }
            guard let artifact = artifacts.first(where: { $0.names.contains(node.name) && parent.markers.contains($0.marker) }) else { return }
            guard isFree(node), !node.ancestors.contains(where: { $0.name == "node_modules" }) else { return }
            let activity = parent.children.filter { $0 !== node && !isArtifact($0.name) }.map(\.total.newest).max() ?? 0
            guard Double(days(max(activity, parent.own.newest))) >= idleDays else { return }
            artifactGroups[artifact.group, default: []].append(node)
        }
        for artifact in artifacts {
            guard let nodes = artifactGroups[artifact.group] else { continue }
            let members = nodes.filter { $0.total.allocated >= 1024 * 1024 }.sorted { $0.total.allocated > $1.total.allocated }
            guard !members.isEmpty else { continue }
            let title = members.count == 1
                ? shortPath(members[0], home: home)
                : "\(artifact.group) in \(members.count) idle projects"
            result.append(DiskSuggestion(
                id: "artifact:" + artifact.group,
                title: title,
                detail: "idle \(Int(idleDays))d+ · largest \(members[0].parent?.name ?? "")",
                kind: artifact.kind,
                nodes: members,
                action: .trash
            ))
            claim(members)
        }

        // 5. Other large caches.
        for cacheRoot in [home + "/Library/Caches", home + "/.cache"] {
            guard let node = index[cacheRoot] else { continue }
            for child in node.children where child.total.allocated >= 500 * 1024 * 1024 && isFree(child) {
                var suggestion = DiskSuggestion(
                    id: "cache:" + child.path, title: shortPath(child, home: home), detail: "app cache",
                    kind: "regenerable", nodes: [child], action: .trash
                )
                if modelCaches.contains(child.name.lowercased()) {
                    suggestion.risk = "Downloaded models will have to be downloaded again"
                }
                result.append(suggestion)
                claim([child])
            }
        }

        // 6. Old downloads.
        if let downloads = index[home + "/Downloads"] {
            let old = downloads.children.filter { days($0.total.newest) >= 90 && $0.total.allocated >= 50 * 1024 * 1024 && isFree($0) }
            if !old.isEmpty {
                result.append(DiskSuggestion(
                    id: "downloads", title: "Downloads older than 90 days",
                    detail: "\(old.count) item\(old.count == 1 ? "" : "s") · \(ageText(old))",
                    kind: "old downloads", nodes: old.sorted { $0.total.allocated > $1.total.allocated }, action: .trash,
                    risk: "Check these before trashing them"
                ))
                claim(old)
            }
        }

        // 7. Large files untouched for six months.
        var bigFiles: [DiskNode] = []
        root.forEach { node in
            if !node.isDirectory, node.total.allocated >= 1024 * 1024 * 1024, days(node.total.newest) >= 180, isFree(node) {
                bigFiles.append(node)
            }
        }
        if !bigFiles.isEmpty {
            result.append(DiskSuggestion(
                id: "bigfiles", title: "Large files untouched for 6 months",
                detail: "\(bigFiles.count) file\(bigFiles.count == 1 ? "" : "s") · \(ageText(bigFiles))",
                kind: "large old files", nodes: bigFiles.sorted { $0.total.allocated > $1.total.allocated }, action: .trash,
                risk: "Check these before trashing them"
            ))
            claim(bigFiles)
        }

        return result.filter { $0.size >= minimumSize }.sorted { $0.size > $1.size }
    }

    private static func isArtifact(_ name: String) -> Bool {
        artifacts.contains { $0.names.contains(name) }
    }

    static func shortPath(_ node: DiskNode, home: String) -> String {
        let components = node.displayPath.split(separator: "/")
        if components.count <= 3 { return node.displayPath.replacingOccurrences(of: "~/", with: "") }
        return components.suffix(2).joined(separator: "/")
    }

    /// A linked worktree has a `.git` file pointing at `<repo>/.git/worktrees/<name>`.
    static func mainRepository(ofWorktree path: String) -> String? {
        guard let text = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }
}
