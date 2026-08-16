import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

    /// Default install location once packaged (qsk.7).
    static let defaultPath = "/usr/local/bin/vpn-ctl.sh"

    /// Fallback used only if the default isn't present -- NOT the sole
    /// option, and not hard-coded as the only path: this is a fallback,
    /// tried after `defaultPath`.
    static var fallbackPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("src/dns-config/bin/vpn-ctl.sh").path
    }

    /// Resolves the configured/effective script path per the resolution
    /// order: UserDefaults override -> defaultPath (if it exists) ->
    /// fallbackPath (if it exists). Returns nil if none exist.
    static func resolvedPath() -> String? {
        if let configured = UserDefaults.standard.string(forKey: userDefaultsKey),
           !configured.isEmpty,
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        if FileManager.default.isExecutableFile(atPath: defaultPath) {
            return defaultPath
        }
        if FileManager.default.isExecutableFile(atPath: fallbackPath) {
            return fallbackPath
        }
        return nil
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
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let argv: [String] = [path] + args
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)

        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { key, value in
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
