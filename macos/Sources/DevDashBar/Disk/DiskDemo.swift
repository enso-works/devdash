import Foundation

/// Synthetic scan used when DEVDASH_DEMO=1 (README screenshots), so no real paths are shown.
enum DiskDemo {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["DEVDASH_DEMO"] == "1" }

    private struct Generator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private static let gib: Double = 1024 * 1024 * 1024

    static func tree() -> DiskNode {
        var random = Generator()
        let now = Date.now.timeIntervalSince1970
        let root = DiskNode(name: NSHomeDirectory(), parent: nil, isDirectory: true, isHidden: false)

        @discardableResult
        func dir(_ name: String, in parent: DiskNode, markers: ProjectMarkers = []) -> DiskNode {
            let node = DiskNode(name: name, parent: parent, isDirectory: true, isHidden: name.hasPrefix("."))
            node.markers = markers
            parent.children.append(node)
            return node
        }
        func fill(_ node: DiskNode, gib size: Double, files: Int64, ageDays: Double) {
            let bytes = Int64(size * gib)
            node.own = DiskTotals(allocated: bytes, apparent: Int64(Double(bytes) * 0.93), files: files, dirs: files / 12,
                                  newest: now - ageDays * 86_400)
        }
        func spread(_ node: DiskNode, names: [String], gib total: Double, ageDays: Double) {
            var weights = names.map { _ in 0.3 + random.next() }
            let sum = weights.reduce(0, +)
            weights = weights.map { $0 / sum }
            for (name, weight) in zip(names, weights) {
                fill(dir(name, in: node), gib: total * weight, files: Int64(total * weight * 9_000), ageDays: ageDays * (0.5 + random.next()))
            }
        }
        func project(_ name: String, in parent: DiskNode, gib size: Double, ageDays: Double, kind: String) {
            var markers: ProjectMarkers = [.git]
            switch kind {
            case "rust": markers.insert(.cargo)
            case "swift": markers.insert(.swiftPackage)
            default: markers.insert(.packageJSON)
            }
            let node = dir(name, in: parent, markers: markers)
            fill(dir("src", in: node), gib: size * 0.12, files: 2_400, ageDays: ageDays)
            fill(dir(".git", in: node), gib: size * 0.1, files: 3_100, ageDays: ageDays)
            switch kind {
            case "rust": fill(dir("target", in: node), gib: size * 0.78, files: 41_000, ageDays: ageDays)
            case "swift": fill(dir(".build", in: node), gib: size * 0.78, files: 12_000, ageDays: ageDays)
            case "next":
                fill(dir("node_modules", in: node), gib: size * 0.55, files: 88_000, ageDays: ageDays + 2)
                fill(dir(".next", in: node), gib: size * 0.23, files: 9_000, ageDays: ageDays)
            default: fill(dir("node_modules", in: node), gib: size * 0.78, files: 120_000, ageDays: ageDays + 2)
            }
        }

        let src = dir("src", in: root)
        project("storefront", in: src, gib: 14, ageDays: 0.2, kind: "next")
        project("design-system", in: src, gib: 6.5, ageDays: 1, kind: "js")
        project("ledger-rs", in: src, gib: 18, ageDays: 40, kind: "rust")
        project("sync-engine", in: src, gib: 11, ageDays: 22, kind: "rust")
        project("old-landing", in: src, gib: 3.2, ageDays: 120, kind: "js")
        project("menubar-kit", in: src, gib: 4.4, ageDays: 60, kind: "swift")
        let tries = dir("tries", in: src)
        for (index, name) in ["2026-06-02-wasm-audio", "2026-07-11-vector-db", "2026-07-19-llm-router", "2026-08-03-edge-cache", "2026-09-20-ui-lab"].enumerated() {
            project(name, in: tries, gib: 1.5 + random.next() * 4, ageDays: index == 4 ? 3 : 45 + Double(index) * 10, kind: index % 2 == 0 ? "rust" : "js")
        }

        let codex = dir(".codex", in: root)
        let worktrees = dir("worktrees", in: codex)
        for (index, name) in ["f4b5", "a91c", "77de"].enumerated() {
            let tree = dir(name, in: worktrees)
            project("storefront", in: tree, gib: 6 + Double(index) * 4, ageDays: 12 + Double(index) * 9, kind: "next")
        }
        fill(dir("sessions", in: codex), gib: 0.8, files: 2_000, ageDays: 0.1)

        let library = dir("Library", in: root)
        let developer = dir("Developer", in: library)
        let xcode = dir("Xcode", in: developer)
        fill(dir("DerivedData", in: xcode), gib: 21, files: 180_000, ageDays: 3)
        fill(dir("iOS DeviceSupport", in: xcode), gib: 12, files: 40_000, ageDays: 90)
        fill(dir("Archives", in: xcode), gib: 4, files: 900, ageDays: 200)
        let simulator = dir("CoreSimulator", in: developer)
        spread(dir("Devices", in: simulator), names: ["2B41", "7F02", "C9A8", "E115"], gib: 34, ageDays: 20)
        let caches = dir("Caches", in: library)
        fill(dir("Homebrew", in: caches), gib: 3.1, files: 400, ageDays: 10)
        fill(dir("Yarn", in: caches), gib: 5.2, files: 60_000, ageDays: 30)
        fill(dir("com.spotify.client", in: caches), gib: 2.4, files: 3_000, ageDays: 1)
        fill(dir("pip", in: caches), gib: 1.6, files: 8_000, ageDays: 50)
        spread(dir("Application Support", in: library), names: ["Code", "Slack", "Figma", "Google", "Arc"], gib: 22, ageDays: 1)
        let cloud = dir("CloudStorage", in: library)
        spread(dir("Dropbox", in: cloud), names: ["Photos", "Clients", "Archive"], gib: 38, ageDays: 5)

        let cache = dir(".cache", in: root)
        fill(dir("uv", in: cache), gib: 6.8, files: 50_000, ageDays: 4)
        fill(dir("huggingface", in: cache), gib: 14, files: 300, ageDays: 70)
        fill(dir("puppeteer", in: cache), gib: 1.2, files: 900, ageDays: 30)
        let npm = dir(".npm", in: root)
        fill(dir("_cacache", in: npm), gib: 9.5, files: 400_000, ageDays: 2)
        let cargo = dir(".cargo", in: root)
        fill(dir("registry", in: cargo), gib: 7.5, files: 150_000, ageDays: 6)
        fill(dir("bin", in: cargo), gib: 0.6, files: 40, ageDays: 30)
        fill(dir(".rustup", in: root), gib: 8.2, files: 30_000, ageDays: 14)
        fill(dir(".nvm", in: root), gib: 3.4, files: 70_000, ageDays: 40)

        let steam = dir("Steam", in: dir("share", in: dir(".local", in: root)))
        spread(dir("steamapps", in: steam), names: ["Hades II", "Factorio", "Portal 2"], gib: 64, ageDays: 15)
        spread(dir("Movies", in: root), names: ["2026 Japan", "Screen recordings", "Talks"], gib: 48, ageDays: 60)
        spread(dir("Pictures", in: root), names: ["Photos Library.photoslibrary", "Wallpapers"], gib: 31, ageDays: 3)
        spread(dir("Documents", in: root), names: ["Taxes", "Scans", "Design", "Books"], gib: 26, ageDays: 20)
        let downloads = dir("Downloads", in: root)
        for (name, size, age) in [("Xcode_26.xip", 7.9, 150.0), ("ubuntu-24.04.iso", 5.8, 210), ("figma-export", 1.1, 100), ("client-assets.zip", 2.3, 12)] {
            let node = DiskNode(name: name, parent: downloads, isDirectory: !name.contains("."), isHidden: false)
            fill(node, gib: size, files: 1, ageDays: age)
            downloads.children.append(node)
        }
        fill(dir(".Trash", in: root), gib: 4.6, files: 3_000, ageDays: 2)

        root.aggregate()
        return root
    }
}
