import AppKit
import SwiftUI

/// `DevDashBar --selftest`: starts the bridge, decodes a snapshot and every command, then exits.
enum SelfTest {
    static func run() {
        Task { @MainActor in
            let code = await check()
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    private static func check() async -> Int32 {
        guard let executable = BridgeLocator.resolve(customPath: ProcessInfo.processInfo.environment["DEVDASH_BIN"] ?? "") else {
            print("FAIL devdash executable not found")
            return 1
        }
        print("using \(executable.path)")

        let bridge = BridgeClient()
        var snapshot: Snapshot?
        var claudeSeen = false
        bridge.onMessage = { message in
            switch message {
            case .hello(let hello): print("ok   hello v\(hello.version) claude=\(hello.hasClaude)")
            case .snapshot(let s):
                snapshot = s
                if s.claude != nil { claudeSeen = true }
            case .error(let e): print("FAIL \(e)")
            case .result: break
            }
        }
        do {
            try bridge.start(executable: executable)
        } catch {
            print("FAIL start: \(error)")
            return 1
        }

        for _ in 0..<50 where snapshot == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let snapshot else {
            print("FAIL no snapshot received")
            return 1
        }
        print("ok   snapshot node=\(snapshot.node.count) docker=\(snapshot.docker.count) procs=\(snapshot.processes.count) cleanup=\(snapshot.cleanup.count) claude=\(claudeSeen)")

        var failures = 0
        func step(_ name: String, _ body: () async throws -> String) async {
            do {
                print("ok   \(name): \(try await body())")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }

        await step("process_detail") {
            let d = try await bridge.request("process_detail", ["pid": ProcessInfo.processInfo.processIdentifier], as: ProcessDetail.self)
            return "\(d.name) threads=\(d.threads ?? -1)"
        }
        await step("graph") {
            let g = try await bridge.request("graph", as: GraphData.self)
            return "owners=\(g.owners.count) edges=\(g.edges.count)"
        }
        await step("heatmap") {
            let h = try await bridge.request("heatmap", as: HeatmapData?.self)
            return "days=\(h?.dailyMessages.count ?? 0) projects=\(h?.projectTimes.count ?? 0)"
        }
        await step("refresh_claude") {
            let c = try await bridge.request("refresh_claude", as: ClaudePayload?.self)
            return "instances=\(c?.instances.count ?? 0) projects=\(c?.projects.count ?? 0) sessions=\(c?.sessions.count ?? 0) stats=\(c?.stats != nil)"
        }
        if let project = (try? await bridge.request("refresh_claude", as: ClaudePayload?.self))??.projects.first {
            await step("project_detail") {
                let d = try await bridge.request("project_detail", ["path": project.path], as: ProjectDetail.self)
                return "\(d.name) sessions=\(d.totalSessions) tools=\(d.toolsUsed.count)"
            }
            await step("project_sessions") {
                let s = try await bridge.request("project_sessions", ["path": project.path], as: [ClaudeSession].self)
                return "\(s.count) sessions"
            }
        }
        await step("usage") {
            let u = try await bridge.request("usage", as: ClaudeUsage?.self)
            let today = u?.periods.today.cost ?? 0
            return "plan=\(u?.plan ?? "-") limits=\(u?.limits.count ?? 0) today=$\(String(format: "%.2f", today)) models=\(u?.models.count ?? 0) error=\(u?.error ?? "none")"
        }
        await step("unknown command errors") {
            do {
                _ = try await bridge.send("nope")
                throw BridgeError.failed("expected an error")
            } catch BridgeError.failed(let message) where message.contains("unknown") {
                return message
            }
        }

        bridge.stop()
        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}

/// `DevDashBar --render <dir>`: renders each popover screen with live data to PNGs (debug aid).
enum Renderer {
    @MainActor
    static func run(outputDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await render(to: URL(fileURLWithPath: outputDir))
            exit(0)
        }
        app.run()
    }

    @MainActor
    private static func render(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store()
        for _ in 0..<80 where store.system == nil || (store.hasClaude && (store.claude == nil || store.usage == nil)) {
            try? await Task.sleep(for: .milliseconds(250))
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RENDER_LIGHT"] != nil ? .aqua : .darkAqua)
        let host = NSHostingView(rootView: PopoverView().environment(store).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = host
        window.orderFrontRegardless()

        let screens: [(String, () -> Void)] = [
            ("dev", { store.routes = []; store.tab = .dev }),
            ("docker", { store.tab = .docker }),
            ("system", { store.tab = .system }),
            ("claude", { store.tab = .claude }),
            ("cleanup", { store.tab = .dev; store.routes = [.cleanup] }),
            ("heatmap", { store.routes = [.heatmap] }),
            ("usage", { store.routes = [.usage] }),
            ("graph", { store.routes = [.graph] }),
            ("project", { store.routes = store.claude?.projects.first.map { [.claudeProject(path: $0.path)] } ?? [] }),
            ("detail", { store.routes = store.node.first.map { [.processDetail(pid: $0.pid, name: $0.displayName)] } ?? [] }),
            ("settings", { store.routes = [.settings] }),
        ]
        for (name, apply) in screens {
            apply()
            try? await Task.sleep(for: .milliseconds(1500))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            print("rendered \(name)")
        }
        store.shutdown()
    }
}
