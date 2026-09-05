import CryptoKit
import Foundation

/// Errors thrown by `UpdateInstaller.verify(dmgURL:manifest:)`.
///
/// Every case here represents a failed security gate. There is no "partial
/// success" — `verify` either returns normally (both gates passed) or throws
/// one of these.
enum UpdateVerificationError: Error, Equatable, Sendable {
    /// `manifest.dmgURL` did not parse as a `URL` at all.
    case invalidDMGURL(String)

    /// `manifest.dmgURL` parsed, but its scheme was not `https`, or the host
    /// or path did not match the pinned GitHub releases location.
    case insecureDMGURL(String)

    /// The streaming SHA-256 of the downloaded DMG did not match
    /// `manifest.dmgSHA256`.
    case digestMismatch(expected: String, actual: String)

    /// `spctl -a -t open --context context:primary-signature` did not exit
    /// 0 for the downloaded DMG — it is not both Developer-ID signed and
    /// notarized.
    case notarizationFailed

    /// The DMG could not be read at all (e.g. missing file).
    case unreadableFile(String)
}

/// Verifies a downloaded update DMG before it is ever installed.
///
/// THIS IS THE WHOLE SECURITY STORY for VPNSwitch's self-update feature.
/// `verify(dmgURL:manifest:)` throws unless BOTH of the following
/// independently hold:
///
/// 1. The DMG's streaming SHA-256 digest matches `manifest.dmgSHA256`.
/// 2. `spctl -a -t open --context context:primary-signature` exits 0 for the
///    DMG, i.e. it is Developer-ID signed AND notarized by Apple.
///
/// Neither check is sufficient alone. A matching digest only proves the file
/// is byte-for-byte what the manifest described — and the manifest itself
/// arrives over the network, so an attacker who can serve a malicious
/// manifest can make the digest "match" whatever they want. Passing
/// notarization only proves the file is *some* legitimately Apple-notarized
/// binary — not that it is genuinely the update this app asked for. Only
/// the conjunction of "matches the manifest we fetched" AND "is a real,
/// notarized Developer-ID artifact" is meaningful.
///
/// Do NOT simplify this type and do NOT make either gate optional.
///
/// Both checks are evaluated before either is judged: the notarization
/// closure runs, and only then are the digest and notarization results
/// tested. That ordering is deliberate — it avoids leaking, through timing,
/// which of the two gates rejected an artifact. Do not "optimise" it into a
/// short-circuit that skips the notarization check when the digest already
/// failed.
enum UpdateInstaller {

    /// The only host VPNSwitch will ever fetch a DMG from.
    ///
    /// Unlike GateOpener's original version of this pin (which only pinned
    /// the generic `github.com` host, because no concrete repository
    /// identity existed in that codebase yet), this app's repo identity IS
    /// known: `ebowman/vpn-switch`. Hence the host pin here is paired with
    /// `pinnedDMGPathPrefix` below, which additionally constrains the path
    /// to that repo's own releases-download path shape. This closes the
    /// gap the original GateOpener doc comment flagged as follow-up work —
    /// a malicious manifest can no longer smuggle a DMG from a different
    /// repo under the same `github.com` host.
    static let pinnedDMGHost = "github.com"

    /// The only release-download path prefix VPNSwitch will ever fetch a
    /// DMG from, paired with `pinnedDMGHost` above. Scoping to this repo's
    /// own `releases/download/` path (rather than accepting any path on
    /// `github.com`) means a malicious manifest cannot point at another
    /// project's release asset on the same host.
    static let pinnedDMGPathPrefix = "/ebowman/vpn-switch/releases/download/"

    /// Bytes read per streaming digest chunk. A DMG can be tens of MB; this
    /// app runs as a background menu-bar process, so the whole file must
    /// never be loaded into memory at once.
    static let chunkSize = 1 << 20 // 1 MiB

    /// Verifies `dmgURL` (a `file://` URL to an already-downloaded DMG)
    /// against `manifest`.
    ///
    /// Throws unless BOTH the digest and notarization checks pass. Also
    /// throws before touching the filesystem at all if `manifest.dmgURL`
    /// fails to parse as a URL, or is not `https` pointing at the pinned
    /// GitHub releases host and path — this validation exists because
    /// `UpdateManifest.dmgURL` is a plain `String` (no URL/network types
    /// baked into the manifest), and the manifest itself arrives over the
    /// network, so an attacker able to serve a malicious manifest must not
    /// be able to smuggle a plaintext-downgraded or off-host/off-repo DMG
    /// URL through untouched.
    ///
    /// - Parameters:
    ///   - dmgURL: A `file://` URL to the DMG already downloaded to local
    ///     disk. This function performs no networking.
    ///   - manifest: The manifest describing the expected digest and the
    ///     origin URL the DMG was (supposedly) downloaded from.
    ///   - notarizationCheck: Injected so tests can substitute a fake
    ///     notarization result without shelling out to `spctl` or needing a
    ///     real signed artifact. Defaults to the real `spctl` invocation.
    /// - Throws: `UpdateVerificationError` describing which gate failed.
    nonisolated static func verify(
        dmgURL: URL,
        manifest: UpdateManifest,
        notarizationCheck: (URL) throws -> Bool = defaultNotarizationCheck
    ) throws {
        try validateManifestDMGURL(manifest.dmgURL)

        let actualDigest = try streamingSHA256Hex(of: dmgURL)
        let digestMatches = actualDigest.caseInsensitiveCompare(manifest.dmgSHA256) == .orderedSame

        let notarized = try notarizationCheck(dmgURL)

        guard digestMatches else {
            throw UpdateVerificationError.digestMismatch(
                expected: manifest.dmgSHA256,
                actual: actualDigest
            )
        }
        guard notarized else {
            throw UpdateVerificationError.notarizationFailed
        }
    }

    /// Validates that `dmgURLString` parses as a URL, uses `https`, and
    /// points at the pinned GitHub releases host and path prefix. Throws
    /// before any I/O.
    nonisolated static func validateManifestDMGURL(_ dmgURLString: String) throws {
        guard let parsed = URL(string: dmgURLString),
              let scheme = parsed.scheme,
              let host = parsed.host else {
            throw UpdateVerificationError.invalidDMGURL(dmgURLString)
        }
        guard scheme.lowercased() == "https" else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }
        guard host.lowercased() == pinnedDMGHost else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }
        guard parsed.path.hasPrefix(pinnedDMGPathPrefix) else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }
    }

    /// Computes the SHA-256 digest of the file at `fileURL`, streaming it in
    /// `chunkSize`-byte chunks so the whole file is never resident in memory
    /// at once. Returns the digest as a lowercase hex string.
    nonisolated static func streamingSHA256Hex(of fileURL: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw UpdateVerificationError.unreadableFile(fileURL.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The real notarization check: runs
    /// `spctl -a -t open --context context:primary-signature <dmg>` and
    /// returns whether it exited 0.
    ///
    /// This is Apple's documented way to verify that a disk image is both
    /// Developer-ID signed AND notarized — Developer ID signing alone is
    /// not sufficient and does not satisfy `spctl` in this mode.
    nonisolated static func defaultNotarizationCheck(_ dmgURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = [
            "-a", "-t", "open",
            "--context", "context:primary-signature",
            dmgURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
