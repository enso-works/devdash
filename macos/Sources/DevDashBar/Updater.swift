import AppKit
import Sparkle

/// Sparkle auto-updates. Only active in release builds, which carry SUFeedURL in Info.plist.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // A menu bar app has no Dock icon to badge, so bring the update window forward instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
