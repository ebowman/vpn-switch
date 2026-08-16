import Foundation
import SwiftUI
import Combine

/// Drives the menu bar UI: current parsed status, in-flight switching state,
/// and the last error/message line to show in the header.
@MainActor
final class AppModel: ObservableObject {
    @Published var status: VPNStatus = VPNStatus()
    @Published var isSwitching: Bool = false
    @Published var headerMessage: String? = nil
    @Published var scriptMissingPath: String? = nil

    /// Runs `vpn-ctl.sh status` once, off the main thread, and renders the
    /// result. Called on launch and after "Refresh" / after a toggle.
    func refresh() {
        Task.detached { [weak self] in
            let outcome = VPNCtl.run(["status"])
            await self?.apply(outcome: outcome, actionDescription: "status")
        }
    }

    /// Toggles NordVPN to the opposite of its current state.
    func toggleNord() {
        let target = status.nord.isOn ? "off" : "on"
        runToggle(args: ["nord", target])
    }

    /// Toggles Tailscale to the opposite of its current state.
    func toggleTailscale() {
        let target = status.ts.isOn ? "off" : "on"
        runToggle(args: ["tailscale", target])
    }

    private func runToggle(args: [String]) {
        guard !isSwitching else { return }
        isSwitching = true
        headerMessage = nil
        Task.detached { [weak self] in
            let outcome = VPNCtl.run(args)
            let toggleFailed = await self?.apply(outcome: outcome, actionDescription: args.joined(separator: " ")) ?? false
            let messageToPreserve = toggleFailed ? await self?.headerMessage ?? nil : nil
            // Re-run status regardless of outcome, per spec: "re-run status".
            // If the toggle itself failed, preserve its error message in the
            // header rather than letting the (successful) status re-run
            // silently clear it.
            let statusOutcome = VPNCtl.run(["status"])
            _ = await self?.apply(
                outcome: statusOutcome,
                actionDescription: "status",
                clearSwitching: true,
                preserveMessageOnSuccess: messageToPreserve
            )
        }
    }

    /// Applies a VPNCtlResult/error to published state. Always called on the
    /// main actor via the `await self?.apply` hop from a detached task.
    /// Returns whether this call represented a failure (non-zero exit,
    /// timeout, or missing script) -- used by runToggle to decide whether to
    /// preserve the error message through the follow-up status re-run.
    @discardableResult
    private func apply(
        outcome: Result<VPNCtlResult, VPNCtlError>,
        actionDescription: String,
        clearSwitching: Bool = false,
        preserveMessageOnSuccess: String? = nil
    ) -> Bool {
        var failed = false
        switch outcome {
        case .failure(.scriptNotFound(let path)):
            scriptMissingPath = path
            headerMessage = "vpn-ctl.sh not found at \(path)"
            failed = true
        case .success(let result):
            scriptMissingPath = nil
            // Parse whatever status line is present, even on failure --
            // vpn-ctl.sh prints the status line before a non-zero exit.
            let combined = result.stdout
            if let statusLine = Self.extractStatusLine(from: combined) {
                status = VPNStatus.parse(statusLine)
            }
            if result.timedOut {
                headerMessage = "\(actionDescription) timed out after 60s"
                failed = true
            } else if result.exitCode != 0 {
                headerMessage = result.lastMessageLine ?? "\(actionDescription) failed (exit \(result.exitCode))"
                failed = true
            } else if let preserved = preserveMessageOnSuccess {
                headerMessage = preserved
            } else {
                headerMessage = nil
            }
        }
        if clearSwitching {
            isSwitching = false
        }
        return failed
    }

    /// vpn-ctl.sh's status line is the one containing "nord=" and "ts=" --
    /// scan stdout for it (it's expected to be the only/last such line).
    private static func extractStatusLine(from output: String) -> String? {
        output.split(separator: "\n").last { line in
            line.contains("nord=") && line.contains("ts=")
        }.map(String.init)
    }
}
