import Testing
@testable import VPNSwitch

/// Covers VPNStatus.parse's tolerant tokenizing (see VPNStatus.swift) and the
/// isOn semantics each state enum exposes to the menu/ActionQueue pruning
/// logic (see ActionQueue.swift's status-based pruning).
struct VPNStatusTests {

    @Test func parsesNordUpAndTailscaleRunningAsOn() {
        let status = VPNStatus.parse("nord=up ts=Running web=ok streamy=1.2.3.4")
        #expect(status.nord == .up)
        #expect(status.ts == .running)
        #expect(status.nord.isOn == true)
        #expect(status.ts.isOn == true)
        #expect(status.web == "ok")
        #expect(status.streamy == "1.2.3.4")
    }

    @Test func parsesNordDownAndTailscaleStoppedAsOff() {
        let status = VPNStatus.parse("nord=down ts=Stopped web=fail streamy=fail")
        #expect(status.nord == .down)
        #expect(status.ts == .stopped)
        #expect(status.nord.isOn == false)
        #expect(status.ts.isOn == false)
    }

    @Test func parsesNordAppAndAppPlusIkev2AsNotOn() {
        let appStatus = VPNStatus.parse("nord=app ts=Stopped web=ok streamy=fail")
        #expect(appStatus.nord == .app)
        #expect(appStatus.nord.isOn == false)

        let appIkev2Status = VPNStatus.parse("nord=app+ikev2 ts=Stopped web=ok streamy=fail")
        #expect(appIkev2Status.nord == .appPlusIkev2)
        #expect(appIkev2Status.nord.isOn == false)
    }

    @Test func parsesTailscaleNeedsLoginAndStartingAsNotOn() {
        let needsLogin = VPNStatus.parse("nord=down ts=NeedsLogin web=fail streamy=fail")
        #expect(needsLogin.ts == .needsLogin)
        #expect(needsLogin.ts.isOn == false)

        let starting = VPNStatus.parse("nord=down ts=Starting web=fail streamy=fail")
        #expect(starting.ts == .starting)
        #expect(starting.ts.isOn == false)
    }

    @Test func parsesUnknownNordAsNotOn() {
        let status = VPNStatus.parse("nord=unknown ts=Stopped web=fail streamy=fail")
        #expect(status.nord == .unknown)
        #expect(status.nord.isOn == false)
    }

    @Test func ignoresUnrecognizedTokenWithoutBreakingTheRest() {
        let status = VPNStatus.parse("nord=up bogus=xyz ts=Running web=ok streamy=1.2.3.4")
        #expect(status.nord == .up)
        #expect(status.ts == .running)
        #expect(status.web == "ok")
        #expect(status.streamy == "1.2.3.4")
    }
}
