import Foundation

/// One of the two VPN mechanisms this app toggles.
enum VPNTarget: CaseIterable, Hashable {
    case nord
    case tailscale

    /// vpn-ctl.sh's positional name for this target.
    var cliName: String {
        switch self {
        case .nord: return "nord"
        case .tailscale: return "tailscale"
        }
    }

    var displayName: String {
        switch self {
        case .nord: return "NordVPN"
        case .tailscale: return "Tailscale"
        }
    }
}

/// The state a target (or all targets) should be driven to.
enum DesiredState: Equatable {
    case on
    case off

    /// vpn-ctl.sh's positional name for this state.
    var cliName: String {
        switch self {
        case .on: return "on"
        case .off: return "off"
        }
    }
}

/// A single vpn-ctl.sh invocation the queue wants run, fully described so the
/// runner closure needs no branching of its own.
enum VPNCommand: Equatable {
    case set(VPNTarget, DesiredState)
    case setAll(DesiredState)
    case status

    var args: [String] {
        switch self {
        case .set(let target, let state): return [target.cliName, state.cliName]
        case .setAll(let state): return ["all", state.cliName]
        case .status: return ["status"]
        }
    }

    /// Kept as the existing magic numbers (see dns-config-5cn): 120s for the
    /// two-target `all` composite, 60s for everything else.
    var timeout: TimeInterval {
        switch self {
        case .setAll: return 120
        case .set, .status: return 60
        }
    }

    var label: String {
        switch self {
        case .set(let target, let state): return "\(target.displayName) \(state.cliName)"
        case .setAll(let state): return "All VPNs \(state.cliName)"
        case .status: return "Refreshing"
        }
    }
}

/// A pure, main-actor, serial intent queue for VPN toggle/refresh requests.
///
/// This class makes no `Process`/`VPNCtl` calls of its own -- it only decides
/// *what* should run and hands each decision to an injected `runner` closure,
/// awaiting it to completion before deciding what to run next. This keeps the
/// coalescing/idempotency rules below pure and independently testable (see
/// `SelfTest.runQueueCasesAndExit()`), without needing a live vpn-ctl.sh.
///
/// Coalescing rules (this is the idempotency guarantee the menu relies on):
///
/// 1. `enqueue(t, s)` records the target's *most recently requested* desired
///    state. Requesting the same state again is a no-op (still just one
///    pending entry); requesting the opposite state before it has been
///    drained *replaces* the pending entry -- last click before the queue
///    next drains wins. `enqueueAll(s)` is exactly `enqueue(.nord, s)` +
///    `enqueue(.tailscale, s)`. `enqueueRefresh()` sets a separate pending
///    refresh flag. `discardPending()` clears the pending map and the
///    pending refresh flag, but never touches a command already in flight.
///
/// 2. Every enqueue, if the queue isn't already draining and `autoDrain` is
///    true, kicks off a `drain()` in a new `Task`. `drain()` itself is also
///    public and idempotent to call directly (a no-op if already busy) --
///    this is what lets the headless self-test cases below drive it by hand
///    with `autoDrain: false`.
///
/// 3. `drain()` runs a loop, entirely on the main actor, that only ever
///    `await`s the `runner` closure (never itself, never concurrently):
///    each iteration snapshots and clears the pending map and refresh flag,
///    *prunes* entries already satisfied by the live status (an `.on`
///    request is dropped if that target already reports `.isOn`; an `.off`
///    request is dropped only for the states this app can positively
///    confirm are fully off -- NordVPN `.down` and Tailscale `.stopped`;
///    every other state, including unknown/starting/needsLogin/app-tunnel
///    states, is left alone and the command still runs so vpn-ctl.sh makes
///    the final call), and then turns what's left into the smallest set of
///    commands: both targets to the same state become one `.setAll`, mixed
///    or single-target requests become one `.set` per target (nord first),
///    and a bare pending refresh with nothing left to mutate becomes a
///    single `.status` (any mutation already re-runs status inside the
///    runner, so a refresh flag alongside a mutation is subsumed by it and
///    produces no extra `.status` call). If, after pruning, there is
///    nothing to run and no pending refresh, the loop stops. Otherwise it
///    runs the resulting command(s) in order, then loops again to pick up
///    anything enqueued while it was running (e.g. a click during an
///    `.setAll` -- see self-test case E).
@MainActor
final class ActionQueue: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var activeCommand: VPNCommand? = nil
    @Published private(set) var pendingIntents: [VPNTarget: DesiredState] = [:]
    @Published private(set) var refreshPending = false

    private let autoDrain: Bool
    private let statusProvider: @MainActor () -> VPNStatus
    private let runner: @MainActor (VPNCommand) async -> Void

    init(
        autoDrain: Bool = true,
        statusProvider: @escaping @MainActor () -> VPNStatus,
        runner: @escaping @MainActor (VPNCommand) async -> Void
    ) {
        self.autoDrain = autoDrain
        self.statusProvider = statusProvider
        self.runner = runner
    }

    /// Labels of currently pending intents, in `VPNTarget.allCases` order
    /// (e.g. ["NordVPN on", "Tailscale off"]), plus "Refresh" appended when a
    /// refresh is pending and there are no pending target intents.
    var queuedLabels: [String] {
        var labels: [String] = []
        for target in VPNTarget.allCases {
            if let state = pendingIntents[target] {
                labels.append("\(target.displayName) \(state.cliName)")
            }
        }
        if refreshPending && pendingIntents.isEmpty {
            labels.append("Refresh")
        }
        return labels
    }

    func enqueue(_ target: VPNTarget, _ state: DesiredState) {
        pendingIntents[target] = state
        kickOffDrainIfNeeded()
    }

    func enqueueAll(_ state: DesiredState) {
        pendingIntents[.nord] = state
        pendingIntents[.tailscale] = state
        kickOffDrainIfNeeded()
    }

    func enqueueRefresh() {
        refreshPending = true
        kickOffDrainIfNeeded()
    }

    func discardPending() {
        pendingIntents = [:]
        refreshPending = false
    }

    private func kickOffDrainIfNeeded() {
        guard autoDrain, !isBusy else { return }
        Task { await drain() }
    }

    /// Drains the pending queue, running commands one at a time until there
    /// is nothing left to do. A no-op if a drain is already in flight. See
    /// the type-level doc comment for the full algorithm and rationale.
    func drain() async {
        guard !isBusy else { return }
        isBusy = true

        while true {
            let snapshot = pendingIntents
            pendingIntents = [:]
            let refresh = refreshPending
            refreshPending = false

            let status = statusProvider()
            var pruned = snapshot
            for (target, state) in snapshot {
                switch (target, state) {
                case (_, .on):
                    if target == .nord, status.nord.isOn {
                        pruned.removeValue(forKey: target)
                    } else if target == .tailscale, status.ts.isOn {
                        pruned.removeValue(forKey: target)
                    }
                case (.nord, .off):
                    if status.nord == .down {
                        pruned.removeValue(forKey: target)
                    }
                case (.tailscale, .off):
                    if status.ts == .stopped {
                        pruned.removeValue(forKey: target)
                    }
                }
            }

            if pruned.isEmpty && !refresh {
                break
            }

            var commands: [VPNCommand] = []
            if let nordState = pruned[.nord], let tsState = pruned[.tailscale], nordState == tsState {
                commands = [.setAll(nordState)]
            } else {
                if let nordState = pruned[.nord] {
                    commands.append(.set(.nord, nordState))
                }
                if let tsState = pruned[.tailscale] {
                    commands.append(.set(.tailscale, tsState))
                }
            }
            if commands.isEmpty && refresh {
                commands = [.status]
            }

            for cmd in commands {
                activeCommand = cmd
                await runner(cmd)
                activeCommand = nil
            }
        }

        isBusy = false
    }
}
