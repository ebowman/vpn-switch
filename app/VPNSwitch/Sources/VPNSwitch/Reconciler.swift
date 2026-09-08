import Foundation

/// The outcome of a single vpn-ctl.sh reconcile attempt, as reported back to
/// the `Reconciler` by whatever actually ran the command.
enum ReconcileOutcome {
    case success
    case failed(exitCode: Int32)
    case timedOut
    case scriptMissing
}

/// A reason enforcement is paused for a target until the user intervenes.
/// While suspended, `Reconciler.actions(observing:now:)` will not propose
/// retrying that target even if it is down and kept-connected.
enum ReconcileSuspension: Equatable {
    case tailscaleNeedsLogin
    case shortcutMissing
    case nordAppTunnel
    case scriptMissing

    /// Header text shown to the user explaining why enforcement is paused.
    var label: String {
        switch self {
        case .tailscaleNeedsLogin: return "Tailscale needs login"
        case .shortcutMissing: return "Shortcut missing"
        case .nordAppTunnel: return "NordVPN app tunnel detected"
        case .scriptMissing: return "vpn-ctl.sh missing"
        }
    }
}

/// A pure, `@MainActor`, I/O-free policy engine deciding which VPN targets
/// should be re-enabled given the user's "keep connected" intent, the most
/// recently observed status, and backoff/suspension state from prior
/// attempts.
///
/// This type makes no `Process`/`VPNCtl`/`UserDefaults` calls of its own --
/// it only decides *what* should run (`actions(observing:now:)`) and records
/// the outcome of what did run (`record(_:for:now:)`). This keeps the
/// backoff and suspension rules pure and independently testable without a
/// live vpn-ctl.sh.
@MainActor
final class Reconciler {
    /// Backoff schedule: `min(initialBackoff * 2^(attempts-1), maxBackoff)`,
    /// i.e. 10, 20, 40, 80, 160, 300, 300, ... seconds.
    static let initialBackoff: TimeInterval = 10
    static let maxBackoff: TimeInterval = 300

    /// Per-target attempt/backoff/suspension bookkeeping.
    struct AttemptState {
        var attempts: Int = 0
        var nextAttemptAt: Date?
        var suspension: ReconcileSuspension?
    }

    /// The targets the user has asked to be kept connected.
    private(set) var keepConnected: Set<VPNTarget> = []

    /// Master switch: when false, `actions(observing:now:)` proposes nothing.
    var enabled: Bool = true

    private var states: [VPNTarget: AttemptState] = [:]

    init(keepConnected: Set<VPNTarget> = []) {
        self.keepConnected = keepConnected
    }

    /// Encodes `targets` as vpn-ctl.sh `cliName`s, sorted ascending, for
    /// UserDefaults persistence.
    static func encode(_ targets: Set<VPNTarget>) -> [String] {
        targets.map(\.cliName).sorted()
    }

    /// Decodes a UserDefaults-stored array of `cliName`s back into a set of
    /// targets. Unknown names are ignored; `nil` decodes to the empty set.
    static func decode(_ raw: [String]?) -> Set<VPNTarget> {
        guard let raw else { return [] }
        return Set(raw.compactMap { name in VPNTarget.allCases.first { $0.cliName == name } })
    }

    /// Read-only view of a target's current attempt/backoff/suspension state.
    func state(for target: VPNTarget) -> AttemptState {
        states[target] ?? AttemptState()
    }

    /// Sets whether `target` should be kept connected. Turning it off clears
    /// all attempt/backoff/suspension state for that target. Turning it on
    /// clears any suspension so a user toggle re-arms enforcement (attempts
    /// are left as-is).
    func setKeepConnected(_ target: VPNTarget, _ on: Bool) {
        if on {
            keepConnected.insert(target)
            states[target]?.suspension = nil
        } else {
            keepConnected.remove(target)
            states.removeValue(forKey: target)
        }
    }

    /// Returns the targets that need an `.on` command right now, in stable
    /// `[.nord, .tailscale]` order. Pure: never mutates attempt state except
    /// for the "reality matches intent" reset on `.up`/`.running`.
    func actions(observing status: VPNStatus, now: Date) -> [VPNTarget] {
        var result: [VPNTarget] = []
        for target in [VPNTarget.nord, .tailscale] {
            let observedIsUp: Bool
            let observedIsDown: Bool
            switch target {
            case .nord:
                observedIsUp = status.nord == .up
                observedIsDown = status.nord == .down
            case .tailscale:
                observedIsUp = status.ts == .running
                observedIsDown = status.ts == .stopped
            }

            if observedIsUp {
                states[target] = AttemptState()
                continue
            }

            guard enabled, keepConnected.contains(target) else { continue }
            let current = states[target] ?? AttemptState()
            guard current.suspension == nil else { continue }
            if let nextAttemptAt = current.nextAttemptAt, now < nextAttemptAt {
                continue
            }
            guard observedIsDown else { continue }
            result.append(target)
        }
        return result
    }

    /// Records the outcome of an attempted `.on` command for `target`,
    /// updating attempts, backoff, and suspension state accordingly.
    func record(_ outcome: ReconcileOutcome, for target: VPNTarget, now: Date) {
        var current = states[target] ?? AttemptState()

        switch outcome {
        case .success:
            current = AttemptState()
        case .failed(let exitCode):
            switch exitCode {
            case 2 where target == .tailscale:
                current.suspension = .tailscaleNeedsLogin
            case 3:
                current.suspension = .shortcutMissing
            case 4:
                current.suspension = .nordAppTunnel
            default:
                current.attempts += 1
                current.nextAttemptAt = now.addingTimeInterval(Self.backoff(forAttempts: current.attempts))
            }
        case .timedOut:
            current.attempts += 1
            current.nextAttemptAt = now.addingTimeInterval(Self.backoff(forAttempts: current.attempts))
        case .scriptMissing:
            current.suspension = .scriptMissing
        }

        states[target] = current
    }

    /// Clears `nextAttemptAt` for every target (making them immediately
    /// eligible again) while preserving attempt counts and suspensions.
    /// Used by the sleep/wake handler.
    func resetBackoff() {
        for target in states.keys {
            states[target]?.nextAttemptAt = nil
        }
    }

    private static func backoff(forAttempts attempts: Int) -> TimeInterval {
        min(initialBackoff * pow(2, Double(attempts - 1)), maxBackoff)
    }
}
