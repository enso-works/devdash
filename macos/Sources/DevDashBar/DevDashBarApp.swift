import AppKit
import SwiftUI

@main
@MainActor
enum Entry {
    static func main() {
        // Writing to a dead bridge must surface as an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            SelfTest.run()
        } else if let index = args.firstIndex(of: "--render-disk"), index + 1 < args.count {
            DiskRenderer.run(output: args[index + 1], path: index + 2 < args.count ? args[index + 2] : nil)
        } else if let index = args.firstIndex(of: "--scan"), index + 1 < args.count {
            ScanTest.run(path: args[index + 1])
        } else if let index = args.firstIndex(of: "--render"), index + 1 < args.count {
            Renderer.run(outputDir: args[index + 1])
        } else {
            DevDashBarApp.main()
        }
    }
}

struct DevDashBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = Store()
    @State private var disk = DiskStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
                .environment(disk)
                .onAppear { appDelegate.store = store }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Disk Tree", id: "disk") {
            DiskWindow()
                .environment(disk)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)

        WindowGroup("Logs", id: "logs", for: LogTarget.self) { $target in
            if let target {
                LogsView(target: target)
            }
        }
        .defaultSize(width: 760, height: 480)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also applies when run unbundled via `swift run`, where LSUIElement is absent.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { Updater.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.shutdown() }
    }
}

struct MenuBarLabel: View {
    let store: Store
    @AppStorage(SettingsKey.showCount) private var showCount = true
    @AppStorage(SettingsKey.showUsage) private var showUsage = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text, !text.isEmpty {
                Text(text).monospacedDigit()
            }
        }
    }

    private var text: String? {
        var parts: [String] = []
        if showCount, store.activeCount > 0 { parts.append("\(store.activeCount)") }
        if showUsage, let session = store.usage?.sessionLimit {
            parts.append("\(Int(session.percent.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch store.connection {
        case .failed, .missingBinary: "exclamationmark.triangle"
        default: store.isUnderPressure ? "flame" : "server.rack"
        }
    }
}
