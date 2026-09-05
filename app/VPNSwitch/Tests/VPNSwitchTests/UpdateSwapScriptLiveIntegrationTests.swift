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

    /// installDir exists but does NOT contain the installed bundle. Even
    /// with a REAL DMG available to attach, the script must refuse before
    /// ever reaching the destructive `rm -rf`, and must still detach the
    /// mount it opened along the way (no leaked `/Volumes` entry).
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
        // the new missing-installed-bundle guard.
        let volName = uniqueVolumeName("VPN Switch Test Missing")
        let dmgSourceDir = scratchRoot.appendingPathComponent("dmgsrc")
        let newBundleDir = dmgSourceDir.appendingPathComponent("VPN Switch.app/Contents")
        try FileManager.default.createDirectory(at: newBundleDir, withIntermediateDirectories: true)
        try Data("NEW".utf8).write(to: newBundleDir.appendingPathComponent("marker.txt"))

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

    /// Full happy-path live run against a REAL (throwaway) DMG built with
    /// `hdiutil create`, proving attach -> python3 plist parse -> installed-
    /// bundle-exists guard -> rm -rf old -> cp -R new -> detach actually
    /// replaces a throwaway bundle end to end. Runs with `relaunch: false`
    /// (parentPID belongs to an already-exited process) so the script never
    /// spawns `open` against the test fixture. Never touches the real
    /// installed app.
    @Test(.tags(.live))
    func scriptSwapsThrowawayBundleEndToEndWithRealDMG() throws {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let installDir = scratchRoot.appendingPathComponent("install")
        let bundleDir = installDir.appendingPathComponent("VPN Switch.app")
        try FileManager.default.createDirectory(at: bundleDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let markerURL = bundleDir.appendingPathComponent("Contents/marker.txt")
        try Data("old".utf8).write(to: markerURL)

        // Build a real throwaway DMG containing a fresh "VPN Switch.app"
        // whose marker.txt differs from the old one, so the test can prove
        // the OLD bundle's contents are gone and the NEW bundle's contents
        // are in place after the swap — not just that "some bundle" exists.
        let volName = uniqueVolumeName("VPN Switch Test")
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
        print("HAPPY-PATH SCRIPT OUTPUT:\n\(output)")
        print("HAPPY-PATH EXIT STATUS: \(status)")

        #expect(status == 0)
        #expect(output.contains("update complete"))

        let markerContents = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(markerContents.trimmingCharacters(in: .whitespacesAndNewlines) == "new")

        // Confirm the mount was detached — no leaked /Volumes entry for
        // this test's throwaway volume.
        let mountCheck = Process()
        mountCheck.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let mountPipe = Pipe()
        mountCheck.standardOutput = mountPipe
        try mountCheck.run()
        mountCheck.waitUntilExit()
        let mountOutput = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(!mountOutput.lowercased().contains(volName.lowercased()))
    }
}
