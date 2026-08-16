import Foundation

/// Maps (NordVPN state, Tailscale state) to an SF Symbol so the combined
/// state is readable at a glance from the menu bar, without opening the
/// menu.
///
/// Symbol mapping (documented here and echoed in the menu header):
///   nord on,  ts on   -> "shield.lefthalf.filled.badge.checkmark"  (both connected)
///   nord on,  ts off  -> "checkmark.shield"                        (NordVPN only)
///   nord off, ts on   -> "network"                                 (Tailscale only)
///   nord off, ts off  -> "shield.slash"                            (both disconnected)
///   error/unknown     -> "exclamationmark.triangle"                (unknown/error state,
///                                                                    e.g. app-tunnel/unrecognized)
enum MenuIcon {
    static func symbolName(for status: VPNStatus) -> String {
        // Error/unknown takes priority: app tunnel, unknown, or unrecognized
        // tokens on either side mean the two-state grid below doesn't apply.
        let nordIsErrorish: Bool
        switch status.nord {
        case .app, .appPlusIkev2, .unknown, .unrecognized:
            nordIsErrorish = true
        case .up, .down:
            nordIsErrorish = false
        }
        let tsIsErrorish: Bool
        switch status.ts {
        case .needsLogin, .starting, .unrecognized:
            tsIsErrorish = true
        case .running, .stopped:
            tsIsErrorish = false
        }
        if nordIsErrorish || tsIsErrorish {
            return "exclamationmark.triangle"
        }

        switch (status.nord.isOn, status.ts.isOn) {
        case (true, true): return "shield.lefthalf.filled.badge.checkmark"
        case (true, false): return "checkmark.shield"
        case (false, true): return "network"
        case (false, false): return "shield.slash"
        }
    }
}
