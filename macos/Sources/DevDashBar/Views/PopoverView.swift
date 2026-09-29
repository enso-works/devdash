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
        case .whatsNew: WhatsNewView()
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
                AttentionSection()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                TabBar()
                    .padding(.horizontal, 12)
                HStack(spacing: 6) {
                    SearchField()
                    if store.tab == .running {
                        GroupingMenu()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Divider().padding(.top, 8).opacity(0.5)
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        switch store.tab {
                        case .running: RunningTab()
                        case .claude: ClaudeTab()
                        case .system: SystemTab()
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
        .background {
            // Cmd+F from anywhere in the popover.
            Button("Filter") { store.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
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
            if let system = store.system {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { store.tab = .system }
                } label: {
                    HStack(spacing: 8) {
                        HeaderMetric(label: "CPU", value: system.cpuPercent)
                        HeaderMetric(label: "Mem", value: system.memoryPercent)
                    }
                }
                .buttonStyle(.plain)
                .help("Show the System tab")
            }
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

private struct HeaderMetric: View {
    @Environment(Store.self) private var store
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text("\(Int(value.rounded()))%").foregroundStyle(store.config.metricTint(value))
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
    }
}

// MARK: - Tabs and search

private struct TabBar: View {
    @Environment(Store.self) private var store
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(visibleTabs.enumerated()), id: \.element) { index, tab in
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
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help("\(tab.title) (Cmd+\(index + 1))")
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
        case .running: store.activeCount
        case .claude: store.claude?.instances.count
        case .system: nil
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
            TextField(placeholder, text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onChange(of: store.searchFocusRequest) { focused = true }
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

    private var placeholder: String {
        switch store.tab {
        case .running: "Filter by project, port, name..."
        case .claude: "Filter projects and sessions..."
        case .system: "Filter processes..."
        }
    }
}

private struct GroupingMenu: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Group By", selection: $store.grouping) {
                ForEach(Grouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.grouping == .project ? "square.stack.3d.up" : "list.bullet.indent")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(store.grouping.title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: 7))
        .help("Group by project or by type")
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Disk tree", symbol: "internaldrive") {
                openWindow(id: "disk")
                NSApp.activate(ignoringOtherApps: true)
            }
            FooterButton(title: "Graph", symbol: "point.3.connected.trianglepath.dotted") { store.push(.graph) }
            if store.hasClaude {
                FooterButton(title: "Activity", symbol: "square.grid.3x3.fill") { store.push(.heatmap) }
            }
            Spacer()
            Menu {
                Button("Export JSON Snapshot") { store.export() }
                Button("Open Terminal UI") {
                    Launcher.runInTerminal(store.executable.map { Launcher.shellQuote($0.path) } ?? "devdash", in: NSHomeDirectory())
                }
                Button("What's New") { store.push(.whatsNew) }
                if Updater.shared.isAvailable {
                    Button("Check for Updates...") { Updater.shared.checkForUpdates() }
                }
                Divider()
                Button("Quit devdash") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            IconButton(symbol: "gearshape", help: "Settings") { store.push(.settings) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(hovering ? 1 : 0.75))
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(.primary.opacity(hovering ? 0.1 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
