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
}
