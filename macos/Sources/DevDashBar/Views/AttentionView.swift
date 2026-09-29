import AppKit
import SwiftUI

/// One entry in the "Needs you" list at the top of the popover.
struct AttentionItem: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case critical, warning, info
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Action { case retry, cleanup, disk, usage, whatsNew }

    let id: String
    let severity: Severity
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: Action
    /// Dismissing hides the item until its signature changes.
    var signature = ""
    var dismissible = true

    var tint: Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .info: .accentColor
        }
    }
}

@MainActor
enum Attention {
    static let reclaimableThreshold: Int64 = 5 * 1024 * 1024 * 1024
    static let limitThreshold = 80.0

    static func items(store: Store, disk: DiskStore) -> [AttentionItem] {
        var items: [AttentionItem] = []

        if case .failed(let reason) = store.connection, store.system != nil {
            items.append(AttentionItem(
                id: "bridge", severity: .critical, symbol: "bolt.horizontal.circle",
                title: "Data stopped updating", detail: reason, actionTitle: "Retry", action: .retry, dismissible: false
            ))
        }

        if let volume = disk.volume, volume.isLow {
            var detail = "\(ByteFormat.string(volume.free)) free on \(volume.name)"
            if disk.knownReclaimable > 0 { detail += ", \(ByteFormat.string(disk.knownReclaimable)) worth a look" }
            items.append(AttentionItem(
                id: "disk", severity: .critical, symbol: "internaldrive",
                title: "Low disk space", detail: detail, actionTitle: "Open", action: .disk,
                signature: "low-\(volume.free / 1_073_741_824)"
            ))
        } else if disk.knownReclaimable >= reclaimableThreshold {
            items.append(AttentionItem(
                id: "disk", severity: .info, symbol: "internaldrive",
                title: "\(ByteFormat.string(disk.knownReclaimable)) of disk space worth a look",
                detail: "Build artifacts, caches and old files in the Disk tree",
                actionTitle: "Open", action: .disk,
                signature: "reclaim-\(disk.knownReclaimable / 1_073_741_824)"
            ))
        }

        if let limit = store.usage?.limits.filter({ $0.percent >= limitThreshold }).max(by: { $0.percent < $1.percent }) {
            let percent = Int(limit.percent.rounded())
            var detail = "\(limit.label) limit"
            if let reset = limit.resetDate {
                detail += ", resets " + reset.formatted(.relative(presentation: .named))
            }
            items.append(AttentionItem(
                id: "limit", severity: limit.percent >= 95 ? .critical : .warning, symbol: "gauge.with.dots.needle.67percent",
                title: "\(percent)% of your plan limit used", detail: detail, actionTitle: "Usage", action: .usage,
                signature: "\(limit.label)-\(percent / 5)"
            ))
        }

        if !store.cleanup.isEmpty {
            let count = store.cleanup.count
            items.append(AttentionItem(
                id: "cleanup", severity: .warning, symbol: "sparkles",
                title: "\(count) cleanup suggestion\(count == 1 ? "" : "s")", detail: cleanupSummary(store.cleanup),
                actionTitle: "Review", action: .cleanup,
                signature: store.cleanup.map(\.id).sorted().joined(separator: ",")
            ))
        }

        if let note = store.whatsNew {
            let title = note.welcome ? "Welcome to devdash" : "What's new in \(note.releases.first?.version ?? "")"
            let detail = note.welcome
                ? "A quick look at what is where"
                : note.releases.flatMap(\.entries).prefix(3).map(\.title).joined(separator: ", ")
            items.append(AttentionItem(
                id: "whatsNew", severity: .info, symbol: note.welcome ? "hand.wave" : "gift",
                title: title, detail: detail, actionTitle: note.welcome ? "Show" : "See", action: .whatsNew
            ))
        }

        return items
            .filter { !store.isDismissed($0) }
            .enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
    }

    private static func cleanupSummary(_ items: [CleanupSuggestion]) -> String {
        let groups = Dictionary(grouping: items, by: \.category)
        let order = ["idle", "orphan", "zombie", "stale_container"]
        let names = ["idle": "idle", "orphan": "orphaned", "zombie": "zombie", "stale_container": "stale containers"]
        return order.compactMap { key in groups[key].map { "\($0.count) \(names[key] ?? key)" } }.joined(separator: " · ")
    }
}

/// "Needs you": everything that wants attention, in one card, hidden when there is nothing.
struct AttentionSection: View {
    @Environment(Store.self) private var store
    @Environment(DiskStore.self) private var disk
    @Environment(\.openWindow) private var openWindow
    @State private var showAll = false

    private static let visibleCount = 3

    var body: some View {
        let items = Attention.items(store: store, disk: disk)
        if !items.isEmpty {
            let visible = showAll ? items : Array(items.prefix(Self.visibleCount))
            VStack(spacing: 0) {
                HStack {
                    Text("NEEDS YOU")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if items.count > Self.visibleCount {
                        Button(showAll ? "Show less" : "\(items.count - Self.visibleCount) more") {
                            withAnimation(.snappy(duration: 0.22)) { showAll.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 2)
                ForEach(visible) { item in
                    AttentionRow(item: item, perform: { perform(item) }, dismiss: { dismiss(item) })
                }
            }
            .padding(.bottom, 3)
            .card(radius: 10, padding: 0)
        }
    }

    private func perform(_ item: AttentionItem) {
        switch item.action {
        case .retry: store.start()
        case .cleanup: store.push(.cleanup)
        case .usage: store.push(.usage)
        case .whatsNew: store.push(.whatsNew)
        case .disk:
            openWindow(id: "disk")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func dismiss(_ item: AttentionItem) {
        withAnimation(.snappy(duration: 0.22)) {
            if item.action == .whatsNew { store.markWhatsNewSeen() } else { store.dismiss(item) }
        }
    }
}

private struct AttentionRow: View {
    let item: AttentionItem
    let perform: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 24, height: 24)
                .background(item.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.dismissible && hovering {
                IconButton(symbol: "xmark", help: "Dismiss", size: 20, action: dismiss)
            }
            Text(item.actionTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.tint)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture(perform: perform)
        .onHover { hovering = $0 }
        .padding(.horizontal, 2)
    }
}
