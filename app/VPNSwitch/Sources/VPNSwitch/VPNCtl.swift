import Foundation

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
enum VPNCtl {
    static let userDefaultsKey = "vpnCtlPath"

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
    /// process is terminated and `timedOut=true` is returned.
    static func run(_ args: [String], timeout: TimeInterval = 60) -> Result<VPNCtlResult, VPNCtlError> {
        guard let path = resolvedPath() else {
            return .failure(.scriptNotFound(pathForDisplay()))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutData = ThreadSafeBox(Data())
        let stderrData = ThreadSafeBox(Data())

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stdoutData.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrData.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            return .failure(.scriptNotFound(path))
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                process.terminate()
                // Give it a moment to die; force-kill via SIGKILL is not
                // available through Process directly, terminate() sends
                // SIGTERM which vpn-ctl.sh (a plain bash script) will honor.
                usleep(200_000)
                break
            }
            usleep(50_000)
        }
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain any remaining buffered data synchronously.
        let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingOut.isEmpty { stdoutData.append(remainingOut) }
        let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingErr.isEmpty { stderrData.append(remainingErr) }

        let result = VPNCtlResult(
            exitCode: timedOut ? 1 : process.terminationStatus,
            stdout: String(data: stdoutData.value, encoding: .utf8) ?? "",
            stderr: String(data: stderrData.value, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
        return .success(result)
    }
}

/// Minimal thread-safe mutable box for accumulating pipe data from
/// readabilityHandler callbacks (which fire on a background queue).
final class ThreadSafeBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) { _value = value }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func append(_ data: Data) where T == Data {
        lock.lock()
        _value.append(data)
        lock.unlock()
    }
}
