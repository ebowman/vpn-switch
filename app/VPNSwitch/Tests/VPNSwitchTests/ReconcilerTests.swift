import Testing
import Foundation
@testable import VPNSwitch

@MainActor
struct ReconcilerTests {

    /// (a) No keep-connected intent for a down target -> no actions.
    @Test func noIntentProducesNoActionsWhenDown() {
        let r = Reconciler()
        let status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        #expect(r.actions(observing: status, now: Date()) == [])
    }

    /// (b) Intent + down -> the target is proposed on the first call.
    @Test func intentPlusDownProducesActionOnFirstCall() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        let status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        #expect(r.actions(observing: status, now: Date()) == [.nord])
    }

    /// (c) After a plain-backoff failure, the same status returns no actions
    /// until now has advanced past nextAttemptAt, then returns the target again.
    @Test func plainFailureSuspendsUntilBackoffElapses() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        let status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        let t0 = Date()
        #expect(r.actions(observing: status, now: t0) == [.nord])

        r.record(.failed(exitCode: 1), for: .nord, now: t0)
        #expect(r.actions(observing: status, now: t0) == [])
        #expect(r.actions(observing: status, now: t0.addingTimeInterval(5)) == [])

        let after = t0.addingTimeInterval(Reconciler.initialBackoff)
        #expect(r.actions(observing: status, now: after) == [.nord])
    }

    /// (d) Backoff sequence 10, 20, 40, 80, 160, 300, 300 measured via
    /// state(for:).nextAttemptAt deltas across repeated plain failures.
    @Test func backoffSequenceDoublesUpToMax() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        let t0 = Date()
        let expected: [TimeInterval] = [10, 20, 40, 80, 160, 300, 300]

        for delta in expected {
            r.record(.failed(exitCode: 1), for: .nord, now: t0)
            let next = r.state(for: .nord).nextAttemptAt
            #expect(next != nil)
            if let next {
                #expect(abs(next.timeIntervalSince(t0) - delta) < 0.001)
            }
        }
    }

    /// (e) record(.success) resets attempts to 0; the next call with the
    /// target still down returns it immediately (no backoff wait).
    @Test func successResetsAttemptsAndAllowsImmediateRetry() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        let status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        let t0 = Date()

        r.record(.failed(exitCode: 1), for: .nord, now: t0)
        #expect(r.state(for: .nord).attempts == 1)

        r.record(.success, for: .nord, now: t0)
        #expect(r.state(for: .nord).attempts == 0)
        #expect(r.state(for: .nord).nextAttemptAt == nil)
        #expect(r.actions(observing: status, now: t0) == [.nord])
    }

    /// (f) Each suspension exit code maps to the correct suspension and
    /// suspends further actions; setKeepConnected(true) again clears it.
    @Test func suspensionCodesMapAndClearOnReenable() {
        let r = Reconciler()
        let t0 = Date()

        // tailscale failed(2) -> tailscaleNeedsLogin
        r.setKeepConnected(.tailscale, true)
        r.record(.failed(exitCode: 2), for: .tailscale, now: t0)
        #expect(r.state(for: .tailscale).suspension == .tailscaleNeedsLogin)
        let tsDown = VPNStatus.parse("nord=up ts=Stopped web=ok streamy=fail")
        #expect(r.actions(observing: tsDown, now: t0) == [])
        r.setKeepConnected(.tailscale, true)
        #expect(r.state(for: .tailscale).suspension == nil)

        // failed(3) -> shortcutMissing
        r.setKeepConnected(.nord, true)
        r.record(.failed(exitCode: 3), for: .nord, now: t0)
        #expect(r.state(for: .nord).suspension == .shortcutMissing)
        r.setKeepConnected(.nord, true)
        #expect(r.state(for: .nord).suspension == nil)

        // failed(4) -> nordAppTunnel
        r.record(.failed(exitCode: 4), for: .nord, now: t0)
        #expect(r.state(for: .nord).suspension == .nordAppTunnel)
        r.setKeepConnected(.nord, true)
        #expect(r.state(for: .nord).suspension == nil)

        // scriptMissing -> scriptMissing
        r.record(.scriptMissing, for: .nord, now: t0)
        #expect(r.state(for: .nord).suspension == .scriptMissing)
        r.setKeepConnected(.nord, true)
        #expect(r.state(for: .nord).suspension == nil)
    }

    /// (g) Observed .app, .unknown, .unrecognized("x"), .needsLogin, .starting
    /// produce no actions even with keep-connected intent set.
    @Test func nonDownNonUpStatesProduceNoActions() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        r.setKeepConnected(.tailscale, true)
        let now = Date()

        var status = VPNStatus()
        status.nord = .app
        status.ts = .stopped
        #expect(r.actions(observing: status, now: now).contains(.nord) == false)

        status.nord = .unknown
        #expect(r.actions(observing: status, now: now).contains(.nord) == false)

        status.nord = .unrecognized("x")
        #expect(r.actions(observing: status, now: now).contains(.nord) == false)

        status.nord = .down
        status.ts = .needsLogin
        #expect(r.actions(observing: status, now: now).contains(.tailscale) == false)

        status.ts = .starting
        #expect(r.actions(observing: status, now: now).contains(.tailscale) == false)
    }

    /// (h) enabled = false produces no actions even with intent + down.
    @Test func disabledProducesNoActionsEvenWithIntent() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        r.enabled = false
        let status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        #expect(r.actions(observing: status, now: Date()) == [])
    }

    /// (i) resetBackoff makes a backed-off target eligible immediately
    /// without changing its attempts count.
    @Test func resetBackoffClearsWaitButKeepsAttempts() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        let status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        let t0 = Date()

        r.record(.failed(exitCode: 1), for: .nord, now: t0)
        #expect(r.actions(observing: status, now: t0) == [])
        #expect(r.state(for: .nord).attempts == 1)

        r.resetBackoff()
        #expect(r.state(for: .nord).attempts == 1)
        #expect(r.state(for: .nord).nextAttemptAt == nil)
        #expect(r.actions(observing: status, now: t0) == [.nord])
    }

    /// (j) Both targets down with both intents set returns both targets in
    /// stable order [nord, tailscale].
    @Test func bothTargetsDownReturnsStableOrder() {
        let r = Reconciler()
        r.setKeepConnected(.nord, true)
        r.setKeepConnected(.tailscale, true)
        let status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        #expect(r.actions(observing: status, now: Date()) == [.nord, .tailscale])
    }

    /// (k) encode/decode round trip: empty set.
    @Test func codecRoundTripsEmptySet() {
        let targets: Set<VPNTarget> = []
        #expect(Reconciler.decode(Reconciler.encode(targets)) == targets)
    }

    /// (l) encode/decode round trip: a single target.
    @Test func codecRoundTripsSingleTarget() {
        let targets: Set<VPNTarget> = [.nord]
        #expect(Reconciler.decode(Reconciler.encode(targets)) == targets)
    }

    /// (m) encode/decode round trip: both targets, and encode is sorted
    /// ascending ("nord" < "tailscale").
    @Test func codecRoundTripsBothTargets() {
        let targets: Set<VPNTarget> = [.nord, .tailscale]
        #expect(Reconciler.encode(targets) == ["nord", "tailscale"])
        #expect(Reconciler.decode(Reconciler.encode(targets)) == targets)
    }

    /// (n) decode ignores unknown names, keeping only recognized ones.
    @Test func decodeIgnoresUnknownNames() {
        #expect(Reconciler.decode(["nord", "bogus"]) == [.nord])
    }

    /// (o) decode maps a nil raw array (key absent from UserDefaults) to
    /// the empty set.
    @Test func decodeOfNilIsEmpty() {
        #expect(Reconciler.decode(nil) == [])
    }

    /// (p) A Reconciler seeded via `init(keepConnected:)` from
    /// `decode(["nord"])` -- simulating a relaunch that reads
    /// keepConnectedTargets=["nord"] from UserDefaults -- proposes `.nord`
    /// on the very first `actions(observing:now:)` call when Nord is
    /// observed down, without any prior `setKeepConnected` call.
    @Test func seededInitProducesActionOnFirstObservation() {
        let r = Reconciler(keepConnected: Reconciler.decode(["nord"]))
        let status = VPNStatus.parse("nord=down ts=Running web=ok streamy=ok")
        #expect(r.actions(observing: status, now: Date()) == [.nord])
    }
}
