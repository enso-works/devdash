import AppKit
import SwiftUI

// MARK: - Groups

/// A block of rows in the Running tab: one project, a Compose stack, or a category such as Services.
struct RunningGroup: Identifiable {
    enum Kind { case project, stack, category, services, other, background }

    let id: String
    let kind: Kind
    var name: String
    var root: String?
    var servers: [Server] = []
    var containers: [DockerContainer] = []
    var claude: [ClaudeInstance] = []

    var count: Int { servers.count + containers.count + claude.count }
    var isEmpty: Bool { count == 0 }
    var collapsedByDefault: Bool { kind == .services || kind == .other || kind == .background }
    var stoppable: Int { servers.filter { !$0.isBackground }.count + containers.count }
    var canStop: Bool { (kind == .project || kind == .stack) && stoppable > 0 }
    var latestStart: Double { servers.map(\.started).max() ?? 0 }
    var memoryMb: Double { servers.reduce(0) { $0 + $1.memoryMb } }

    /// Groups by project, with Services, Other and Background at the end.
    static func byProject(servers: [Server], containers: [DockerContainer], claude: [ClaudeInstance]) -> [RunningGroup] {
        var projects: [String: RunningGroup] = [:]
        var services = RunningGroup(id: "@services", kind: .services, name: "Services")
        var other = RunningGroup(id: "@other", kind: .other, name: "Other")
        var background = RunningGroup(id: "@background", kind: .background, name: "Background")

        func project(_ root: String, _ name: String) -> RunningGroup {
            var group = projects[root] ?? RunningGroup(id: root, kind: .project, name: "", root: root)
            if group.name.isEmpty { group.name = name.isEmpty ? (root as NSString).lastPathComponent : name }
            return group
        }

        for server in servers {
            if server.isBackground {
                background.servers.append(server)
            } else if !server.projectRoot.isEmpty {
                var group = project(server.projectRoot, server.projectName)
                group.servers.append(server)
                projects[server.projectRoot] = group
            } else if server.isService {
                services.servers.append(server)
            } else {
                other.servers.append(server)
            }
        }
        for container in containers {
            if let root = container.projectRoot, !root.isEmpty {
                var group = project(root, container.projectName ?? "")
                group.containers.append(container)
                projects[root] = group
            } else {
                other.containers.append(container)
            }
        }
        for instance in claude {
            if let root = instance.projectRoot, !root.isEmpty {
                var group = project(root, instance.projectName ?? "")
                group.claude.append(instance)
                projects[root] = group
            } else {
                other.claude.append(instance)
            }
        }

        background.servers.sort { $0.memoryMb > $1.memoryMb }
        let sorted = projects.values.sorted {
            if $0.latestStart != $1.latestStart { return $0.latestStart > $1.latestStart }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return (sorted + [services, other, background]).filter { !$0.isEmpty }
    }

    /// Dev servers, Compose stacks, Claude sessions, Services and Background, as the old Dev and Docker tabs did.
    static func byType(servers: [Server], containers: [DockerContainer], claude: [ClaudeInstance]) -> [RunningGroup] {
        var groups = [RunningGroup(id: "@servers", kind: .category, name: "Dev servers", servers: servers.filter { $0.kind == "app" })]
        let stacks = Dictionary(grouping: containers, by: \.composeProject).sorted { lhs, rhs in
            if lhs.key.isEmpty != rhs.key.isEmpty { return !lhs.key.isEmpty }
            return lhs.key < rhs.key
        }
        for (name, members) in stacks {
            groups.append(name.isEmpty
                ? RunningGroup(id: "@standalone", kind: .category, name: "Standalone containers", containers: members)
                : RunningGroup(id: "@stack-\(name)", kind: .stack, name: name, containers: members))
        }
        groups.append(RunningGroup(id: "@claude", kind: .category, name: "Claude sessions", claude: claude))
        groups.append(RunningGroup(id: "@services", kind: .services, name: "Services", servers: servers.filter(\.isService)))
        groups.append(RunningGroup(
            id: "@background", kind: .background, name: "Background",
            servers: servers.filter(\.isBackground).sorted { $0.memoryMb > $1.memoryMb }
        ))
        return groups.filter { !$0.isEmpty }
    }

    /// The whole group when its name or path matches, else only the matching rows.
    func filtered(by query: String) -> RunningGroup? {
        guard !query.isEmpty else { return self }
        if name.matches(query: query) || (root ?? "").matches(query: query) { return self }
        var group = self
        group.servers = servers.filter { $0.matches(query: query) }
        group.containers = containers.filter { $0.matches(query: query) }
        group.claude = claude.filter { $0.project.matches(query: query) || $0.cwd.matches(query: query) }
        return group.isEmpty ? nil : group
    }
}

extension Server {
    func matches(query q: String) -> Bool {
        displayName.matches(query: q) || command.matches(query: q) || cwd.matches(query: q)
            || projectName.matches(query: q) || package.matches(query: q) || runtime.matches(query: q)
            || ports.contains { String($0).contains(q) } || String(pid) == q
    }
}

extension DockerContainer {
    func matches(query q: String) -> Bool {
        name.matches(query: q) || image.matches(query: q) || composeProject.matches(query: q)
            || composeService.matches(query: q) || ports.matches(query: q)
    }
}

// MARK: - Tab

struct RunningTab: View {
    @Environment(Store.self) private var store

    var body: some View {
        let claude = store.claudeInstances
        let all = store.grouping == .project
            ? RunningGroup.byProject(servers: store.servers, containers: store.docker, claude: claude)
            : RunningGroup.byType(servers: store.servers, containers: store.docker, claude: claude)
        let groups = all.compactMap { $0.filtered(by: store.query) }

        if all.isEmpty {
            EmptyState(
                symbol: "moon.zzz",
                title: "Nothing running",
                message: "Dev servers in any language, Docker containers and Claude sessions show up here, grouped by project."
            )
        } else if groups.isEmpty {
            VStack(spacing: 0) {
                EmptyState(symbol: "magnifyingglass", title: "No matches for \u{201C}\(store.query)\u{201D}")
                PillButton(title: "Clear filter") { store.query = "" }
            }
        } else {
            ForEach(groups) { group in
                let expanded = !store.query.isEmpty || !store.isCollapsed(group)
                GroupHeader(group: group, expanded: expanded)
                if expanded {
                    GroupRows(group: group)
                }
            }
        }
    }
}

private struct GroupRows: View {
    let group: RunningGroup

    var body: some View {
        let inProject = group.kind == .project
        ForEach(group.servers.sorted { ($0.ports.first ?? .max, $0.pid) < ($1.ports.first ?? .max, $1.pid) }) {
            ServerRow(server: $0, showProject: !inProject)
        }
        ForEach(group.containers) { ContainerRow(container: $0) }
        ForEach(group.claude) { ClaudeInstanceRow(instance: $0, inGroup: inProject) }
    }
}

// MARK: - Group header

private struct GroupHeader: View {
    @Environment(Store.self) private var store
    let group: RunningGroup
    let expanded: Bool
    @State private var hovering = false
    @State private var armed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Text(group.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isCategory ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let root = group.root, let branch = store.projects[root]?.branch, !branch.isEmpty {
                BranchChip(branch: branch)
            }
            if let root = group.root {
                Text(Format.shortPath(root))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if group.kind == .background {
                Text(Format.memory(group.memoryMb))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if store.isPending("group-\(group.id)") {
                ProgressView().controlSize(.mini)
            } else if armed {
                Button("Stop \(group.stoppable)?") {
                    armed = false
                    store.stopGroup(group)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.red, in: .capsule)
            } else {
                CountBadge(count: group.count).fixedSize()
            }
            if group.root != nil || group.canStop {
                GroupMenu(group: group, armStop: arm)
                    .opacity(hovering || armed ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
        .onTapGesture {
            guard store.query.isEmpty else { return }
            withAnimation(.snappy(duration: 0.22)) { store.toggleCollapsed(group) }
        }
        .onHover { hovering = $0 }
        .contextMenu { GroupMenuItems(group: group, armStop: arm) }
        .padding(.top, 8)
    }

    private var isCategory: Bool { group.kind != .project && group.kind != .stack }

    private func arm() {
        withAnimation(.snappy(duration: 0.2)) { armed = true }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.snappy(duration: 0.2)) { armed = false }
        }
    }
}

private struct GroupMenu: View {
    let group: RunningGroup
    let armStop: () -> Void

    var body: some View {
        Menu {
            GroupMenuItems(group: group, armStop: armStop)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project actions")
    }
}

private struct GroupMenuItems: View {
    @Environment(Store.self) private var store
    let group: RunningGroup
    let armStop: () -> Void

    var body: some View {
        if let root = group.root {
            Button("Open in Editor") { store.openInEditor(root) }
            Button("Reveal in Finder") { Launcher.revealInFinder(root) }
            Button("Open in Terminal") { Launcher.launchClaude(.shell, in: root) }
            if store.hasClaude {
                Button("New Claude Session") { Launcher.launchClaude(.new, in: root) }
            }
            Button("Copy Path") { Pasteboard.copy(root) }
        }
        if group.canStop {
            Divider()
            Button("Stop All (\(group.stoppable))...", role: .destructive, action: armStop)
        }
    }
}

private struct BranchChip: View {
    let branch: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5, weight: .semibold))
            Text(branch)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.primary.opacity(0.06), in: .capsule)
    }
}

// MARK: - Rows

struct ServerRow: View {
    @Environment(Store.self) private var store
    let server: Server
    /// Show the project name, for rows outside a project group.
    var showProject = false

    var body: some View {
        HoverRow(onTap: showDetail) {
            HStack(spacing: 8) {
                RuntimeBadge(runtime: server.runtime)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if !server.package.isEmpty {
                            Text(server.package)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(server.ports.prefix(3), id: \.self) { PortChip(port: $0) }
                        if server.ports.count > 3 {
                            Text("+\(server.ports.count - 3)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5, design: showProject ? .default : .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } metrics: {
            VStack(alignment: .trailing, spacing: 3) {
                Metric(text: Format.percent(server.cpuPercent), color: store.config.metricTint(server.cpuPercent))
                Metric(text: Format.memory(server.memoryMb))
            }
        } actions: {
            if let port = server.ports.first {
                IconButton(symbol: "safari", help: "Open localhost:\(port)") { Launcher.openPort(port) }
            }
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                store.openInEditor(server.cwdFull)
            }
            ConfirmIconButton(symbol: "xmark.octagon", help: "Kill PID \(server.pid)", busy: store.isPending("pid-\(server.pid)")) {
                store.kill(pid: server.pid, label: server.displayName)
            }
        }
        .contextMenu {
            ForEach(server.ports, id: \.self) { port in
                Button("Open localhost:\(String(port))") { Launcher.openPort(port) }
            }
            if let port = server.ports.first {
                Button("Copy URL") { Pasteboard.copy("http://localhost:\(port)") }
                Divider()
            }
            Button("Show Details", action: showDetail)
            Button("Open in Editor") { store.openInEditor(server.cwdFull) }
            Button("Reveal in Finder") { Launcher.revealInFinder(server.cwdFull) }
            Button("Open in Terminal") { Launcher.launchClaude(.shell, in: server.cwdFull) }
            Button("Copy Command") { Pasteboard.copy(server.command) }
            Divider()
            Button("Kill PID \(String(server.pid))", role: .destructive) {
                store.kill(pid: server.pid, label: server.displayName)
            }
        }
    }

    private var subtitle: String {
        guard showProject else { return server.shortCommand }
        let place = server.projectName.isEmpty ? server.cwd : server.projectName
        return "\(place)  ·  up \(server.uptime)"
    }

    private func showDetail() {
        store.push(.processDetail(pid: server.pid, name: server.displayName))
    }
}

/// A small colored mark for a runtime, container or Claude session.
struct RuntimeBadge: View {
    let runtime: String
    var tint: Color?

    var body: some View {
        let style = Self.style(runtime)
        let color = tint ?? style.color
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16))
            if let symbol = style.symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            } else {
                Text(style.mark)
                    .font(.system(size: style.mark.count > 2 ? 7.5 : 8.5, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(color)
        .frame(width: 22, height: 22)
        .help(style.name)
    }

    struct Style {
        var mark = ""
        var symbol: String?
        var color: Color
        var name: String
    }

    static func style(_ runtime: String) -> Style {
        switch runtime {
        case "node": Style(mark: "JS", color: .green, name: "Node.js")
        case "bun": Style(mark: "BUN", color: .pink, name: "Bun")
        case "deno": Style(mark: "DN", color: .mint, name: "Deno")
        case "python": Style(mark: "PY", color: .blue, name: "Python")
        case "go": Style(mark: "GO", color: .cyan, name: "Go")
        case "ruby": Style(mark: "RB", color: .red, name: "Ruby")
        case "rust": Style(mark: "RS", color: .orange, name: "Rust")
        case "java": Style(mark: "JV", color: .orange, name: "Java")
        case "php": Style(mark: "PHP", color: .indigo, name: "PHP")
        case "dotnet": Style(mark: ".N", color: .purple, name: ".NET")
        case "elixir": Style(mark: "EX", color: .purple, name: "Elixir")
        case "postgres": Style(mark: "PG", color: .blue, name: "PostgreSQL")
        case "redis": Style(mark: "RD", color: .red, name: "Redis")
        case "mysql": Style(mark: "MY", color: .teal, name: "MySQL")
        case "mongo": Style(mark: "MG", color: .green, name: "MongoDB")
        case "memcached": Style(mark: "MC", color: .gray, name: "Memcached")
        case "docker": Style(symbol: "shippingbox.fill", color: .blue, name: "Docker container")
        case "claude": Style(symbol: "sparkle", color: .orange, name: "Claude Code")
        default: Style(symbol: "terminal", color: .gray, name: "Process")
        }
    }
}

// MARK: - Helpers

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
