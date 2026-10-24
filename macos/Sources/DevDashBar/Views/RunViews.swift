import AppKit
import SwiftUI

// MARK: - Chips

/// Marks a server devdash started, with the script's name.
struct ManagedChip: View {
    let run: ManagedRun

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: run.restartOnCrash ? "arrow.triangle.2.circlepath" : "play.fill")
                .font(.system(size: 7, weight: .bold))
            Text(run.name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.accentColor.opacity(0.12), in: .capsule)
        .fixedSize()
        .help("Started by devdash: \(run.command)\(run.restartOnCrash ? "\nRestarts when it crashes" : "")")
    }
}

struct RunStatusChip: View {
    let run: ManagedRun

    var body: some View {
        let style = Self.style(run)
        Text(style.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(style.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(style.color.opacity(0.14), in: .capsule)
    }

    static func style(_ run: ManagedRun) -> (label: String, color: Color) {
        switch run.status {
        case "running": ("Running", .green)
        case "restarting": ("Restarting", .orange)
        case "crashed": ("Crashed", .red)
        default: ("Exited", .secondary)
        }
    }
}

// MARK: - Run rows

/// A run without a server row: starting, without a port (a worker, a watcher), or ended.
struct RunRow: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let run: ManagedRun
    var showProject = false

    var body: some View {
        HoverRow(onTap: { openLogs(run, openWindow) }) {
            HStack(spacing: 8) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(run.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text(run.command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(run.isCrashed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        } metrics: {
            RunStatusChip(run: run)
        } actions: {
            IconButton(symbol: "text.alignleft", help: "Show logs") { openLogs(run, openWindow) }
            IconButton(symbol: run.isAlive ? "arrow.clockwise" : "play.fill", help: run.isAlive ? "Restart" : "Run again") {
                store.restartRun(run)
            }
            if run.isAlive {
                ConfirmIconButton(symbol: "stop.circle", help: "Stop \(run.title)", confirmLabel: "Stop?",
                                  busy: store.isPending("run-\(run.id)")) {
                    store.stopRun(run)
                }
            } else {
                IconButton(symbol: "xmark", help: "Remove from the list") { store.clearRun(run) }
            }
        }
        .contextMenu {
            Button("Show Logs") { openLogs(run, openWindow) }
            Button(run.isAlive ? "Restart \(run.title)" : "Run \(run.title) Again") { store.restartRun(run) }
            RestartOnCrashToggle(run: run)
            Divider()
            Button("Reveal Log in Finder") { Launcher.revealInFinder(run.log) }
            Button("Copy Command") { Pasteboard.copy(run.command) }
            Divider()
            if run.isAlive {
                Button("Stop \(run.title)", role: .destructive) { store.stopRun(run) }
            } else {
                Button("Remove from List") { store.clearRun(run) }
            }
        }
    }

    private var badge: some View {
        let (symbol, color): (String, Color) = switch run.status {
        case "crashed": ("exclamationmark.triangle.fill", .red)
        case "restarting": ("arrow.clockwise", .orange)
        case "running": ("play.fill", .green)
        default: ("stop.fill", .gray)
        }
        return ZStack {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16))
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .frame(width: 22, height: 22)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showProject { parts.append(run.projectName) }
        switch run.status {
        case "running":
            parts.append(run.ports.isEmpty && Date().timeIntervalSince(run.startDate) < 30 ? "Starting" : "Running, no port")
            parts.append("up " + run.startDate.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)).replacingOccurrences(of: " ago", with: ""))
        case "restarting":
            parts.append("Crashed, restarting (\(run.restarts.count) of 3)")
        case "crashed":
            let code = run.exitCode.map { "exit code \($0)" } ?? "crashed"
            parts.append(run.gaveUp ? "Crashed 3 times in 5 minutes, \(code)" : "Crashed with \(code)")
            parts.append(run.endDate.formatted(.relative(presentation: .named)))
        default:
            parts.append("Exited " + run.endDate.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: "  ·  ")
    }
}

struct RestartOnCrashToggle: View {
    @Environment(Store.self) private var store
    let run: ManagedRun

    var body: some View {
        Toggle("Restart When It Crashes", isOn: Binding(
            get: { run.restartOnCrash },
            set: { store.setRestartOnCrash(run, $0) }
        ))
    }
}

@MainActor
func openLogs(_ run: ManagedRun, _ openWindow: OpenWindowAction) {
    openWindow(id: "logs", value: LogTarget(file: run.log, runId: run.id, name: "\(run.title) · \(run.projectName)"))
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - Scripts menu

/// "Run dev" and a Run submenu with every script, for a project's menu.
struct RunMenuItems: View {
    @Environment(Store.self) private var store
    let project: RunnableProject

    var body: some View {
        if let script = project.defaultScript {
            let live = store.liveRun(root: project.root, scriptId: script.id)
            Button(live == nil ? "Run \(script.title)" : "Restart \(script.title)") {
                if let live { store.restartRun(live) } else { store.run(script, in: project) }
            }
        }
        if project.scripts.count > 1 {
            Menu("Run") {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.scripts) { script in
                            let running = store.liveRun(root: project.root, scriptId: script.id) != nil
                            Button(running ? "\(script.name) (running)" : script.name) { store.run(script, in: project) }
                                .disabled(running)
                                .help(script.command)
                        }
                    }
                }
            }
        }
    }

    /// Root scripts, then one section per workspace package, then the Procfile.
    private var sections: [(title: String, scripts: [RunScript])] {
        var order: [String] = []
        var groups: [String: [RunScript]] = [:]
        for script in project.scripts {
            let title = script.source == "package.json" ? (script.package.isEmpty ? "package.json" : script.package) : script.source
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(script)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

// MARK: - Ready to run

/// Recent projects with nothing running, each with a play button.
struct ReadyToRunSection: View {
    @Environment(Store.self) private var store
    static let id = "@ready"
    @State private var hovering = false

    var body: some View {
        let projects = store.readyToRun.filter {
            store.query.isEmpty || $0.name.matches(query: store.query) || $0.root.matches(query: store.query)
        }
        if !projects.isEmpty {
            let expanded = !store.query.isEmpty || !store.isCollapsed(id: Self.id, byDefault: true)
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Text("Ready to run")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                CountBadge(count: projects.count).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
            .onTapGesture {
                guard store.query.isEmpty else { return }
                withAnimation(.snappy(duration: 0.22)) { store.toggleCollapsed(id: Self.id) }
            }
            .onHover { hovering = $0 }
            .help("Recent projects with nothing running")
            .padding(.top, 8)
            if expanded {
                ForEach(projects) { ReadyRow(project: $0) }
            }
        }
    }
}

private struct ReadyRow: View {
    @Environment(Store.self) private var store
    let project: RunnableProject

    var body: some View {
        let script = project.defaultScript
        HoverRow {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.14))
                    Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(Format.shortPath(project.root))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } metrics: {
            if let script {
                Text(script.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } actions: {
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                store.openInEditor(project.root)
            }
            if project.scripts.count > 1 {
                Menu {
                    RunMenuItems(project: project)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Other scripts")
            }
            if let script {
                IconButton(symbol: "play.fill", help: "Run \(script.command)", tint: .accentColor) {
                    store.run(script, in: project)
                }
                .overlay {
                    if store.isPending("run-\(project.root)#\(script.id)") { ProgressView().controlSize(.mini) }
                }
            }
        }
        .contextMenu {
            RunMenuItems(project: project)
            Divider()
            Button("Open in Editor") { store.openInEditor(project.root) }
            Button("Reveal in Finder") { Launcher.revealInFinder(project.root) }
            Button("Open in Terminal") { Launcher.launchClaude(.shell, in: project.root) }
        }
    }
}
