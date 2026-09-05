import Foundation
import Testing
@testable import VPNSwitch

/// Tests for `UpdateSwapScript.shQuote(_:)` and
/// `UpdateSwapScript.generate(dmgPath:parentPID:installDir:bundleName:relaunch:)`.
///
/// `shQuote` is the single most dangerous line in this codebase (see the
/// type's doc comment): an unquoted space or shell metacharacter in a path
/// interpolated into the generated `rm -rf` can corrupt it. Every case
/// below is proven non-vacuous by ACTUALLY HANDING THE QUOTED STRING TO A
/// REAL POSIX SHELL and checking the shell reconstructs the exact original
/// value — this is a mutation-style check: if `shQuote` were broken (e.g.
/// stopped escaping embedded quotes, or used double-quotes and thus allowed
/// `$(...)` expansion), these assertions would fail because the shell would
/// echo back something other than the original input.
struct UpdateSwapScriptTests {

    // MARK: - shQuote: round-trip through a real shell

    /// Runs `/bin/sh -c "printf '%s' <quoted>"` and returns what the shell
    /// actually produced. This is the ground truth for "is this quoting
    /// safe" — not a hand-rolled parser that could share the same blind
    /// spots as the code under test.
    private func shellRoundTrip(_ quoted: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(quoted)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test func roundTripsPlainPath() throws {
        let input = "/Applications/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithSpaces() throws {
        let input = "/Users/eric bowman/Applications/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithSingleQuote() throws {
        let input = "/Users/eric's mac/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithDoubleQuote() throws {
        let input = "/Users/eric \"the boss\" bowman/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithBackslash() throws {
        let input = "/Users/eric\\bowman/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithNewline() throws {
        let input = "/Users/eric\nbowman/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    /// The classic injection payload: if `shQuote` used double-quotes (or
    /// left the value unquoted), `$(...)` would be executed by the shell.
    /// Single-quoting must render it inert. Uses a probe path under
    /// `NSTemporaryDirectory()` (never `/tmp` directly) so that IF this
    /// assertion ever regressed and the substitution executed, it could
    /// only ever touch the test's own scratch space, not shared /tmp state.
    @Test func roundTripsPathWithCommandSubstitution() throws {
        let probePath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateSwapScriptTests-injection-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probePath) }

        let input = "/tmp/$(touch \(probePath.path))/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
        #expect(!FileManager.default.fileExists(atPath: probePath.path))
    }

    @Test func roundTripsPathWithSemicolon() throws {
        let input = "/tmp/foo; rm -rf /; echo pwned/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithLeadingDash() throws {
        // A leading "-" could otherwise be misread as an option flag by
        // whatever command consumes the quoted word.
        let input = "-rf/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithMultipleAdjacentSingleQuotes() throws {
        let input = "it''s ''weird''"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsEmptyString() throws {
        let input = ""
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithDollarSign() throws {
        let input = "/tmp/$HOME/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    @Test func roundTripsPathWithBacktick() throws {
        let input = "/tmp/`whoami`/VPN Switch.app"
        let quoted = UpdateSwapScript.shQuote(input)
        #expect(try shellRoundTrip(quoted) == input)
    }

    // MARK: - shQuote structural properties (independent of the shell)

    @Test func alwaysWrapsInSingleQuotes() {
        let quoted = UpdateSwapScript.shQuote("anything")
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
    }

    @Test func embeddedSingleQuoteIsEscapedNotLeftBare() {
        // Non-vacuous by construction: if shQuote naively wrapped the
        // input in quotes WITHOUT escaping embedded quotes, this exact
        // "close-escape-reopen" substring would be absent (there'd just be
        // a bare "'" instead), so this assertion fails under that mutation.
        let quoted = UpdateSwapScript.shQuote("it's")
        #expect(quoted.contains("'\\''"))
        #expect(quoted == "'it'\\''s'")
    }

    // MARK: - Script generation: exact text for known inputs

    @Test func generatedScriptContainsShellShebangAndSetE() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 4242,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("set -e"))
    }

    @Test func generatedScriptEmbedsQuotedValuesExactlyOnce() {
        let dmgPath = "/tmp/VPN Switch Update.dmg"
        let pid: Int32 = 99887
        let installDir = "/Applications"
        let bundleName = "VPN Switch.app"
        let bundleIdentifier = "ie.boboco.vpnswitch"

        let script = UpdateSwapScript.generate(
            dmgPath: dmgPath,
            parentPID: pid,
            installDir: installDir,
            bundleName: bundleName,
            bundleIdentifier: bundleIdentifier
        )

        let expectedDMGAssignment = "DMG_PATH=\(UpdateSwapScript.shQuote(dmgPath))"
        let expectedPIDAssignment = "PID=\(UpdateSwapScript.shQuote(String(pid)))"
        let expectedInstallDirAssignment = "INSTALL_DIR=\(UpdateSwapScript.shQuote(installDir))"
        let expectedBundleNameAssignment = "BUNDLE_NAME=\(UpdateSwapScript.shQuote(bundleName))"
        let expectedBundleIDAssignment = "BUNDLE_ID=\(UpdateSwapScript.shQuote(bundleIdentifier))"

        #expect(script.contains(expectedDMGAssignment))
        #expect(script.contains(expectedPIDAssignment))
        #expect(script.contains(expectedInstallDirAssignment))
        #expect(script.contains(expectedBundleNameAssignment))
        #expect(script.contains(expectedBundleIDAssignment))

        // Each assignment line appears EXACTLY once — proves the value is
        // not accidentally duplicated (e.g. once quoted, once raw), which
        // would be a real injection surface if the raw form were also
        // present and later referenced instead of the quoted variable.
        #expect(script.components(separatedBy: expectedDMGAssignment).count == 2)
        #expect(script.components(separatedBy: expectedPIDAssignment).count == 2)
        #expect(script.components(separatedBy: expectedInstallDirAssignment).count == 2)
        #expect(script.components(separatedBy: expectedBundleNameAssignment).count == 2)
        #expect(script.components(separatedBy: expectedBundleIDAssignment).count == 2)
    }

    @Test func generatedScriptNeverContainsRawUnquotedDangerousPath() {
        // The raw (unquoted) dangerous value must NEVER appear anywhere in
        // the script text on its own — only inside the shQuote(...) wrapped
        // assignment. This directly guards against a regression where some
        // OTHER interpolation site forgets to call shQuote.
        let dangerousPath = "/tmp/evil; rm -rf ~"
        let script = UpdateSwapScript.generate(
            dmgPath: dangerousPath,
            parentPID: 1,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        // The only occurrence of the raw substring must be inside the
        // shQuote(...)'d assignment line.
        let quoted = UpdateSwapScript.shQuote(dangerousPath)
        let scriptWithoutQuotedOccurrence = script.replacingOccurrences(of: quoted, with: "")
        #expect(!scriptWithoutQuotedOccurrence.contains(dangerousPath))
    }

    @Test func generatedScriptWaitsForParentPIDBeforeAnyDestructiveStep() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        guard let killRange = script.range(of: "kill -0"),
              let mvRange = script.range(of: "/bin/mv \"$OLD_BUNDLE\" \"$OLD_ASIDE\"") else {
            Issue.record("expected both 'kill -0' wait loop and the old-bundle mv-aside step to be present")
            return
        }
        // Non-vacuous: this fails if the destructive mv-aside step were ever
        // moved (or newly introduced) ahead of the parent-exit wait loop.
        #expect(killRange.lowerBound < mvRange.lowerBound)
    }

    /// The atomic stage-and-swap must happen in exactly this order: verify
    /// the MOUNTED bundle, ditto it into a staging dir, re-verify the
    /// STAGED copy, move the old bundle aside, move the staged copy into
    /// place, and only then remove the set-aside old bundle. Any other
    /// ordering reopens the "no app installed after a failure" gap this
    /// bead closes.
    @Test func generatedScriptPerformsAtomicStageAndSwapInOrder() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        guard let codesignOnNewRange = script.range(of: "/usr/bin/codesign --verify --deep --strict -R=\"$REQUIREMENT\" \"$NEW_BUNDLE\""),
              let dittoRange = script.range(of: "/usr/bin/ditto \"$NEW_BUNDLE\" \"$STAGED\""),
              let codesignOnStagedRange = script.range(of: "/usr/bin/codesign --verify --deep --strict -R=\"$REQUIREMENT\" \"$STAGED\""),
              let mvOldAsideRange = script.range(of: "/bin/mv \"$OLD_BUNDLE\" \"$OLD_ASIDE\""),
              let mvStagedIntoPlaceRange = script.range(of: "/bin/mv \"$STAGED\" \"$OLD_BUNDLE\""),
              let rmOldAsideRange = script.range(of: "/bin/rm -rf \"$OLD_ASIDE\"") else {
            Issue.record("expected all six atomic stage-and-swap steps to be present")
            return
        }

        #expect(codesignOnNewRange.lowerBound < dittoRange.lowerBound)
        #expect(dittoRange.lowerBound < codesignOnStagedRange.lowerBound)
        #expect(codesignOnStagedRange.lowerBound < mvOldAsideRange.lowerBound)
        #expect(mvOldAsideRange.lowerBound < mvStagedIntoPlaceRange.lowerBound)
        #expect(mvStagedIntoPlaceRange.lowerBound < rmOldAsideRange.lowerBound)
    }

    @Test func generatedScriptUsesPython3ToParsePlistNotGrepVolumes() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        #expect(script.contains("python3"))
        #expect(script.contains("plistlib"))
        #expect(!script.contains("grep") || !script.lowercased().contains("/volumes"))
    }

    @Test func generatedScriptFailsLoudlyWhenPython3Missing() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        #expect(script.contains("command -v python3"))
        // Must exit nonzero rather than silently continuing when python3
        // is absent.
        guard let checkRange = script.range(of: "command -v python3") else {
            Issue.record("expected python3 availability check")
            return
        }
        let afterCheck = script[checkRange.upperBound...]
        #expect(afterCheck.contains("exit 1"))
    }

    /// With an empty BUNDLE_NAME, "$MOUNT_POINT/$BUNDLE_NAME" is the mount
    /// ROOT — a real directory, so the -d check further down PASSES — and
    /// "$INSTALL_DIR/$BUNDLE_NAME" collapses to "/". That is `rm -rf /` with
    /// no recovery but this log.
    ///
    /// Not reachable via Bundle.main.bundleURL today, but this is the one
    /// bug class where "not currently reachable" is not good enough, so the
    /// script refuses outright. These assertions exist so a future edit
    /// cannot quietly drop the guard.
    @Test func generatedScriptRefusesEmptyOrRootTargetsBeforeRemoving() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/x.dmg",
            parentPID: 999_999,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        // The guards must exist...
        #expect(script.contains(#"[ -z "$INSTALL_DIR" ]"#))
        #expect(script.contains(#"[ -z "$BUNDLE_NAME" ]"#))
        #expect(script.contains(#"[ "$INSTALL_DIR" = "/" ]"#))

        // ...and must come BEFORE the destructive line, or they are useless.
        let guardIndex = script.range(of: #"[ -z "$INSTALL_DIR" ]"#)
        let moveAsideIndex = script.range(of: #"/bin/mv "$OLD_BUNDLE" "$OLD_ASIDE""#)
        #expect(guardIndex != nil)
        #expect(moveAsideIndex != nil)
        if let g = guardIndex, let m = moveAsideIndex {
            #expect(g.lowerBound < m.lowerBound)
        }
    }

    /// All five refusal messages must be present verbatim: empty
    /// dir/name, root install dir, unsafe bundle name, and (new for
    /// VPN Switch) missing installed bundle before the rm -rf.
    @Test func generatedScriptContainsAllFiveRefusalMessages() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/x.dmg",
            parentPID: 999_999,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        #expect(script.contains("refusing to run: empty install dir or bundle name"))
        #expect(script.contains("refusing to run: install dir is /"))
        #expect(script.contains("refusing to run: unsafe bundle name"))
        #expect(script.contains("not found on mounted volume, aborting"))
        #expect(script.contains("installed bundle not found at $OLD_BUNDLE, aborting"))
    }

    @Test func generatedScriptRefusesWhenInstalledBundleMissingBeforeRemoving() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/x.dmg",
            parentPID: 999_999,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        guard let guardRange = script.range(of: "installed bundle not found at $OLD_BUNDLE, aborting"),
              let moveAsideRange = script.range(of: #"/bin/mv "$OLD_BUNDLE" "$OLD_ASIDE""#) else {
            Issue.record("expected both the missing-installed-bundle guard and the old-bundle mv-aside step to be present")
            return
        }
        #expect(guardRange.lowerBound < moveAsideRange.lowerBound)
    }

    @Test func generatedScriptOpensRelaunchedAppAtEndWhenRelaunchIsTrue() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch",
            relaunch: true
        )
        guard let mvStagedIntoPlaceRange = script.range(of: "/bin/mv \"$STAGED\" \"$OLD_BUNDLE\""),
              let openRange = script.range(of: "open \"$OLD_BUNDLE\"") else {
            Issue.record("expected both the staged-copy install step and the open step to be present")
            return
        }
        #expect(mvStagedIntoPlaceRange.lowerBound < openRange.lowerBound)
    }

    @Test func generatedScriptOmitsOpenWhenRelaunchIsFalse() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch",
            relaunch: false
        )
        #expect(!script.contains("open \"$OLD_BUNDLE\""))
        #expect(script.contains("relaunch skipped (relaunch=false)"))
    }

    @Test func generatedScriptDefaultsToRelaunchTrue() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        #expect(script.contains("open \"$OLD_BUNDLE\""))
    }

    /// The old install-in-place approach (`rm -rf "$OLD_BUNDLE"` immediately
    /// followed by `cp -R`) is exactly the non-atomic sequence this bead
    /// replaces: a failure between the two left no app installed. The
    /// script must never remove `$OLD_BUNDLE` directly -- only ever move it
    /// aside (to `$OLD_ASIDE`) first. Every `rm -rf` in the script must
    /// target only the staging or set-aside paths, never the live bundle
    /// directly.
    @Test func generatedScriptNeverRemovesOldBundleDirectlyOnlyStagedOrAsidePaths() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        #expect(!script.contains("rm -rf \"$OLD_BUNDLE\""))

        // Every `rm -rf` target found in the script text must be either
        // "$STAGED" or "$OLD_ASIDE" -- never "$OLD_BUNDLE" or anything else.
        let pattern = #"rm -rf "([^"]+)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsScript = script as NSString
        let matches = regex.matches(in: script, range: NSRange(location: 0, length: nsScript.length))
        #expect(!matches.isEmpty, "expected at least one rm -rf in the generated script")
        for match in matches {
            let target = nsScript.substring(with: match.range(at: 1))
            #expect(target == "$STAGED" || target == "$OLD_ASIDE", "unexpected rm -rf target: \(target)")
        }
    }

    // MARK: - Team ID re-verification of the mounted bundle (dns-config-407)

    @Test func generatedScriptReVerifiesMountedBundleBetweenAttachAndRemove() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )

        guard let attachRange = script.range(of: "hdiutil attach"),
              let codesignRange = script.range(of: "/usr/bin/codesign --verify --deep --strict -R=\"$REQUIREMENT\""),
              let mvOldAsideRange = script.range(of: "/bin/mv \"$OLD_BUNDLE\" \"$OLD_ASIDE\"") else {
            Issue.record("expected hdiutil attach, the codesign re-verify step, and the old-bundle mv-aside step to all be present")
            return
        }
        // Non-vacuous: fails if the re-verify step were ever moved ahead of
        // the attach (nothing to verify yet) or behind the destructive
        // mv-aside step (too late to prevent it) -- see
        // UpdateSwapScript.generate's doc comment step 5.
        #expect(attachRange.lowerBound < codesignRange.lowerBound)
        #expect(codesignRange.lowerBound < mvOldAsideRange.lowerBound)
    }

    @Test func generatedScriptDefaultRequirementEqualsUpdateInstallerConstant() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        let expectedAssignment = "REQUIREMENT=\(UpdateSwapScript.shQuote(UpdateInstaller.designatedRequirement))"
        #expect(script.contains(expectedAssignment))
        // Embedded exactly once.
        #expect(script.components(separatedBy: expectedAssignment).count == 2)
    }

    @Test func generatedScriptEmbedsCustomRequirementShQuotedExactlyOnce() {
        let customRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"TESTTEAMID\""
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch",
            requirement: customRequirement
        )
        let expectedAssignment = "REQUIREMENT=\(UpdateSwapScript.shQuote(customRequirement))"
        #expect(script.contains(expectedAssignment))
        #expect(script.components(separatedBy: expectedAssignment).count == 2)

        // The raw (unquoted) value must never appear outside the quoted
        // assignment -- same discipline as the dangerous-path check above.
        let scriptWithoutQuotedOccurrence = script.replacingOccurrences(of: expectedAssignment, with: "")
        #expect(!scriptWithoutQuotedOccurrence.contains(customRequirement))
    }

    /// A requirement string containing a single quote or a `$(...)`
    /// command-substitution payload must still round-trip safely through a
    /// real shell -- reuses the same ground-truth technique as the
    /// `shQuote` round-trip tests above, applied to the REQUIREMENT
    /// assignment line specifically.
    @Test func generatedScriptEmbedsRequirementWithSingleQuoteSafely() throws {
        let trickyRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"it's odd\""
        let quoted = UpdateSwapScript.shQuote(trickyRequirement)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let roundTripped = String(data: data, encoding: .utf8) ?? ""
        #expect(roundTripped == trickyRequirement)

        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch",
            requirement: trickyRequirement
        )
        #expect(script.contains("REQUIREMENT=\(quoted)"))
    }

    @Test func generatedScriptEmbedsRequirementWithCommandSubstitutionSafely() throws {
        let probePath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateSwapScriptTests-requirement-injection-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probePath) }

        let trickyRequirement = "$(touch \(probePath.path))"
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch",
            requirement: trickyRequirement
        )
        let quoted = UpdateSwapScript.shQuote(trickyRequirement)
        #expect(script.contains("REQUIREMENT=\(quoted)"))

        // Actually run the generated script (it will fail early for
        // unrelated reasons -- no real DMG at /tmp/update.dmg -- but the
        // REQUIREMENT assignment line itself must not execute the
        // substitution as a side effect of merely being assigned).
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateSwapScriptTests-requirement-injection-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(!FileManager.default.fileExists(atPath: probePath.path))
    }

    @Test func generatedScriptContainsShasumCheckWhenExpectedSHA256Provided() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch",
            expectedSHA256: "abc123"
        )
        #expect(script.contains("EXPECTED_SHA256=\(UpdateSwapScript.shQuote("abc123"))"))
        #expect(script.contains("shasum"))
        #expect(script.contains("refusing to install: DMG digest changed since verification"))

        guard let shasumRange = script.range(of: "shasum"),
              let attachRange = script.range(of: "hdiutil attach") else {
            Issue.record("expected both shasum check and hdiutil attach to be present")
            return
        }
        #expect(shasumRange.lowerBound < attachRange.lowerBound)
    }

    @Test func generatedScriptOmitsShasumWhenExpectedSHA256IsNil() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch",
            expectedSHA256: nil
        )
        #expect(!script.contains("shasum"))
        #expect(!script.contains("EXPECTED_SHA256"))
    }

    // MARK: - Atomic stage-and-swap hardening (dns-config-lsj)

    @Test func generatedScriptMountsReadOnly() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        guard let attachLineRange = script.range(of: "hdiutil attach -nobrowse -noverify -readonly -plist") else {
            Issue.record("expected hdiutil attach to include -readonly")
            return
        }
        _ = attachLineRange
    }

    @Test func generatedScriptEmbedsBundleIDShQuotedExactlyOnceAndChecksPrecedeAnyMove() {
        let bundleIdentifier = "ie.boboco.vpnswitch"
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: bundleIdentifier
        )

        let expectedAssignment = "BUNDLE_ID=\(UpdateSwapScript.shQuote(bundleIdentifier))"
        #expect(script.contains(expectedAssignment))
        #expect(script.components(separatedBy: expectedAssignment).count == 2)

        guard let oldPlistBuddyRange = script.range(of: "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$OLD_BUNDLE/Contents/Info.plist\""),
              let newPlistBuddyRange = script.range(of: "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$NEW_BUNDLE/Contents/Info.plist\""),
              let mvOldAsideRange = script.range(of: "/bin/mv \"$OLD_BUNDLE\" \"$OLD_ASIDE\"") else {
            Issue.record("expected both PlistBuddy identity checks and the old-bundle mv-aside step to be present")
            return
        }
        #expect(oldPlistBuddyRange.lowerBound < mvOldAsideRange.lowerBound)
        #expect(newPlistBuddyRange.lowerBound < mvOldAsideRange.lowerBound)
    }

    @Test func generatedScriptRefusesSymlinkedNewBundle() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        guard let symlinkCheckRange = script.range(of: #"[ -L "$NEW_BUNDLE" ]"#),
              let mvOldAsideRange = script.range(of: "/bin/mv \"$OLD_BUNDLE\" \"$OLD_ASIDE\"") else {
            Issue.record("expected both the symlink check and the old-bundle mv-aside step to be present")
            return
        }
        #expect(symlinkCheckRange.lowerBound < mvOldAsideRange.lowerBound)
    }

    @Test func generatedScriptRemovesPlistAndDMGOnSuccessPath() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        guard let updateCompleteRange = script.range(of: "update complete") else {
            Issue.record("expected the success log line to be present")
            return
        }
        let beforeSuccess = script[..<updateCompleteRange.lowerBound]
        #expect(beforeSuccess.contains("/bin/rm -f \"$PLIST_PATH\""))
        #expect(beforeSuccess.contains("/bin/rm -f \"$DMG_PATH\""))
    }

    @Test func generatedScriptRefusalGuardsPrecedeEverythingElse() {
        let script = UpdateSwapScript.generate(
            dmgPath: "/tmp/update.dmg",
            parentPID: 555,
            installDir: "/Applications",
            bundleName: "VPN Switch.app",
            bundleIdentifier: "ie.boboco.vpnswitch"
        )
        guard let lastGuardRange = script.range(of: #"[ "$INSTALL_DIR" = "/" ]"#),
              let waitRange = script.range(of: "kill -0") else {
            Issue.record("expected both the root-install-dir guard and the parent-exit wait loop to be present")
            return
        }
        #expect(lastGuardRange.lowerBound < waitRange.lowerBound)
    }
}
