import Foundation

/// Headless verification path for environments where driving menu clicks via
/// System Events UI scripting is impractical. Exercises the same
/// VPNCtl.run/VPNStatus.parse code paths the UI uses, prints results, and
/// exits -- does not present the MenuBarExtra UI.
enum SelfTest {
    static func runAndExit() -> Never {
        print("VPNSwitch --selftest")

        print("resolvedPath: \(VPNCtl.resolvedPath() ?? "nil (not found)")")

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

        exit(0)
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
}
