import Testing
import Foundation
@testable import VPNSwitch

/// Covers the dns-config-du2 fix: VPNCtl.run must spawn children with an
/// empty (nothing-blocked) signal mask and default dispositions,
/// REGARDLESS of the calling thread's own mask.
///
/// BACKGROUND (dns-config-du2): AppModel calls VPNCtl.run from
/// Task.detached. Swift concurrency / libdispatch worker threads run with
/// nearly every signal blocked at the pthread level (observed mask:
/// 1,2,3,6,14,15,16,18-26,28-31 -- SIGTERM is 15). posix_spawn children
/// normally INHERIT the calling thread's signal mask, so vpn-ctl.sh (and
/// everything it spawns) started with SIGTERM blocked whenever `run` was
/// invoked from a detached Task, which is how AppModel always calls it.
/// lib/*.sh's _vpn_run_bounded watchdog does `kill -TERM $watchdog_pid;
/// wait $watchdog_pid`; with TERM blocked in the child, the wait sleeps for
/// the full watchdog timeout on every bounded call. Measured directly: 0.7s
/// from a terminal (SIGTERM unblocked) vs. 20.5s with SIGTERM blocked in
/// the parent shell.
///
/// This premise -- that a thread's blocked-signal mask is otherwise
/// inherited by posix_spawn children -- is the documented, stable behavior
/// of posix_spawn(2) (see NOTES: "the new process image inherits ...
/// signal mask" absent POSIX_SPAWN_SETSIGMASK) and is what the bead's
/// measurement (0.7s vs 20.5s) demonstrates empirically; it is not
/// re-asserted here as a second, separately-timed test because pthread
/// signal masks are per-OS-thread state that Swift's Task.detached gives
/// no supported, deterministic way to fix in place for a bare posix_spawn
/// probe (the mask of whichever worker thread happens to run the detached
/// closure varies run to run). The single assertion below is the
/// behavioral one that actually matters: with the dns-config-du2 fix in
/// place, VPNCtl.run's own posix_spawn call -- invoked from inside
/// Task.detached, exactly as AppModel does it -- always produces a child
/// with an empty blocked-signal mask.
struct VPNCtlSignalMaskTests {

    /// Stub script: prints the child's own blocked-signal set (as reported
    /// by python3's pthread_sigmask) as a sorted Python list literal, e.g.
    /// `[]` or `[15]`.
    private static let stubScriptContents = """
    #!/bin/bash
    /usr/bin/python3 -c 'import signal; print(sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, [])))'
    """

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPNCtlSignalMaskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the stub script into `dir`, marks it executable (0755), and
    /// returns its path.
    private func writeStubScript(in dir: URL) throws -> String {
        let scriptURL = dir.appendingPathComponent("stub-vpn-ctl.sh")
        try Self.stubScriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }

    @Test func runFromDetachedTaskSpawnsChildWithEmptySignalMask() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptPath = try writeStubScript(in: dir)

        let previous = UserDefaults.standard.string(forKey: VPNCtl.userDefaultsKey)
        UserDefaults.standard.set(scriptPath, forKey: VPNCtl.userDefaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: VPNCtl.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: VPNCtl.userDefaultsKey)
            }
        }

        // Exactly how AppModel invokes it (dns-config-du2): from inside
        // Task.detached, whose worker thread runs with nearly every signal
        // (including SIGTERM) blocked absent the fix.
        let outcome = await Task.detached {
            VPNCtl.run([], timeout: 10)
        }.value

        guard case let .success(result) = outcome else {
            Issue.record("expected VPNCtl.run to succeed, got \(outcome)")
            return
        }

        let printed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(printed == "[]", "child's blocked-signal set should be empty; got \(printed) (stderr: \(result.stderr))")
    }
}
