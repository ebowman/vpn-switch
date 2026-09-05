import Testing
import Foundation
@testable import VPNSwitch

/// Covers ScriptBundle's pure decision function (`needsSync`) and the file
/// I/O half (`sync(from:to:)`), which are independently testable and
/// together cover `syncIfNeeded`'s composition (dns-config-8v7.3).
struct ScriptBundleTests {

    // MARK: - needsSync truth table

    @Test func needsSyncFalseWhenNoBundledVersion() {
        #expect(ScriptBundle.needsSync(bundledVersion: nil, installedStamp: "1.0+1", vpnCtlPresent: true) == false)
        #expect(ScriptBundle.needsSync(bundledVersion: nil, installedStamp: nil, vpnCtlPresent: false) == false)
    }

    @Test func needsSyncFalseWhenStampEqualAndPresent() {
        #expect(ScriptBundle.needsSync(bundledVersion: "1.0+1", installedStamp: "1.0+1", vpnCtlPresent: true) == false)
    }

    @Test func needsSyncTrueWhenStampDiffers() {
        #expect(ScriptBundle.needsSync(bundledVersion: "1.1+2", installedStamp: "1.0+1", vpnCtlPresent: true) == true)
    }

    @Test func needsSyncTrueWhenStampEqualButVpnCtlMissing() {
        #expect(ScriptBundle.needsSync(bundledVersion: "1.0+1", installedStamp: "1.0+1", vpnCtlPresent: false) == true)
    }

    @Test func needsSyncTrueWhenStampNil() {
        #expect(ScriptBundle.needsSync(bundledVersion: "1.0+1", installedStamp: nil, vpnCtlPresent: true) == true)
    }

    // MARK: - sync(from:to:)

    /// Builds a fabricated "bundled" tree at `root`:
    ///   bin/vpn-ctl.sh, lib/a.sh, lib/b.sh, config/lan-hosts.conf, VERSION
    private func makeBundledTree(at root: URL, version: String = "9.9+9") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)

        try "#!/bin/bash\necho vpn-ctl-new\n".write(
            to: root.appendingPathComponent("bin/vpn-ctl.sh"), atomically: true, encoding: .utf8
        )
        try "#!/bin/bash\necho a\n".write(
            to: root.appendingPathComponent("lib/a.sh"), atomically: true, encoding: .utf8
        )
        try "#!/bin/bash\necho b\n".write(
            to: root.appendingPathComponent("lib/b.sh"), atomically: true, encoding: .utf8
        )
        try "127.0.0.1 example.lan\n".write(
            to: root.appendingPathComponent("config/lan-hosts.conf"), atomically: true, encoding: .utf8
        )
        try "\(version)\n".write(to: root.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func syncWritesExactlyExpectedFilesAndStamp() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let bundled = base.appendingPathComponent("bundled")
        let installed = base.appendingPathComponent("installed")
        try makeBundledTree(at: bundled, version: "9.9+9")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        let written = try ScriptBundle.sync(from: bundled, to: installed)

        #expect(Set(written) == Set([
            "bin/vpn-ctl.sh", "lib/a.sh", "lib/b.sh", "config/lan-hosts.conf", ScriptBundle.stampFileName,
        ]))

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("bin/vpn-ctl.sh").path))
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("lib/a.sh").path))
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("lib/b.sh").path))
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("config/lan-hosts.conf").path))

        let stamp = try String(
            contentsOf: installed.appendingPathComponent(ScriptBundle.stampFileName), encoding: .utf8
        )
        #expect(stamp.trimmingCharacters(in: .whitespacesAndNewlines) == "9.9+9")
    }

    @Test func syncedShellFilesAreExecutable() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let bundled = base.appendingPathComponent("bundled")
        let installed = base.appendingPathComponent("installed")
        try makeBundledTree(at: bundled)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        _ = try ScriptBundle.sync(from: bundled, to: installed)

        let fm = FileManager.default
        for relPath in ["bin/vpn-ctl.sh", "lib/a.sh", "lib/b.sh"] {
            let attrs = try fm.attributesOfItem(atPath: installed.appendingPathComponent(relPath).path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(perms & 0o777 == 0o755, "\(relPath) expected 0755, got \(String(format: "%o", perms))")
        }
    }

    @Test func syncLeavesUnrelatedFileByteIdentical() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let bundled = base.appendingPathComponent("bundled")
        let installed = base.appendingPathComponent("installed")
        try makeBundledTree(at: bundled)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        let unrelated = installed.appendingPathComponent("home-arpa.hosts")
        let unrelatedContent = "192.0.2.1 something.home.arpa\n"
        try unrelatedContent.write(to: unrelated, atomically: true, encoding: .utf8)

        _ = try ScriptBundle.sync(from: bundled, to: installed)

        let after = try String(contentsOf: unrelated, encoding: .utf8)
        #expect(after == unrelatedContent)
    }

    @Test func syncReplacesExistingOlderVpnCtl() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let bundled = base.appendingPathComponent("bundled")
        let installed = base.appendingPathComponent("installed")
        try makeBundledTree(at: bundled)
        try FileManager.default.createDirectory(
            at: installed.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        let oldContent = "#!/bin/bash\necho vpn-ctl-OLD\n"
        try oldContent.write(
            to: installed.appendingPathComponent("bin/vpn-ctl.sh"), atomically: true, encoding: .utf8
        )

        _ = try ScriptBundle.sync(from: bundled, to: installed)

        let newContent = try String(
            contentsOf: installed.appendingPathComponent("bin/vpn-ctl.sh"), encoding: .utf8
        )
        #expect(newContent != oldContent)
        #expect(newContent.contains("vpn-ctl-new"))
    }

    @Test func syncLeavesNoTmpLeftovers() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let bundled = base.appendingPathComponent("bundled")
        let installed = base.appendingPathComponent("installed")
        try makeBundledTree(at: bundled)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        _ = try ScriptBundle.sync(from: bundled, to: installed)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: installed, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate installed dir")
            return
        }
        var tmpLeftovers: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.contains(".tmp-") {
                tmpLeftovers.append(url.path)
            }
        }
        #expect(tmpLeftovers.isEmpty, "found leftover tmp files: \(tmpLeftovers)")
    }
}
