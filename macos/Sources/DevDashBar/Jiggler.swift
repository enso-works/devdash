import AppKit
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac awake and the user active while on: holds a display sleep assertion and, once
/// the user has been idle for a while, nudges the cursor one point and back so chat apps stay green.
/// The nudge needs Accessibility access; without it only the power assertion and a declared user
/// activity are used.
@MainActor
@Observable
final class Jiggler {
    static let shared = Jiggler()

    private static let enabledKey = "jigglerEnabled"
    private static let checkInterval: Duration = .seconds(20)
    private static let idleThreshold: TimeInterval = 50

    private(set) var isOn = false
    /// Whether the cursor nudge can be posted; refreshed on every check.
    private(set) var canNudge = CGPreflightPostEventAccess()

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var activity: IOPMAssertionID = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Restores the state from the last launch.
    func start() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { setOn(true) }
    }

    func toggle() {
        // Shows the system prompt once; the nudge starts working as soon as access is granted.
        if !isOn, !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        setOn(!isOn)
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "devdash jiggler" as CFString,
                &assertion
            )
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: Self.checkInterval)
                }
            }
        } else {
            loop?.cancel()
            loop = nil
            release(&assertion)
            release(&activity)
        }
    }

    private func tick() {
        canNudge = CGPreflightPostEventAccess()
        guard idleSeconds >= Self.idleThreshold else { return }
        if canNudge { nudge() }
        // Resets the system idle timer even without Accessibility access.
        IOPMAssertionDeclareUserActivity("devdash jiggler" as CFString, kIOPMUserActiveLocal, &activity)
    }

    private var idleSeconds: TimeInterval {
        // kCGAnyInputEventType: time since any keyboard, mouse or tablet event.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Moves the cursor one point and straight back, too fast to see.
    private func nudge() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for point in [CGPoint(x: location.x + 1, y: location.y), location] {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}
