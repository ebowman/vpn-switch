import CryptoKit
import Foundation
import Testing
@testable import VPNSwitch

/// Tests for
/// `UpdateInstaller.verify(dmgURL:manifest:notarizationCheck:identityCheck:)`
/// — the whole security story for VPNSwitch's self-update feature.
///
/// The three gates (digest match, notarization, Team ID identity) are
/// independent: this suite deliberately covers combinations of them so no
/// gate can silently become optional. It also validates the manifest URL
/// scheme/host/path pinning, which runs before any I/O. Every assertion
/// here is non-vacuous by construction.
struct UpdateInstallerTests {

    // MARK: - Fixtures

    /// Writes `data` to a fresh temporary file and returns its `file://`
    /// URL. Caller is responsible for no cleanup — `NSTemporaryDirectory`
    /// entries are ephemeral and harmless to leave behind in test runs.
    private func writeTempFile(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString).dmg")
        try data.write(to: url)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func manifest(
        dmgURL: String = "https://github.com/ebowman/vpn-switch/releases/download/v1.0.0/VPNSwitch-1.0.0.dmg",
        sha256: String
    ) -> UpdateManifest {
        UpdateManifest(
            latestVersion: "1.0.0",
            notes: "https://github.com/ebowman/vpn-switch/releases/tag/v1.0.0",
            dmgURL: dmgURL,
            dmgSHA256: sha256
        )
    }

    // MARK: - Digest correctness, including a >1 MiB file (chunk-boundary path)

    @Test func matchingDigestAndPassingNotarizationSucceeds() throws {
        let content = Data("small known content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        // Must not throw.
        try UpdateInstaller.verify(
            dmgURL: fileURL,
            manifest: m,
            notarizationCheck: { _ in true },
            identityCheck: { _ in true }
        )
    }

    @Test func matchingDigestOverMultipleChunksSucceeds() throws {
        // 1 MiB chunk size; use a file > 2.5 MiB so at least two full chunks
        // plus a partial final chunk are read, genuinely exercising the
        // streaming loop's boundary handling rather than a single read.
        var bytes = [UInt8]()
        bytes.reserveCapacity(2_684_354) // ~2.56 MiB, deliberately not a clean multiple of 1 MiB
        for i in 0..<2_684_354 {
            bytes.append(UInt8(truncatingIfNeeded: i))
        }
        let content = Data(bytes)
        #expect(content.count > (1 << 20) * 2) // sanity: genuinely multi-chunk

        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        try UpdateInstaller.verify(
            dmgURL: fileURL,
            manifest: m,
            notarizationCheck: { _ in true },
            identityCheck: { _ in true }
        )
    }

    @Test func digestIsCaseInsensitiveMatch() throws {
        let content = Data("case insensitivity check".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content).uppercased())

        try UpdateInstaller.verify(
            dmgURL: fileURL,
            manifest: m,
            notarizationCheck: { _ in true },
            identityCheck: { _ in true }
        )
    }

    // MARK: - The two gates are independent; neither is sufficient alone

    @Test func digestMismatchThrowsEvenWhenNotarizationPasses() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let wrongDigest = sha256Hex(Data("different content".utf8))
        let m = manifest(sha256: wrongDigest)

        #expect(throws: UpdateVerificationError.self) {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
        }
    }

    @Test func notarizationFailureThrowsEvenWhenDigestMatches() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        #expect(throws: UpdateVerificationError.self) {
            try UpdateInstaller.verify(
                dmgURL: fileURL,
                manifest: m,
                notarizationCheck: { _ in false },
                identityCheck: { _ in true }
            )
        }
    }

    @Test func bothDigestAndNotarizationFailingThrows() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(Data("wrong".utf8)))

        #expect(throws: UpdateVerificationError.self) {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in false }
        }
    }

    @Test func specificErrorIsDigestMismatchWhenOnlyDigestFails() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let wrongDigest = sha256Hex(Data("different content".utf8))
        let m = manifest(sha256: wrongDigest)

        do {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            guard case .digestMismatch = error else {
                Issue.record("expected .digestMismatch, got \(error)")
                return
            }
        }
    }

    @Test func specificErrorIsNotarizationFailedWhenOnlyNotarizationFails() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        do {
            try UpdateInstaller.verify(
                dmgURL: fileURL,
                manifest: m,
                notarizationCheck: { _ in false },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .notarizationFailed)
        }
    }

    /// The identity closure must run even when digest and notarization both
    /// pass -- the Team ID pin is not skippable just because the other two
    /// gates are satisfied.
    @Test func identityFailureThrowsEvenWhenDigestAndNotarizationPass() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(sha256: sha256Hex(content))

        do {
            try UpdateInstaller.verify(
                dmgURL: fileURL,
                manifest: m,
                notarizationCheck: { _ in true },
                identityCheck: { _ in false }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .identityMismatch)
        }
    }

    /// The identity closure must run even when the digest already
    /// mismatches -- all three gates are evaluated before any is judged.
    @Test func identityCheckIsInvokedEvenWhenDigestMismatches() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let wrongDigest = sha256Hex(Data("different content".utf8))
        let m = manifest(sha256: wrongDigest)

        var identityCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: fileURL,
                manifest: m,
                notarizationCheck: { _ in true },
                identityCheck: { _ in
                    identityCheckWasCalled = true
                    return true
                }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            guard case .digestMismatch = error else {
                Issue.record("expected .digestMismatch, got \(error)")
                return
            }
        }
        #expect(identityCheckWasCalled)
    }

    /// The notarization closure must run even when the digest already
    /// mismatches -- both gates are evaluated before either is judged (see
    /// `UpdateInstaller.verify`'s doc comment on why this ordering is
    /// deliberate, not an optimization target).
    @Test func notarizationClosureIsInvokedEvenWhenDigestMismatches() throws {
        let content = Data("real content".utf8)
        let fileURL = try writeTempFile(content)
        let wrongDigest = sha256Hex(Data("different content".utf8))
        let m = manifest(sha256: wrongDigest)

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(dmgURL: fileURL, manifest: m) { _ in
                notarizationCheckWasCalled = true
                return true
            }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            guard case .digestMismatch = error else {
                Issue.record("expected .digestMismatch, got \(error)")
                return
            }
        }
        #expect(notarizationCheckWasCalled)
    }

    // MARK: - URL validation runs before any I/O

    @Test func nonHTTPSSchemeThrowsBeforeAnyIO() throws {
        let m = manifest(dmgURL: "http://github.com/ebowman/vpn-switch/releases/download/v1.0.0/VPNSwitch-1.0.0.dmg", sha256: "irrelevant")

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in
                notarizationCheckWasCalled = true
                return true
            }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            // Must be rejected specifically as insecure (wrong scheme), not
            // merely as "some error or other" (e.g. the unreadable-local-file
            // error, which would also be thrown here if URL validation were
            // skipped and the code fell through to I/O against a nonexistent
            // path — that would make this assertion pass for the wrong
            // reason). Pinning the exact case closes that gap.
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        // Confirms validation happens before I/O: a nonexistent local file
        // and a closure that would otherwise succeed are both never reached.
        #expect(!notarizationCheckWasCalled)
    }

    @Test func arbitrarySchemeThrows() throws {
        let m = manifest(dmgURL: "ftp://github.com/ebowman/vpn-switch/releases/download/v1.0.0/VPNSwitch-1.0.0.dmg", sha256: "irrelevant")

        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
    }

    @Test func unparseableManifestURLThrows() throws {
        // A string with control characters / malformed percent-encoding
        // that Foundation's URL(string:) parser rejects outright.
        let badURLString = "not a valid url at all with spaces and no scheme"
        let m = manifest(dmgURL: badURLString, sha256: "irrelevant")

        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .invalidDMGURL(badURLString))
        }
    }

    @Test func httpsButWrongHostThrows() throws {
        let m = manifest(dmgURL: "https://evil.example.com/ebowman/vpn-switch/releases/download/v1.0.0/VPNSwitch-1.0.0.dmg", sha256: "irrelevant")

        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in true }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
    }

    /// Right host (`github.com`), but a different repo's release-download
    /// path -- must still be rejected. This is the gap the path-prefix pin
    /// (over and above the host-only pin) exists to close.
    @Test func httpsAndRightHostButWrongPathThrows() throws {
        let m = manifest(dmgURL: "https://github.com/someone-else/repo/releases/download/x.dmg", sha256: "irrelevant")

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m
            ) { _ in
                notarizationCheckWasCalled = true
                return true
            }
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// Dot-segment traversal in the raw path: `.path` does not normalize
    /// `..`, so the naive `hasPrefix` check on the raw path would pass while
    /// GitHub itself would route the request to a completely different,
    /// unpinned repo/path. Must be rejected.
    @Test func dotSegmentTraversalPathThrows() throws {
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/../../../evil/repo/releases/download/v1/x.dmg",
            sha256: "irrelevant"
        )

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m,
                notarizationCheck: { _ in
                    notarizationCheckWasCalled = true
                    return true
                },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// Percent-encoded dot-segment traversal (`%2e%2e`) must also be
    /// rejected, not just the literal `..` form.
    @Test func percentEncodedDotSegmentTraversalThrows() throws {
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/%2e%2e/%2e%2e/evil/x.dmg",
            sha256: "irrelevant"
        )

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m,
                notarizationCheck: { _ in
                    notarizationCheckWasCalled = true
                    return true
                },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// A single-dot (`.`) path component is also a dot-segment and must be
    /// rejected, not just `..`.
    @Test func singleDotPathComponentThrows() throws {
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/./v1/x.dmg",
            sha256: "irrelevant"
        )

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m,
                notarizationCheck: { _ in
                    notarizationCheckWasCalled = true
                    return true
                },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// A URL that is exactly the pinned prefix, with nothing after it, is
    /// not a valid DMG location and must be rejected.
    @Test func bareprefixWithNothingAfterItThrows() throws {
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/",
            sha256: "irrelevant"
        )

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m,
                notarizationCheck: { _ in
                    notarizationCheckWasCalled = true
                    return true
                },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// Encoded-slash traversal: `..%2f..%2fevil` decodes (via `URL.path`)
    /// into a single fused path component `../../evil` that is never a
    /// literal `.`/`..` `pathComponents` entry, sidestepping the naive
    /// component check. Must still be rejected.
    @Test func encodedSlashTraversalThrows() throws {
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/..%2f..%2fevil/x.dmg",
            sha256: "irrelevant"
        )

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m,
                notarizationCheck: { _ in
                    notarizationCheckWasCalled = true
                    return true
                },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// Encoded-slash traversal embedded later in the path (in the filename
    /// position) must also be rejected.
    @Test func encodedSlashTraversalInFilenamePositionThrows() throws {
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/v1/x%2f..%2f..%2fevil.dmg",
            sha256: "irrelevant"
        )

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m,
                notarizationCheck: { _ in
                    notarizationCheckWasCalled = true
                    return true
                },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// An encoded backslash (`%5c`) anywhere in the URL must also be
    /// rejected, alongside the encoded-slash case.
    @Test func encodedBackslashThrows() throws {
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/v1/x%5cy.dmg",
            sha256: "irrelevant"
        )

        var notarizationCheckWasCalled = false
        do {
            try UpdateInstaller.verify(
                dmgURL: URL(fileURLWithPath: "/nonexistent/path/App.dmg"),
                manifest: m,
                notarizationCheck: { _ in
                    notarizationCheckWasCalled = true
                    return true
                },
                identityCheck: { _ in true }
            )
            Issue.record("expected verify to throw")
        } catch let error as UpdateVerificationError {
            #expect(error == .insecureDMGURL(m.dmgURL))
        }
        #expect(!notarizationCheckWasCalled)
    }

    /// Ordinary percent-encoding that is NOT a traversal/slash/backslash
    /// sequence (a percent-encoded space in the filename) must NOT be
    /// over-rejected: the legitimate URL still passes end-to-end.
    @Test func percentEncodedSpaceInFilenameStillPasses() throws {
        let content = Data("encoded space filename check".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/v9.9.9/VPNSwitch%201.dmg",
            sha256: sha256Hex(content)
        )

        try UpdateInstaller.verify(
            dmgURL: fileURL,
            manifest: m,
            notarizationCheck: { _ in true },
            identityCheck: { _ in true }
        )
    }

    @Test func httpsAndPinnedHostAndPathPassesURLValidation() throws {
        // Confirms the host+path pin isn't accidentally rejecting the
        // legitimate host/path too: only the URL-validation step is under
        // test here, so we give it real matching content + a passing
        // notarization stub and expect success end-to-end.
        let content = Data("pinned host check".utf8)
        let fileURL = try writeTempFile(content)
        let m = manifest(
            dmgURL: "https://github.com/ebowman/vpn-switch/releases/download/v9.9.9/VPNSwitch-9.9.9.dmg",
            sha256: sha256Hex(content)
        )

        try UpdateInstaller.verify(
            dmgURL: fileURL,
            manifest: m,
            notarizationCheck: { _ in true },
            identityCheck: { _ in true }
        )
    }

    // MARK: - Real spctl closure (default parameter) does not crash on a bogus path

    @Test func defaultNotarizationCheckReturnsFalseForNonSignedFile() throws {
        let content = Data("not a real dmg".utf8)
        let fileURL = try writeTempFile(content)
        // Exercise the real (non-injected) spctl-backed default via the
        // public entry point, confirming it fails closed for a plain file
        // that is obviously not a signed, notarized disk image.
        let result = try UpdateInstaller.defaultNotarizationCheck(fileURL)
        #expect(result == false)
    }

    // MARK: - Real codesign closure (default parameter) does not crash on a bogus path

    @Test func defaultIdentityCheckReturnsFalseForNonSignedFile() throws {
        let content = Data("not a real dmg".utf8)
        let fileURL = try writeTempFile(content)
        // Exercise the real (non-injected) codesign-backed default via the
        // public entry point, confirming it fails closed for a plain file
        // that is obviously not signed at all, let alone by the pinned
        // Team ID.
        let result = try UpdateInstaller.defaultIdentityCheck(fileURL)
        #expect(result == false)
    }

    // MARK: - The designated requirement constant

    @Test func designatedRequirementPinsExpectedTeamID() {
        #expect(UpdateInstaller.designatedRequirement == "anchor apple generic and certificate leaf[subject.OU] = \"Y5SB82BPYL\"")
    }
}
