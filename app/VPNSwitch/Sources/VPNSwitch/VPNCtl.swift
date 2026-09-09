import Foundation
#if canImport(Darwin)
import Darwin
#endif
import os

/// Result of running vpn-ctl.sh: exit code plus captured output.
struct VPNCtlResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// Timed out and was killed before completing (exit code is synthetic).
    let timedOut: Bool

    /// The last non-empty line from stderr, falling back to stdout -- used
    /// for surfacing error messages (exit-3 shortcut missing, exit-2 needs
    /// login, exit-4 app tunnel, etc.) per the vpn-ctl.sh exit code contract.
    var lastMessageLine: String? {
        func lastNonEmpty(_ s: String) -> String? {
            s.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
        }
        return lastNonEmpty(stderr) ?? lastNonEmpty(stdout)
    }
}

enum VPNCtlError: Error {
    case scriptNotFound(String)
}

/// Resolves and runs bin/vpn-ctl.sh.
///
/// PROCESS-GROUP TIMEOUT NOTE (dns-config-qsk.6 fold-in from qsk.5 review):
/// Foundation.Process offers no supported hook to pass posix_spawn attribute
/// flags (e.g. POSIX_SPAWN_SETSID) to the child it launches, so a
/// Process.terminate()/SIGTERM only ever reaches the direct child
/// (vpn-ctl.sh itself); a grandchild the script spawns and detaches (or one
/// left behind if bash itself doesn't forward the signal) can survive past
/// the 60s timeout. To close that gap, `run` below bypasses Process
/// entirely and calls posix_spawn(2) directly with
/// POSIX_SPAWN_SETSID set, which makes the child a new session/process
/// group leader. On timeout we then signal the whole group with
/// kill(-pid, SIGTERM), wait briefly, and if it's still alive escalate to
/// kill(-pid, SIGKILL) -- so a hung grandchild cannot outlive the timeout.
enum VPNCtl {
    static let userDefaultsKey = "vpnCtlPath"

    private static let logger = Logger(subsystem: "com.vpnswitch", category: "vpn-ctl")

    /// Fixed PATH handed to every vpn-ctl.sh child process. Deliberately
    /// excludes Homebrew's prefixes (/opt/homebrew/bin, /usr/local/... via
    /// brew, etc.): on this machine /opt/homebrew/bin and
    /// /opt/homebrew/sbin are group-admin writable, so a bare tool name
    /// (e.g. a dropped `timeout`) resolved via an inherited PATH could run
    /// with the app's identity on every toggle. Only the fixed system
    /// directories plus /usr/local/bin (needed for the Tailscale CLI) are
    /// included; lib/*.sh and bin/vpn-ctl.sh call every other tool by
    /// absolute path regardless.
    static let childPATH = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

    /// Builds the environment passed to the vpn-ctl.sh child process from
    /// the parent (app) environment, allowlisting only a small set of keys.
    ///
    /// WHY an allowlist rather than passing the parent environment through
    /// verbatim: PATH is inherited from the login session and could include
    /// group-writable directories (see `childPATH`'s doc comment) that let
    /// a same-user dropped binary hijack a bare tool invocation. Beyond
    /// PATH, environment variables the scripts themselves read as
    /// overrides for security-relevant binaries or behavior (TS_CTL_BIN,
    /// NORD_*, VPN_CTL_*, LAN_DNS_*, DYLD_*, etc.) would let any same-user
    /// process that can set the app's environment (or influence a launch
    /// context) redirect which binaries/paths vpn-ctl.sh and its libs
    /// actually run. Dropping everything except a minimal, inert set of
    /// locale/identity variables removes that whole class of override.
    ///
    /// PATH is always set to `childPATH`, regardless of what (if anything)
    /// the parent had. HOME, USER, LOGNAME, TMPDIR, LANG, LC_ALL, and
    /// LC_CTYPE are copied through only when present in `parent` -- they
    /// are needed for the scripts to resolve `$HOME`-relative paths and
    /// behave correctly under the user's locale, and carry no meaningful
    /// override risk.
    nonisolated static func childEnvironment(from parent: [String: String]) -> [String: String] {
        var env: [String: String] = ["PATH": childPATH]
        let passthroughKeys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        for key in passthroughKeys {
            if let value = parent[key] {
                env[key] = value
            }
        }
        return env
    }

    /// Ensures the "resolved to a non-default vpn-ctl.sh path" warning is
    /// logged at most once per process, no matter how many times `run` is
    /// called.
    private static let nonDefaultPathWarned = ThreadSafeBox(false)

    /// Registry of currently-spawned child pids (each its own process-group
    /// leader per POSIX_SPAWN_SETSID below), so the app's Quit path can
    /// signal any in-flight run's whole group even though `run` is
    /// synchronous and Task cancellation cannot interrupt it. Without this,
    /// quitting the app while a poll/toggle is blocked inside a slow or
    /// hung vpn-ctl.sh would leave that child (and any grandchildren) as
    /// orphans reparented to launchd.
    private static let liveGroups = ThreadSafeBox(Set<pid_t>())

    /// Sends SIGTERM (then, after a short grace period, SIGKILL) to every
    /// process group currently registered as in-flight. Called from the
    /// Quit menu item before NSApplication.terminate so no child outlives
    /// the app. Safe to call with nothing in-flight (no-op).
    static func terminateAllInFlight() {
        let groups = Array(liveGroups.value)
        guard !groups.isEmpty else { return }
        for pid in groups {
            kill(-pid, SIGTERM)
        }
        usleep(300_000)
        for pid in groups {
            kill(-pid, SIGKILL)
        }
    }

    /// Default (no-sudo) install location: user-writable, installed by
    /// bin/install-vpn-switch.sh (dns-config-qsk.7 DESIGN ADJUSTMENT --
    /// no sudo by default).
    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/vpn-switch/bin/vpn-ctl.sh").path
    }

    /// Opt-in system-wide install location (INSTALL_PREFIX=/usr/local,
    /// requires sudo -- the install script prints but never runs those
    /// commands). Tried after `defaultPath`.
    static let optInSystemPath = "/usr/local/bin/vpn-ctl.sh"

    /// Fallback used only if neither of the above is present -- a repo
    /// checkout at the conventional location. NOT the sole option, and not
    /// hard-coded as the only path: this is a last-resort fallback.
    static var fallbackPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("src/vpn-switch/bin/vpn-ctl.sh").path
    }

    /// Resolves the configured/effective script path per the resolution
    /// order (dns-config-qsk.7 DESIGN ADJUSTMENT): UserDefaults override ->
    /// ~/Library/Application Support/vpn-switch/bin/vpn-ctl.sh ->
    /// /usr/local/bin/vpn-ctl.sh -> ~/src/vpn-switch/bin/vpn-ctl.sh ->
    /// not found (nil).
    static func resolvedPath() -> String? {
        if let configured = UserDefaults.standard.string(forKey: userDefaultsKey),
           !configured.isEmpty,
           FileManager.default.isExecutableFile(atPath: configured) {
            warnIfNonDefaultPath(configured)
            return configured
        }
        if FileManager.default.isExecutableFile(atPath: defaultPath) {
            return defaultPath
        }
        if FileManager.default.isExecutableFile(atPath: optInSystemPath) {
            warnIfNonDefaultPath(optInSystemPath)
            return optInSystemPath
        }
        if FileManager.default.isExecutableFile(atPath: fallbackPath) {
            warnIfNonDefaultPath(fallbackPath)
            return fallbackPath
        }
        return nil
    }

    /// Logs a one-time-per-process warning when the resolved vpn-ctl.sh
    /// path is not the standard `defaultPath` install location -- i.e. the
    /// UserDefaults override or the opt-in/fallback paths are in play.
    /// Both the UserDefaults override and the ~/src fallback are same-user
    /// writable, so this is purely observability (surfaced in Console.app
    /// via the os.Logger subsystem), not an enforcement mechanism.
    private static func warnIfNonDefaultPath(_ path: String) {
        var alreadyWarned = false
        nonDefaultPathWarned.mutate { warned in
            alreadyWarned = warned
            warned = true
        }
        guard !alreadyWarned else { return }
        logger.warning("vpn-ctl resolved to non-default path \(path, privacy: .public)")
    }

    /// The path that would be reported to the user when nothing resolves --
    /// prefer showing the configured/default path, falling back to it.
    static func pathForDisplay() -> String {
        if let configured = UserDefaults.standard.string(forKey: userDefaultsKey), !configured.isEmpty {
            return configured
        }
        return defaultPath
    }

    /// Runs `vpn-ctl.sh <args...>` off the calling thread's expectations --
    /// this function itself is synchronous/blocking and MUST be called from
    /// a background context (Task.detached / a background DispatchQueue),
    /// never from the main thread. Hard timeout: 60s, after which the
    /// child's whole process group is signaled (SIGTERM, then SIGKILL after
    /// a grace period) and `timedOut=true` is returned.
    static func run(_ args: [String], timeout: TimeInterval = 60) -> Result<VPNCtlResult, VPNCtlError> {
        guard let path = resolvedPath() else {
            return .failure(.scriptNotFound(pathForDisplay()))
        }

        var stdoutFDs: [Int32] = [0, 0]
        var stderrFDs: [Int32] = [0, 0]
        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
            return .failure(.scriptNotFound(path))
        }
        let stdoutReadFD = stdoutFDs[0]
        let stdoutWriteFD = stdoutFDs[1]
        let stderrReadFD = stderrFDs[0]
        let stderrWriteFD = stderrFDs[1]

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        // Child's stdout/stderr -> the write ends of our pipes.
        posix_spawn_file_actions_adddup2(&fileActions, stdoutWriteFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrWriteFD, 2)
        // Close all four pipe fds in the child after the dup2s above -- the
        // dup'd targets (1, 2) stay open; the originals must not leak into
        // the child (in particular, an open read-end fd would let a
        // grandchild inherit and hold the pipe open after we've killed the
        // group we know about).
        posix_spawn_file_actions_addclose(&fileActions, stdoutReadFD)
        posix_spawn_file_actions_addclose(&fileActions, stdoutWriteFD)
        posix_spawn_file_actions_addclose(&fileActions, stderrReadFD)
        posix_spawn_file_actions_addclose(&fileActions, stderrWriteFD)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        // POSIX_SPAWN_SETSID (0x0400): child becomes a new session and
        // process-group leader, so kill(-pid, sig) below reaches it and any
        // grandchildren it spawns (they inherit its new pgid unless they
        // explicitly change it themselves).
        //
        // POSIX_SPAWN_SETSIGMASK / POSIX_SPAWN_SETSIGDEF (dns-config-du2):
        // `run` is documented above to require being called off the main
        // thread (Task.detached / a background DispatchQueue). Swift
        // concurrency and libdispatch worker threads run with nearly every
        // signal blocked at the pthread level (observed mask included
        // SIGTERM), and posix_spawn children normally INHERIT the calling
        // thread's signal mask -- so vpn-ctl.sh (and everything it in turn
        // spawns) would start with SIGTERM blocked. lib/*.sh's
        // _vpn_run_bounded watchdog relies on `kill -TERM $watchdog_pid;
        // wait $watchdog_pid`; with TERM blocked, the signal is queued but
        // never delivered, so the wait sleeps for the full watchdog timeout
        // on every single bounded call (measured: 0.7s from a terminal vs.
        // 20.5s with SIGTERM blocked in the parent -- see dns-config-du2).
        // Passing an empty signal mask plus SIG_DFL for every signal here
        // makes posix_spawn set the CHILD's mask/dispositions explicitly,
        // overriding whatever the spawning thread had, so vpn-ctl.sh always
        // starts with nothing blocked regardless of which thread called
        // `run`.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        var defaultMask = sigset_t()
        sigfillset(&defaultMask)
        posix_spawnattr_setsigdefault(&attr, &defaultMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv: [String] = [path] + args
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)

        var envp: [UnsafeMutablePointer<CChar>?] = childEnvironment(from: ProcessInfo.processInfo.environment).map { key, value in
            strdup("\(key)=\(value)")
        }
        envp.append(nil)

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, path, &fileActions, &attr, &cArgs, &envp)

        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        cArgs.forEach { if let p = $0 { free(p) } }
        envp.forEach { if let p = $0 { free(p) } }

        // Parent no longer needs the write ends once the child has them.
        close(stdoutWriteFD)
        close(stderrWriteFD)

        guard spawnResult == 0 else {
            close(stdoutReadFD)
            close(stderrReadFD)
            return .failure(.scriptNotFound(path))
        }

        registerLiveGroup(pid)
        defer { unregisterLiveGroup(pid) }

        // Read both pipes to completion on background threads so a full
        // pipe buffer can never deadlock the process (matches the previous
        // Process-based readabilityHandler behavior).
        let stdoutData = ThreadSafeBox(Data())
        let stderrData = ThreadSafeBox(Data())
        let stdoutReadDone = DispatchSemaphore(value: 0)
        let stderrReadDone = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            stdoutData.set(readAllAndClose(fd: stdoutReadFD))
            stdoutReadDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrData.set(readAllAndClose(fd: stderrReadFD))
            stderrReadDone.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var exitStatus: Int32 = 0
        while true {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                exitStatus = status
                break
            }
            if Date() > deadline {
                timedOut = true
                break
            }
            usleep(50_000)
        }

        if timedOut {
            // Signal the whole process group (negative pid), not just the
            // direct child, so a detached grandchild dies too.
            kill(-pid, SIGTERM)
            let termDeadline = Date().addingTimeInterval(2)
            var reaped = false
            while Date() < termDeadline {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    reaped = true
                    break
                }
                usleep(50_000)
            }
            if !reaped {
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }

        // Pipes must complete (the child, and its group, are dead/dying by
        // now, so the write ends will hit EOF).
        stdoutReadDone.wait()
        stderrReadDone.wait()

        let result = VPNCtlResult(
            exitCode: timedOut ? 1 : (WIFEXITED(exitStatus) ? WEXITSTATUS(exitStatus) : 1),
            stdout: String(data: stdoutData.value, encoding: .utf8) ?? "",
            stderr: String(data: stderrData.value, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
        return .success(result)
    }

    private static func registerLiveGroup(_ pid: pid_t) {
        liveGroups.mutate { $0.insert(pid) }
    }

    private static func unregisterLiveGroup(_ pid: pid_t) {
        liveGroups.mutate { $0.remove(pid) }
    }

    /// Reads a file descriptor to EOF and closes it. Runs on a background
    /// DispatchQueue -- blocking read() here is fine, it never touches the
    /// main thread.
    private static func readAllAndClose(fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        close(fd)
        return data
    }
}

/// WIFEXITED/WEXITSTATUS are C macros not imported into Swift; reimplement
/// per the standard <sys/wait.h> bit layout (status is a 16-bit value: low
/// byte encodes signal/exited-flag, next byte the exit code).
private func WIFEXITED(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}
private func WEXITSTATUS(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

/// Minimal thread-safe mutable box for accumulating pipe data read on a
/// background queue.
final class ThreadSafeBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) { _value = value }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: T) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }

    func append(_ data: Data) where T == Data {
        lock.lock()
        _value.append(data)
        lock.unlock()
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&_value)
        lock.unlock()
    }
}
