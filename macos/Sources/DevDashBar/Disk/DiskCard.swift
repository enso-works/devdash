import SwiftUI

/// Summary of the last disk scan on the System tab, opening the Disk window.
struct DiskCard: View {
    @Environment(DiskStore.self) private var disk
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Disk tree").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if disk.isScanning {
                        ProgressView().controlSize(.mini)
                    }
                    Text("Open").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                if let root = disk.root {
                    CategoryStrip(root: root)
                }
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .card(radius: 10, padding: 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        if disk.isScanning, disk.root == nil {
            return "Scanning · \(Format.count(Int(disk.progress.files))) files"
        }
        guard disk.root != nil else { return "Scan your home folder to find space you can reclaim" }
        var parts: [String] = []
        if disk.reclaimableTotal > 0 { parts.append("\(ByteFormat.string(disk.reclaimableTotal)) worth a look") }
        if let date = disk.scanDate {
            parts.append("scanned " + date.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func open() {
        openWindow(id: "disk")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Share of the scan per category, as one stacked bar.
private struct CategoryStrip: View {
    let root: DiskNode

    var body: some View {
        let shares = Self.shares(root)
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(shares, id: \.0) { category, share in
                    Rectangle()
                        .fill(category.color.gradient)
                        .frame(width: max(2, geo.size.width * share))
                        .help("\(category.label) \(Int((share * 100).rounded()))%")
                }
            }
            .clipShape(.capsule)
        }
        .frame(height: 6)
    }

    private static func shares(_ root: DiskNode) -> [(DiskCategory, Double)] {
        var sizes: [DiskCategory: Int64] = [:]
        func visit(_ node: DiskNode, inherited: DiskCategory?) {
            // Attribute each subtree to the first node whose category differs from its parent's.
            if node.category != inherited || node.children.isEmpty {
                sizes[node.category, default: 0] += node.total.allocated
                return
            }
            sizes[node.category, default: 0] += node.own.allocated
            for child in node.children { visit(child, inherited: node.category) }
        }
        sizes[root.category, default: 0] += root.own.allocated
        for child in root.children { visit(child, inherited: root.category) }
        let total = Double(max(sizes.values.reduce(0, +), 1))
        return sizes.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, Double($0.value) / total) }
    }
}
