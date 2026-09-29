import AppKit
import SwiftUI

struct PopoverView: View {
    @Environment(Store.self) private var store

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let route = store.routes.last {
                    RouteView(route: route)
                        .id(route)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
                } else {
                    MainView()
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.25), value: store.routes)

            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 46)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: store.toast)
        .frame(width: 400, height: 580)
    }
}

private struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case let .processDetail(pid, name): ProcessDetailView(pid: pid, name: name)
        case let .claudeProject(path): ClaudeProjectView(path: path)
        case .cleanup: CleanupView()
        case .graph: GraphView()
        case .heatmap: HeatmapView()
        case .usage: UsageView()
        case .settings: SettingsView()
        }
    }
}

private struct MainView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            switch store.connection {
            case .missingBinary:
                SetupView(
                    symbol: "terminal",
                    title: "Install the devdash CLI",
                    message: "The menu bar app reads its data from the devdash command line tool.",
                    command: SetupView.installCommand
                )
            case .failed(let reason) where store.system == nil:
                if reason.contains("--serve") {
                    SetupView(
                        symbol: "arrow.down.circle",
                        title: "Update the devdash CLI",
                        message: "This version of devdash is too old for the menu bar app.",
                        command: "devdash --update"
                    )
                } else {
                    Spacer()
                    EmptyState(symbol: "bolt.horizontal.circle", title: "Bridge stopped", message: reason)
                    PillButton(title: "Retry", symbol: "arrow.clockwise", prominent: true) { store.start() }
                    Spacer()
                }
            case .starting where store.system == nil:
                Spacer()
                ProgressView().controlSize(.small)
                Text("Collecting processes...").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                Spacer()
            default:
                StatsStrip()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                TabBar()
                    .padding(.horizontal, 12)
                SearchField()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Divider().padding(.top, 8).opacity(0.5)
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        if store.tab == .dev || store.tab == .docker, !store.cleanup.isEmpty {
                            CleanupBanner()
                                .padding(.horizontal, 4)
                                .padding(.top, 8)
                        }
                        if store.tab == .dev || store.tab == .docker {
                            DiskBanner()
                                .padding(.horizontal, 4)
                                .padding(.top, 6)
                        }
                        switch store.tab {
                        case .dev: DevTab()
                        case .docker: DockerTab()
                        case .system: SystemTab()
                        case .claude: ClaudeTab()
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
            }
            Divider().opacity(0.5)
            FooterBar()
        }
    }
}

// MARK: - Setup

/// Shown when the CLI is missing or outdated: explains the fix and can run it in Terminal.
private struct SetupView: View {
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/enso-works/devdash/main/install.sh | bash"

    @Environment(Store.self) private var store
    let symbol: String
    let title: String
    let message: String
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                Text(command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
            }
            .card(radius: 8, padding: 8)
            HStack(spacing: 8) {
                PillButton(title: "Run in Terminal", symbol: "terminal", prominent: true) {
                    Launcher.runInTerminal(command, in: NSHomeDirectory())
                }
                PillButton(title: "Check again", symbol: "arrow.clockwise") { store.start() }
            }
            Button("Set a custom path in Settings") { store.push(.settings) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("devdash").font(.system(size: 13, weight: .semibold))
            StatusDot(color: statusColor)
                .help(statusHelp)
            Spacer()
            if let lastUpdate = store.lastUpdate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(relative(lastUpdate, now: context.date))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { store.refresh() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var statusColor: Color {
        switch store.connection {
        case .connected: .green
        case .starting: .yellow
        case .failed, .missingBinary: .red
        }
    }

    private var statusHelp: String {
        switch store.connection {
        case .connected: "Connected to devdash \(store.hello?.version ?? "")"
        case .starting: "Starting bridge"
        case .missingBinary: "devdash not found"
        case .failed(let reason): reason
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 2 ? "live" : "\(seconds)s ago"
    }
}

// MARK: - Stats strip

private struct StatsStrip: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let system = store.system {
            HStack(spacing: 8) {
                GaugeTile(
                    title: "CPU",
                    value: system.cpuPercent,
                    detail: "\(system.cpuCount) cores",
                    tint: store.config.severity(system.cpuPercent)
                ) {
                    Sparkline(values: store.cpuHistory, tint: store.config.severity(system.cpuPercent))
                        .frame(height: 18)
                        .opacity(0.5)
                }
                GaugeTile(
                    title: "Memory",
                    value: system.memoryPercent,
                    detail: String(format: "%.1f / %.0f GB", system.memoryUsedGb, system.memoryTotalGb),
                    tint: store.config.severity(system.memoryPercent)
                ) { EmptyView() }
                GaugeTile(
                    title: "Disk",
                    value: system.diskPercent,
                    detail: String(format: "%.0f GB free", system.diskFreeGb),
                    tint: store.config.severity(system.diskPercent)
                ) { EmptyView() }
            }
        }
    }
}

private struct GaugeTile<Extra: View>: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color
    @ViewBuilder let background: () -> Extra

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RingGauge(value: value / 100, tint: tint, lineWidth: 3.5)
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(alignment: .bottom) { background().clipShape(.rect(cornerRadius: 10)) }
        .card(radius: 10, padding: 0)
    }
}

// MARK: - Tabs and search

private struct TabBar: View {
    @Environment(Store.self) private var store
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visibleTabs) { tab in
                let selected = store.tab == tab
                Button {
                    withAnimation(.snappy(duration: 0.22)) { store.tab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(tab.title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        if let count = count(for: tab), count > 0 {
                            CountBadge(count: count, selected: selected)
                        }
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(.background.opacity(0.9))
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "tab", in: selection)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 9))
    }

    private var visibleTabs: [Tab] {
        Tab.allCases.filter { $0 != .claude || store.hasClaude }
    }

    private func count(for tab: Tab) -> Int? {
        switch tab {
        case .dev: store.servers.count
        case .docker: store.docker.count
        case .system: nil
        case .claude: store.claude?.instances.count
        }
    }
}

private struct SearchField: View {
    @Environment(Store.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter by name, port, path...", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.primary.opacity(focused ? 0.07 : 0.045), in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Color.accentColor.opacity(0.5) : .clear))
        .onExitCommand { store.query = "" }
    }
}

// MARK: - Cleanup banner

private struct CleanupBanner: View {
    @Environment(Store.self) private var store

    var body: some View {
        Button {
            store.push(.cleanup)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 26, height: 26)
                    .background(.orange.opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(store.cleanup.count) cleanup suggestion\(store.cleanup.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("Review")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .card(radius: 10, padding: 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        let groups = Dictionary(grouping: store.cleanup, by: \.category)
        let order = ["idle", "orphan", "zombie", "stale_container"]
        let names = ["idle": "idle", "orphan": "orphaned", "zombie": "zombie", "stale_container": "stale containers"]
        return order.compactMap { key in groups[key].map { "\($0.count) \(names[key] ?? key)" } }.joined(separator: " · ")
    }
}

// MARK: - Disk banner

/// Full-width row that opens the Disk tree window, with free space and reclaimable size.
private struct DiskBanner: View {
    @Environment(DiskStore.self) private var disk
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "disk")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if disk.isScanning {
                    ProgressView().controlSize(.mini)
                }
                Text("Open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .card(radius: 10, padding: 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if disk.reclaimableTotal > 0 { return "Disk tree · \(ByteFormat.string(disk.reclaimableTotal)) worth a look" }
        return "Disk tree"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let volume = disk.volume { parts.append("\(ByteFormat.string(volume.free)) free") }
        if disk.isScanning {
            parts.append("scanning \(Format.count(Int(disk.progress.files))) files")
        } else if disk.root == nil {
            parts.append("see what takes up space")
        } else if let date = disk.scanDate {
            parts.append("scanned " + date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "internaldrive", help: "Disk tree") {
                openWindow(id: "disk")
                NSApp.activate(ignoringOtherApps: true)
            }
            IconButton(symbol: "point.3.connected.trianglepath.dotted", help: "Dependency graph") { store.push(.graph) }
            if store.hasClaude {
                IconButton(symbol: "square.grid.3x3.fill", help: "Claude activity heatmap") { store.push(.heatmap) }
            }
            IconButton(symbol: "square.and.arrow.up", help: "Export JSON snapshot") { store.export() }
            IconButton(symbol: "terminal", help: "Open devdash TUI in Terminal") {
                Launcher.runInTerminal(store.executable.map { Launcher.shellQuote($0.path) } ?? "devdash", in: NSHomeDirectory())
            }
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings") { store.push(.settings) }
            IconButton(symbol: "power", help: "Quit devdash") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .red : .green)
            Text(toast.message)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 20)
    }
}
