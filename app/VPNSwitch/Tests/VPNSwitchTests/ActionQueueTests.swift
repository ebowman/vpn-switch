import Testing
@testable import VPNSwitch

/// Mirrors a subset of the headless canned cases in SelfTest.runQueueCasesAndExit()
/// (cases A, C, F) as swift-testing assertions, using a fake @MainActor runner
/// that logs `cmd.args.joined(separator: " ")` instead of shelling out.
@MainActor
final class ActionQueueTestHarness {
    var status: VPNStatus
    var log: [String] = []

    var queue: ActionQueue!

    init(status: VPNStatus) {
        self.status = status
        queue = ActionQueue(
            autoDrain: false,
            statusProvider: { [unowned self] in self.status },
            runner: { [unowned self] cmd in
                self.log.append(cmd.args.joined(separator: " "))
            }
        )
    }
}

@MainActor
struct ActionQueueTests {

    /// Case A: dedupe -- enqueuing the same target/state twice before a
    /// drain collapses to a single command.
    @Test func dedupesRepeatedSameStateEnqueue() async {
        let h = ActionQueueTestHarness(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
        h.queue.enqueue(.nord, .on)
        h.queue.enqueue(.nord, .on)
        await h.queue.drain()
        #expect(h.log == ["nord on"])
    }

    /// Case C: merge -- requesting the same state for both targets becomes
    /// one `all on` command rather than two separate `.set` commands.
    @Test func mergesSameStateBothTargetsIntoAllCommand() async {
        let h = ActionQueueTestHarness(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
        h.queue.enqueue(.nord, .on)
        h.queue.enqueue(.tailscale, .on)
        await h.queue.drain()
        #expect(h.log == ["all on"])
        #expect(h.log != ["nord on", "tailscale on"])
    }

    /// Case F: prune -- a request already satisfied by the live status
    /// (nord already up) is dropped and nothing runs.
    @Test func prunesRequestAlreadySatisfiedByStatus() async {
        let h = ActionQueueTestHarness(status: VPNStatus.parse("nord=up ts=Stopped web=ok streamy=fail"))
        h.queue.enqueue(.nord, .on)
        await h.queue.drain()
        #expect(h.log == [])
    }

    /// dns-config-l6s: queuedLabels must derive each target/state label from
    /// VPNCommand.label so the two cannot drift -- asserted directly against
    /// VPNCommand rather than duplicating its formatting logic here.
    @Test func queuedLabelsMatchVPNCommandLabel() async {
        let h = ActionQueueTestHarness(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
        h.queue.enqueue(.nord, .on)
        h.queue.enqueue(.tailscale, .off)
        #expect(h.queue.queuedLabels == [
            VPNCommand.set(.nord, .on).label,
            VPNCommand.set(.tailscale, .off).label
        ])
    }
}
