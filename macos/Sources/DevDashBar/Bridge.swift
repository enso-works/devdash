import Foundation

enum BridgeError: LocalizedError {
    case notRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "devdash bridge is not running"
        case .failed(let message): message
        }
    }
}

enum BridgeMessage: Sendable {
    case hello(Hello)
    case snapshot(Snapshot)
    case result(id: String, Result<Data, BridgeError>)
    case error(String)
}

enum BridgeCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private struct Envelope: Decodable {
        let type: String
        let id: String?
        let ok: Bool?
        let error: String?
        let message: String?
    }

    static func parse(_ line: Data) -> BridgeMessage? {
        let decoder = decoder()
        do {
            let envelope = try decoder.decode(Envelope.self, from: line)
            switch envelope.type {
            case "hello":
                return .hello(try decoder.decode(Hello.self, from: line))
            case "snapshot":
                return .snapshot(try decoder.decode(Snapshot.self, from: line))
            case "result":
                guard let id = envelope.id else { return nil }
                guard envelope.ok == true else {
                    return .result(id: id, .failure(.failed(envelope.error ?? "Command failed")))
                }
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                let payload = object?["data"] ?? NSNull()
                let data = try JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed)
                return .result(id: id, .success(data))
            case "error":
                return .error(envelope.message ?? "Unknown bridge error")
            default:
                return nil
            }
        } catch {
            return .error("Could not decode bridge output: \(error)")
        }
    }
}

/// Accumulates bytes from a pipe and yields complete newline-terminated lines.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (Data) -> Void

    init(onLine: @escaping @Sendable (Data) -> Void) {
        self.onLine = onLine
    }

    func feed(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}

/// Owns the `devdash --serve` child process and speaks its JSON-lines protocol.
@MainActor
final class BridgeClient {
    var onMessage: ((BridgeMessage) -> Void)?
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var nextId = 0
    private var stderrTail = StderrTail()

    var isRunning: Bool { process?.isRunning ?? false }

    func start(executable: URL) throws {
        stop()

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--serve"]
        process.environment = ShellEnvironment.childEnvironment()

        let stdout = Pipe(), stdin = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = stderr

        let reader = LineReader { [weak self] line in
            guard let message = BridgeCoding.parse(line) else { return }
            Task { @MainActor in self?.handle(message) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { reader.feed(chunk) }
        }
        let tail = stderrTail
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { tail.append(chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.handleTermination(of: proc, status: status) }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        if process.isRunning { process.terminate() }
        failPending(with: BridgeError.notRunning)
    }

    func request<T: Decodable & Sendable>(_ cmd: String, _ params: [String: Any] = [:], as type: T.Type) async throws -> T {
        let data = try await send(cmd, params)
        return try BridgeCoding.decoder().decode(T.self, from: data)
    }

    @discardableResult
    func send(_ cmd: String, _ params: [String: Any] = [:]) async throws -> Data {
        guard let stdinHandle, isRunning else { throw BridgeError.notRunning }
        nextId += 1
        let id = String(nextId)
        var payload = params
        payload["id"] = id
        payload["cmd"] = cmd
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func handle(_ message: BridgeMessage) {
        if case let .result(id, result) = message {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            switch result {
            case .success(let data): continuation.resume(returning: data)
            case .failure(let error): continuation.resume(throwing: error)
            }
            return
        }
        onMessage?(message)
    }

    private func handleTermination(of proc: Process, status: Int32) {
        // Ignore exits of processes we already replaced or stopped on purpose.
        guard proc === process else { return }
        process = nil
        stdinHandle = nil
        failPending(with: BridgeError.notRunning)
        let detail = stderrTail.text
        onExit?(detail.isEmpty ? "devdash exited with status \(status)" : detail)
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }
}

/// Keeps the last few lines of the bridge's stderr for error reporting.
private final class StderrTail: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        lines.append(contentsOf: text.split(separator: "\n").map(String.init))
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
