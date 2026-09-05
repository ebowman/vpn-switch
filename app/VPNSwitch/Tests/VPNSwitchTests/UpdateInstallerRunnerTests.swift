import Foundation
import Testing
@testable import VPNSwitch

/// Tests for `UpdateInstallerRunner.writeSwapScript(text:)` and
/// `UpdateSwapError`.
///
/// `launchSwap(dmgURL:expectedSHA256:beforeTerminate:)` itself is NOT tested here: on
/// success it calls `NSApp.terminate(nil)`, which would tear down the test
/// process. `writeSwapScript(text:)` is factored out precisely so the
/// script-writing step (the only part of `launchSwap` that can fail before
/// anything irreversible happens) can be exercised directly.
@MainActor
struct UpdateInstallerRunnerTests {

    @Test func writeSwapScriptWritesExecutableFileUnderTempDirectory() throws {
        let text = "#!/bin/sh\necho hello\n"

        let url = try UpdateInstallerRunner.writeSwapScript(text: text)
        defer { try? FileManager.default.removeItem(at: url) }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        #expect(url.path.hasPrefix(tempDir.path))

        let writtenText = try String(contentsOf: url, encoding: .utf8)
        #expect(writtenText == text)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
    }

    @Test func writeSwapScriptProducesUniquePathsAcrossCalls() throws {
        let url1 = try UpdateInstallerRunner.writeSwapScript(text: "one")
        defer { try? FileManager.default.removeItem(at: url1) }
        let url2 = try UpdateInstallerRunner.writeSwapScript(text: "two")
        defer { try? FileManager.default.removeItem(at: url2) }

        #expect(url1 != url2)
    }

    // MARK: - UpdateSwapError

    /// Non-vacuous check that all three documented cases exist and carry a
    /// `String` payload, without needing to drive an actual write/chmod/
    /// launch failure.
    @Test func updateSwapErrorCasesExist() {
        let errors: [UpdateSwapError] = [
            .scriptWriteFailed("write failed"),
            .scriptPermissionsFailed("chmod failed"),
            .launchFailed("launch failed")
        ]
        #expect(errors.count == 3)

        for error in errors {
            switch error {
            case .scriptWriteFailed(let message),
                 .scriptPermissionsFailed(let message),
                 .launchFailed(let message):
                #expect(!message.isEmpty)
            }
        }
    }
}
