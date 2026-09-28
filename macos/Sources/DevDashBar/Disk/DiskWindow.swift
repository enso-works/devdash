import SwiftUI

private enum DiskStyle {
    static let background = Color(red: 0.086, green: 0.094, blue: 0.125)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.157)
    static let hairline = Color.white.opacity(0.08)
    static let caption = Font.system(size: 10.5, weight: .semibold)
}

@MainActor private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
}()

@MainActor private func relative(_ timestamp: Double) -> String {
    guard timestamp > 0 else { return "unknown" }
    return relativeFormatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: .now)
}

struct DiskWindow: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            DiskHeader()
            Rectangle().fill(DiskStyle.hairline).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SummaryBar()
                    Group {
                        if let viewRoot = store.viewRoot {
                            TreemapView(root: viewRoot)
                                .clipShape(.rect(cornerRadius: 6))
                        } else {
                            ScanningPlaceholder()
                        }
                    }
                    .padding(.horizontal, 12)
                    StatusBar()
                }
                Rectangle().fill(DiskStyle.hairline).frame(width: 1)
                SidePanel()
                    .frame(width: 330)
                    .background(DiskStyle.panel)
            }
        }
        .background(DiskStyle.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 620)
        .overlay(alignment: .bottom) {
            if let message = store.message {
                HStack(spacing: 6) {
                    Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.isError ? .red : .green)
                    Text(message.message).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: store.message)
        .alert(
            store.pendingAction?.title ?? "",
            isPresented: Binding(get: { store.pendingAction != nil }, set: { if !$0 { store.pendingAction = nil } }),
            presenting: store.pendingAction
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                Task { await action.run() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .onAppear { store.prepare() }
    }
}

// MARK: - Header

private struct DiskHeader: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                LogoMark()
                Text("disk tree").font(.system(size: 17, weight: .medium))
            }
            Breadcrumb()
            Spacer(minLength: 8)
            if store.isScanning, store.root != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Rescanning · \(Format.count(Int(store.progress.files))) files")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $store.mode) {
                ForEach(TreemapMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            Toggle("Hidden files", isOn: $store.showHidden).toggleStyle(.checkbox)
            Toggle("Apparent size", isOn: $store.apparentSize).toggleStyle(.checkbox)
            HStack(spacing: 0) {
                Text("Depth \(store.depth)")
                    .font(.system(size: 12).monospacedDigit())
                    .padding(.horizontal, 10)
                Divider().frame(height: 16)
                Button { store.depth = max(1, store.depth - 1) } label: { Image(systemName: "minus").frame(width: 26, height: 24) }
                    .buttonStyle(.plain)
                Button { store.depth = min(8, store.depth + 1) } label: { Image(systemName: "plus").frame(width: 26, height: 24) }
                    .buttonStyle(.plain)
            }
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DiskStyle.hairline))
            IconButton(symbol: "folder", help: "Scan another folder") { store.chooseFolder() }
            IconButton(symbol: "arrow.clockwise", help: "Rescan") { store.scan() }
                .disabled(store.isScanning)
        }
        .font(.system(size: 12))
        .padding(.leading, 84) // traffic lights
        .padding(.trailing, 14)
        .frame(height: 52)
    }
}

private struct LogoMark: View {
    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                RoundedRectangle(cornerRadius: 2).fill(DiskCategory.code.color)
                RoundedRectangle(cornerRadius: 2).fill(DiskCategory.agent.color)
            }
            GridRow {
                RoundedRectangle(cornerRadius: 2).fill(DiskCategory.toolchains.color)
                RoundedRectangle(cornerRadius: 2).fill(DiskCategory.synced.color)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct Breadcrumb: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            if let viewRoot = store.viewRoot {
                let chain = Array((viewRoot.ancestors.reversed() + [viewRoot]))
                ForEach(Array(chain.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Text("/").foregroundStyle(.tertiary)
                    }
                    let isLast = index == chain.count - 1
                    Button {
                        store.viewRoot = node
                        store.selection = node
                    } label: {
                        Text(node.label)
                            .foregroundStyle(isLast ? .primary : .secondary)
                            .padding(.horizontal, isLast ? 7 : 2)
                            .padding(.vertical, 3)
                            .background(isLast ? Color.white.opacity(0.08) : .clear, in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(store.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

}

// MARK: - Summary and status

private struct SummaryBar: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            if let node = store.viewRoot {
                Text("\(ByteFormat.string(node.total.size(apparent: store.apparentSize, includeHidden: store.showHidden))) · \(Format.count(Int(node.total.fileCount(includeHidden: store.showHidden)))) files · \(Format.count(Int(node.total.dirs))) dirs")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.mode == .age {
                ForEach(AgeScale.stops, id: \.label) { stop in
                    LegendChip(color: stop.color, label: stop.label)
                }
            } else {
                HatchChip()
                ForEach(DiskCategory.allCases.filter { $0 != .other }, id: \.self) { category in
                    LegendChip(color: category.color, label: category.label)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}

private struct LegendChip: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.85)).frame(width: 10, height: 10)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct HatchChip: View {
    var body: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.1)))
                var path = Path()
                var x: CGFloat = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 3.5
                }
                context.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 1)
            }
            .frame(width: 10, height: 10)
            .clipShape(.rect(cornerRadius: 2))
            Text("Reclaimable").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct StatusBar: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            if let node = store.hovered ?? store.selection {
                Circle().fill(node.category.color).frame(width: 7, height: 7)
                Text(node.displayPath).lineLimit(1).truncationMode(.middle)
                Text(ByteFormat.string(node.total.allocated)).foregroundStyle(.secondary)
                if node.isDirectory {
                    Text("\(Format.count(Int(node.total.files))) files").foregroundStyle(.secondary)
                }
                Text("modified \(relative(node.total.newest))").foregroundStyle(.tertiary)
                if node.isInsideReclaimable {
                    Text("reclaimable").foregroundStyle(.orange)
                }
                if node.skippedReason != nil || node.denied {
                    Text(node.skippedReason ?? "No permission").foregroundStyle(.orange)
                }
            } else {
                Text("Click to select · double-click to zoom in · right-click for actions").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.system(size: 11.5).monospacedDigit())
        .padding(.horizontal, 14)
        .frame(height: 28)
    }
}

private struct ScanningPlaceholder: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            if store.isScanning {
                ProgressView().controlSize(.large)
                Text("Scanning \(store.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .font(.system(size: 15, weight: .medium))
                Text("\(Format.count(Int(store.progress.files))) files · \(Format.count(Int(store.progress.dirs))) folders · \(ByteFormat.string(store.progress.bytes))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(store.progress.currentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
                Text("The first scan of a large home folder can take a minute. Results are cached afterwards.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                PillButton(title: "Cancel") { store.cancelScan() }
            } else {
                Image(systemName: "square.grid.3x3.square").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                Text("No scan yet").font(.system(size: 15, weight: .medium))
                PillButton(title: "Scan \(store.rootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))", symbol: "play.fill", prominent: true) {
                    store.scan()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.02), in: .rect(cornerRadius: 6))
    }
}

// MARK: - Side panel

private struct SidePanel: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let node = store.selection ?? store.viewRoot, let root = store.root {
                    SelectionSection(node: node, root: root)
                    Rectangle().fill(DiskStyle.hairline).frame(height: 1)
                }
                if !store.hasFullDiskAccess, !store.skippedFolders.isEmpty {
                    AccessBanner(count: store.skippedFolders.count)
                }
                if !store.suggestions.isEmpty {
                    SuggestionsSection()
                    Rectangle().fill(DiskStyle.hairline).frame(height: 1)
                }
                VolumeSection()
                if let date = store.scanDate {
                    Text("Scanned \(relativeFormatter.localizedString(for: date, relativeTo: .now)) in \(Int(store.scanDuration.rounded()))s")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.never)
    }
}

private struct SelectionSection: View {
    @Environment(DiskStore.self) private var store
    let node: DiskNode
    let root: DiskNode

    var body: some View {
        let size = node.isDirectory ? node.total : node.own
        let rootSize = max(root.total.allocated, 1)
        let share = Double(size.allocated) / Double(rootSize)
        VStack(alignment: .leading, spacing: 12) {
            Text("SELECTION").font(DiskStyle.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(node.category.color).frame(width: 3, height: 20)
                Text(node.label)
                    .font(.system(size: 18, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(node.displayPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            let parts = ByteFormat.string(size.allocated).split(separator: " ")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.first.map(String.init) ?? "").font(.system(size: 46, weight: .regular, design: .rounded).monospacedDigit())
                Text(parts.dropFirst().joined()).font(.system(size: 16)).foregroundStyle(.secondary)
            }
            MeterBar(value: share, tint: node.category.color, height: 4)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Stat(label: "OF SCAN", value: share >= 0.001 ? String(format: "%.1f%%", share * 100) : "<0.1%")
                    Stat(label: "FILES", value: Format.count(Int(size.files)))
                }
                GridRow {
                    Stat(label: "LAST WRITE", value: relative(size.newest))
                    Stat(label: "KIND", value: node.category.label)
                }
            }
            if node.skippedReason != nil || node.denied {
                Label(node.skippedReason ?? "No permission to read this folder", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                PillButton(title: "Reveal", symbol: "folder") { Launcher.revealInFinder(node.path) }
                if node.isDirectory {
                    PillButton(title: "Terminal", symbol: "terminal") { Launcher.runInTerminal("clear", in: node.path) }
                }
                if node.parent != nil {
                    PillButton(title: "Trash", symbol: "trash", role: .destructive) { store.confirmTrash(node) }
                }
            }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(DiskStyle.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccessBanner: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(count) folder\(count == 1 ? "" : "s") skipped", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
            Text("App containers (including Docker's disk image), Mail and cloud folders need Full Disk Access. Grant it to DevDash, then rescan.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            PillButton(title: "Open Privacy Settings", symbol: "gear") { NSWorkspace.shared.open(DiskAccess.settingsURL) }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25)))
    }
}

private struct SuggestionsSection: View {
    @Environment(DiskStore.self) private var store
    @State private var expanded: String?

    var body: some View {
        let maxSize = store.suggestions.map(\.size).max() ?? 1
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("WORTH A LOOK").font(DiskStyle.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(store.reclaimableTotal))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskCategory.cache.color)
            }
            .padding(.bottom, 6)
            ForEach(store.suggestions) { suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    maxSize: maxSize,
                    isExpanded: expanded == suggestion.id
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        expanded = expanded == suggestion.id ? nil : suggestion.id
                    }
                }
            }
        }
    }
}

private struct SuggestionRow: View {
    @Environment(DiskStore.self) private var store
    let suggestion: DiskSuggestion
    let maxSize: Int64
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(suggestion.category.color)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(suggestion.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(suggestion.sizeText).font(.system(size: 12.5).monospacedDigit())
                        }
                        HStack {
                            Text(suggestion.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            MeterBar(value: Double(suggestion.size) / Double(max(maxSize, 1)), tint: suggestion.category.color, height: 3)
                                .frame(width: 70)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(.white.opacity(hovering || isExpanded ? 0.05 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(suggestion.kind.prefix(1).capitalized + suggestion.kind.dropFirst())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let risk = suggestion.risk {
                        Label(risk, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestion.nodes.prefix(8)) { node in
                            Button {
                                if let parent = node.parent { store.viewRoot = parent }
                                store.selection = node
                            } label: {
                                HStack {
                                    Text(node.displayPath).lineLimit(1).truncationMode(.head)
                                    Spacer()
                                    Text(ByteFormat.string(node.total.allocated)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.system(size: 10.5))
                                .padding(.vertical, 2)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        if suggestion.nodes.count > 8 {
                            Text("and \(suggestion.nodes.count - 8) more").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                    if store.isRunning(suggestion) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working...").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else {
                        PillButton(title: suggestion.actionLabel, symbol: symbol, prominent: true) {
                            store.confirm(suggestion)
                        }
                    }
                }
                .padding(.leading, 19)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }

    private var symbol: String {
        switch suggestion.action {
        case .trash: "trash"
        case .command: "terminal"
        case .emptyTrash: "trash.slash"
        }
    }
}

private struct VolumeSection: View {
    @Environment(DiskStore.self) private var store

    var body: some View {
        if let volume = store.volume {
            let usedShare = Double(volume.used) / Double(max(volume.total, 1))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("DISK").font(DiskStyle.caption).foregroundStyle(.secondary)
                    Text(volume.name).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                let parts = ByteFormat.string(volume.free).split(separator: " ")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.first.map(String.init) ?? "").font(.system(size: 34, design: .rounded).monospacedDigit())
                    Text("\(parts.dropFirst().joined()) free").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                MeterBar(value: usedShare, tint: usedShare > 0.9 ? .red : .white.opacity(0.55), height: 6)
                HStack {
                    Text("\(ByteFormat.string(volume.used)) used")
                    Spacer()
                    Text("\(ByteFormat.string(volume.total)) total")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}
