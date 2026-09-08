import Testing
import Foundation
@testable import VPNSwitch

/// Unit tests for the pure header-line helper (dns-config-l40.3 step 5):
/// `AppModel.reconcileHeaderLine(target:activity:nextAttemptAt:now:)`.
@MainActor
struct ReconcileHeaderTests {

    /// Attempt 1 with the next attempt 10s in the future -> "next try in 10s".
    @Test func reconnectingWithFutureNextAttemptShowsCountdown() {
        let now = Date()
        let line = AppModel.reconcileHeaderLine(
            target: .nord,
            activity: .reconnecting(attempt: 1),
            nextAttemptAt: now.addingTimeInterval(10),
            now: now
        )
        #expect(line == "Reconnecting NordVPN… next try in 10s")
    }

    /// Paused with shortcutMissing -> "NordVPN reconnect paused: Shortcut missing".
    @Test func pausedShowsSuspensionLabel() {
        let now = Date()
        let line = AppModel.reconcileHeaderLine(
            target: .nord,
            activity: .paused(.shortcutMissing),
            nextAttemptAt: nil,
            now: now
        )
        #expect(line == "NordVPN reconnect paused: Shortcut missing")
    }

    /// Reconnecting with a nil nextAttemptAt -> falls back to "(attempt 2)".
    @Test func reconnectingWithNilNextAttemptShowsAttemptNumber() {
        let now = Date()
        let line = AppModel.reconcileHeaderLine(
            target: .nord,
            activity: .reconnecting(attempt: 2),
            nextAttemptAt: nil,
            now: now
        )
        #expect(line == "Reconnecting NordVPN… (attempt 2)")
    }

    /// Reconnecting with a nextAttemptAt already in the past also falls back
    /// to the attempt-number form rather than a negative/zero countdown.
    @Test func reconnectingWithPastNextAttemptShowsAttemptNumber() {
        let now = Date()
        let line = AppModel.reconcileHeaderLine(
            target: .tailscale,
            activity: .reconnecting(attempt: 3),
            nextAttemptAt: now.addingTimeInterval(-5),
            now: now
        )
        #expect(line == "Reconnecting Tailscale… (attempt 3)")
    }
}
