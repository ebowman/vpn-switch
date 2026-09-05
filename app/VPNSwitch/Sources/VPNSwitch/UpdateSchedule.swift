import Foundation

/// Pure scheduling/decision logic for the background update-check loop
/// (dns-config-8v7.7). Deliberately has NO dependency on `AppModel`,
/// `UserDefaults`, or `Date()` at the call site -- every function here takes
/// its inputs as parameters and returns a value, so the scheduling rules can
/// be unit tested without touching the network, the filesystem, or wall-clock
/// time.
///
/// DESIGN (plan of record): background checks are SILENT on failure, NEVER
/// modal, NEVER activate the app, and NEVER auto-install. A newer version
/// only ever surfaces as menu content (see `AppModel.availableUpdate` and
/// `MenuContentView`) -- this type never itself shows UI.
enum UpdateSchedule {
    /// Default interval between background checks when no override is set.
    static let defaultInterval: TimeInterval = 24 * 60 * 60
    /// Delay after `startPolling()` before the very first background check,
    /// so app launch never races a network call.
    static let initialDelay: TimeInterval = 30
    /// Floor for `effectiveInterval` -- guards against a pathologically
    /// small `intervalOverrideKey` (e.g. a stray `0.001` written during
    /// testing) turning the loop into a busy poll.
    static let minInterval: TimeInterval = 60
    /// Ceiling on how long the background loop ever sleeps in one go
    /// between re-evaluating `shouldCheck` -- so a change to
    /// `autoCheckEnabledKey` or `intervalOverrideKey` made while the app is
    /// running takes effect within at most this long, rather than only on
    /// the next relaunch.
    static let maxEvaluationSleep: TimeInterval = 60 * 60

    /// UserDefaults key: whether background update checks are enabled at
    /// all. Bool, default `true` when unset -- mirrors
    /// `AppModel.notifyOnExternalChanges`'s own default-on pattern.
    static let autoCheckEnabledKey = "autoUpdateCheckEnabled"
    /// UserDefaults key: the `Date` of the last completed (successful)
    /// background or manual check.
    static let lastCheckKey = "lastUpdateCheck"
    /// UserDefaults key: the `latestVersion` string of an update the user
    /// explicitly chose to skip via "Skip This Version". Sticky: only
    /// cleared implicitly when a *different* (newer) version appears, never
    /// by a manual "Check for Updates…".
    static let skippedVersionKey = "skippedUpdateVersion"
    /// UserDefaults key: testing-only override (`Double`, seconds) for the
    /// interval between checks, in place of `defaultInterval`.
    static let intervalOverrideKey = "updateCheckIntervalSeconds"

    /// Whether a background check should run right now.
    ///
    /// - Returns: `true` iff `enabled` is true AND either no check has ever
    ///   completed (`lastCheck == nil`) or at least `interval` seconds have
    ///   elapsed since `lastCheck`. Exactly `interval` elapsed counts as due
    ///   (`>=`, not `>`).
    static func shouldCheck(now: Date, lastCheck: Date?, interval: TimeInterval, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// Resolves the testing override (`intervalOverrideKey`, read by the
    /// caller) into the interval actually used by the loop.
    ///
    /// - Parameter override: `nil` or `0` (i.e. the UserDefaults key was
    ///   never set -- `UserDefaults.double(forKey:)` returns `0` for a
    ///   missing key) both mean "no override": returns `defaultInterval`.
    ///   Any other value is clamped to be at least `minInterval`.
    static func effectiveInterval(override: Double?) -> TimeInterval {
        guard let override, override != 0 else { return defaultInterval }
        return max(override, minInterval)
    }

    /// Decides what (if anything) should be shown to the user for a
    /// completed check's result.
    ///
    /// - Returns: the manifest when `result` is `.updateAvailable` and its
    ///   `latestVersion` does not equal `skippedVersion`; `nil` for
    ///   `.upToDate` or for an available update matching the skipped
    ///   version exactly. A *different* (e.g. newer) version than the one
    ///   skipped compares unequal and is therefore surfaced again -- this is
    ///   what keeps "Skip This Version" scoped to that one version rather
    ///   than silencing all future updates.
    static func visibleUpdate(result: UpdateCheckResult, skippedVersion: String?) -> UpdateManifest? {
        switch result {
        case .upToDate:
            return nil
        case .updateAvailable(let manifest):
            if let skippedVersion, manifest.latestVersion == skippedVersion {
                return nil
            }
            return manifest
        }
    }
}
