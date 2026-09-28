import Charts
import ServiceManagement
import SwiftUI

// MARK: - Process detail

struct ProcessDetailView: View {
    @Environment(Store.self) private var store
    let pid: Int
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: name, subtitle: "PID \(pid)") {
                ConfirmIconButton(symbol: "xmark.octagon", help: "Kill PID \(pid)", busy: store.isPending("pid-\(pid)")) {
                    store.kill(pid: pid, label: name)
                    store.pop()
                }
            }
            Divider().opacity(0.5)
            AsyncContent(load: { try await store.processDetail(pid: pid) }) { detail in
                ScrollView {
                    ProcessDetailBody(detail: detail)
                        .padding(12)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct ProcessDetailBody: View {
    let detail: ProcessDetail
    @State private var showEnvironment = false
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatTile(value: Format.percent(detail.cpuPercent), label: "CPU")
                StatTile(value: detail.rssMb.map(Format.memory) ?? "--", label: "resident")
                StatTile(value: detail.threads.map(String.init) ?? "--", label: "threads")
            }

            VStack(alignment: .leading, spacing: 5) {
                KeyValueRow(key: "Status", value: detail.status)
                KeyValueRow(key: "User", value: detail.user)
                if !detail.cwd.isEmpty {
                    HStack {
                        KeyValueRow(key: "Directory", value: detail.cwd, monospaced: true)
                        IconButton(symbol: "folder", help: "Reveal in Finder", size: 20) { Launcher.revealInFinder(detail.cwd) }
                    }
                }
                if let vms = detail.vmsMb { KeyValueRow(key: "Virtual", value: Format.memory(vms)) }
            }
            .card()

            if !detail.command.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Command").font(.system(size: 11, weight: .semibold))
                    Text(detail.command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .card()
            }

            if !detail.connections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network (\(detail.connections.count))").font(.system(size: 11, weight: .semibold))
                    ForEach(detail.connections, id: \.self) { conn in
                        HStack(spacing: 6) {
                            Text(conn.status)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(conn.status == "LISTEN" ? .green : .secondary)
                                .frame(width: 78, alignment: .leading)
                            Text(conn.laddr)
                            if !conn.raddr.isEmpty {
                                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                                Text(conn.raddr)
                            }
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            if !detail.children.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Children (\(detail.children.count))").font(.system(size: 11, weight: .semibold))
                    ForEach(detail.children, id: \.self) { child in
                        Text(verbatim: "\(child.pid)  \(child.name)").font(.system(size: 10.5, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            if !detail.openFiles.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(detail.openFiles, id: \.self) { path in
                            Text(path).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                } label: {
                    Text("Open files (\(detail.openFiles.count))").font(.system(size: 11, weight: .semibold))
                }
                .card()
            }

            if !detail.environment.isEmpty {
                DisclosureGroup(isExpanded: $showEnvironment) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(detail.environment, id: \.self) { pair in
                            Text("\(pair.first ?? "")=\(pair.last ?? "")")
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                } label: {
                    Text("Environment (\(detail.environment.count))").font(.system(size: 11, weight: .semibold))
                }
                .card()
            }
        }
    }
}

// MARK: - Cleanup

struct CleanupView: View {
    @Environment(Store.self) private var store
    @State private var selected: Set<String> = []
    @State private var initialized = false
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: "Cleanup", subtitle: "Idle, orphaned and stale resources")
            Divider().opacity(0.5)
            if store.cleanup.isEmpty {
                Spacer()
                EmptyState(symbol: "checkmark.seal", title: "All clean", message: "Nothing to clean up right now.")
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.cleanup) { item in
                            CleanupRow(item: item, isSelected: selected.contains(item.id)) {
                                if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                            }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                Divider().opacity(0.5)
                HStack {
                    Button(allSelected ? "Select none" : "Select all") {
                        selected = allSelected ? [] : Set(store.cleanup.map(\.id))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        PillButton(title: actionTitle, symbol: "sparkles", role: .destructive) {
                            Task { await run() }
                        }
                        .disabled(selectedItems.isEmpty)
                        .opacity(selectedItems.isEmpty ? 0.5 : 1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            selected = Set(store.cleanup.map(\.id))
        }
    }

    private var selectedItems: [CleanupSuggestion] { store.cleanup.filter { selected.contains($0.id) } }
    private var allSelected: Bool { selected.count == store.cleanup.count }

    private var actionTitle: String {
        let kills = selectedItems.filter { $0.actionType == "kill" }.count
        let stops = selectedItems.count - kills
        var parts: [String] = []
        if kills > 0 { parts.append("kill \(kills)") }
        if stops > 0 { parts.append("stop \(stops)") }
        return parts.isEmpty ? "Clean up" : "Clean up: " + parts.joined(separator: ", ")
    }

    private func run() async {
        running = true
        await store.runCleanup(selectedItems)
        running = false
        store.pop()
    }
}

private struct CleanupRow: View {
    let item: CleanupSuggestion
    let isSelected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.reason).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.actionType == "kill" ? "Kill" : "Stop")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        switch item.category {
        case "idle": "moon.zzz.fill"
        case "zombie": "exclamationmark.triangle.fill"
        case "orphan": "person.fill.questionmark"
        default: "shippingbox.fill"
        }
    }

    private var tint: Color {
        switch item.category {
        case "idle": .blue
        case "zombie": .red
        case "orphan": .orange
        default: .purple
        }
    }
}

// MARK: - Dependency graph

struct GraphView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: "Dependency graph", subtitle: "Live TCP connections between services")
            Divider().opacity(0.5)
            AsyncContent(load: { try await store.graph() }) { graph in
                ScrollView {
                    GraphBody(graph: graph).padding(12)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct GraphBody: View {
    let graph: GraphData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if graph.edges.isEmpty {
                EmptyState(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "No connections",
                    message: "No Node process is currently connected to another local service."
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(graph.edges, id: \.self) { edge in
                        HStack(spacing: 6) {
                            NodeChip(label: edge.fromLabel, kind: edge.fromKind)
                            HStack(spacing: 3) {
                                Rectangle().fill(.tertiary).frame(height: 1)
                                Text(verbatim: ":\(edge.port)")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7)).foregroundStyle(.tertiary)
                            }
                            .frame(minWidth: 60)
                            NodeChip(label: edge.toLabel, kind: edge.toKind)
                        }
                    }
                }
                .card()
            }

            let listeners = graph.owners.filter { !$0.ports.isEmpty }
            if !listeners.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Listening").font(.system(size: 11, weight: .semibold))
                    ForEach(listeners, id: \.self) { owner in
                        HStack(spacing: 6) {
                            NodeChip(label: owner.label, kind: owner.kind)
                            Spacer()
                            ForEach(owner.ports.prefix(4), id: \.self) { PortChip(port: $0) }
                        }
                    }
                }
                .card()
            }
        }
    }
}

private struct NodeChip: View {
    let label: String
    let kind: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind == "docker" ? "shippingbox.fill" : "hexagon.fill")
                .font(.system(size: 9))
                .foregroundStyle(kind == "docker" ? .blue : .green)
            Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.06), in: .capsule)
    }
}

// MARK: - Activity heatmap

struct HeatmapView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: "Claude activity", subtitle: "Sessions, messages and time per project")
            Divider().opacity(0.5)
            AsyncContent(load: { try await store.heatmap() }) { data in
                if let data {
                    ScrollView {
                        HeatmapBody(data: data).padding(12)
                    }
                    .scrollIndicators(.never)
                } else {
                    EmptyState(symbol: "square.grid.3x3", title: "No activity data")
                }
            }
        }
    }
}

private struct HeatmapBody: View {
    let data: HeatmapData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatTile(value: Format.count(data.totalSessions), label: "sessions")
                StatTile(value: Format.count(data.totalMessages), label: "messages")
                StatTile(value: String(format: "%.0fh", data.totalHours), label: "tracked")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("This week").font(.system(size: 11, weight: .semibold))
                WeekGrid(grid: data.weeklyHeatmap, labels: data.weekDayLabels)
            }
            .card()

            if !data.dailyMessages.isEmpty {
                let recent = Array(data.dailyMessages.suffix(60))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Messages per day").font(.system(size: 11, weight: .semibold))
                    Chart(recent, id: \.label) { day in
                        BarMark(x: .value("Date", day.label), y: .value("Messages", day.value))
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(1.5)
                    }
                    .chartXAxis {
                        AxisMarks(values: axisDates(recent)) { value in
                            AxisValueLabel {
                                if let label = value.as(String.self) { Text(String(label.suffix(5))) }
                            }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
                    .font(.system(size: 9))
                    .frame(height: 110)
                }
                .card()
            }

            if !data.projectTimes.isEmpty {
                RankedBars(
                    title: "Time by project",
                    items: Array(data.projectTimes.prefix(8)),
                    format: { String(format: "%.1fh", $0) }
                )
            }
        }
    }

    private func axisDates(_ days: [LabeledValue]) -> [String] {
        guard days.count > 4 else { return days.map(\.label) }
        let step = days.count / 4
        return stride(from: step / 2, to: days.count, by: step).map { days[$0].label }
    }
}

private struct WeekGrid: View {
    let grid: [[Int]]
    let labels: [String]

    var body: some View {
        let maxValue = max(grid.flatMap { $0 }.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(grid.enumerated()), id: \.offset) { day, hours in
                HStack(spacing: 2) {
                    Text(day < labels.count ? labels[day] : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                    ForEach(Array(hours.enumerated()), id: \.offset) { hour, value in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(value == 0 ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.2 + 0.8 * Double(value) / Double(maxValue)))
                            .aspectRatio(1, contentMode: .fit)
                            .help("\(labels[safe: day] ?? "") \(hour):00 · \(value) messages")
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 26)
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text("\(hour)h").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(SettingsKey.devdashPath) private var devdashPath = ""
    @AppStorage(SettingsKey.showCount) private var showCount = true
    @AppStorage(SettingsKey.notifications) private var notifications = true
    @AppStorage(SettingsKey.editor) private var editor = Editor.auto.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: "Settings")
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show active count in menu bar", isOn: $showCount)
                        Toggle("Notify when servers start or stop", isOn: $notifications)
                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                        Picker("Editor", selection: $editor) {
                            ForEach(Editor.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.menu)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .card()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("devdash executable").font(.system(size: 11, weight: .semibold))
                        HStack(spacing: 6) {
                            TextField("Auto-detect", text: $devdashPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            PillButton(title: "Apply") { store.start() }
                        }
                        Text(resolvedDescription)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Thresholds and refresh rate come from ~/.config/devdash/config.toml")
                        if let hello = store.hello {
                            Text("devdash \(hello.version) · refresh every \(hello.config.refreshRate.formatted())s")
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(12)
            }
        }
    }

    private var resolvedDescription: String {
        if let url = BridgeLocator.resolve(customPath: devdashPath) { return "Using \(url.path)" }
        return "Not found. Install devdash or enter a path."
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.showToast("Launch at login: \(error.localizedDescription)", isError: true)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
