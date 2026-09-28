import SwiftUI

extension DiskCategory {
    var color: Color {
        switch self {
        case .code: Color(red: 0.33, green: 0.45, blue: 0.72)
        case .agent: Color(red: 0.72, green: 0.49, blue: 0.29)
        case .toolchains: Color(red: 0.36, green: 0.62, blue: 0.43)
        case .synced: Color(red: 0.36, green: 0.62, blue: 0.70)
        case .git: Color(red: 0.70, green: 0.33, blue: 0.40)
        case .media: Color(red: 0.49, green: 0.38, blue: 0.75)
        case .documents: Color(red: 0.50, green: 0.53, blue: 0.58)
        case .cache: Color(red: 0.73, green: 0.64, blue: 0.30)
        case .other: Color(red: 0.36, green: 0.40, blue: 0.50)
        }
    }
}

/// Colors for Age mode, from recently modified (warm) to long untouched (cold).
enum AgeScale {
    static let stops: [(days: Double, label: String, color: Color)] = [
        (1, "Today", Color(red: 0.93, green: 0.45, blue: 0.30)),
        (7, "Week", Color(red: 0.90, green: 0.68, blue: 0.30)),
        (30, "Month", Color(red: 0.50, green: 0.70, blue: 0.40)),
        (180, "6 months", Color(red: 0.32, green: 0.60, blue: 0.68)),
        (365, "Year", Color(red: 0.35, green: 0.45, blue: 0.75)),
        (.infinity, "Older", Color(red: 0.42, green: 0.36, blue: 0.62)),
    ]

    static func color(forNewest timestamp: Double, now: Double) -> Color {
        let days = timestamp > 0 ? (now - timestamp) / 86_400 : .infinity
        return stops.first { days <= $0.days }?.color ?? stops.last!.color
    }
}

struct TreemapTile {
    let node: DiskNode
    let rect: CGRect
    let depth: Int
    /// The block for a directory's own loose files rather than a real child.
    let isFiles: Bool
    let hasChildren: Bool
    let hatched: Bool
}

enum TreemapLayout {
    static let headerHeight: CGFloat = 20
    static let inset: CGFloat = 2

    struct Options {
        var mode: TreemapMode
        var showHidden: Bool
        var apparent: Bool
        var maxDepth: Int
    }

    static func value(_ totals: DiskTotals, _ options: Options) -> Double {
        switch options.mode {
        case .files: Double(max(totals.fileCount(includeHidden: options.showHidden), 0))
        case .size, .age: Double(max(totals.size(apparent: options.apparent, includeHidden: options.showHidden), 0))
        }
    }

    static func tiles(for root: DiskNode, in rect: CGRect, options: Options) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        layout(root, rect: rect, depth: 0, hatched: root.isInsideReclaimable, options: options, into: &tiles)
        return tiles
    }

    private static func layout(_ node: DiskNode, rect: CGRect, depth: Int, hatched: Bool, options: Options, into tiles: inout [TreemapTile]) {
        let canNest = node.isDirectory && depth < options.maxDepth && rect.width > 44 && rect.height > headerHeight + 18
        var items: [(DiskNode, Double, Bool)] = []
        if canNest {
            for child in node.children where options.showHidden || !child.isHidden {
                let v = value(child.isDirectory ? child.total : child.own, options)
                if v > 0 { items.append((child, v, false)) }
            }
            var ownTotals = node.own
            if !options.showHidden {
                ownTotals.allocated -= ownTotals.hiddenAllocated
                ownTotals.apparent -= ownTotals.hiddenApparent
                ownTotals.files -= ownTotals.hiddenFiles
            }
            let ownValue = options.mode == .files ? Double(max(ownTotals.files, 0)) : Double(max(options.apparent ? ownTotals.apparent : ownTotals.allocated, 0))
            if ownValue > 0 { items.append((node, ownValue, true)) }
            items.sort { $0.1 > $1.1 }
        }
        // A folder whose only content is loose files is drawn as a single tile.
        let nests = canNest && items.contains { !$0.2 }
        tiles.append(TreemapTile(node: node, rect: rect, depth: depth, isFiles: false, hasChildren: nests, hatched: hatched))
        guard nests else { return }

        let inner = CGRect(
            x: rect.minX + inset, y: rect.minY + headerHeight,
            width: rect.width - inset * 2, height: rect.height - headerHeight - inset
        )
        let rects = squarify(items.map(\.1), in: inner)
        for (item, childRect) in zip(items, rects) where childRect.width >= 2 && childRect.height >= 2 {
            let gap = childRect.insetBy(dx: 0.75, dy: 0.75)
            if item.2 {
                tiles.append(TreemapTile(node: item.0, rect: gap, depth: depth + 1, isFiles: true, hasChildren: false, hatched: hatched))
            } else {
                layout(item.0, rect: gap, depth: depth + 1, hatched: hatched || item.0.reclaimable, options: options, into: &tiles)
            }
        }
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk). `values` must be sorted descending.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var remaining = rect
        var index = 0

        func worst(_ sum: Double, _ minArea: Double, _ maxArea: Double, _ side: Double) -> Double {
            let s2 = sum * sum, w2 = side * side
            return max(w2 * maxArea / s2, s2 / (w2 * minArea))
        }

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var sum = areas[index], minArea = areas[index], maxArea = areas[index]
            var end = index + 1
            var current = worst(sum, minArea, maxArea, side)
            while end < areas.count {
                let a = areas[end]
                let candidate = worst(sum + a, min(minArea, a), max(maxArea, a), side)
                if candidate > current { break }
                sum += a
                minArea = min(minArea, a)
                maxArea = max(maxArea, a)
                current = candidate
                end += 1
            }
            if remaining.width >= remaining.height {
                let width = CGFloat(sum) / remaining.height
                var y = remaining.minY
                for area in areas[index..<end] {
                    let height = CGFloat(area) / width
                    result.append(CGRect(x: remaining.minX, y: y, width: width, height: height))
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                let height = CGFloat(sum) / remaining.width
                var x = remaining.minX
                for area in areas[index..<end] {
                    let width = CGFloat(area) / height
                    result.append(CGRect(x: x, y: remaining.minY, width: width, height: height))
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(remaining.height - height, 0))
            }
            index = end
        }
        return result
    }
}

struct TreemapView: View {
    @Environment(DiskStore.self) private var store
    let root: DiskNode
    @State private var tiles: [TreemapTile] = []
    @State private var layoutKey = ""

    var body: some View {
        GeometryReader { geo in
            let options = TreemapLayout.Options(mode: store.mode, showHidden: store.showHidden, apparent: store.apparentSize, maxDepth: store.depth)
            let key = "\(ObjectIdentifier(root).hashValue)-\(store.revision)-\(Int(geo.size.width))x\(Int(geo.size.height))"
            // Read state here, not inside the Canvas closures, so SwiftUI redraws when it changes.
            let current = tiles
            let hovered = store.hovered
            let selected = store.selection
            ZStack {
                TreemapBase(tiles: current, options: options, key: layoutKey)
                    .equatable()
                Canvas { context, _ in
                    drawHighlights(current, hovered: hovered, selected: selected, context: context)
                }
                .allowsHitTesting(false)
            }
            .onAppear { relayout(size: geo.size, options: options, key: key) }
            .onChange(of: key) { relayout(size: geo.size, options: options, key: key) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): store.hovered = tile(at: point)?.node
                case .ended: store.hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    if let tile = tile(at: value.location) {
                        store.zoom(into: tile.isFiles ? tile.node : (tile.node.isDirectory ? tile.node : tile.node.parent ?? tile.node))
                    }
                }
                .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                    store.selection = tile(at: value.location)?.node
                })
            )
            .contextMenu { contextMenu }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let node = store.hovered ?? store.selection {
            if node.isDirectory {
                Button("Zoom In") { store.zoom(into: node) }
            }
            Button("Reveal in Finder") { Launcher.revealInFinder(node.path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
            if node.isDirectory {
                Button("Open in Terminal") { Launcher.runInTerminal("clear", in: node.path) }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { store.confirmTrash(node) }
                .disabled(node.parent == nil)
        }
    }

    private func relayout(size: CGSize, options: TreemapLayout.Options, key: String) {
        guard key != layoutKey || tiles.isEmpty else { return }
        layoutKey = key
        tiles = TreemapLayout.tiles(for: root, in: CGRect(origin: .zero, size: size), options: options)
    }

    /// The deepest tile under the point.
    private func tile(at point: CGPoint) -> TreemapTile? {
        tiles.last { $0.rect.contains(point) }
    }

    /// Drawn in a separate layer so hovering doesn't redraw every tile.
    private func drawHighlights(_ tiles: [TreemapTile], hovered: DiskNode?, selected: DiskNode?, context: GraphicsContext) {
        if let hovered, let tile = tiles.last(where: { $0.node === hovered && !$0.isFiles }) {
            context.stroke(Path(roundedRect: tile.rect, cornerRadius: 3), with: .color(.white.opacity(0.55)), lineWidth: 1.5)
        }
        if let selected, let tile = tiles.last(where: { $0.node === selected && !$0.isFiles }) {
            context.stroke(Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3), with: .color(.white), lineWidth: 2)
        }
    }
}

/// The tile layer. Equatable on the layout key so hover changes don't redraw thousands of tiles.
private struct TreemapBase: View, Equatable {
    let tiles: [TreemapTile]
    let options: TreemapLayout.Options
    let key: String

    nonisolated static func == (lhs: TreemapBase, rhs: TreemapBase) -> Bool { lhs.key == rhs.key && lhs.tiles.count == rhs.tiles.count }

    var body: some View {
        Canvas { context, _ in
            draw(tiles, context: context, options: options)
        }
    }

    private func draw(_ tiles: [TreemapTile], context: GraphicsContext, options: TreemapLayout.Options) {
        let now = Date.now.timeIntervalSince1970
        for tile in tiles {
            let rect = tile.rect
            let base = options.mode == .age
                ? AgeScale.color(forNewest: tile.node.total.newest, now: now)
                : tile.node.category.color
            let shape = Path(roundedRect: rect, cornerRadius: tile.depth == 0 ? 0 : 3)
            let fillOpacity = tile.isFiles ? 0.16 : max(0.22, 0.46 - Double(tile.depth) * 0.05)
            context.fill(shape, with: .color(base.opacity(fillOpacity)))

            if tile.hasChildren {
                let header = Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: TreemapLayout.headerHeight - 2))
                context.fill(header, with: .color(base.opacity(0.28)))
                context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2)), with: .color(base.opacity(0.9)))
            }
            if tile.hatched && !tile.hasChildren {
                drawHatch(in: rect, context: context)
            }
            context.stroke(shape, with: .color(.black.opacity(0.35)), lineWidth: 0.75)
            drawLabel(for: tile, options: options, context: context)
        }
    }

    private func drawHatch(in rect: CGRect, context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: Path(rect))
        var path = Path()
        let spacing: CGFloat = 6
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        clipped.stroke(path, with: .color(.white.opacity(0.09)), lineWidth: 1)
    }

    private func drawLabel(for tile: TreemapTile, options: TreemapLayout.Options, context: GraphicsContext) {
        let rect = tile.rect
        guard rect.width > 34, rect.height > 16 else { return }
        let name = tile.isFiles ? "files" : tile.node.label
        let totals = tile.isFiles ? tile.node.own : (tile.node.isDirectory ? tile.node.total : tile.node.own)
        let valueText = options.mode == .files
            ? "\(Format.count(Int(totals.fileCount(includeHidden: options.showHidden))))"
            : ByteFormat.compact(totals.size(apparent: options.apparent, includeHidden: options.showHidden))

        let title = Text(name)
            .font(.system(size: 11.5, weight: tile.hasChildren ? .semibold : .medium))
            .foregroundColor(.white.opacity(tile.isFiles ? 0.5 : 0.92))
        let detail = Text(valueText)
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundColor(.white.opacity(0.5))

        if tile.hasChildren {
            let resolvedDetail = context.resolve(detail)
            let detailSize = resolvedDetail.measure(in: CGSize(width: 200, height: 20))
            let showDetail = rect.width > detailSize.width + 70
            let titleWidth = rect.width - 12 - (showDetail ? detailSize.width + 8 : 0)
            context.draw(context.resolve(title), in: CGRect(x: rect.minX + 6, y: rect.minY + 3, width: titleWidth, height: 15))
            if showDetail {
                context.draw(resolvedDetail, at: CGPoint(x: rect.maxX - 6, y: rect.minY + 3), anchor: .topTrailing)
            }
        } else {
            context.draw(context.resolve(title), in: CGRect(x: rect.minX + 5, y: rect.minY + 3, width: rect.width - 10, height: 15))
            if rect.height > 34 {
                context.draw(context.resolve(detail), in: CGRect(x: rect.minX + 5, y: rect.minY + 18, width: rect.width - 10, height: 14))
            }
        }
    }
}
