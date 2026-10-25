import SwiftUI

struct CodexTab: View {
    @Environment(Store.self) private var store
    @State private var section: Section = .projects

    enum Section: String, CaseIterable, Identifiable {
        case running = "Running"
        case projects = "Projects"
        case sessions = "Sessions"
        var id: String { rawValue }
    }

    var body: some View {
        if let codex = store.codex {
            if let usage = store.codexUsage {
                UsageCard(usage: usage, agent: .codex)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }

            Picker("", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section == .running && !codex.instances.isEmpty ? "Running (\(codex.instances.count))" : section.rawValue)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .onAppear { if !codex.instances.isEmpty { section = .running } }

            switch section {
            case .running: runningList(codex.instances)
            case .projects: projectList(codex.projects)
            case .sessions: sessionList(codex.sessions)
            }
        } else {
            ProgressView().controlSize(.small).padding(.top, 40)
        }
    }

    @ViewBuilder
    private func runningList(_ instances: [CodexInstance]) -> some View {
        let filtered = instances.filter { $0.project.matches(query: store.query) || $0.cwd.matches(query: store.query) }
        if filtered.isEmpty {
            EmptyState(symbol: "terminal", title: "No Codex sessions running", message: "Codex running in a terminal shows up here.")
        } else {
            ForEach(filtered) { CodexInstanceRow(instance: $0) }
        }
    }

    @ViewBuilder
    private func projectList(_ projects: [CodexProject]) -> some View {
        let filtered = projects.filter { $0.name.matches(query: store.query) || $0.path.matches(query: store.query) }
        if filtered.isEmpty {
            EmptyState(symbol: "folder", title: "No projects found")
        } else {
            ForEach(filtered) { CodexProjectRow(project: $0) }
        }
    }

    @ViewBuilder
    private func sessionList(_ sessions: [CodexSession]) -> some View {
        let filtered = sessions.filter {
            $0.title.matches(query: store.query) || $0.projectPath.matches(query: store.query) || $0.gitBranch.matches(query: store.query)
        }
        if filtered.isEmpty {
            EmptyState(symbol: "text.bubble", title: "No sessions found")
        } else {
            ForEach(filtered) { CodexSessionRow(session: $0, showProject: true) }
        }
    }
}

struct CodexInstanceRow: View {
    @Environment(Store.self) private var store
    let instance: CodexInstance
    /// Inside a project group, where the project name is already in the header.
    var inGroup = false

    var body: some View {
        HoverRow(onTap: { store.push(.codexProject(path: instance.cwdFull)) }) {
            HStack(spacing: 8) {
                if inGroup { RuntimeBadge(runtime: "codex") }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if !inGroup { StatusDot(color: .green, pulsing: instance.cpuPercent > 5) }
                        Text(inGroup ? "Codex session" : (instance.project.isEmpty ? "codex" : instance.project))
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text(inGroup ? "\(instance.tty)  ·  up \(instance.uptime)" : "\(instance.cwd)  ·  \(instance.tty)  ·  up \(instance.uptime)")
                        .font(.system(size: inGroup ? 10.5 : 10))
                        .foregroundStyle(inGroup ? .secondary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } metrics: {
            VStack(alignment: .trailing, spacing: 3) {
                Metric(text: Format.percent(instance.cpuPercent), color: store.config.metricTint(instance.cpuPercent))
                Metric(text: Format.memory(instance.memoryMb))
            }
        } actions: {
            IconButton(symbol: "folder", help: "Reveal in Finder") { Launcher.revealInFinder(instance.cwdFull) }
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                store.openInEditor(instance.cwdFull)
            }
            ConfirmIconButton(symbol: "xmark.octagon", help: "Kill PID \(instance.pid)", busy: store.isPending("pid-\(instance.pid)")) {
                store.kill(pid: instance.pid, label: "codex in \(instance.project)")
            }
        }
    }
}

private struct CodexProjectRow: View {
    @Environment(Store.self) private var store
    let project: CodexProject

    var body: some View {
        HoverRow(onTap: { store.push(.codexProject(path: project.path)) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if project.isRunning { StatusDot(color: .green) }
                    Text(project.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                Text("\(project.sessions) session\(project.sessions == 1 ? "" : "s")  ·  \(Format.count(project.tokens)) tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        } metrics: {
            Metric(text: project.lastActive)
        } actions: {
            IconButton(symbol: "plus.bubble", help: "New Codex session") { Launcher.launchCodex(.new, in: project.path) }
            IconButton(symbol: "arrow.uturn.forward", help: "Continue last session") {
                Launcher.launchCodex(.continueSession, in: project.path)
            }
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                store.openInEditor(project.path)
            }
            IconButton(symbol: "chevron.right", help: "Details") { store.push(.codexProject(path: project.path)) }
        }
    }
}

struct CodexSessionRow: View {
    let session: CodexSession
    var showProject = false

    var body: some View {
        HoverRow(onTap: resume) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if showProject {
                        Text(session.projectName).fontWeight(.medium)
                        Text("·")
                    }
                    if !session.gitBranch.isEmpty {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5))
                        Text(session.gitBranch).lineLimit(1)
                        Text("·")
                    }
                    Text("\(Format.count(session.tokens)) tokens")
                    if session.source != "cli" {
                        Text("·")
                        Text("App")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        } metrics: {
            Metric(text: session.lastActive)
        } actions: {
            IconButton(symbol: "play.circle", help: "Resume in Terminal", action: resume)
        }
        .help(session.model.isEmpty ? "" : ModelCost.displayName(session.model))
    }

    private func resume() {
        Launcher.resumeCodex(session: session.sessionId, in: session.projectPath)
    }
}

// MARK: - Project page

struct CodexProjectView: View {
    @Environment(Store.self) private var store
    let path: String

    var body: some View {
        let sessions = store.codex?.sessions.filter { $0.projectPath == path } ?? []
        let project = store.codex?.projects.first { $0.path == path }
        VStack(spacing: 0) {
            SubPageHeader(title: (path as NSString).lastPathComponent, subtitle: path) {
                IconButton(symbol: "folder", help: "Reveal in Finder") { Launcher.revealInFinder(path) }
                IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                    store.openInEditor(path)
                }
            }
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(CodexLaunch.allCases) { mode in
                            LaunchButton(label: mode.label, symbol: mode.symbol, command: mode.command) {
                                Launcher.launchCodex(mode, in: path)
                            }
                        }
                    }
                    if let project {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            StatTile(value: "\(project.sessions)", label: "sessions")
                            StatTile(value: Format.count(project.tokens), label: "tokens")
                            StatTile(value: project.lastActive, label: "last active")
                        }
                    }
                    if !sessions.isEmpty {
                        SectionHeader(title: "Recent sessions", count: sessions.count)
                            .padding(.horizontal, -8)
                        VStack(spacing: 0) {
                            ForEach(sessions) { CodexSessionRow(session: $0) }
                        }
                        .padding(.horizontal, -8)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)
        }
    }
}
