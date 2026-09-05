import Foundation

/// Generates the detached `/bin/sh` script that performs VPN Switch's
/// self-replacing update swap, and the shell-quoting helper that makes doing
/// so safe.
///
/// THIS IS THE MOST DANGEROUS CODE IN THE PROJECT. The generated script ends
/// with `rm -rf "$INSTALL_DIR/$BUNDLE_NAME"` against a path built from
/// filesystem/bundle strings that this app does not fully control (a
/// build-directory path, a Finder-renamed `.app`, etc.). An unquoted space,
/// quote character, or shell metacharacter in any interpolated value can
/// corrupt that `rm -rf` into deleting the wrong thing, or worse. Every
/// value that flows into the generated script MUST go through `shQuote(_:)`
/// first — there is no other line of defense once the script is launched:
/// by the time it runs, the app that could have caught a mistake has already
/// called `NSApp.terminate(nil)`. Note the installed bundle name is
/// `"VPN Switch.app"` — it contains a space, which is exactly why `shQuote`
/// is what makes interpolating it into shell text safe in the first place.
///
/// A running `.app` cannot overwrite its own bundle out from under itself,
/// so the swap has to happen from a process that outlives it: this type only
/// produces the *text* of that script. Writing it to disk, making it
/// executable, launching it detached, and calling `NSApp.terminate(nil)`
/// afterward are all done elsewhere (in the code that owns `NSApp`) — kept
/// here only because this logic is pure string generation with no AppKit
/// dependency, and pure string generation is exactly what can be
/// unit-tested exhaustively without ever touching a filesystem or process.
enum UpdateSwapScript {

    /// Shell-quotes `value` for safe interpolation into a POSIX `/bin/sh`
    /// script as a single word, using the standard single-quote technique:
    /// wrap in `'...'`, and for every literal single quote in `value`, close
    /// the quoting, emit an escaped quote (`\'`), and reopen quoting.
    ///
    /// Single-quoting is used (not double-quoting) because inside single
    /// quotes, POSIX shells treat EVERY character literally — no variable
    /// expansion (`$(...)`, `$VAR`), no backslash escapes, no command
    /// substitution, nothing. The only character that cannot appear inside a
    /// single-quoted string at all is the single quote itself, which is why
    /// it needs the close-escape-reopen dance below. This makes the result
    /// safe against spaces, double quotes, backslashes, newlines, `$(...)`,
    /// semicolons, and leading dashes (a leading `-` inside `'...'` is just
    /// a literal character to the shell, not an option flag, once the
    /// quoted word is used as a plain argument rather than passed through
    /// something like `getopt`).
    ///
    /// Example: `shQuote("it's")` -> `'it'\''s'`
    ///   - `'it'`      -- literal "it"
    ///   - `\'`        -- an escaped literal single quote
    ///   - `'s'`       -- literal "s"
    ///   Concatenated by the shell (with no separators between adjacent
    ///   quoted/escaped segments) into the single word `it's`.
    static func shQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }

    /// Builds the full text of the detached swap script.
    ///
    /// - Parameters:
    ///   - dmgPath: absolute filesystem path to the already-downloaded AND
    ///     VERIFIED DMG (see `UpdateInstaller.verify` — this script must
    ///     never run against an unverified artifact).
    ///   - parentPID: the running app's own `getpid()`, so the script can
    ///     wait for this specific process to exit before touching anything.
    ///   - installDir: the directory CONTAINING the installed bundle (i.e.
    ///     `Bundle.main.bundleURL.deletingLastPathComponent().path`) — NOT
    ///     hardcoded to `/Applications`, so this works from a build
    ///     directory too.
    ///   - bundleName: the bundle's own last path component (e.g.
    ///     `"VPN Switch.app"`), taken from `Bundle.main.bundleURL`.
    ///   - relaunch: whether the script's final step should `open` the
    ///     freshly-swapped bundle. Defaults to `true` (the real production
    ///     path). Only the LIVE integration test passes `false`, so it can
    ///     run the real end-to-end swap against a throwaway, non-launchable
    ///     test fixture without spawning a fake "app" process as a side
    ///     effect of the test.
    ///   - requirement: the `codesign -R` designated-requirement string the
    ///     mounted bundle must satisfy before the script will touch
    ///     anything installed. Defaults to
    ///     `UpdateInstaller.designatedRequirement` (the Team ID pin). This
    ///     re-checks, on the MOUNTED volume at swap time, the same identity
    ///     already checked by `UpdateInstaller.verify` on the downloaded
    ///     DMG at download time — closing the TOCTOU window between
    ///     `verify()` returning and this detached script actually running
    ///     (the whole parent-exit wait loop) during which the DMG at
    ///     `dmgPath` could in principle have been replaced or the mount
    ///     could expose different bundle content than was hashed.
    ///   - expectedSHA256: when non-nil, the script re-hashes `$DMG_PATH`
    ///     immediately before `hdiutil attach` and refuses to proceed if it
    ///     no longer matches — the other half of closing that same TOCTOU
    ///     window, for the DMG file itself rather than the bundle inside
    ///     it. `nil` (the default) omits this check entirely, which the
    ///     LIVE integration tests rely on for fixtures built without a
    ///     precomputed digest.
    ///
    /// Every one of the four core string values (`dmgPath`, `parentPID`,
    /// `installDir`, `bundleName`) is interpolated through `shQuote(_:)`
    /// exactly once; `requirement` and `expectedSHA256` (when present) are
    /// too. The script:
    ///   1. Spins on `kill -0 "$PID"` (once per 0.5s) until the parent
    ///      process has actually exited, so the running `.app` bundle is
    ///      never touched while still in use.
    ///   2. When `expectedSHA256` was supplied, re-hashes `$DMG_PATH` with
    ///      `shasum -a 256` and refuses to proceed (app untouched, nothing
    ///      mounted) if it no longer matches what was verified.
    ///   3. `hdiutil attach -nobrowse -noverify -plist` the DMG, capturing
    ///      its plist output to a temp file.
    ///   4. Parses the mount point out of that plist with `python3` (never
    ///      by grepping `/Volumes` — fragile and ambiguous with concurrent
    ///      mounts). If `python3` is unavailable, or parsing fails to
    ///      produce a mount point, the script logs and exits NONZERO
    ///      *before* doing anything destructive — it never falls back to
    ///      guessing a path.
    ///   5. Re-verifies the MOUNTED new bundle
    ///      (`"$MOUNT_POINT/$BUNDLE_NAME"`) against `$REQUIREMENT` with
    ///      `/usr/bin/codesign --verify --deep --strict -R="$REQUIREMENT"`
    ///      (absolute path, so a `PATH` hijack cannot substitute a fake
    ///      `codesign`), and aborts (detach, exit 1, installed bundle
    ///      untouched) if it does not satisfy the pinned Team ID
    ///      requirement.
    ///   6. Refuses to proceed if the installed bundle
    ///      (`"$INSTALL_DIR/$BUNDLE_NAME"`) does not already exist as a
    ///      directory — guards against a wrong `installDir` turning the
    ///      next step into a no-op `rm -rf` of the wrong place followed by
    ///      installing into a location nothing will ever launch from.
    ///   7. `rm -rf` the OLD installed bundle
    ///      (`"$INSTALL_DIR/$BUNDLE_NAME"`) — the single irreversible step
    ///      in this entire pipeline.
    ///   8. `cp -R` the new bundle from the mounted DMG into `installDir` in
    ///      its place — same path, same signing identity, so TCC/login-item/
    ///      keychain-ACL grants survive (do not change this to a "fresh
    ///      install" elsewhere).
    ///   9. `hdiutil detach` the mounted volume.
    ///   10. `open` the freshly-installed bundle — unless `relaunch` is
    ///      `false`, in which case this step is skipped and a log line is
    ///      emitted in its place.
    ///
    /// Every step from `hdiutil attach` onward is written with `set -e`
    /// semantics made explicit (`|| exit 1` after the load-bearing steps)
    /// so a failure partway through stops rather than silently continuing
    /// into the next (potentially destructive) step. All output is expected
    /// to be redirected to a log file by the CALLER (via `nohup ... >>
    /// /tmp/vpn-switch-update.log 2>&1 &` or similar), not by this script
    /// itself — this script just writes to stdout/stderr as normal.
    static func generate(
        dmgPath: String,
        parentPID: Int32,
        installDir: String,
        bundleName: String,
        relaunch: Bool = true,
        requirement: String = UpdateInstaller.designatedRequirement,
        expectedSHA256: String? = nil
    ) -> String {
        let qDMG = shQuote(dmgPath)
        let qPID = shQuote(String(parentPID))
        let qInstallDir = shQuote(installDir)
        let qBundleName = shQuote(bundleName)
        let qRequirement = shQuote(requirement)

        let relaunchStep: String
        if relaunch {
            relaunchStep = """
            echo "[vpn-switch-update] relaunching $OLD_BUNDLE"
            open "$OLD_BUNDLE"
            """
        } else {
            relaunchStep = """
            echo "[vpn-switch-update] relaunch skipped (relaunch=false)"
            """
        }

        let expectedSHA256Assignment: String
        if let expectedSHA256 {
            expectedSHA256Assignment = "EXPECTED_SHA256=\(shQuote(expectedSHA256))"
        } else {
            expectedSHA256Assignment = ""
        }

        let digestCheckStep: String
        if expectedSHA256 != nil {
            digestCheckStep = """

            echo "[vpn-switch-update] re-checking DMG digest before attach"
            ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
            if [ "$(echo "$ACTUAL_SHA256" | tr 'A-Z' 'a-z')" != "$(echo "$EXPECTED_SHA256" | tr 'A-Z' 'a-z')" ]; then
                echo "[vpn-switch-update] refusing to install: DMG digest changed since verification"
                exit 1
            fi
            """
        } else {
            digestCheckStep = ""
        }

        return """
        #!/bin/sh
        set -e

        DMG_PATH=\(qDMG)
        PID=\(qPID)
        INSTALL_DIR=\(qInstallDir)
        BUNDLE_NAME=\(qBundleName)
        REQUIREMENT=\(qRequirement)
        \(expectedSHA256Assignment)

        # Refuse to run at all with a target that could make the rm -rf below
        # catastrophic. With an empty BUNDLE_NAME, "$MOUNT_POINT/$BUNDLE_NAME"
        # is the mount root — a real directory, so the -d check further down
        # PASSES — and "$INSTALL_DIR/$BUNDLE_NAME" collapses to "/". That is
        # `rm -rf /` with no recovery but this log. Bundle.main.bundleURL
        # never yields empty components today, so this is defence in depth on
        # the single most dangerous line in the project: cheap, and the one
        # bug class where "not currently reachable" is not good enough.
        if [ -z "$INSTALL_DIR" ] || [ -z "$BUNDLE_NAME" ]; then
            echo "[vpn-switch-update] refusing to run: empty install dir or bundle name"
            exit 1
        fi
        if [ "$INSTALL_DIR" = "/" ]; then
            echo "[vpn-switch-update] refusing to run: install dir is /"
            exit 1
        fi
        case "$BUNDLE_NAME" in
            */*|.|..)
                echo "[vpn-switch-update] refusing to run: unsafe bundle name $BUNDLE_NAME"
                exit 1
                ;;
        esac

        echo "[vpn-switch-update] waiting for parent pid $PID to exit"
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.5
        done
        echo "[vpn-switch-update] parent exited, proceeding"
        \(digestCheckStep)
        PLIST_PATH="$(mktemp -t vpn-switch-update-plist)"
        echo "[vpn-switch-update] attaching $DMG_PATH"
        if ! hdiutil attach -nobrowse -noverify -plist "$DMG_PATH" > "$PLIST_PATH"; then
            echo "[vpn-switch-update] hdiutil attach failed"
            exit 1
        fi

        if ! command -v python3 >/dev/null 2>&1; then
            echo "[vpn-switch-update] python3 not found; cannot safely parse hdiutil plist, aborting"
            exit 1
        fi

        MOUNT_POINT="$(python3 -c '
        import plistlib
        import sys

        with open(sys.argv[1], "rb") as f:
            data = plistlib.load(f)

        for entity in data.get("system-entities", []):
            mount_point = entity.get("mount-point")
            if mount_point:
                print(mount_point)
                break
        ' "$PLIST_PATH")"

        if [ -z "$MOUNT_POINT" ]; then
            echo "[vpn-switch-update] could not determine mount point from hdiutil plist, aborting"
            exit 1
        fi
        echo "[vpn-switch-update] mounted at $MOUNT_POINT"

        NEW_BUNDLE="$MOUNT_POINT/$BUNDLE_NAME"
        if [ ! -d "$NEW_BUNDLE" ]; then
            echo "[vpn-switch-update] $NEW_BUNDLE not found on mounted volume, aborting"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            exit 1
        fi

        # Re-verify the MOUNTED bundle against the pinned Team ID
        # requirement, using an absolute path to codesign so a PATH hijack
        # cannot substitute a fake one. This closes the verify-then-install
        # TOCTOU gap: UpdateInstaller.verify already checked the DOWNLOADED
        # DMG before this detached script ever ran, but the whole
        # parent-exit wait loop above is a window during which the file at
        # DMG_PATH (or, once mounted, the bundle inside it) could in
        # principle differ from what was verified. Re-checking here, on the
        # actual bundle about to be installed, means that window cannot be
        # used to smuggle in an unsigned or wrong-Team-ID bundle.
        echo "[vpn-switch-update] verifying $NEW_BUNDLE satisfies designated requirement"
        if ! /usr/bin/codesign --verify --deep --strict -R="$REQUIREMENT" "$NEW_BUNDLE"; then
            echo "[vpn-switch-update] refusing to install: $NEW_BUNDLE does not satisfy the designated requirement (Team ID pin)"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            exit 1
        fi

        OLD_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME"
        if [ ! -d "$OLD_BUNDLE" ]; then
            echo "[vpn-switch-update] installed bundle not found at $OLD_BUNDLE, aborting"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            exit 1
        fi

        echo "[vpn-switch-update] removing $OLD_BUNDLE"
        rm -rf "$OLD_BUNDLE"

        echo "[vpn-switch-update] copying $NEW_BUNDLE to $INSTALL_DIR"
        cp -R "$NEW_BUNDLE" "$INSTALL_DIR/"

        echo "[vpn-switch-update] detaching $MOUNT_POINT"
        hdiutil detach "$MOUNT_POINT" -quiet || true

        \(relaunchStep)

        echo "[vpn-switch-update] update complete"
        """
    }
}
