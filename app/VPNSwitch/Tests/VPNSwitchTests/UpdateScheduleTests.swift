import Foundation
import Testing
@testable import VPNSwitch

/// Pure-logic tests for `UpdateSchedule` (dns-config-8v7.7). No network, no
/// UserDefaults, no Bundle -- every function under test takes its inputs as
/// parameters, so these tests exercise the scheduling/visibility rules
/// directly against fixed `Date`/`TimeInterval` values.
struct UpdateScheduleTests {

    // MARK: - shouldCheck

    @Test func shouldCheckFalseWhenDisabledEvenWithNilLastCheck() {
        let now = Date()
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: nil, interval: 3600, enabled: false) == false)
    }

    @Test func shouldCheckTrueWhenEnabledAndNeverChecked() {
        let now = Date()
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: nil, interval: 3600, enabled: true) == true)
    }

    @Test func shouldCheckFalseWhenRecentlyChecked() {
        let interval: TimeInterval = 3600
        let now = Date()
        let lastCheck = now.addingTimeInterval(-(interval - 1))
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: lastCheck, interval: interval, enabled: true) == false)
    }

    @Test func shouldCheckTrueWhenStale() {
        let interval: TimeInterval = 3600
        let now = Date()
        let lastCheck = now.addingTimeInterval(-(interval + 1))
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: lastCheck, interval: interval, enabled: true) == true)
    }

    @Test func shouldCheckTrueWhenExactlyAtInterval() {
        let interval: TimeInterval = 3600
        let now = Date()
        let lastCheck = now.addingTimeInterval(-interval)
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: lastCheck, interval: interval, enabled: true) == true)
    }

    // MARK: - effectiveInterval

    @Test func effectiveIntervalNilOverrideIsDefault() {
        #expect(UpdateSchedule.effectiveInterval(override: nil) == UpdateSchedule.defaultInterval)
    }

    @Test func effectiveIntervalZeroOverrideIsDefault() {
        #expect(UpdateSchedule.effectiveInterval(override: 0) == UpdateSchedule.defaultInterval)
    }

    @Test func effectiveIntervalSmallOverrideClampsToMin() {
        #expect(UpdateSchedule.effectiveInterval(override: 30) == UpdateSchedule.minInterval)
    }

    @Test func effectiveIntervalLargeOverridePassesThrough() {
        #expect(UpdateSchedule.effectiveInterval(override: 3600) == 3600)
    }

    // MARK: - visibleUpdate

    private func manifest(version: String) -> UpdateManifest {
        UpdateManifest(latestVersion: version, notes: "", dmgURL: "https://example.com/x.dmg", dmgSHA256: "abc")
    }

    @Test func visibleUpdateAvailableNoSkipReturnsManifest() {
        let m = manifest(version: "2.0.0")
        let result = UpdateCheckResult.updateAvailable(manifest: m)
        #expect(UpdateSchedule.visibleUpdate(result: result, skippedVersion: nil) == m)
    }

    @Test func visibleUpdateAvailableSkippedSameVersionReturnsNil() {
        let m = manifest(version: "2.0.0")
        let result = UpdateCheckResult.updateAvailable(manifest: m)
        #expect(UpdateSchedule.visibleUpdate(result: result, skippedVersion: "2.0.0") == nil)
    }

    @Test func visibleUpdateAvailableSkippedDifferentVersionReturnsManifest() {
        let m = manifest(version: "2.1.0")
        let result = UpdateCheckResult.updateAvailable(manifest: m)
        #expect(UpdateSchedule.visibleUpdate(result: result, skippedVersion: "2.0.0") == m)
    }

    @Test func visibleUpdateUpToDateReturnsNil() {
        let m = manifest(version: "1.0.0")
        let result = UpdateCheckResult.upToDate(manifest: m)
        #expect(UpdateSchedule.visibleUpdate(result: result, skippedVersion: nil) == nil)
    }
}
