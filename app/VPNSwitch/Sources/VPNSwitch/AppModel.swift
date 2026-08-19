import Foundation
import SwiftUI
import AppKit
import Combine
import UserNotifications

/// Drives the menu bar UI: current parsed status, in-flight switching state,
/// and the last error/message line to show in the header. Also owns the
/// polling timer that keeps the icon/header truthful when state changes
/// outside this app (Nord auto-reconnecting, Tailscale toggled from its own
/// menu, etc.) -- see dns-config-qsk.6.
@MainActor
final class AppModel: ObservableObject {
    @Published var status: VPNStatus = VPNStatus()
    @Published var isSwitching: Bool = false
    @Published var headerMessage: String? = nil
    @Published var scriptMissingPath: String? = nil
    /// "Launch at login" toggle state, mirrored from SMAppService.mainApp
    /// (dns-config-qsk.7). Re-read on menu open via refreshLoginItemStatus()
    /// so a change made in System Settings > Login Items is reflected here
    /// too, not just changes made from this app's own toggle.
    @Published var loginItemRegistered: Bool = LoginItem.isRegistered
    /// Whether the login item toggle should be enabled -- false (with a
    /// hint) when the running app isn't under /Applications, since
    /// SMAppService needs a stable path.
    @Published var loginItemEligible: Bool = LoginItem.isEligible
    /// User preference: post a local notification when a poll detects a
    /// state change that this app did not cause (e.g. Tailscale toggled from
    /// its own menu, or Nord dropping). Persisted in UserDefaults; default on.
    /// Changes the app itself makes are excluded via `selfInitiatedChangeInFlight`.
    @Published var notifyOnExternalChanges: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnExternalChanges, forKey: Self.notifyKey)
        }
    }

    static let pollIntervalKey = "pollIntervalSeconds"
    static let notifyKey = "notifyOnExternalChanges"
    static let defaultPollInterval: TimeInterval = 5
    static let minPollInterval: TimeInterval = 2
    static let maxPollInterval: TimeInterval = 60

    /// Effective poll interval, clamped to [min, max]. Reads UserDefaults
    /// fresh each time a timer is (re)armed so a change takes effect on the
    /// next tick without requiring a relaunch.
    static func pollInterval() -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: pollIntervalKey)
        if stored == 0 { return defaultPollInterval }
        return min(max(stored, minPollInterval), maxPollInterval)
    }

    /// Guards against overlapping poll runs: if a status call is still in
    /// flight when the timer fires again, that tick is skipped entirely
    /// (coalesced), never queued -- so a slow vpn-ctl.sh cannot pile up
    /// concurrent Process invocations.
    private var pollInFlight = false
    private var pollTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Set true for the duration of a self-initiated refresh/toggle so the
    /// notification logic below can tell "I changed this" apart from "it
    /// changed on its own" -- notifications are only posted for the latter.
    private var selfInitiatedChangeInFlight = false
    /// True while a background `lan-dns sync` run (dns-config-qsk.12) is
    /// in flight. Used to coalesce: a second observed transition while one
    /// sync is still running is simply skipped rather than queued -- if
    /// Tailscale has moved again, the next poll's own from/to comparison
    /// will observe that further transition and trigger its own sync.
    private var lanDNSSyncInFlight = false
    /// Count of `lan-dns sync` runs triggered by this model, for
    /// verification/logging (dns-config-qsk.12 DONE criteria: "verify with
    /// a counter/log").
    private(set) var lanDNSSyncCount = 0

    init() {
        notifyOnExternalChanges = (UserDefaults.standard.object(forKey: Self.notifyKey) as? Bool) ?? true
    }

    /// Starts the periodic poll loop and the wake observer. Call once from
    /// the app's launch path (not from a SwiftUI onAppear, which can fire
    /// more than once for a MenuBarExtra).
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollTick()
                let interval = Self.pollInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.pollTick(force: true)
                    // Force a resync regardless of whether the wake-time
                    // poll observed a ts transition: Tailscale may have
                    // flipped and flipped back while asleep (no net change
                    // for the from/to comparison to catch), or dnsmasq may
                    // have been restarted independently -- either way the
                    // hosts file should be re-rendered against current
                    // reality after a sleep/wake cycle.
                    self?.forceLANDNSSync(reason: "wake")
                }
            }
        }
    }

    /// Stops the timer loop and removes the wake observer -- called on
    /// quit so nothing outlives the app (no leaked Task, no dangling
    /// NSWorkspace observer).
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// One poll attempt. Skipped (coalesced) if a poll or a toggle is
    /// already in flight, unless `force` is set (used by the wake handler,
    /// which still respects an in-flight toggle -- polling stays paused
    /// while switching regardless of force).
    private func pollTick(force: Bool = false) async {
        guard !isSwitching else { return }
        guard force || !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }
        let outcome = await Task.detached { VPNCtl.run(["status"]) }.value
        apply(outcome: outcome, actionDescription: "status")
    }

    /// Runs `vpn-ctl.sh status` once, off the main thread, and renders the
    /// result. Called on launch and from "Refresh".
    func refresh() {
        selfInitiatedChangeInFlight = true
        Task.detached { [weak self] in
            let outcome = VPNCtl.run(["status"])
            await self?.apply(outcome: outcome, actionDescription: "status")
            await MainActor.run { self?.selfInitiatedChangeInFlight = false }
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

    /// Turns both NordVPN and Tailscale off via `vpn-ctl.sh all off`. Given
    /// a longer timeout than the default toggle: `all off` runs two
    /// sequential waits of up to VPN_CTL_WAIT_TIMEOUT (45s) each plus web
    /// checks, so it can exceed the default 60s.
    func turnAllOff() {
        runToggle(args: ["all", "off"], timeout: 120)
    }

    /// Opens the Tailscale app (used by the "Open Tailscale…" menu item
    /// shown when ts=NeedsLogin). Does not attempt to drive any login flow
    /// itself -- that's left entirely to the human via the Tailscale app.
    func openTailscaleApp() {
        let url = URL(fileURLWithPath: "/Applications/Tailscale.app")
        NSWorkspace.shared.open(url)
    }

    /// Re-reads SMAppService.mainApp's real status -- called on menu open so
    /// the toggle reflects reality even if the user revoked/changed it from
    /// System Settings > Login Items directly.
    func refreshLoginItemStatus() {
        loginItemEligible = LoginItem.isEligible
        loginItemRegistered = LoginItem.isRegistered
    }

    /// Toggles the "Launch at login" state via SMAppService. No-op if not
    /// eligible (app isn't running from /Applications).
    func toggleLoginItem() {
        guard loginItemEligible else { return }
        if loginItemRegistered {
            if let error = LoginItem.unregister() {
                headerMessage = error
            }
        } else {
            if let error = LoginItem.register() {
                headerMessage = error
            }
        }
        loginItemRegistered = LoginItem.isRegistered
    }

    private func runToggle(args: [String], timeout: TimeInterval = 60) {
        guard !isSwitching else { return }
        isSwitching = true
        selfInitiatedChangeInFlight = true
        headerMessage = nil
        Task.detached { [weak self] in
            let outcome = VPNCtl.run(args, timeout: timeout)
            let toggleFailed = await self?.apply(
                outcome: outcome,
                actionDescription: args.joined(separator: " "),
                timeout: timeout
            ) ?? false
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
            await MainActor.run { self?.selfInitiatedChangeInFlight = false }
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
        preserveMessageOnSuccess: String? = nil,
        timeout: TimeInterval = 60
    ) -> Bool {
        var failed = false
        let previousStatus = status
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
            } else if result.timedOut {
                // A genuine timeout with no parseable status line: render
                // Unknown rather than holding onto stale state (per DONE
                // criteria -- "a stalled status shows 'unknown'").
                status = VPNStatus()
            }
            if result.timedOut {
                headerMessage = "\(actionDescription) timed out after \(Int(timeout))s"
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
        notifyIfExternalChange(from: previousStatus, to: status)
        // Independent of notifyOnExternalChanges -- the resolver must stay
        // truthful even if the user has notifications turned off.
        syncLANDNSIfNeeded(from: previousStatus, to: status, reason: "poll")
        return failed
    }

    /// Posts a local notification when the parsed status changed and this
    /// app did not itself cause the change (no toggle/refresh currently in
    /// flight from this app). Cheap: only string comparisons plus, at most,
    /// one notification request. Silently does nothing if notifications are
    /// disabled in the menu or if authorization was denied.
    private func notifyIfExternalChange(from previous: VPNStatus, to current: VPNStatus) {
        guard notifyOnExternalChanges else { return }
        guard !selfInitiatedChangeInFlight else { return }
        guard previous != current else { return }
        // First poll after launch: previous is the all-default placeholder
        // and there is nothing meaningful to compare against yet.
        guard previous != VPNStatus() else { return }

        var lines: [String] = []
        if previous.ts != current.ts {
            lines.append("Tailscale: \(previous.ts.label) → \(current.ts.label) (changed outside VPN Switch)")
        }
        if previous.nord != current.nord {
            lines.append("NordVPN: \(previous.nord.label) → \(current.nord.label) (changed outside VPN Switch)")
        }
        guard !lines.isEmpty else { return }
        postNotification(body: lines.joined(separator: "\n"))
    }

    /// Re-syncs dnsmasq's hosts file (`vpn-ctl.sh lan-dns sync`) when a poll
    /// observes that Tailscale's state changed and this app did not itself
    /// cause the change (dns-config-qsk.12). vpn-ctl.sh's own `tailscale
    /// on|off` already calls lan_dns_sync internally, so a self-initiated
    /// toggle must not trigger a second, redundant run here -- guarded via
    /// `selfInitiatedChangeInFlight`.
    private func syncLANDNSIfNeeded(from previous: VPNStatus, to current: VPNStatus, reason: String) {
        guard !selfInitiatedChangeInFlight else { return }
        // First poll after launch: previous is the all-default placeholder
        // and there is nothing meaningful to compare against yet.
        guard previous != VPNStatus() else { return }
        guard previous.ts != current.ts else { return }
        guard !lanDNSSyncInFlight else { return }
        runLANDNSSync(logDetail: "ts \(previous.ts.label) -> \(current.ts.label)", reason: reason)
    }

    /// Forces one `lan-dns sync` run regardless of whether an observed
    /// transition occurred -- used after a wake, since Tailscale may have
    /// flipped and flipped back while asleep (no net change for the
    /// from/to comparison in `syncLANDNSIfNeeded` to catch) or dnsmasq may
    /// have been restarted independently. Shares the same in-flight/
    /// self-initiated guards.
    private func forceLANDNSSync(reason: String) {
        guard !selfInitiatedChangeInFlight else { return }
        guard !lanDNSSyncInFlight else { return }
        runLANDNSSync(logDetail: "forced", reason: reason)
    }

    /// Shared runner for both sync paths above: sets the in-flight guard,
    /// bumps the counter, logs, and runs `vpn-ctl.sh lan-dns sync` off the
    /// main thread. This is background housekeeping -- unlike toggle/status
    /// failures, a failed sync here does not set `headerMessage` or post a
    /// notification; it is only logged via NSLog. Must not block the UI or
    /// the poll loop.
    private func runLANDNSSync(logDetail: String, reason: String) {
        lanDNSSyncInFlight = true
        lanDNSSyncCount += 1
        NSLog("VPNSwitch: lan-dns sync (%@): %@", reason, logDetail)
        Task.detached { [weak self] in
            let outcome = VPNCtl.run(["lan-dns", "sync"], timeout: 30)
            switch outcome {
            case .failure(.scriptNotFound(let path)):
                NSLog("VPNSwitch: lan-dns sync (%@) failed: script not found at %@", reason, path)
            case .success(let result):
                if result.timedOut {
                    NSLog("VPNSwitch: lan-dns sync (%@) timed out after 30s", reason)
                } else if result.exitCode != 0 {
                    NSLog(
                        "VPNSwitch: lan-dns sync (%@) failed (exit %d): %@",
                        reason,
                        result.exitCode,
                        result.lastMessageLine ?? ""
                    )
                }
            }
            await MainActor.run { self?.lanDNSSyncInFlight = false }
        }
    }

    private func postNotification(body: String) {
        Task.detached {
            let granted = await Self.requestNotificationAuthorizationIfNeeded()
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "VPN Switch"
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Requests notification authorization lazily, once, on first use.
    /// If the user has already denied it (or it was denied under
    /// automation/TCC with no prompt possible), subsequent calls just
    /// report "not granted" without prompting again.
    private static func requestNotificationAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// vpn-ctl.sh's status line is the one containing "nord=" and "ts=" --
    /// scan stdout for it (it's expected to be the only/last such line).
    private static func extractStatusLine(from output: String) -> String? {
        output.split(separator: "\n").last { line in
            line.contains("nord=") && line.contains("ts=")
        }.map(String.init)
    }
}
