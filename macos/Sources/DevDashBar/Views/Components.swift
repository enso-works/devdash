import SwiftUI

// MARK: - Formatting

enum Format {
    static func memory(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    static func percent(_ value: Double) -> String {
        String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
    }

    static func rate(_ bps: Double?) -> String {
        guard let bps else { return "--" }
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        return String(format: "%.1f MB/s", bps / (1024 * 1024))
    }

    static func count(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 10_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return n.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

extension BridgeConfig {
    /// Same three-level scale as the TUI's _severity_style.
    func severity(_ percent: Double) -> Color {
        if percent >= colorThresholdHigh { return .red }
        if percent >= colorThresholdLow { return .orange }
        return .green
    }

    /// Per-row metrics stay quiet until they cross the low threshold.
    func metricTint(_ percent: Double) -> Color {
        percent >= colorThresholdLow ? severity(percent) : .secondary
    }
}

// MARK: - Surfaces

struct CardBackground: ViewModifier {
    var radius: CGFloat = 10
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.06)))
    }
}

extension View {
    func card(radius: CGFloat = 10, padding: CGFloat = 10) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }
}

// MARK: - Gauges

struct RingGauge: View {
    let value: Double
    let tint: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.smooth(duration: 0.6), value: value)
    }
}

struct MeterBar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.6), value: value)
    }
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double = 100
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: values.count > 1 ? geo.size.width * CGFloat(index) / CGFloat(values.count - 1) : 0,
                    y: geo.size.height * (1 - CGFloat(min(value / maxValue, 1)))
                )
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                }
                .fill(tint.opacity(0.15).gradient)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }
}

// MARK: - Chips and badges

struct PortChip: View {
    let port: Int
    var interactive = true

    var body: some View {
        Button {
            Launcher.openPort(port)
        } label: {
            Text(verbatim: ":\(port)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: .capsule)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
        .help("Open http://localhost:\(port)")
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    Circle().stroke(color.opacity(0.4), lineWidth: 3).scaleEffect(1.6)
                }
            }
    }
}

struct CountBadge: View {
    let count: Int
    var selected = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08), in: .capsule)
    }
}

struct Metric: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(color)
    }
}

// MARK: - Buttons

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    var size: CGFloat = 24
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.75))
                .frame(width: size, height: size)
                .background(.primary.opacity(hovering ? 0.1 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Destructive action that asks for a second click instead of an alert.
struct ConfirmIconButton: View {
    let symbol: String
    let help: String
    var confirmLabel = "Kill?"
    var busy = false
    let action: () -> Void
    @State private var armed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
            } else if armed {
                Button {
                    armed = false
                    action()
                } label: {
                    Text(confirmLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color.red, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                IconButton(symbol: symbol, help: help, tint: .red) {
                    withAnimation(.snappy(duration: 0.2)) { armed = true }
                    disarmTask?.cancel()
                    disarmTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        withAnimation(.snappy(duration: 0.2)) { armed = false }
                    }
                }
            }
        }
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(background, in: .capsule)
            .foregroundStyle(prominent ? .white : .primary)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        let base: Color = role == .destructive ? .red : (prominent ? .accentColor : .primary)
        if prominent || role == .destructive { return base.opacity(hovering ? 0.85 : 1) }
        return base.opacity(hovering ? 0.12 : 0.07)
    }
}

// MARK: - Rows and sections

/// A list row that swaps its trailing metrics for action buttons while hovered.
struct HoverRow<Leading: View, Metrics: View, Actions: View>: View {
    var onTap: (() -> Void)?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let metrics: () -> Metrics
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                metrics()
                    .opacity(hovering ? 0 : 1)
                HStack(spacing: 2) { actions() }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { onTap?() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if let count { CountBadge(count: count) }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            if let message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

struct SubPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "chevron.left", help: "Back") { store.pop() }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

extension SubPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Loads async content for a sub-page and renders loading and error states.
struct AsyncContent<Value: Sendable, Content: View>: View {
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(Value)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let value):
                content(value)
            case .failed(let message):
                EmptyState(symbol: "exclamationmark.triangle", title: "Could not load", message: message)
            }
        }
        .task {
            do {
                state = .loaded(try await load())
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 8, padding: 8)
    }
}

extension String {
    func matches(query: String) -> Bool {
        query.isEmpty || localizedCaseInsensitiveContains(query)
    }
}
