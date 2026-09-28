import AppKit
import Foundation

/// GUI apps start with a minimal PATH; child processes need the usual developer locations.
enum ShellEnvironment {
    static let extraPaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.docker/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/Applications/OrbStack.app/Contents/MacOS/xbin",
        ]
    }()

    static var path: String {
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (extraPaths + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    static func which(_ command: String) -> URL? {
        for dir in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

enum BridgeLocator {
    /// The CLI embedded in release builds, next to its own Python runtime.
    static var bundled: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/devdash"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Resolution order: user setting, bundled CLI, path baked in at bundle time, well-known install locations.
    static func resolve(customPath: String) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        let trimmed = customPath.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { candidates.append((trimmed as NSString).expandingTildeInPath) }
        if let bundled { candidates.append(bundled.path) }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "DevDashCommand") as? String, !baked.isEmpty {
            candidates.append(baked)
        }
        if let env = ProcessInfo.processInfo.environment["DEVDASH_BIN"] { candidates.append(env) }
        candidates.append("\(NSHomeDirectory())/.local/bin/devdash")
        candidates.append("\(NSHomeDirectory())/.devdash/.venv/bin/devdash")
        if let found = ShellEnvironment.which("devdash") { candidates.append(found.path) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Links the bundled CLI into ~/.local/bin so `devdash` also works in a terminal.
enum CommandLineTool {
    static let link = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/devdash")

    enum State: Equatable {
        /// No bundled CLI, or the app runs from a read-only location (disk image, App Translocation).
        case unavailable
        case linked
        /// Nothing there, or a symlink to another install that can be replaced.
        case notLinked(current: String?)
        /// A regular file we won't overwrite.
        case blocked
    }

    static var state: State {
        guard let bundled = BridgeLocator.bundled,
              !bundled.path.hasPrefix("/Volumes/"), !bundled.path.contains("/AppTranslocation/") else { return .unavailable }
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            return target == bundled.path ? .linked : .notLinked(current: target)
        }
        return fm.fileExists(atPath: link.path) ? .blocked : .notLinked(current: nil)
    }

    static func install() throws {
        guard let bundled = BridgeLocator.bundled else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { try fm.removeItem(at: link) }
        try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
    }
}

enum Editor: String, CaseIterable, Identifiable {
    case auto, vscode, cursor

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        }
    }

    /// Returns the CLI to invoke and its display name. Auto prefers VS Code, matching the TUI.
    var resolved: (url: URL, name: String)? {
        switch self {
        case .vscode: ShellEnvironment.which("code").map { ($0, "VS Code") }
        case .cursor: ShellEnvironment.which("cursor").map { ($0, "Cursor") }
        case .auto: Editor.vscode.resolved ?? Editor.cursor.resolved
        }
    }
}

enum ClaudeLaunch: String, CaseIterable, Identifiable {
    case new, continueSession, plan, resume, skipPermissions, shell

    var id: String { rawValue }
    var label: String {
        switch self {
        case .new: "New session"
        case .skipPermissions: "Skip permissions"
        case .plan: "Plan mode"
        case .continueSession: "Continue last"
        case .resume: "Resume picker"
        case .shell: "Terminal here"
        }
    }
    var symbol: String {
        switch self {
        case .new: "plus.bubble"
        case .skipPermissions: "bolt.shield"
        case .plan: "list.bullet.clipboard"
        case .continueSession: "arrow.uturn.forward"
        case .resume: "clock.arrow.circlepath"
        case .shell: "terminal"
        }
    }
    var command: String {
        switch self {
        case .new: "claude"
        case .skipPermissions: "claude --dangerously-skip-permissions"
        case .plan: "claude --permission-mode plan"
        case .continueSession: "claude --continue"
        case .resume: "claude --resume"
        case .shell: "clear"
        }
    }
}

enum Launcher {
    static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openPort(_ port: Int) {
        openURL("http://localhost:\(port)")
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @discardableResult
    static func openInEditor(_ path: String, editor: Editor) -> String? {
        guard let resolved = editor.resolved else { return nil }
        run(resolved.url, [path])
        return resolved.name
    }

    /// Runs a shell command in a new Terminal window, like the TUI launch menu.
    static func runInTerminal(_ command: String, in directory: String) {
        let script = "cd \(shellQuote(directory)) && \(command)"
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source])
    }

    static func launchClaude(_ mode: ClaudeLaunch, in path: String) {
        runInTerminal(mode.command, in: path)
    }

    static func resumeClaude(session: String, in path: String) {
        runInTerminal("claude --resume \(shellQuote(session))", in: path)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ executable: URL, _ arguments: [String]) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ShellEnvironment.childEnvironment()
        try? process.run()
    }
}
