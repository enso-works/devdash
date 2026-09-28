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

/// `DevDashBar --render <dir>`: renders each popover screen to PNGs (debug aid and README screenshots).
/// Run with DEVDASH_DEMO=1 to use synthetic data. Also writes hero.png, three panels under a menu bar strip.
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
    private static func waitForData(_ store: Store) async {
        for _ in 0..<80 where store.system == nil || (store.hasClaude && (store.claude == nil || store.usage == nil)) {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private static func host<V: View>(_ view: V, size: CGSize) -> NSHostingView<some View> {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["RENDER_LIGHT"] != nil ? .aqua : .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        return host
    }

    @MainActor
    private static func capture(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("rendered \(url.lastPathComponent)")
    }

    @MainActor
    private static func render(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store()
        let disk = DiskStore()
        await waitForData(store)

        let panel = host(PanelFrame { PopoverView().environment(store).environment(disk) }, size: PanelFrame<EmptyView>.size)
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
            capture(panel, to: dir.appendingPathComponent("\(name).png"))
        }
        store.routes = []
        store.tab = .dev

        let claudeStore = Store()
        let usageStore = Store()
        await waitForData(claudeStore)
        await waitForData(usageStore)
        claudeStore.tab = .claude
        usageStore.routes = [.usage]
        let hero = host(HeroView(stores: [store, claudeStore, usageStore], disk: disk), size: HeroView.size)
        try? await Task.sleep(for: .milliseconds(1500))
        capture(hero, to: dir.appendingPathComponent("hero.png"))

        [store, claudeStore, usageStore].forEach { $0.shutdown() }
    }
}

/// A popover-shaped panel with rounded corners on a transparent background.
private struct PanelFrame<Content: View>: View {
    static var size: CGSize { CGSize(width: 432, height: 612) }
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: 400, height: 580)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .padding(16)
    }
}

/// Menu bar strip with the status item, and three popovers hanging below it.
private struct HeroView: View {
    static var size: CGSize { CGSize(width: 1312, height: 658) }
    let stores: [Store]
    let disk: DiskStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Spacer()
                ForEach(["wifi", "battery.75percent", "magnifyingglass"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
                MenuBarLabel(store: stores[0])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.2), in: .rect(cornerRadius: 5))
                Text("Mon 9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(.black.opacity(0.55))
            HStack(alignment: .top, spacing: 0) {
                ForEach(stores.indices, id: \.self) { index in
                    PanelFrame { PopoverView().environment(stores[index]).environment(disk) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.33), Color(red: 0.05, green: 0.07, blue: 0.12)], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(.rect(cornerRadius: 12))
    }
}

/// `DevDashBar --scan <path>`: runs the disk scanner and prints totals, timing and the largest children.
enum ScanTest {
    static func run(path: String) {
        let start = Date()
        let scanner = DiskScanner(rootPath: (path as NSString).expandingTildeInPath, skip: DiskAccess.protectedFolders(fullDiskAccess: DiskAccess.hasFullDiskAccess))
        print("full disk access: \(DiskAccess.hasFullDiskAccess)")
        if let threads = ProcessInfo.processInfo.environment["SCAN_THREADS"].flatMap(Int.init) {
            scanner.run(threads: threads)
        } else {
            scanner.run()
        }
        let elapsed = Date().timeIntervalSince(start)
        let root = scanner.root
        print(String(format: "scanned in %.2fs", elapsed))
        print("allocated \(root.total.allocated) (\(ByteFormat.string(root.total.allocated)))  apparent \(ByteFormat.string(root.total.apparent))")
        print("files \(root.total.files)  dirs \(root.total.dirs)  hidden \(ByteFormat.string(root.total.hiddenAllocated))")
        var denied = 0
        root.forEach { if $0.denied { denied += 1 } }
        print("denied dirs \(denied)")
        DiskClassifier.apply(to: root)
        var nodes = 0
        root.forEach { _ in nodes += 1 }
        print("nodes kept \(nodes)")
        for child in root.children.sorted(by: { $0.total.allocated > $1.total.allocated }).prefix(12) {
            print("  \(ByteFormat.string(child.total.allocated).padding(toLength: 10, withPad: " ", startingAt: 0)) \(child.name) [\(child.category.label)]")
        }
        let started = Date()
        let suggestions = DiskSuggestionEngine.suggestions(for: root)
        print(String(format: "suggestions in %.2fs, total %@", Date().timeIntervalSince(started), ByteFormat.string(suggestions.reduce(0) { $0 + $1.size })))
        for suggestion in suggestions {
            print("  \(ByteFormat.string(suggestion.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(suggestion.title) | \(suggestion.detail) | \(suggestion.actionLabel)")
        }
    }
}

/// `DevDashBar --render-disk <out.png> [path]`: scans (or loads the cached scan) and renders the Disk window.
enum DiskRenderer {
    @MainActor
    static func run(output: String, path: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let disk = DiskStore()
            if let path {
                disk.scan(path: (path as NSString).expandingTildeInPath)
            } else {
                disk.prepare()
            }
            while disk.root == nil || disk.isScanning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            let size = CGSize(width: 1380, height: 880)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: DiskWindow().environment(disk).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            if let first = disk.root?.children.max(by: { $0.total.allocated < $1.total.allocated }) {
                disk.selection = first
            }
            try? await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
                print("rendered \(output)")
            }
            exit(0)
        }
        app.run()
    }
}
