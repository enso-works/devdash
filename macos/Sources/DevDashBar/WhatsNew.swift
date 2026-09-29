import Foundation

/// Highlights per version, shown once after an update, and a short tour on a fresh install.
enum WhatsNew {
    struct Entry: Hashable {
        let symbol: String
        let title: String
        let detail: String
    }

    struct Release: Hashable {
        let version: String
        let entries: [Entry]
    }

    static let releases: [Release] = [
        Release(version: "0.3.0", entries: [
            Entry(symbol: "bell.badge", title: "Needs you",
                  detail: "Cleanup suggestions, low disk space and plan limits now appear in one list at the top."),
            Entry(symbol: "square.stack.3d.up", title: "Running, grouped by project",
                  detail: "Dev servers, containers and Claude sessions from the same repository appear together. Choose Group by Type for the old layout."),
            Entry(symbol: "chevron.left.forwardslash.chevron.right", title: "Dev servers in any language",
                  detail: "Vite, Bun, Python, Rails, Go and more, not only Node. Local databases appear under Services."),
            Entry(symbol: "contextualmenu.and.cursorarrow", title: "Right-click for every action",
                  detail: "Rows and project headers have a menu with everything they can do."),
            Entry(symbol: "keyboard", title: "Keyboard shortcuts",
                  detail: "Cmd+1 to Cmd+3 switch tabs and Cmd+F filters."),
        ]),
    ]

    static let tour: [Entry] = [
        Entry(symbol: "bell.badge", title: "Needs you",
              detail: "Anything that needs your attention, such as cleanup suggestions, low disk space or plan limits, appears at the top."),
        Entry(symbol: "play.circle", title: "Running",
              detail: "Your dev servers, containers and Claude sessions, grouped by project. Click a port to open it in the browser."),
        Entry(symbol: "contextualmenu.and.cursorarrow", title: "Right-click for every action",
              detail: "Rows and project headers have a menu: open in your editor, open a terminal, stop everything in a project."),
        Entry(symbol: "internaldrive", title: "Disk tree, Graph and Activity",
              detail: "Open them from the bottom bar."),
        Entry(symbol: "gearshape", title: "Settings",
              detail: "Launch at login, notifications, your editor and what the menu bar shows."),
    ]

    static let seenKey = "whatsNewSeenVersion"
    static let welcomeKey = "showWelcome"

    /// Runs at startup, before anything writes to user defaults: an empty defaults domain means a fresh
    /// install, which gets the tour instead of release notes.
    static func captureLaunchState() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        if UserDefaults.standard.persistentDomain(forName: id)?.isEmpty ?? true {
            UserDefaults.standard.set(true, forKey: welcomeKey)
        }
    }

    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Releases newer than `seen`, up to the running version, newest first.
    static func releases(after seen: String?) -> [Release] {
        guard let current = currentVersion else { return [] }
        return releases
            .filter { newer($0.version, than: seen) && !newer($0.version, than: current) }
            .sorted { newer($0.version, than: $1.version) }
    }

    private static func newer(_ version: String, than other: String?) -> Bool {
        guard let other else { return true }
        return version.compare(other, options: .numeric) == .orderedDescending
    }
}
