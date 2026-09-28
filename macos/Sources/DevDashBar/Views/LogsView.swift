import AppKit
import SwiftUI

/// Streams `docker logs --follow` for one container.
@MainActor
@Observable
final class LogStream {
    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var isRunning = false
    private(set) var failure: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var counter = 0
    private let maxLines = 5000

    func start(containerId: String) {
        stop()
        guard let docker = ShellEnvironment.which("docker") else {
            failure = "docker CLI not found"
            return
        }
        let process = Process()
        process.executableURL = docker
        process.arguments = ["logs", "--tail", "300", "--follow", containerId]
        process.environment = ShellEnvironment.childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LogBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = buffer.feed(chunk)
            guard !lines.isEmpty else { return }
            Task { @MainActor in self?.append(lines) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.isRunning = false }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        isRunning = false
    }

    func clear() { lines.removeAll() }

    private func append(_ newLines: [String]) {
        for text in newLines {
            counter += 1
            lines.append(Line(id: counter, text: text))
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}

private final class LogBuffer: @unchecked Sendable {
    private var pending = ""
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        var parts = pending.components(separatedBy: "\n")
        pending = parts.removeLast()
        return parts
    }
}

struct LogsView: View {
    let target: LogTarget
    @State private var stream = LogStream()
    @State private var filter = ""
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(color: stream.isRunning ? .green : .secondary, pulsing: stream.isRunning)
                Text(target.name).font(.system(size: 13, weight: .semibold))
                Text(String(target.containerId.prefix(12)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter", text: $filter).textFieldStyle(.plain).frame(width: 160)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 6))
                Toggle("Follow", isOn: $follow).toggleStyle(.button).controlSize(.small)
                IconButton(symbol: "doc.on.doc", help: "Copy visible lines") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visible.map(\.text).joined(separator: "\n"), forType: .string)
                }
                IconButton(symbol: "trash", help: "Clear") { stream.clear() }
                IconButton(symbol: "arrow.clockwise", help: "Restart stream") { stream.start(containerId: target.containerId) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let failure = stream.failure {
                EmptyState(symbol: "exclamationmark.triangle", title: "Could not stream logs", message: failure)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visible) { line in
                                Text(line.text)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(color(for: line.text))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(10)
                    }
                    .onChange(of: stream.lines.last?.id) { _, id in
                        guard follow, let id else { return }
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .onAppear { stream.start(containerId: target.containerId) }
        .onDisappear { stream.stop() }
    }

    private var visible: [LogStream.Line] {
        filter.isEmpty ? stream.lines : stream.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    private func color(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("panic") { return .red }
        if lower.contains("warn") { return .orange }
        return .primary
    }
}
