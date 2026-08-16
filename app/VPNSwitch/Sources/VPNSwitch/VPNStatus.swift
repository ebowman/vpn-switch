import Foundation

/// NordVPN state, parsed from vpn-ctl.sh's `nord=<...>` token.
/// Known values (see lib/nord-ctl.sh `nord_state`): up | down | app | app+ikev2 | unknown.
/// Any unrecognized token is tolerated and mapped to `.unrecognized(raw)`.
enum NordState: Equatable {
    case up
    case down
    case app
    case appPlusIkev2
    case unknown
    case unrecognized(String)

    init(raw: String) {
        switch raw {
        case "up": self = .up
        case "down": self = .down
        case "app": self = .app
        case "app+ikev2": self = .appPlusIkev2
        case "unknown": self = .unknown
        default: self = .unrecognized(raw)
        }
    }

    /// Whether the IKEv2-based NordVPN control this app manages is "on".
    var isOn: Bool { self == .up }

    var label: String {
        switch self {
        case .up: return "Connected"
        case .down: return "Disconnected"
        case .app, .appPlusIkev2: return "App tunnel (unsupported)"
        case .unknown: return "Unknown"
        case .unrecognized(let raw): return "Unknown (\(raw))"
        }
    }
}

/// Tailscale state, parsed from vpn-ctl.sh's `ts=<...>` token.
/// Known values (see lib/tailscale-ctl.sh `ts_state`): Running | Stopped | NeedsLogin | Starting | ...
/// Any unrecognized token is tolerated and mapped to `.unrecognized(raw)`.
enum TailscaleState: Equatable {
    case running
    case stopped
    case needsLogin
    case starting
    case unrecognized(String)

    init(raw: String) {
        switch raw {
        case "Running": self = .running
        case "Stopped": self = .stopped
        case "NeedsLogin": self = .needsLogin
        case "Starting": self = .starting
        default: self = .unrecognized(raw)
        }
    }

    var isOn: Bool { self == .running }

    var label: String {
        switch self {
        case .running: return "Connected"
        case .stopped: return "Disconnected"
        case .needsLogin: return "Needs login"
        case .starting: return "Starting…"
        case .unrecognized(let raw): return "Unknown (\(raw))"
        }
    }
}

/// Parsed form of vpn-ctl.sh's one-line status output:
///   nord=<..> ts=<..> web=<..> streamy=<..>
/// Tolerant of missing/unknown tokens -- any token not recognized is kept in
/// `extra` and doesn't prevent parsing the rest.
struct VPNStatus: Equatable {
    var nord: NordState = .unknown
    var ts: TailscaleState = .unrecognized("")
    var web: String?
    var streamy: String?

    static func parse(_ line: String) -> VPNStatus {
        var status = VPNStatus()
        let tokens = line.split(separator: " ")
        for token in tokens {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = token[token.startIndex..<eq]
            let value = String(token[token.index(after: eq)...])
            switch key {
            case "nord": status.nord = NordState(raw: value)
            case "ts": status.ts = TailscaleState(raw: value)
            case "web": status.web = value
            case "streamy": status.streamy = value
            default: break
            }
        }
        return status
    }
}
