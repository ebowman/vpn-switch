import Foundation
import Testing
@testable import VPNSwitch

extension Tag {
    /// Tag for slow, system-touching integration tests (real `hdiutil`
    /// mounts under `/Volumes`, real subprocess launches) as opposed to the
    /// pure-string-generation unit tests in `UpdateSwapScriptTests`. Tests
    /// tagged `.live` remain enabled by default; the tag exists purely for
    /// filtering (e.g. `swift test --skip-tag live` for a fast inner loop),
    /// not for gating.
    @Tag static var live: Self
}

/// LIVE integration tests for `UpdateSwapScript.generate(...)`: run the
/// REAL generated script text through a REAL `/bin/sh`, including real
/// `hdiutil attach`/`hdiutil detach`/`cp -R` calls, against a THROWAWAY
/// install directory and a THROWAWAY DMG built with `hdiutil create` — both
/// entirely under `NSTemporaryDirectory()`. NEVER touches `/Applications`,
/// `~/Library`, or any real installed VPN Switch.app.
///
/// These are slower (the end-to-end test takes several seconds because it
/// actually creates and mounts a disk image) and touch real system state
/// (mounts a volume under `/Volumes`) more than the rest of this test
/// target does. They are kept anyway because they are the only test
/// coverage that proves the swap script's shell logic is correct as ACTUAL
/// shell script text executed by a real shell — the `UpdateSwapScriptTests`
/// suite only asserts on the generated string.
/// `.serialized` forces this suite's tests to run one at a time (never
/// concurrently with each other). Each test also builds its DMG with a
/// unique `-volname` (see `uniqueVolumeName`), but concurrent runs would
/// still race on `hdiutil attach`'s own mount-point allocation under
/// `/Volumes`, so both defenses are kept belt-and-braces.
@Suite(.serialized, .tags(.live))
struct UpdateSwapScriptLiveIntegrationTests {

    /// Returns a volume name guaranteed unique to this test invocation, so
    /// concurrent (or accidentally re-ordered) test runs never collide on
    /// the same `/Volumes/<name>` mount point.
    private func uniqueVolumeName(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// Runs `/bin/sh <scriptURL>` to completion and returns (exit status,
    /// combined stdout+stderr).
    private func runScript(at scriptURL: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        try process.run()
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func writeAndMakeExecutable(_ script: String, at scriptURL: URL) throws {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Spawns and waits for `/bin/true` to exit, then returns its pid. Used
    /// as a `parentPID` that is GUARANTEED to have already exited by the
    /// time the generated script's `kill -0` wait loop runs, so tests don't
    /// have to sleep waiting for a made-up pid's improbable non-existence.
    private func pidOfAlreadyExitedProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test(.tags(.live))
    func scriptFailsLoudlyWhenDMGMissingAndNeverTouchesBundle() throws {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let installDir = scratchRoot.appendingPathComponent("install")
        let bundleDir = installDir.appendingPathComponent("VPN Switch.app")
        try FileManager.default.createDirectory(at: bundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let markerURL = bundleDir.appendingPathComponent("Contents/marker.txt")
        try Data("marker".utf8).write(to: markerURL)

        let script = UpdateSwapScript.generate(
            dmgPath: scratchRoot.appendingPathComponent("nonexistent.dmg").path,
            parentPID: try pidOfAlreadyExitedProcess(),
            installDir: installDir.path,
            bundleName: "VPN Switch.app",
            relaunch: false
        )

        let scriptURL = scratchRoot.appendingPathComponent("swap.sh")
        try writeAndMakeExecutable(script, at: scriptURL)

        let (status, output) = try runScript(at: scriptURL)
        print("SCRIPT OUTPUT:\n\(output)")
        print("EXIT STATUS: \(status)")

        #expect(status != 0)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    /// Writes the minimum `Contents/Info.plist` and `Contents/MacOS/<exe>`
    /// that `codesign` requires to recognize `contentsDir`'s parent as a
    /// signable bundle at all -- a bare directory (even one ending in
    /// `.app`) is rejected outright with "bundle format unrecognized,
    /// invalid, or unsuitable" before signature verification is even
    /// attempted. `contentsDir` is the bundle's `Contents` directory
    /// (already created by the caller); this only adds the two files
    /// needed to make it signable.
    private func writeMinimalSignableBundleContents(contentsDir: URL) throws {
        let macOSDir = contentsDir.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.vpnswitch-swap-test</string>
        <key>CFBundleExecutable</key><string>stub</string>
        </dict></plist>
        """
        try plist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let executableURL = macOSDir.appendingPathComponent("stub")
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    /// Ad-hoc code-signs the bundle at `bundlePath` (`codesign --sign -
    /// --force`) and returns its own designated requirement text (parsed
    /// out of `codesign -d -r-`'s `designated => ...` line). Used so tests
    /// that want to isolate a guard OTHER than the Team ID re-verification
    /// step can pass a `requirement` the fixture will genuinely satisfy,
    /// without needing a real Developer-ID signature.
    private func adHocSignAndGetDesignatedRequirement(bundlePath: String) throws -> String {
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--sign", "-", "--force", bundlePath]
        let signPipe = Pipe()
        sign.standardOutput = signPipe
        sign.standardError = signPipe
        try sign.run()
        sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)

        let dump = Process()
        dump.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        dump.arguments = ["-d", "-r-", bundlePath]
        let dumpPipe = Pipe()
        dump.standardOutput = dumpPipe
        dump.standardError = dumpPipe
        try dump.run()
        dump.waitUntilExit()
        let data = dumpPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard let designatedLine = output.split(separator: "\n").first(where: { $0.contains("designated =>") }) else {
            Issue.record("could not find 'designated =>' line in codesign -d -r- output: \(output)")
            return "cdhash H\"0000000000000000000000000000000000000000\""
        }
        guard let arrowRange = designatedLine.range(of: "=> ") else {
            Issue.record("could not parse designated requirement from: \(designatedLine)")
            return "cdhash H\"0000000000000000000000000000000000000000\""
        }
        return String(designatedLine[arrowRange.upperBound...])
    }

    /// installDir exists but does NOT contain the installed bundle. Even
    /// with a REAL DMG available to attach, the script must refuse before
    /// ever reaching the destructive `rm -rf`, and must still detach the
    /// mount it opened along the way (no leaked `/Volumes` entry).
    ///
    /// Uses an ad-hoc signed fixture with its OWN designated requirement
    /// passed as `requirement:` (rather than the real Team ID pin) so this
    /// test continues to isolate the missing-installed-bundle guard
    /// specifically, independent of the Team ID re-verification step
    /// covered by the unsigned/signed tests elsewhere in this suite.
    @Test(.tags(.live))
    func scriptFailsLoudlyWhenInstalledBundleMissingAndDetachesMount() throws {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        // installDir exists, but nothing named "VPN Switch.app" is inside it.
        let installDir = scratchRoot.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        // Build a real, minimal DMG containing a "VPN Switch.app" so the
        // script gets past the attach + NEW_BUNDLE-exists checks and reaches
        // the new missing-installed-bundle guard. The bundle must be a
        // codesign-recognizable structure (Info.plist + executable) so it
        // can actually be ad-hoc signed below -- a bare directory with just
        // a marker file is rejected by `codesign` as "bundle format
        // unrecognized" before it even gets to checking a signature.
        let volName = uniqueVolumeName("VPN Switch Test Missing")
        let dmgSourceDir = scratchRoot.appendingPathComponent("dmgsrc")
        let newBundleContentsDir = dmgSourceDir.appendingPathComponent("VPN Switch.app/Contents")
        let newBundleResourcesDir = newBundleContentsDir.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: newBundleResourcesDir, withIntermediateDirectories: true)
        // Marker file goes under Resources, not loose in Contents -- codesign
        // rejects arbitrary loose files directly under Contents as unsigned
        // "subcomponents" it doesn't know how to sign, but Resources is
        // expected bundle structure.
        try Data("NEW".utf8).write(to: newBundleResourcesDir.appendingPathComponent("marker.txt"))
        try writeMinimalSignableBundleContents(contentsDir: newBundleContentsDir)

        let newBundlePath = dmgSourceDir.appendingPathComponent("VPN Switch.app").path
        let adHocRequirement = try adHocSignAndGetDesignatedRequirement(bundlePath: newBundlePath)

        let dmgPath = scratchRoot.appendingPathComponent("update.dmg").path
        let createDMG = Process()
        createDMG.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createDMG.arguments = ["create", "-srcfolder", dmgSourceDir.path, "-volname", volName, "-format", "UDZO", "-quiet", dmgPath]
        createDMG.standardOutput = Pipe()
        createDMG.standardError = Pipe()
        try createDMG.run()
        createDMG.waitUntilExit()
        #expect(createDMG.terminationStatus == 0)

        let script = UpdateSwapScript.generate(
            dmgPath: dmgPath,
            parentPID: try pidOfAlreadyExitedProcess(),
            installDir: installDir.path,
            bundleName: "VPN Switch.app",
            relaunch: false,
            requirement: adHocRequirement
        )

        let scriptURL = scratchRoot.appendingPathComponent("swap.sh")
        try writeAndMakeExecutable(script, at: scriptURL)

        let (status, output) = try runScript(at: scriptURL)
        print("SCRIPT OUTPUT:\n\(output)")
        print("EXIT STATUS: \(status)")

        #expect(status != 0)
        #expect(output.contains("installed bundle not found"))

        // Give the detach a brief moment to take effect and confirm no
        // leaked mount from this test's volume.
        let mountCheck = Process()
        mountCheck.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let mountPipe = Pipe()
        mountCheck.standardOutput = mountPipe
        try mountCheck.run()
        mountCheck.waitUntilExit()
        let mountOutput = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(!mountOutput.lowercased().contains(volName.lowercased()))
    }

    /// Streaming SHA-256 hex digest of the file at `path`, via the real
    /// `shasum -a 256` binary (the same tool the generated script itself
    /// uses), so tests never need to reimplement digesting logic that could
    /// silently diverge from what the script actually runs.
    private func shasum256Hex(ofFileAt path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let digest = output.split(separator: " ").first.map(String.init) ?? ""
        #expect(!digest.isEmpty)
        return digest
    }

    /// Whether `/Volumes` still shows a mount whose name contains
    /// `volName` -- used to assert a mount was actually detached (no
    /// leaked `/Volumes` entry) rather than merely that the script claimed
    /// to detach it.
    private func volumeIsMounted(named volName: String) throws -> Bool {
        let mountCheck = Process()
        mountCheck.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let mountPipe = Pipe()
        mountCheck.standardOutput = mountPipe
        try mountCheck.run()
        mountCheck.waitUntilExit()
        let mountOutput = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return mountOutput.lowercased().contains(volName.lowercased())
    }

    /// NEGATIVE end-to-end test: the throwaway fixture bundle built by
    /// these tests is unsigned (it's a bare directory with a marker file,
    /// not a real code-signed `.app`), so with the Team ID re-verification
    /// step (dns-config-407) now in the script, it MUST be refused before
    /// the destructive `rm -rf` ever runs. This replaces the old
    /// (pre-Team-ID-pin) "swaps successfully" happy-path test, which relied
    /// on an unsigned fixture actually being accepted -- that acceptance
    /// was exactly the security gap this bead closes. See
    /// `scriptSwapsRealSignedAppEndToEnd` below for the positive
    /// (signed-fixture) end-to-end happy path.
    @Test(.tags(.live))
    func scriptRefusesUnsignedThrowawayBundleAndLeavesInstalledBundleIntact() throws {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let installDir = scratchRoot.appendingPathComponent("install")
        let bundleDir = installDir.appendingPathComponent("VPN Switch.app")
        try FileManager.default.createDirectory(at: bundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let markerURL = bundleDir.appendingPathComponent("Contents/marker.txt")
        try Data("old".utf8).write(to: markerURL)

        // Build a real throwaway DMG containing an unsigned "VPN Switch.app"
        // -- this must be refused by the new Team ID re-verification step.
        let volName = uniqueVolumeName("VPN Switch Test Unsigned")
        let dmgSourceDir = scratchRoot.appendingPathComponent("dmgsrc")
        let newBundleDir = dmgSourceDir.appendingPathComponent("VPN Switch.app")
        try FileManager.default.createDirectory(at: newBundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newBundleDir.appendingPathComponent("Contents/marker.txt"))

        let dmgPath = scratchRoot.appendingPathComponent("update.dmg").path
        let createDMG = Process()
        createDMG.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createDMG.arguments = ["create", "-srcfolder", dmgSourceDir.path, "-volname", volName, "-format", "UDZO", "-quiet", dmgPath]
        createDMG.standardOutput = Pipe()
        createDMG.standardError = Pipe()
        try createDMG.run()
        createDMG.waitUntilExit()
        #expect(createDMG.terminationStatus == 0)

        let script = UpdateSwapScript.generate(
            dmgPath: dmgPath,
            parentPID: try pidOfAlreadyExitedProcess(),
            installDir: installDir.path,
            bundleName: "VPN Switch.app",
            relaunch: false
        )

        let scriptURL = scratchRoot.appendingPathComponent("swap.sh")
        try writeAndMakeExecutable(script, at: scriptURL)

        let (status, output) = try runScript(at: scriptURL)
        print("UNSIGNED-BUNDLE SCRIPT OUTPUT:\n\(output)")
        print("UNSIGNED-BUNDLE EXIT STATUS: \(status)")

        #expect(status != 0)
        #expect(output.contains("does not satisfy the designated requirement"))

        // The installed (old) bundle must be untouched -- rm -rf must never
        // have run.
        let markerContents = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(markerContents.trimmingCharacters(in: .whitespacesAndNewlines) == "old")

        // No leaked mount.
        #expect(!(try volumeIsMounted(named: volName)))
    }

    /// POSITIVE end-to-end test: copies the REAL installed, Developer-ID
    /// signed "VPN Switch.app" (preserving its signature via `ditto`) into
    /// both a throwaway "old" install dir and a throwaway "new" DMG source
    /// dir, builds a real DMG, and runs the generated script for real. This
    /// is the only test that proves a genuinely signed, Team-ID-matching
    /// bundle is ACCEPTED by the new re-verification step, not merely that
    /// unsigned ones are rejected.
    ///
    /// Skips cleanly (not a failure) when `/Applications/VPN Switch.app`
    /// isn't present or doesn't satisfy the designated requirement -- CI
    /// has no installed app, so this is expected to skip there; it is
    /// intended to run locally after `make cut`/`install-vpn-switch.sh`.
    @Test(.tags(.live))
    func scriptSwapsRealSignedAppEndToEnd() throws {
        let installedAppPath = "/Applications/VPN Switch.app"
        guard FileManager.default.fileExists(atPath: installedAppPath) else {
            print("SKIPPING scriptSwapsRealSignedAppEndToEnd: \(installedAppPath) does not exist in this environment")
            return
        }
        let verifyProcess = Process()
        verifyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProcess.arguments = ["--verify", "--deep", "--strict", "-R=\(UpdateInstaller.designatedRequirement)", installedAppPath]
        verifyProcess.standardOutput = Pipe()
        verifyProcess.standardError = Pipe()
        try verifyProcess.run()
        verifyProcess.waitUntilExit()
        guard verifyProcess.terminationStatus == 0 else {
            print("SKIPPING scriptSwapsRealSignedAppEndToEnd: \(installedAppPath) does not satisfy the designated requirement in this environment")
            return
        }

        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        // "Old" installed bundle: a ditto copy of the real signed app,
        // preserving its signature, at a throwaway install path.
        let installDir = scratchRoot.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let oldBundlePath = installDir.appendingPathComponent("VPN Switch.app").path
        try runDitto(from: installedAppPath, to: oldBundlePath)

        // "New" bundle for the DMG: another ditto copy of the same real
        // signed app, into the DMG source directory.
        let volName = uniqueVolumeName("VPN Switch Test Signed")
        let dmgSourceDir = scratchRoot.appendingPathComponent("dmgsrc")
        try FileManager.default.createDirectory(at: dmgSourceDir, withIntermediateDirectories: true)
        let newBundlePath = dmgSourceDir.appendingPathComponent("VPN Switch.app").path
        try runDitto(from: installedAppPath, to: newBundlePath)

        let dmgPath = scratchRoot.appendingPathComponent("update.dmg").path
        let createDMG = Process()
        createDMG.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createDMG.arguments = ["create", "-srcfolder", dmgSourceDir.path, "-volname", volName, "-format", "UDZO", "-quiet", dmgPath]
        createDMG.standardOutput = Pipe()
        createDMG.standardError = Pipe()
        try createDMG.run()
        createDMG.waitUntilExit()
        #expect(createDMG.terminationStatus == 0)

        let script = UpdateSwapScript.generate(
            dmgPath: dmgPath,
            parentPID: try pidOfAlreadyExitedProcess(),
            installDir: installDir.path,
            bundleName: "VPN Switch.app",
            relaunch: false
        )

        let scriptURL = scratchRoot.appendingPathComponent("swap.sh")
        try writeAndMakeExecutable(script, at: scriptURL)

        let (status, output) = try runScript(at: scriptURL)
        print("SIGNED-BUNDLE SCRIPT OUTPUT:\n\(output)")
        print("SIGNED-BUNDLE EXIT STATUS: \(status)")

        #expect(status == 0)
        #expect(output.contains("update complete"))
        #expect(FileManager.default.fileExists(atPath: oldBundlePath))

        // No leaked mount.
        #expect(!(try volumeIsMounted(named: volName)))
    }

    /// When `expectedSHA256` is supplied but does not match the DMG on
    /// disk, the script must refuse and exit nonzero BEFORE `hdiutil
    /// attach` ever runs -- i.e. before anything is mounted, and with the
    /// old (installed) bundle completely untouched.
    @Test(.tags(.live))
    func scriptRefusesWhenExpectedSHA256DoesNotMatchAndNeverAttaches() throws {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let installDir = scratchRoot.appendingPathComponent("install")
        let bundleDir = installDir.appendingPathComponent("VPN Switch.app")
        try FileManager.default.createDirectory(at: bundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let markerURL = bundleDir.appendingPathComponent("Contents/marker.txt")
        try Data("old".utf8).write(to: markerURL)

        let volName = uniqueVolumeName("VPN Switch Test BadDigest")
        let dmgSourceDir = scratchRoot.appendingPathComponent("dmgsrc")
        let newBundleDir = dmgSourceDir.appendingPathComponent("VPN Switch.app")
        try FileManager.default.createDirectory(at: newBundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newBundleDir.appendingPathComponent("Contents/marker.txt"))

        let dmgPath = scratchRoot.appendingPathComponent("update.dmg").path
        let createDMG = Process()
        createDMG.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createDMG.arguments = ["create", "-srcfolder", dmgSourceDir.path, "-volname", volName, "-format", "UDZO", "-quiet", dmgPath]
        createDMG.standardOutput = Pipe()
        createDMG.standardError = Pipe()
        try createDMG.run()
        createDMG.waitUntilExit()
        #expect(createDMG.terminationStatus == 0)

        // Deliberately wrong digest -- real digest is computed but never
        // used, so this is guaranteed to mismatch.
        let wrongDigest = String(repeating: "0", count: 64)
        let realDigest = try shasum256Hex(ofFileAt: dmgPath)
        #expect(realDigest != wrongDigest)

        let script = UpdateSwapScript.generate(
            dmgPath: dmgPath,
            parentPID: try pidOfAlreadyExitedProcess(),
            installDir: installDir.path,
            bundleName: "VPN Switch.app",
            relaunch: false,
            expectedSHA256: wrongDigest
        )

        let scriptURL = scratchRoot.appendingPathComponent("swap.sh")
        try writeAndMakeExecutable(script, at: scriptURL)

        let (status, output) = try runScript(at: scriptURL)
        print("BAD-DIGEST SCRIPT OUTPUT:\n\(output)")
        print("BAD-DIGEST EXIT STATUS: \(status)")

        #expect(status != 0)
        #expect(output.contains("refusing to install: DMG digest changed since verification"))
        // Never reached hdiutil attach.
        #expect(!output.contains("mounted at"))

        let markerContents = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(markerContents.trimmingCharacters(in: .whitespacesAndNewlines) == "old")

        #expect(!(try volumeIsMounted(named: volName)))
    }

    /// Copies `sourcePath` to `destinationPath` using `/usr/bin/ditto`,
    /// which (unlike a naive recursive file copy) preserves code-signing
    /// metadata and extended attributes, so the copy remains validly
    /// signed.
    private func runDitto(from sourcePath: String, to destinationPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [sourcePath, destinationPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            Issue.record("ditto \(sourcePath) -> \(destinationPath) failed: \(output)")
        }
        #expect(process.terminationStatus == 0)
    }
}
