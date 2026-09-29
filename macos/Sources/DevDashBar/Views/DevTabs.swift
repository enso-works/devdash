import SwiftUI

// MARK: - Docker

struct LogTarget: Codable, Hashable {
    let containerId: String
    let name: String
}

struct ContainerRow: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    let container: DockerContainer

    var body: some View {
        HoverRow(onTap: openLogs) {
            HStack(spacing: 8) {
                RuntimeBadge(runtime: "docker", tint: container.isHealthy ? nil : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
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
        .contextMenu {
            ForEach(container.hostPorts, id: \.self) { port in
                Button("Open localhost:\(String(port))") { Launcher.openPort(port) }
            }
            if let port = container.hostPorts.first {
                Button("Copy URL") { Pasteboard.copy("http://localhost:\(port)") }
                Divider()
            }
            Button("Stream Logs", action: openLogs)
            Button("Copy Container ID") { Pasteboard.copy(container.containerId) }
            Button("Copy Image") { Pasteboard.copy(container.image) }
            Divider()
            Button("Stop Container", role: .destructive) { store.stop(container) }
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
                StatsStrip()
                HStack(spacing: 8) {
                    ResourceCard(
                        title: "Swap",
                        value: system.swapPercent,
                        detail: String(format: "%.1f of %.0f GB", system.swapUsedGb, system.swapTotalGb)
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

struct StatsStrip: View {
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
