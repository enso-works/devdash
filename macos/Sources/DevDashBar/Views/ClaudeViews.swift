import Charts
import SwiftUI

struct ClaudeTab: View {
    @Environment(Store.self) private var store
    @State private var section: Section = .projects

    enum Section: String, CaseIterable, Identifiable {
        case running = "Running"
        case projects = "Projects"
        case sessions = "Sessions"
        var id: String { rawValue }
    }

    var body: some View {
        if let claude = store.claude {
            if let usage = store.usage {
                UsageCard(usage: usage)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            } else if let stats = claude.stats {
                StatsCard(stats: stats)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }

            Picker("", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(label(for: section, claude: claude)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .onAppear { if !claude.instances.isEmpty { section = .running } }

            switch section {
            case .running: runningList(claude.instances)
            case .projects: projectList(claude.projects)
            case .sessions: sessionList(claude.sessions)
            }
        } else {
            ProgressView().controlSize(.small).padding(.top, 40)
        }
    }

    private func label(for section: Section, claude: ClaudePayload) -> String {
        switch section {
        case .running: claude.instances.isEmpty ? "Running" : "Running (\(claude.instances.count))"
        case .projects: "Projects"
        case .sessions: "Sessions"
        }
    }

    @ViewBuilder
    private func runningList(_ instances: [ClaudeInstance]) -> some View {
        let filtered = instances.filter { $0.project.matches(query: store.query) || $0.cwd.matches(query: store.query) }
        if filtered.isEmpty {
            EmptyState(symbol: "sparkle", title: "No Claude sessions running")
        } else {
            ForEach(filtered) { ClaudeInstanceRow(instance: $0) }
        }
    }

    @ViewBuilder
    private func projectList(_ projects: [ClaudeProject]) -> some View {
        let filtered = projects.filter { $0.name.matches(query: store.query) || $0.path.matches(query: store.query) }
        if filtered.isEmpty {
            EmptyState(symbol: "folder", title: "No projects found")
        } else {
            ForEach(filtered) { ClaudeProjectRow(project: $0) }
        }
    }

    @ViewBuilder
    private func sessionList(_ sessions: [ClaudeSession]) -> some View {
        let filtered = sessions.filter {
            !$0.isSidechain && ($0.title.matches(query: store.query) || $0.projectPath.matches(query: store.query) || $0.gitBranch.matches(query: store.query))
        }
        if filtered.isEmpty {
            EmptyState(symbol: "text.bubble", title: "No sessions found")
        } else {
            ForEach(filtered) { SessionRow(session: $0, showProject: true) }
        }
    }
}

private struct StatsCard: View {
    @Environment(Store.self) private var store
    let stats: ClaudeStats

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    stat(Format.count(stats.totalSessions), "sessions")
                    stat(Format.count(stats.totalMessages), "messages")
                    if let tokens = totalOutputTokens {
                        stat(Format.count(tokens), "output tokens")
                    }
                }
                Text("Last 14 days")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Chart(stats.dailyActivity, id: \.label) { day in
                BarMark(x: .value("Day", day.label), y: .value("Messages", day.value), width: .ratio(0.7))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 110, height: 34)
            .help("Messages per day, last 14 days")
        }
        .card(radius: 10, padding: 10)
        .onTapGesture { store.push(.heatmap) }
    }

    private var totalOutputTokens: Int? {
        let total = stats.modelUsage.reduce(0) { $0 + $1.output }
        return total > 0 ? total : nil
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

private struct ClaudeInstanceRow: View {
    @Environment(Store.self) private var store
    let instance: ClaudeInstance

    var body: some View {
        HoverRow(onTap: { store.push(.claudeProject(path: instance.cwdFull)) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(color: .green, pulsing: instance.cpuPercent > 5)
                    Text(instance.project.isEmpty ? "claude" : instance.project)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text("\(instance.cwd)  ·  \(instance.tty)  ·  up \(instance.uptime)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
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
                store.kill(pid: instance.pid, label: "claude in \(instance.project)")
            }
        }
    }
}

private struct ClaudeProjectRow: View {
    @Environment(Store.self) private var store
    let project: ClaudeProject

    var body: some View {
        HoverRow(onTap: { store.push(.claudeProject(path: project.path)) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if project.isRunning { StatusDot(color: .green) }
                    Text(project.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                Text("\(project.sessions) sessions  ·  \(Format.count(project.messages)) prompts")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        } metrics: {
            Metric(text: project.lastActive)
        } actions: {
            IconButton(symbol: "plus.bubble", help: "New Claude session") { Launcher.launchClaude(.new, in: project.path) }
            IconButton(symbol: "arrow.uturn.forward", help: "Continue last session") {
                Launcher.launchClaude(.continueSession, in: project.path)
            }
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                store.openInEditor(project.path)
            }
            IconButton(symbol: "chevron.right", help: "Details") { store.push(.claudeProject(path: project.path)) }
        }
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    var showProject = false

    var body: some View {
        HoverRow(onTap: resume) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
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
                    Text("\(session.messageCount) msgs")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        } metrics: {
            Metric(text: session.modified)
        } actions: {
            IconButton(symbol: "play.circle", help: "Resume in Terminal", action: resume)
        }
    }

    private func resume() {
        Launcher.resumeClaude(session: session.sessionId, in: session.projectPath)
    }
}

// MARK: - Project detail

struct ClaudeProjectView: View {
    @Environment(Store.self) private var store
    let path: String

    var body: some View {
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
                    LaunchGrid(path: path)
                    AsyncContent(load: { try await store.projectDetail(path: path) }) { detail in
                        ProjectDetailBody(detail: detail)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct LaunchGrid: View {
    let path: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(ClaudeLaunch.allCases) { mode in
                LaunchButton(mode: mode) { Launcher.launchClaude(mode, in: path) }
            }
        }
    }
}

private struct LaunchButton: View {
    let mode: ClaudeLaunch
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(mode == .skipPermissions ? .orange : Color.accentColor)
                    .frame(width: 16)
                Text(mode.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(.primary.opacity(hovering ? 0.09 : 0.05), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mode.command)
    }
}

private struct ProjectDetailBody: View {
    let detail: ProjectDetail
    @State private var showMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                StatTile(value: "\(detail.totalSessions)", label: "sessions")
                StatTile(value: Format.count(detail.totalMessages), label: "messages")
                StatTile(value: "\(detail.gitCommits)", label: "commits")
                StatTile(value: "+\(Format.count(detail.totalLinesAdded))", label: "lines added", tint: .green)
                StatTile(value: "-\(Format.count(detail.totalLinesRemoved))", label: "lines removed", tint: .red)
                StatTile(value: Format.count(detail.totalFilesModified), label: "files touched")
            }

            if !detail.toolsUsed.isEmpty {
                RankedBars(title: "Top tools", items: Array(detail.toolsUsed.prefix(6)))
            }
            if !detail.languages.isEmpty {
                RankedBars(title: "Languages", items: Array(detail.languages.prefix(5)))
            }

            if !detail.recentSessions.isEmpty {
                SectionHeader(title: "Recent sessions", count: detail.recentSessions.count)
                    .padding(.horizontal, -8)
                VStack(spacing: 0) {
                    ForEach(detail.recentSessions) { SessionRow(session: $0) }
                }
                .padding(.horizontal, -8)
            }

            if let memory = detail.memoryContent, !memory.isEmpty {
                DisclosureGroup(isExpanded: $showMemory) {
                    Text(memory)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text("MEMORY.md").font(.system(size: 11, weight: .semibold))
                }
                .card(radius: 10, padding: 10)
            }
        }
    }
}

struct RankedBars: View {
    let title: String
    let items: [LabeledValue]
    var format: (Double) -> String = { Format.count(Int($0)) }

    var body: some View {
        let maxValue = items.map(\.value).max() ?? 1
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold))
            ForEach(items, id: \.label) { item in
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 110, alignment: .leading)
                    MeterBar(value: item.value / maxValue, tint: .accentColor, height: 5)
                    Text(format(item.value))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .card(radius: 10, padding: 10)
    }
}
