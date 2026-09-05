import Foundation

/// Keeps the control scripts (bin/vpn-ctl.sh, lib/*.sh, config/lan-hosts.conf)
/// under `~/Library/Application Support/vpn-switch` in sync with the copies
/// shipped inside the app bundle (see app/build.sh, dns-config-8v7.3).
///
/// WHY: a self-update replaces only the .app; the scripts the app drives are
/// installed separately (bin/install-vpn-switch.sh) and would otherwise go
/// stale after an update. The app now carries its own copy of those scripts
/// under Contents/Resources/vpn-switch and syncs them into the installed
/// location on every launch (and via `--sync-scripts` for scripting/tests).
///
/// The scripts themselves always RUN from the installed location, never from
/// inside the signed bundle: vpn-ctl.sh creates a lock directory next to
/// itself, and writing inside the app bundle at runtime would invalidate the
/// code signature.
enum ScriptBundle {
    /// Name of the small marker file written into the installed root after a
    /// successful sync, recording which bundled VERSION was last synced.
    static let stampFileName = ".installed-version"

    /// The root of the scripts shipped inside the app bundle
    /// (Contents/Resources/vpn-switch), if present.
    static func bundledRoot(in bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let root = resourceURL.appendingPathComponent("vpn-switch", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return root
    }

    /// The current user's home directory, preferring the `HOME` environment
    /// variable over `FileManager.homeDirectoryForCurrentUser` when it is
    /// set: the latter resolves via directory services and ignores `$HOME`
    /// entirely, which would make it impossible to safely exercise script
    /// syncing (which writes real files) against a temp directory rather
    /// than the operator's actual Application Support folder.
    static func currentHomeDirectory() -> URL {
        if let homeEnv = ProcessInfo.processInfo.environment["HOME"], !homeEnv.isEmpty {
            return URL(fileURLWithPath: homeEnv, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The installed root the scripts run from:
    /// `~/Library/Application Support/vpn-switch`.
    static func installedRoot(home: URL = ScriptBundle.currentHomeDirectory()) -> URL {
        home.appendingPathComponent("Library/Application Support/vpn-switch", isDirectory: true)
    }

    /// Pure decision function: should a sync run?
    ///
    /// - `bundledVersion == nil` (no bundled scripts / no VERSION file found)
    ///   -> false, there is nothing to sync from.
    /// - Otherwise true when the installed stamp doesn't match the bundled
    ///   version, OR vpn-ctl.sh isn't present at the installed location at
    ///   all (fresh install / scripts never installed / accidentally
    ///   deleted), OR `contentsDiffer` is true (a bundled script's bytes no
    ///   longer match the installed copy, even though the version stamp
    ///   matches -- e.g. the installed lib was hand-edited, corrupted, or
    ///   tampered with; dns-config-ci5 PART C self-healing).
    static func needsSync(
        bundledVersion: String?,
        installedStamp: String?,
        vpnCtlPresent: Bool,
        contentsDiffer: Bool = false
    ) -> Bool {
        guard let bundledVersion else { return false }
        if installedStamp != bundledVersion { return true }
        if !vpnCtlPresent { return true }
        if contentsDiffer { return true }
        return false
    }

    /// Compares every file `sync(from:to:)` would copy (bin/vpn-ctl.sh,
    /// lib/*.sh, config/lan-hosts.conf) byte-for-byte between the bundled
    /// and installed trees. Returns `true` (contents differ / need sync) if
    /// ANY of those files differs, including when a bundled file is simply
    /// missing on the installed side. Deliberately mirrors `sync`'s own
    /// file allowlist -- it must NEVER be extended to compare credential
    /// files (nord-ikev2.env, *.mobileconfig), which are intentionally
    /// excluded from both functions.
    ///
    /// Used to detect a tampered or stale installed copy even when the
    /// version stamp still matches (needsSync's other checks are stamp/
    /// presence based and would otherwise miss that case).
    static func installedContentMatches(bundleDir: URL, installDir: URL) -> Bool {
        let fm = FileManager.default

        func filesMatch(_ a: URL, _ b: URL) -> Bool {
            guard let dataA = try? Data(contentsOf: a), let dataB = try? Data(contentsOf: b) else {
                return false
            }
            return dataA == dataB
        }

        // bin/vpn-ctl.sh
        let vpnCtlSrc = bundleDir.appendingPathComponent("bin/vpn-ctl.sh")
        if fm.fileExists(atPath: vpnCtlSrc.path) {
            let dest = installDir.appendingPathComponent("bin/vpn-ctl.sh")
            if !fm.fileExists(atPath: dest.path) { return false }
            if !filesMatch(vpnCtlSrc, dest) { return false }
        }

        // lib/*.sh
        let libSrcDir = bundleDir.appendingPathComponent("lib", isDirectory: true)
        if let libFiles = try? fm.contentsOfDirectory(at: libSrcDir, includingPropertiesForKeys: nil) {
            for libFile in libFiles where libFile.pathExtension == "sh" {
                let dest = installDir.appendingPathComponent("lib/\(libFile.lastPathComponent)")
                if !fm.fileExists(atPath: dest.path) { return false }
                if !filesMatch(libFile, dest) { return false }
            }
        }

        // config/lan-hosts.conf
        let lanHostsSrc = bundleDir.appendingPathComponent("config/lan-hosts.conf")
        if fm.fileExists(atPath: lanHostsSrc.path) {
            let dest = installDir.appendingPathComponent("config/lan-hosts.conf")
            if !fm.fileExists(atPath: dest.path) { return false }
            if !filesMatch(lanHostsSrc, dest) { return false }
        }

        return true
    }

    /// Errors surfaced by `sync(from:to:)`.
    enum SyncError: Error {
        case missingSource(String)
    }

    /// Copies the control scripts from `bundled` into `installed`.
    ///
    /// Copies (when present in `bundled`):
    ///   - bin/vpn-ctl.sh
    ///   - every lib/*.sh file present under bundled/lib
    ///   - config/lan-hosts.conf
    ///
    /// Each file is written atomically: the new content is written to a
    /// sibling temp file (`<dest>.tmp-<uuid>`) in the destination directory,
    /// then swapped into place with `replaceItemAt`/rename. `.sh` files are
    /// given mode 0755 after the swap. Destination directories are created
    /// as needed.
    ///
    /// Finally writes `stampFileName` at the installed root containing the
    /// bundled VERSION file's contents (trimmed of whitespace/newlines).
    ///
    /// Returns the relative paths (relative to `installed`) that were
    /// written, including the stamp file.
    ///
    /// This function touches ONLY the files listed above (plus the stamp) --
    /// it never enumerates or deletes anything else under `installed` (e.g.
    /// dnsmasq conf, home-arpa.hosts, nord-ikev2.env, LaunchAgent artefacts
    /// all remain untouched).
    @discardableResult
    static func sync(from bundled: URL, to installed: URL) throws -> [String] {
        let fm = FileManager.default
        var written: [String] = []

        func atomicCopy(sourceFile: URL, destFile: URL, executable: Bool) throws {
            let destDir = destFile.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let tmpFile = destDir.appendingPathComponent(
                "\(destFile.lastPathComponent).tmp-\(UUID().uuidString)"
            )
            // Clean up any stale temp file at that exact name (won't
            // normally exist given the UUID, but be defensive) before
            // copying fresh content into it.
            try? fm.removeItem(at: tmpFile)
            try fm.copyItem(at: sourceFile, to: tmpFile)
            if executable {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpFile.path)
            }
            do {
                _ = try fm.replaceItemAt(destFile, withItemAt: tmpFile)
            } catch {
                // replaceItemAt requires destFile's parent to exist, which it
                // does, but if destFile itself doesn't exist yet on some
                // platforms replaceItemAt still works (it creates it) -- if
                // this ever fails, clean up the temp file and rethrow.
                try? fm.removeItem(at: tmpFile)
                throw error
            }
        }

        // bin/vpn-ctl.sh
        let vpnCtlSrc = bundled.appendingPathComponent("bin/vpn-ctl.sh")
        if fm.fileExists(atPath: vpnCtlSrc.path) {
            let dest = installed.appendingPathComponent("bin/vpn-ctl.sh")
            try atomicCopy(sourceFile: vpnCtlSrc, destFile: dest, executable: true)
            written.append("bin/vpn-ctl.sh")
        }

        // lib/*.sh
        let libSrcDir = bundled.appendingPathComponent("lib", isDirectory: true)
        if let libFiles = try? fm.contentsOfDirectory(at: libSrcDir, includingPropertiesForKeys: nil) {
            for libFile in libFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard libFile.pathExtension == "sh" else { continue }
                let dest = installed.appendingPathComponent("lib/\(libFile.lastPathComponent)")
                try atomicCopy(sourceFile: libFile, destFile: dest, executable: true)
                written.append("lib/\(libFile.lastPathComponent)")
            }
        }

        // config/lan-hosts.conf
        let lanHostsSrc = bundled.appendingPathComponent("config/lan-hosts.conf")
        if fm.fileExists(atPath: lanHostsSrc.path) {
            let dest = installed.appendingPathComponent("config/lan-hosts.conf")
            try atomicCopy(sourceFile: lanHostsSrc, destFile: dest, executable: false)
            written.append("config/lan-hosts.conf")
        }

        // Stamp file, from the bundled VERSION contents (trimmed).
        let versionSrc = bundled.appendingPathComponent("VERSION")
        let versionContents = (try? String(contentsOf: versionSrc, encoding: .utf8)) ?? ""
        let trimmed = versionContents.trimmingCharacters(in: .whitespacesAndNewlines)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        let stampDest = installed.appendingPathComponent(stampFileName)
        let stampTmp = installed.appendingPathComponent(".\(stampFileName).tmp-\(UUID().uuidString)")
        try? fm.removeItem(at: stampTmp)
        try trimmed.write(to: stampTmp, atomically: false, encoding: .utf8)
        do {
            _ = try fm.replaceItemAt(stampDest, withItemAt: stampTmp)
        } catch {
            try? fm.removeItem(at: stampTmp)
            throw error
        }
        written.append(stampFileName)

        return written
    }

    /// Reads the bundled VERSION file's contents (trimmed), if present.
    private static func bundledVersion(at bundledRoot: URL) -> String? {
        let versionURL = bundledRoot.appendingPathComponent("VERSION")
        guard let contents = try? String(contentsOf: versionURL, encoding: .utf8) else { return nil }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the installed stamp file's contents (trimmed), if present.
    private static func installedStamp(at installedRoot: URL) -> String? {
        let stampURL = installedRoot.appendingPathComponent(stampFileName)
        guard let contents = try? String(contentsOf: stampURL, encoding: .utf8) else { return nil }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Syncs the bundled scripts into the installed location if needed.
    /// Synchronous (a handful of small files); safe to call from app launch.
    /// Never throws -- any error is logged via NSLog and treated as "nothing
    /// synced" (returns `[]`).
    @discardableResult
    static func syncIfNeeded(
        bundle: Bundle = .main,
        home: URL = ScriptBundle.currentHomeDirectory()
    ) -> [String] {
        guard let bundledRootURL = bundledRoot(in: bundle) else {
            NSLog("ScriptBundle: no bundled scripts found (Contents/Resources/vpn-switch missing); skipping sync")
            return []
        }
        let installedRootURL = installedRoot(home: home)
        let bundledVer = bundledVersion(at: bundledRootURL)
        let installedVer = installedStamp(at: installedRootURL)
        let vpnCtlPresent = FileManager.default.fileExists(
            atPath: installedRootURL.appendingPathComponent("bin/vpn-ctl.sh").path
        )
        let contentsDiffer = !installedContentMatches(bundleDir: bundledRootURL, installDir: installedRootURL)

        guard needsSync(
            bundledVersion: bundledVer,
            installedStamp: installedVer,
            vpnCtlPresent: vpnCtlPresent,
            contentsDiffer: contentsDiffer
        ) else {
            NSLog("ScriptBundle: installed scripts up to date (version \(installedVer ?? "unknown")); skipping sync")
            return []
        }

        do {
            let written = try sync(from: bundledRootURL, to: installedRootURL)
            NSLog("ScriptBundle: synced scripts to \(installedRootURL.path): \(written.joined(separator: ", "))")
            return written
        } catch {
            NSLog("ScriptBundle: failed to sync scripts to \(installedRootURL.path): \(error)")
            return []
        }
    }
}
