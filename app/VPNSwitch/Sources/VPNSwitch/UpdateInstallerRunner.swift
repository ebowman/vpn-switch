import AppKit
import Foundation
import os

/// Errors from `UpdateInstallerRunner.launchSwap(dmgURL:expectedSHA256:beforeTerminate:)`.
///
/// Every case here is thrown BEFORE anything irreversible happens — the
/// installed bundle is only ever touched by the detached script AFTER this
/// function has already returned successfully, `beforeTerminate()` has run,
/// and `NSApp.terminate(nil)` has been called. See `UpdateInstallerRunner`'s
/// doc comment for the full ordering guarantee.
enum UpdateSwapError: Error {
    /// Writing the generated script to `NSTemporaryDirectory()` failed.
    case scriptWriteFailed(String)

    /// Marking the script executable (mode 0755) failed.
    case scriptPermissionsFailed(String)

    /// Launching the detached `/bin/sh -c` process failed.
    case launchFailed(String)

    /// Creating the log directory (`~/Library/Logs/vpn-switch`, mode 0700)
    /// failed. The app is left completely untouched.
    case logDirectoryCreationFailed(String)
}

/// Performs the self-replacing update swap: writes a detached `/bin/sh`
/// script, launches it, and terminates this app so the script can safely
/// replace the running bundle.
///
/// ## Order of operations is the safety property
///
/// `UpdateInstallerRunner.launchSwap(dmgURL:expectedSHA256:beforeTerminate:)` is called
/// ONLY after `UpdateInstaller.verify(dmgURL:manifest:)` has already
/// succeeded (see `UpdateChecker`, the caller) — that is this whole
/// feature's security boundary, and it is not re-checked or re-validated
/// here. Within THIS function, everything that can fail (writing the
/// script, chmod'ing it, launching it) is attempted BEFORE
/// `beforeTerminate()` and `NSApp.terminate(nil)` are called, and every
/// failure throws rather than proceeding. The running app is UNTOUCHED if
/// this function throws for any reason. Once `beforeTerminate()` and
/// `NSApp.terminate(nil)` run, control has left this process for good --
/// there is no later point at which a failure here could still be reported
/// to the user, which is exactly why every prior step fails loudly and
/// nothing is skipped or reordered "as an optimisation". Once the detached
/// script's own destructive steps run, the only recovery is
/// `~/Library/Logs/vpn-switch/update.log` (the script's own stdout/stderr,
/// redirected there by the `nohup` launch below) -- this function's entire
/// job is to make sure that irreversible step is only ever reached with a
/// verified DMG and a successfully-launched script.
///
/// `beforeTerminate` exists so the caller (`AppModel.checkForUpdates()`,
/// via `UpdateChecker`) can run its own pre-termination teardown --
/// `AppModel.prepareForTermination()`, the same teardown Quit performs
/// (stop polling, discard pending queued actions, terminate any
/// vpn-ctl.sh child already in flight) -- at exactly the right point: after
/// the script has been verified launchable, but before this process
/// actually exits.
@MainActor
enum UpdateInstallerRunner {
    private static let logger = Logger(subsystem: "com.vpnswitch", category: "update-installer")

    /// `~/Library/Logs/vpn-switch/update.log`, computed at runtime (never a
    /// literal path) so it always resolves against the actual invoking
    /// user's home directory. Previously `/tmp/vpn-switch-update.log`: a
    /// predictable name in a world-writable directory, opened with `>>` by
    /// the detached script, that another local user could pre-create as a
    /// symlink. `~/Library/Logs/<subdir>` is a per-user directory this
    /// process creates itself (mode 0700, see `ensureLogDirectory()`)
    /// immediately before use.
    static var updateLogPath: String {
        logDirectoryURL.appendingPathComponent("update.log").path
    }

    private static var logDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/vpn-switch")
    }

    /// Creates `~/Library/Logs/vpn-switch` (mode 0700) if it does not
    /// already exist. Called before the detached script is launched, so a
    /// failure here throws `UpdateSwapError.logDirectoryCreationFailed`
    /// and leaves the app completely untouched -- consistent with every
    /// other failure mode in `launchSwap`.
    static func ensureLogDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw UpdateSwapError.logDirectoryCreationFailed(error.localizedDescription)
        }
    }

    /// Writes `text` to a fresh, unique path under `NSTemporaryDirectory()`
    /// and marks it executable (mode 0755).
    ///
    /// Factored out of `launchSwap` so it can be unit-tested directly
    /// without needing to launch a process or terminate the app -- see
    /// `UpdateInstallerRunnerTests`.
    ///
    /// - Returns: the `URL` the script was written to.
    /// - Throws: `UpdateSwapError.scriptWriteFailed` if the write itself
    ///   failed, or `UpdateSwapError.scriptPermissionsFailed` if marking it
    ///   executable failed.
    static func writeSwapScript(text: String) throws -> URL {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpn-switch-update-\(UUID().uuidString).sh")

        do {
            try text.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw UpdateSwapError.scriptWriteFailed(error.localizedDescription)
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw UpdateSwapError.scriptPermissionsFailed(error.localizedDescription)
        }

        return scriptURL
    }

    /// Writes the swap script, launches it detached, runs
    /// `beforeTerminate()`, and terminates this app.
    ///
    /// - Parameters:
    ///   - dmgURL: a `file://` URL to a DMG that has ALREADY passed
    ///     `UpdateInstaller.verify(dmgURL:manifest:)`. This function does
    ///     not re-verify it -- callers must not call this with an
    ///     unverified DMG.
    ///   - expectedSHA256: the digest `UpdateInstaller.verify` already
    ///     confirmed for this DMG (i.e. `manifest.dmgSHA256`), forwarded
    ///     into the generated script so it can re-check the DMG on disk
    ///     immediately before `hdiutil attach` -- see
    ///     `UpdateSwapScript.generate`'s doc comment for why this closes a
    ///     TOCTOU window. No default: callers must be explicit about
    ///     whether a re-check digest is available.
    ///   - beforeTerminate: run after the detached script has been
    ///     successfully launched but before `NSApp.terminate(nil)` -- see
    ///     the type's doc comment for why this ordering matters.
    /// - Throws: `UpdateSwapError` if the script could not be written, made
    ///   executable, or launched. The app is left completely untouched (and
    ///   `beforeTerminate` is NOT called) in every throwing case --
    ///   `beforeTerminate()` and `NSApp.terminate(nil)` are only reached
    ///   after the launch itself has succeeded.
    static func launchSwap(dmgURL: URL, expectedSHA256: String?, beforeTerminate: () -> Void) throws {
        try ensureLogDirectory()

        let bundleURL = Bundle.main.bundleURL
        let installDir = bundleURL.deletingLastPathComponent().path
        let bundleName = bundleURL.lastPathComponent
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "ie.boboco.vpnswitch"

        let scriptText = UpdateSwapScript.generate(
            dmgPath: dmgURL.path,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            installDir: installDir,
            bundleName: bundleName,
            bundleIdentifier: bundleIdentifier,
            relaunch: true,
            expectedSHA256: expectedSHA256
        )

        let scriptURL = try writeSwapScript(text: scriptText)

        // Launched DETACHED: `nohup ... >>~/Library/Logs/vpn-switch/update.log 2>&1 &`
        // via `/bin/sh -c`, so the script keeps running after this process
        // exits (a plain child process would be killed along with its
        // parent on quit/terminate). All of the script's own output is
        // captured to updateLogPath -- the ONLY recovery path once the
        // script's destructive steps have run.
        let quotedScriptPath = UpdateSwapScript.shQuote(scriptURL.path)
        let quotedLogPath = UpdateSwapScript.shQuote(updateLogPath)
        let shellCommand = "nohup /bin/sh \(quotedScriptPath) >>\(quotedLogPath) 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]

        do {
            try process.run()
        } catch {
            throw UpdateSwapError.launchFailed(error.localizedDescription)
        }

        logger.notice("update swap script launched (pid target \(ProcessInfo.processInfo.processIdentifier)); terminating app")
        beforeTerminate()
        NSApp.terminate(nil)
    }
}
