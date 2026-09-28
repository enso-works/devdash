import SwiftUI

// MARK: - Dev (Node)

struct DevTab: View {
    @Environment(Store.self) private var store
    @State private var showBackground = false

    var body: some View {
        let servers = store.servers.filter(matches).sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
        let background = store.backgroundNode.filter(matches)

        SectionHeader(title: "Dev servers", count: servers.count)
        if servers.isEmpty {
            EmptyState(
                symbol: "moon.zzz",
                title: store.query.isEmpty ? "No dev servers running" : "No matching servers",
                message: store.query.isEmpty ? "Node processes listening on a port show up here." : nil
            )
        } else {
            ForEach(servers) { NodeRow(proc: $0) }
        }

        if !background.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showBackground.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showBackground || !store.query.isEmpty ? 90 : 0))
                    Text("OTHER NODE PROCESSES")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                    CountBadge(count: background.count)
                    Spacer()
                    Text(Format.memory(background.reduce(0) { $0 + $1.memoryMb }))
                        .font(.system(size: 10.5).monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showBackground || !store.query.isEmpty {
                ForEach(background) { NodeRow(proc: $0, compact: true) }
            }
        }
    }

    private func matches(_ proc: NodeProcess) -> Bool {
        let q = store.query
        guard !q.isEmpty else { return true }
        return proc.displayName.matches(query: q) || proc.command.matches(query: q)
            || proc.cwd.matches(query: q) || proc.ports.contains { String($0).contains(q) }
            || String(proc.pid) == q
    }
}

struct NodeRow: View {
    @Environment(Store.self) private var store
    let proc: NodeProcess
    var compact = false

    var body: some View {
        HoverRow(onTap: { store.push(.processDetail(pid: proc.pid, name: proc.displayName)) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !compact { StatusDot(color: .green) }
                    Text(proc.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    ForEach(proc.ports.prefix(3), id: \.self) { PortChip(port: $0) }
                    if proc.ports.count > 3 {
                        Text("+\(proc.ports.count - 3)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(proc.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact {
                    Text(verbatim: "\(proc.cwd)  ·  PID \(proc.pid)  ·  up \(proc.uptime)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } metrics: {
            VStack(alignment: .trailing, spacing: 3) {
                Metric(text: Format.percent(proc.cpuPercent), color: store.config.metricTint(proc.cpuPercent))
                Metric(text: Format.memory(proc.memoryMb))
            }
        } actions: {
            if let port = proc.ports.first {
                IconButton(symbol: "safari", help: "Open localhost:\(port)") { Launcher.openPort(port) }
            }
            IconButton(symbol: "folder", help: "Reveal in Finder") { Launcher.revealInFinder(proc.cwdFull) }
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                store.openInEditor(proc.cwdFull)
            }
            ConfirmIconButton(symbol: "xmark.octagon", help: "Kill PID \(proc.pid)", busy: store.isPending("pid-\(proc.pid)")) {
                store.kill(pid: proc.pid, label: proc.displayName)
            }
        }
    }
}

// MARK: - Docker

struct LogTarget: Codable, Hashable {
    let containerId: String
    let name: String
}

struct DockerTab: View {
    @Environment(Store.self) private var store

    var body: some View {
        let containers = store.docker.filter(matches)
        let groups = Dictionary(grouping: containers, by: \.composeProject)
            .sorted { lhs, rhs in
                // Compose stacks first, standalone containers last.
                if lhs.key.isEmpty != rhs.key.isEmpty { return !lhs.key.isEmpty }
                return lhs.key < rhs.key
            }

        if containers.isEmpty {
            EmptyState(
                symbol: "shippingbox",
                title: store.query.isEmpty ? "No running containers" : "No matching containers",
                message: store.query.isEmpty ? "Docker may not be running." : nil
            )
        } else {
            ForEach(groups, id: \.key) { project, members in
                SectionHeader(title: project.isEmpty ? "Standalone" : project, count: members.count) {
                    if !project.isEmpty {
                        StopStackButton(project: project)
                    }
                }
                ForEach(members) { ContainerRow(container: $0) }
            }
        }
    }

    private func matches(_ container: DockerContainer) -> Bool {
        let q = store.query
        return container.name.matches(query: q) || container.image.matches(query: q)
            || container.composeProject.matches(query: q) || container.composeService.matches(query: q)
            || container.ports.matches(query: q)
    }
}

private struct StopStackButton: View {
    @Environment(Store.self) private var store
    let project: String
    @State private var armed = false

    var body: some View {
        if store.isPending("stack-\(project)") {
            ProgressView().controlSize(.mini)
        } else {
            Button(armed ? "Stop all?" : "Stop all") {
                if armed {
                    armed = false
                    store.stopStack(project)
                } else {
                    armed = true
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        armed = false
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(armed ? .white : .red)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(armed ? Color.red : Color.red.opacity(0.1), in: .capsule)
        }
    }
}

struct ContainerRow: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let container: DockerContainer

    var body: some View {
        HoverRow(onTap: openLogs) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(color: container.isHealthy ? .green : .orange)
                    Text(container.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    ForEach(container.hostPorts.prefix(3), id: \.self) { PortChip(port: $0) }
                }
                Text(container.image)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } metrics: {
            VStack(alignment: .trailing, spacing: 3) {
                Metric(text: container.status, color: container.isHealthy ? .secondary : .orange)
                Metric(text: String(container.containerId.prefix(12)), color: .secondary.opacity(0.7))
                    .font(.system(size: 10, design: .monospaced))
            }
        } actions: {
            if let port = container.hostPorts.first {
                IconButton(symbol: "safari", help: "Open localhost:\(port)") { Launcher.openPort(port) }
            }
            IconButton(symbol: "text.alignleft", help: "Stream logs", action: openLogs)
            ConfirmIconButton(
                symbol: "stop.circle",
                help: "Stop container",
                confirmLabel: "Stop?",
                busy: store.isPending("ctr-\(container.containerId)")
            ) {
                store.stop(container)
            }
        }
    }

    private func openLogs() {
        openWindow(id: "logs", value: LogTarget(containerId: container.containerId, name: container.displayName))
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - System

struct SystemTab: View {
    @Environment(Store.self) private var store
    @State private var sortByCPU = false

    var body: some View {
        if let system = store.system {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ResourceCard(
                        title: "Memory",
                        value: system.memoryPercent,
                        detail: String(format: "%.1f of %.0f GB", system.memoryUsedGb, system.memoryTotalGb)
                    )
                    ResourceCard(
                        title: "Swap",
                        value: system.swapPercent,
                        detail: String(format: "%.1f of %.0f GB", system.swapUsedGb, system.swapTotalGb)
                    )
                }
                HStack(spacing: 8) {
                    ResourceCard(
                        title: "Disk",
                        value: system.diskPercent,
                        detail: String(format: "%.0f GB free of %.0f", system.diskFreeGb, system.diskTotalGb)
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Network").font(.system(size: 11, weight: .semibold))
                        Label(Format.rate(system.netRecvPerSec), systemImage: "arrow.down")
                        Label(Format.rate(system.netSentPerSec), systemImage: "arrow.up")
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .labelStyle(CompactLabelStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 10, padding: 9)
                }
                DiskCard()
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
        }

        SectionHeader(title: "Top processes", count: filtered.count) {
            Picker("", selection: $sortByCPU) {
                Text("Memory").tag(false)
                Text("CPU").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
        }
        ForEach(filtered) { GeneralRow(proc: $0) }
    }

    private var filtered: [GeneralProcess] {
        let q = store.query
        let list = store.processes.filter {
            $0.name.matches(query: q) || $0.command.matches(query: q) || $0.user.matches(query: q) || String($0.pid) == q
        }
        return sortByCPU ? list.sorted { $0.cpuPercent > $1.cpuPercent } : list
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.secondary).font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

private struct ResourceCard: View {
    @Environment(Store.self) private var store
    let title: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(Format.percent(value))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(store.config.severity(value))
            }
            MeterBar(value: value / 100, tint: store.config.severity(value))
            Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .card(radius: 10, padding: 9)
    }
}

struct GeneralRow: View {
    @Environment(Store.self) private var store
    let proc: GeneralProcess

    var body: some View {
        HoverRow(onTap: { store.push(.processDetail(pid: proc.pid, name: proc.name)) }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(proc.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(verbatim: "PID \(proc.pid)  ·  \(proc.user)  ·  \(proc.status)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        } metrics: {
            HStack(spacing: 10) {
                Metric(text: Format.percent(proc.cpuPercent), color: store.config.metricTint(proc.cpuPercent))
                    .frame(width: 44, alignment: .trailing)
                Metric(text: Format.memory(proc.memoryMb), color: store.config.metricTint(proc.memoryPercent * 4))
                    .frame(width: 58, alignment: .trailing)
            }
        } actions: {
            IconButton(symbol: "info.circle", help: "Details") {
                store.push(.processDetail(pid: proc.pid, name: proc.name))
            }
            ConfirmIconButton(symbol: "xmark.octagon", help: "Kill PID \(proc.pid)", busy: store.isPending("pid-\(proc.pid)")) {
                store.kill(pid: proc.pid, label: proc.name)
            }
        }
    }
}
