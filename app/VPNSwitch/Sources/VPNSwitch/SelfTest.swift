import Foundation

/// Headless verification path for environments where driving menu clicks via
/// System Events UI scripting is impractical. Exercises the same
/// VPNCtl.run/VPNStatus.parse code paths the UI uses, prints results, and
/// exits -- does not present the MenuBarExtra UI.
enum SelfTest {
    static func runAndExit() -> Never {
        print("VPNSwitch --selftest")

        print("resolvedPath: \(VPNCtl.resolvedPath() ?? "nil (not found)")")
        print("loginItem: eligible=\(LoginItem.isEligible) registered=\(LoginItem.isRegistered)")

        print("\n--- status ---")
        let statusOutcome = VPNCtl.run(["status"])
        report(statusOutcome, label: "status")

        if case .success(let result) = statusOutcome {
            let line = result.stdout.split(separator: "\n").last { $0.contains("nord=") } ?? ""
            let parsed = VPNStatus.parse(String(line))
            print("parsed: nord=\(parsed.nord) ts=\(parsed.ts) web=\(parsed.web ?? "?") streamy=\(parsed.streamy ?? "?")")
            print("icon: \(MenuIcon.symbolName(for: parsed))")
        }

        print("\n--- nord on (expect exit 3, shortcut missing) ---")
        report(VPNCtl.run(["nord", "on"]), label: "nord on")

        print("\n--- final status ---")
        report(VPNCtl.run(["status"]), label: "status")

        print("\n--- canned parser cases (dns-config-qsk.6) ---")
        cannedCase("nord=app ts=Running web=ok streamy=1.2.3.4")
        cannedCase("nord=app+ikev2 ts=Stopped web=fail streamy=fail")
        cannedCase("nord=up ts=NeedsLogin web=ok streamy=1.2.3.4")
        cannedCase("nord=up ts=Starting web=fail streamy=fail")
        cannedCase("nord=up ts=Running web=fail streamy=1.2.3.4")
        cannedCase("nord=unknown ts=unrecognizedtoken web=fail streamy=fail")

        exit(0)
    }

    /// Feeds a canned status line through the same VPNStatus.parse /
    /// MenuIcon.symbolName / label rendering the live UI uses, and prints
    /// the resulting strings -- used to exercise the app-tunnel error state
    /// and Tailscale NeedsLogin rendering without needing to actually
    /// disconnect NordVPN's IKEv2 profile or drive a real login flow.
    private static func cannedCase(_ line: String) {
        let parsed = VPNStatus.parse(line)
        let isAppTunnelError = MenuIcon.isErrorState(parsed)
        let headerNord = isAppTunnelError ? "⚠︎ NordVPN: \(parsed.nord.label)" : "NordVPN: \(parsed.nord.label)"
        let headerTs = "Tailscale: \(parsed.ts.label)"
        let webWarning = (parsed.web == "fail" && parsed.nord.isOn && parsed.ts.isOn)
            ? "⚠ Internet check failed"
            : nil
        let needsLoginMenuItem = (parsed.ts == .needsLogin) ? "Open Tailscale… (menu item present)" : nil

        print("input:  \(line)")
        print("  \(headerNord)")
        print("  \(headerTs)")
        if isAppTunnelError {
            print("  NordVPN app tunnel detected — 100.64.0.2 collides with Tailscale; disconnect the NordVPN app and use the IKEv2 profile")
        }
        if let webWarning {
            print("  \(webWarning)")
        }
        if let needsLoginMenuItem {
            print("  \(needsLoginMenuItem)")
        }
        print("  icon: \(MenuIcon.symbolName(for: parsed))")
    }

    private static func report(_ outcome: Result<VPNCtlResult, VPNCtlError>, label: String) {
        switch outcome {
        case .failure(.scriptNotFound(let path)):
            print("\(label): SCRIPT NOT FOUND at \(path)")
        case .success(let result):
            print("\(label): exit=\(result.exitCode) timedOut=\(result.timedOut)")
            if !result.stdout.isEmpty { print("  stdout: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))") }
            if !result.stderr.isEmpty { print("  stderr: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
    }

    /// Headless canned cases for ActionQueue (dns-config-cr9.2): exercises
    /// the coalescing/idempotency rules documented on ActionQueue directly,
    /// with a fake status provider and a fake async runner -- no Process
    /// calls, no live vpn-ctl.sh, safe to run anywhere.
    @MainActor
    private final class QueueTestHarness {
        var status = VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail")
        var log: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var failed = false
        /// Set by a case to enqueue something else from inside the runner
        /// (simulates a click arriving mid-command), keyed by the args of
        /// the command that should trigger it.
        var midRunHook: ((VPNCommand, ActionQueue) -> Void)?

        var queue: ActionQueue!

        init() {
            queue = ActionQueue(
                autoDrain: false,
                statusProvider: { [unowned self] in self.status },
                runner: { [unowned self] cmd in
                    self.inFlight += 1
                    self.maxInFlight = max(self.maxInFlight, self.inFlight)
                    // Genuinely suspend here (dns-config-l6s): without a real
                    // await, this closure never yields the main actor, so a
                    // second concurrent drain() could never actually overlap
                    // with this one and the maxInFlight assertions below
                    // could never fail regardless of ActionQueue correctness.
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(5))
                    self.midRunHook?(cmd, self.queue)
                    self.log.append(cmd.args.joined(separator: " "))
                    self.inFlight -= 1
                }
            )
        }

        func reset(status newStatus: VPNStatus? = nil) {
            log = []
            midRunHook = nil
            if let newStatus { status = newStatus }
        }

        func check(_ name: String, expected: [String]) {
            if log != expected {
                failed = true
                print("FAIL \(name): expected \(expected) got \(log)")
            } else if queue.isBusy {
                failed = true
                print("FAIL \(name): expected isBusy == false after drain, got true")
            } else if queue.activeCommand != nil {
                failed = true
                print("FAIL \(name): expected activeCommand == nil after drain, got \(String(describing: queue.activeCommand))")
            } else {
                print("PASS \(name)")
            }
        }
    }

    static func runQueueCasesAndExit() -> Never {
        Task { @MainActor in
            let h = QueueTestHarness()

            // A: dedupe -- same state enqueued twice collapses to one command.
            h.queue.enqueue(.nord, .on)
            h.queue.enqueue(.nord, .on)
            await h.queue.drain()
            h.check("A dedupe", expected: ["nord on"])

            // B: last-wins -- opposite state before drain replaces the pending
            // entry. With nord=up the .on would have been pruned anyway, but
            // it is replaced before drain runs; the .off is not satisfied
            // (nord is up, not down), so it runs.
            h.reset(status: VPNStatus.parse("nord=up ts=Stopped web=ok streamy=fail"))
            h.queue.enqueue(.nord, .on)
            h.queue.enqueue(.nord, .off)
            await h.queue.drain()
            h.check("B last-wins", expected: ["nord off"])

            // C: merge -- same state on both targets becomes one `all` command.
            h.reset(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
            h.queue.enqueue(.nord, .on)
            h.queue.enqueue(.tailscale, .on)
            await h.queue.drain()
            h.check("C merge (on)", expected: ["all on"])

            h.reset(status: VPNStatus.parse("nord=up ts=Running web=ok streamy=fail"))
            h.queue.enqueueAll(.off)
            await h.queue.drain()
            h.check("C merge (off)", expected: ["all off"])

            // D: split -- mixed states become two `.set` commands, nord first.
            h.reset(status: VPNStatus.parse("nord=down ts=Running web=ok streamy=fail"))
            h.queue.enqueue(.nord, .on)
            h.queue.enqueue(.tailscale, .off)
            await h.queue.drain()
            h.check("D split", expected: ["nord on", "tailscale off"])

            // E: mid-run click -- enqueuing while "all on" is executing is
            // picked up by the next loop iteration, never concurrently. The
            // fake runner also mutates status mid-command here, mimicking
            // the real runner re-running status after each mutation --
            // that's what leaves the queued nord off unpruned on the next
            // loop iteration (status becomes nord=up, so nord=off is not
            // yet satisfied and still needs to run).
            h.reset(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
            h.queue.enqueueAll(.on)
            h.midRunHook = { cmd, queue in
                if cmd == .setAll(.on) {
                    h.status = VPNStatus.parse("nord=up ts=Running web=ok streamy=fail")
                    queue.enqueue(.nord, .off)
                }
            }
            await h.queue.drain()
            h.check("E mid-run click", expected: ["all on", "nord off"])
            if h.maxInFlight > 1 {
                h.failed = true
                print("FAIL E mid-run click: max concurrency expected 1 got \(h.maxInFlight)")
            }

            // E2: mid-run click, but the requested state is already
            // satisfied by the time drain re-checks status -- the mid-run
            // duplicate is pruned rather than re-run. Documents the
            // idempotency guarantee end to end.
            h.reset(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
            h.queue.enqueueAll(.on)
            h.midRunHook = { cmd, queue in
                if cmd == .setAll(.on) {
                    h.status = VPNStatus.parse("nord=up ts=Running web=ok streamy=fail")
                    queue.enqueue(.nord, .on)
                }
            }
            await h.queue.drain()
            h.check("E2 mid-run click already satisfied", expected: ["all on"])
            if h.maxInFlight > 1 {
                h.failed = true
                print("FAIL E2 mid-run click already satisfied: max concurrency expected 1 got \(h.maxInFlight)")
            }

            // F: prune -- requests already satisfied by live status are dropped.
            h.reset(status: VPNStatus.parse("nord=up ts=Stopped web=ok streamy=fail"))
            h.queue.enqueue(.nord, .on)
            await h.queue.drain()
            h.check("F prune (satisfied on)", expected: [])

            h.reset(status: VPNStatus.parse("nord=down ts=Starting web=ok streamy=fail"))
            h.queue.enqueue(.tailscale, .off)
            await h.queue.drain()
            h.check("F prune (not pruned, unknown state)", expected: ["tailscale off"])

            // G: refresh -- bare refresh becomes `.status`; refresh alongside
            // a mutation is subsumed by it.
            h.reset(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
            h.queue.enqueueRefresh()
            await h.queue.drain()
            h.check("G refresh alone", expected: ["status"])

            h.reset(status: VPNStatus.parse("nord=down ts=Stopped web=ok streamy=fail"))
            h.queue.enqueueRefresh()
            h.queue.enqueue(.nord, .on)
            await h.queue.drain()
            h.check("G refresh subsumed", expected: ["nord on"])

            // H: discard -- pending intents cleared before drain never run.
            h.reset()
            h.queue.enqueue(.nord, .on)
            h.queue.discardPending()
            await h.queue.drain()
            h.check("H discard", expected: [])

            // I: concurrent drain -- calling drain() a second time while the
            // first call is already suspended inside the runner (i.e.
            // genuinely in flight, not just scheduled) must not let the
            // second call re-enter the runner concurrently; the second
            // call's `guard !isBusy` makes it an immediate no-op instead.
            //
            // This needs a *second* pending intent (enqueued only after the
            // first drain's runner call is confirmed suspended) for the
            // second drain() call to find and act on -- otherwise the
            // second call's `pendingIntents` snapshot is already empty
            // (drained synchronously by the first call before its first
            // await) and it returns having never reached the runner at
            // all, which would pass trivially even with the isBusy guard
            // removed and prove nothing.
            h.reset(status: VPNStatus.parse("nord=down ts=Running web=ok streamy=fail"))
            h.queue.enqueue(.nord, .on)
            let drainA = Task { await h.queue.drain() }
            while h.inFlight == 0 {
                await Task.yield()
            }
            h.queue.enqueue(.tailscale, .off)
            let drainB = Task { await h.queue.drain() }
            _ = await (drainA.value, drainB.value)
            h.check("I concurrent drain", expected: ["nord on", "tailscale off"])
            if h.maxInFlight > 1 {
                h.failed = true
                print("FAIL I concurrent drain: max concurrency expected 1 got \(h.maxInFlight)")
            }

            // J: mid-run enqueue while suspended -- enqueuing a second
            // intent while the first command is still suspended inside the
            // runner must not run concurrently with it; it is picked up by
            // drain()'s next loop iteration only after the first command
            // returns, preserving order (nord on, then tailscale off).
            h.reset(status: VPNStatus.parse("nord=down ts=Running web=ok streamy=fail"))
            h.queue.enqueue(.nord, .on)
            let drainTask = Task { await h.queue.drain() }
            try? await Task.sleep(for: .milliseconds(1))
            h.queue.enqueue(.tailscale, .off)
            await drainTask.value
            h.check("J mid-run enqueue while suspended", expected: ["nord on", "tailscale off"])
            if h.maxInFlight > 1 {
                h.failed = true
                print("FAIL J mid-run enqueue while suspended: max concurrency expected 1 got \(h.maxInFlight)")
            }

            // queuedLabels eyeball check (before draining).
            h.reset()
            h.queue.enqueue(.nord, .on)
            h.queue.enqueue(.tailscale, .off)
            print("queuedLabels: \(h.queue.queuedLabels)")
            await h.queue.drain()

            exit(h.failed ? 1 : 0)
        }
        dispatchMain()
    }
}
