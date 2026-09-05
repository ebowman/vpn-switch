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

    /// `codesign --verify -R=<designatedRequirement>` did not exit 0 for
    /// the downloaded DMG — it is not signed by the pinned Team ID
    /// (`UpdateInstaller.pinnedTeamID`). `spctl` notarization alone accepts
    /// any Apple developer's notarized artifact; this gate additionally
    /// requires the artifact to carry VPN Switch's own Developer ID
    /// signature, so a GitHub/release-account compromise alone cannot ship
    /// an update — the attacker would also need the Developer ID signing
    /// key.
    case identityMismatch

    /// The DMG could not be read at all (e.g. missing file).
    case unreadableFile(String)
}

/// Verifies a downloaded update DMG before it is ever installed.
///
/// THIS IS THE WHOLE SECURITY STORY for VPNSwitch's self-update feature.
/// `verify(dmgURL:manifest:)` throws unless ALL THREE of the following
/// independently hold:
///
/// 1. The DMG's streaming SHA-256 digest matches `manifest.dmgSHA256`.
/// 2. `spctl -a -t open --context context:primary-signature` exits 0 for the
///    DMG, i.e. it is Developer-ID signed AND notarized by Apple.
/// 3. `codesign --verify -R=<designatedRequirement>` exits 0 for the DMG,
///    i.e. it is signed specifically by VPN Switch's own pinned Team ID
///    (`pinnedTeamID`) — not merely by *some* notarized Developer ID.
///
/// None of the three checks is sufficient alone. A matching digest only
/// proves the file is byte-for-byte what the manifest described — and the
/// manifest itself arrives over the network, so an attacker who can serve a
/// malicious manifest can make the digest "match" whatever they want.
/// Passing notarization only proves the file is *some* legitimately
/// Apple-notarized binary from *any* Apple developer account — not that it
/// is genuinely the update this app asked for. That gap is exactly what the
/// Team ID pin closes: even if an attacker compromises the GitHub release
/// (stolen token, account takeover) and ships a manifest pointing at their
/// own notarized DMG, that DMG will not satisfy the designated requirement
/// unless they also possess VPN Switch's actual Developer ID signing key.
/// Only the conjunction of "matches the manifest we fetched" AND "is a
/// real, notarized Developer-ID artifact" AND "is signed by our own Team
/// ID" is meaningful.
///
/// Do NOT simplify this type and do NOT make any gate optional.
///
/// All three checks are evaluated before any is judged: the notarization
/// and identity closures both run, and only then are the digest,
/// notarization, and identity results tested. That ordering is deliberate
/// — it avoids leaking, through timing, which of the gates rejected an
/// artifact. Do not "optimise" it into a short-circuit that skips a check
/// when an earlier one already failed.
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

    /// The only Developer ID Team ID VPNSwitch will ever accept an update
    /// DMG from.
    ///
    /// `spctl -a -t open --context context:primary-signature` (see
    /// `defaultNotarizationCheck`) only proves an artifact is Developer-ID
    /// signed AND notarized by Apple — it accepts that from ANY Apple
    /// developer account, not just this project's own. Trust in the update
    /// path would otherwise reduce entirely to "whoever can write to the
    /// `ebowman/vpn-switch` GitHub releases" (TLS-to-GitHub plus a manifest
    /// with a matching digest), because a manifest and a notarized DMG are
    /// both things an attacker who compromises that GitHub account (stolen
    /// token, account takeover) could produce under their OWN notarized
    /// Developer ID. Pinning this Team ID closes that gap: even a fully
    /// compromised release pipeline cannot ship an update unless the
    /// attacker also possesses this project's actual Developer ID signing
    /// key.
    static let pinnedTeamID = "Y5SB82BPYL"

    /// The `codesign -R` designated-requirement string that pins
    /// `pinnedTeamID`. Shared verbatim between `defaultIdentityCheck` (via
    /// `codesign --verify`) and `UpdateSwapScript.generate`, which embeds
    /// this same string into the generated shell script so the post-mount
    /// re-verification step checks the identical requirement.
    static let designatedRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(pinnedTeamID)\""

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
    ///   - identityCheck: Injected so tests can substitute a fake Team ID
    ///     identity result without shelling out to `codesign` or needing a
    ///     real Developer-ID-signed artifact. Defaults to the real
    ///     `codesign --verify -R=<designatedRequirement>` invocation.
    /// - Throws: `UpdateVerificationError` describing which gate failed.
    nonisolated static func verify(
        dmgURL: URL,
        manifest: UpdateManifest,
        notarizationCheck: (URL) throws -> Bool = defaultNotarizationCheck,
        identityCheck: (URL) throws -> Bool = defaultIdentityCheck
    ) throws {
        try validateManifestDMGURL(manifest.dmgURL)

        let actualDigest = try streamingSHA256Hex(of: dmgURL)
        let digestMatches = actualDigest.caseInsensitiveCompare(manifest.dmgSHA256) == .orderedSame

        let notarized = try notarizationCheck(dmgURL)
        let identityMatches = try identityCheck(dmgURL)

        guard digestMatches else {
            throw UpdateVerificationError.digestMismatch(
                expected: manifest.dmgSHA256,
                actual: actualDigest
            )
        }
        guard notarized else {
            throw UpdateVerificationError.notarizationFailed
        }
        guard identityMatches else {
            throw UpdateVerificationError.identityMismatch
        }
    }

    /// Validates that `dmgURLString` parses as a URL, uses `https`, and
    /// points at the pinned GitHub releases host and path prefix. Throws
    /// before any I/O.
    ///
    /// The path-prefix check is deliberately defense-in-depth against dot-
    /// segment traversal: Foundation's `URL.path` does NOT normalize `.`/`..`
    /// components, so `.../releases/download/../../../evil/repo/...` would
    /// still report a raw `.path` that starts with `pinnedDMGPathPrefix`
    /// even though `.standardized.path` resolves to a completely different,
    /// unpinned path (which is what GitHub itself would actually serve).
    /// Several independent measures close this:
    ///
    /// 1. Any raw path component that is literally `.` or `..`, or any
    ///    percent-encoded `%2e`/`%2E` sequence or backslash in the raw path,
    ///    is rejected outright before path comparison even begins.
    /// 2. The full `absoluteString` is rejected if it contains an encoded
    ///    slash (`%2f`/`%2F`) or encoded backslash (`%5c`/`%5C`). A
    ///    legitimate GitHub release asset URL never needs an encoded slash:
    ///    it would otherwise let a component like `..%2f..%2fevil` decode
    ///    (via `URL.path`) into fused-but-still-traversing segments such as
    ///    `../../evil` that never appear as a literal `.`/`..` component in
    ///    `pathComponents` and are not caught by check 1.
    /// 3. The *decoded* `parsed.path` is independently scanned for `..`
    ///    anywhere, or any component containing `..`, as a belt-and-braces
    ///    check that does not depend on exactly how Foundation happens to
    ///    split path components.
    /// 4. The prefix check itself runs against `parsed.standardized.path`
    ///    rather than the raw `parsed.path`, so even a traversal sequence
    ///    that slipped past 1-3 would still be caught by resolving against
    ///    the pin.
    /// 5. A bare prefix match with nothing after it is also rejected -- a
    ///    real DMG URL always has a version/filename segment following the
    ///    prefix.
    ///
    /// Ordinary, non-traversal percent-encoding (e.g. `%20` for a space in a
    /// filename) is left untouched -- only encoded slashes/backslashes and
    /// literal/encoded dot-segments are rejected.
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

        // Reject any dot-segment component outright, whether literal or
        // percent-encoded, before ever comparing paths.
        guard !parsed.pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }
        let rawPath = parsed.path
        guard !rawPath.lowercased().contains("%2e"),
              !rawPath.contains("\\") else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }

        // Reject encoded slashes/backslashes anywhere in the URL: a
        // legitimate GitHub release asset URL never needs one, and an
        // encoded slash lets a traversal segment like `..%2f..%2fevil`
        // decode into `../../evil` inside a single fused path component,
        // sidestepping the literal `.`/`..` component check above.
        let lowerAbsolute = parsed.absoluteString.lowercased()
        guard !lowerAbsolute.contains("%2f"),
              !lowerAbsolute.contains("%5c") else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }

        // Belt-and-braces: scan the decoded path itself for ".." anywhere,
        // or any component containing "..", independent of how Foundation
        // happens to split pathComponents.
        guard !rawPath.contains(".."),
              !rawPath.split(separator: "/").contains(where: { $0.contains("..") }) else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }

        // Compare the *standardized* (dot-segment-resolved) path against the
        // pin, not the raw path, so any traversal sequence that slipped past
        // the checks above is still caught by resolving to where GitHub
        // would actually route the request.
        let standardizedPath = parsed.standardized.path
        guard standardizedPath.hasPrefix(pinnedDMGPathPrefix) else {
            throw UpdateVerificationError.insecureDMGURL(dmgURLString)
        }
        let remainder = standardizedPath.dropFirst(pinnedDMGPathPrefix.count)
        guard !remainder.isEmpty else {
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

    /// The real identity check: runs
    /// `codesign --verify -R=<designatedRequirement> <dmg>` and returns
    /// whether it exited 0.
    ///
    /// This proves the DMG's primary signature satisfies the designated
    /// requirement pinning `pinnedTeamID` — i.e. it is signed specifically
    /// by VPN Switch's own Developer ID, not merely by some other
    /// Apple-notarized Developer ID (which `defaultNotarizationCheck` alone
    /// would accept). The `-R=` form (value directly attached, not passed
    /// as a separate argv element) is required by `codesign`'s argument
    /// parsing.
    nonisolated static func defaultIdentityCheck(_ dmgURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "-R=\(designatedRequirement)",
            dmgURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
