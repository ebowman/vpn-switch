import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp for the "Launch at login" toggle
/// (dns-config-qsk.7 DESIGN ADJUSTMENT). Preferred over a LaunchAgent plist
/// because it shows up in System Settings > General > Login Items and the
/// user can revoke it there.
///
/// SMAppService needs a stable path to register against, so registration is
/// only offered while the running app is under /Applications -- registering
/// from a build directory or DerivedData would silently break on the next
/// build. `isEligible` reflects that constraint; callers should disable the
/// toggle (with a hint) when it's false rather than attempt to register.
enum LoginItem {
    /// True only when the running app bundle lives under /Applications.
    static var isEligible: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// Human-readable reason the toggle is disabled, shown as a hint in the
    /// menu when `isEligible` is false.
    static let ineligibleHint = "Install to /Applications first"

    /// Current registration status, read fresh each time (SMAppService is
    /// the source of truth -- the user may have revoked it from System
    /// Settings independently of this app).
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers the app to launch at login. No-op (returns success) if
    /// already registered. Returns a human-readable error message on
    /// failure, or nil on success.
    @discardableResult
    static func register() -> String? {
        guard isEligible else { return ineligibleHint }
        if SMAppService.mainApp.status == .enabled { return nil }
        do {
            try SMAppService.mainApp.register()
            return nil
        } catch {
            return "Failed to register login item: \(error.localizedDescription)"
        }
    }

    /// Unregisters the app from launching at login. No-op (returns success)
    /// if not currently registered.
    @discardableResult
    static func unregister() -> String? {
        if SMAppService.mainApp.status != .enabled {
            // Still attempt unregister in case status is stale
            // (.notFound/.requiresApproval) but a registration record
            // exists -- SMAppService.unregister() is safe to call even
            // when not enabled.
        }
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return "Failed to unregister login item: \(error.localizedDescription)"
        }
    }
}
