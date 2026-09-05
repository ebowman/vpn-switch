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
    ///   - bundleIdentifier: the expected `CFBundleIdentifier` of BOTH the
    ///     installed (old) bundle and the mounted (new) bundle. No default —
    ///     callers must be explicit; `UpdateInstallerRunner` passes
    ///     `Bundle.main.bundleIdentifier ?? "ie.boboco.vpnswitch"`. Read from
    ///     each bundle's `Contents/Info.plist` with `PlistBuddy` at swap
    ///     time and compared against this value before either bundle is
    ///     touched — see step 7 below.
    ///
    /// Every one of the four core string values (`dmgPath`, `parentPID`,
    /// `installDir`, `bundleName`) is interpolated through `shQuote(_:)`
    /// exactly once; `requirement`, `bundleIdentifier`, and `expectedSHA256`
    /// (when present) are too. The script:
    ///   1. Spins on `kill -0 "$PID"` (once per 0.5s) until the parent
    ///      process has actually exited, so the running `.app` bundle is
    ///      never touched while still in use.
    ///   2. When `expectedSHA256` was supplied, re-hashes `$DMG_PATH` with
    ///      `shasum -a 256` and refuses to proceed (app untouched, nothing
    ///      mounted) if it no longer matches what was verified.
    ///   3. `hdiutil attach -nobrowse -noverify -readonly -plist` the DMG
    ///      (mounted read-only: this script never writes to the mounted
    ///      volume), capturing its plist output to a temp file.
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
    ///      next steps into installing into a location nothing will ever
    ///      launch from.
    ///   7. Bundle identity sanity, BEFORE anything is moved: refuses if
    ///      `$NEW_BUNDLE` is a symlink; reads `CFBundleIdentifier` from both
    ///      `$OLD_BUNDLE/Contents/Info.plist` and
    ///      `$NEW_BUNDLE/Contents/Info.plist` via
    ///      `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier'`; if
    ///      either read fails or either value differs from `$BUNDLE_ID`, the
    ///      script refuses, detaches, and exits 1 with the installed bundle
    ///      completely untouched.
    ///   8. Atomic stage-and-swap (the ONLY way the installed bundle is ever
    ///      modified): `ditto` the new bundle into a staging directory
    ///      alongside it, re-verify the codesign requirement against the
    ///      STAGED copy (proves the copy itself is intact, not just the
    ///      mounted source), `mv` the old bundle aside, `mv` the staged copy
    ///      into the old bundle's place, then `rm -rf` the set-aside old
    ///      bundle. Every one of these uses `mv`/`ditto`/`rm` on paths
    ///      derived from `INSTALL_DIR`/`BUNDLE_NAME`, both of which are
    ///      guarded above (non-empty, not `/`, no slash or dot-only names)
    ///      before this point — those guards protect these derived paths
    ///      too. A failure at the `ditto` step or the staged codesign
    ///      re-check leaves the installed bundle completely untouched
    ///      (nothing renamed yet). A failure moving the old bundle aside
    ///      leaves it in place (never renamed). A failure moving the staged
    ///      copy into place attempts to roll the old bundle back into place
    ///      and logs whether that rollback itself succeeded. See
    ///      `generate`'s implementation for the exact step-by-step shell.
    ///   9. `hdiutil detach` the mounted volume.
    ///   10. `open` the freshly-installed bundle — unless `relaunch` is
    ///      `false`, in which case this step is skipped and a log line is
    ///      emitted in its place.
    ///   11. On the success path only, removes the temp plist file and the
    ///      downloaded DMG (`rm -f`, non-fatal if either is already gone).
    ///      Every failure path removes the temp plist but deliberately
    ///      LEAVES the DMG in place for diagnosis (logged explicitly).
    ///
    /// Every step from `hdiutil attach` onward is written with `set -e`
    /// semantics made explicit (`|| exit 1` after the load-bearing steps)
    /// so a failure partway through stops rather than silently continuing
    /// into the next (potentially destructive) step. All output is expected
    /// to be redirected to a log file by the CALLER (via `nohup ... >>
    /// ~/Library/Logs/vpn-switch/update.log 2>&1 &` or similar), not by this
    /// script itself — this script just writes to stdout/stderr as normal.
    static func generate(
        dmgPath: String,
        parentPID: Int32,
        installDir: String,
        bundleName: String,
        bundleIdentifier: String,
        relaunch: Bool = true,
        requirement: String = UpdateInstaller.designatedRequirement,
        expectedSHA256: String? = nil
    ) -> String {
        let qDMG = shQuote(dmgPath)
        let qPID = shQuote(String(parentPID))
        let qInstallDir = shQuote(installDir)
        let qBundleName = shQuote(bundleName)
        let qRequirement = shQuote(requirement)
        let qBundleID = shQuote(bundleIdentifier)

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
        BUNDLE_ID=\(qBundleID)
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

        # Removes the temp plist. Called on every exit path (success and
        # failure alike) -- unlike the downloaded DMG (deliberately kept on
        # failure for diagnosis), the plist is pure hdiutil-attach output
        # with no diagnostic value once the script has decided what to do
        # with it.
        # Failure-path cleanup: drop the hdiutil plist but keep the DMG so the
        # failure can be diagnosed; say so in the log.
        cleanup_plist() {
            /bin/rm -f "$PLIST_PATH"
            echo "[vpn-switch-update] DMG left at $DMG_PATH for diagnosis"
        }

        echo "[vpn-switch-update] attaching $DMG_PATH"
        if ! hdiutil attach -nobrowse -noverify -readonly -plist "$DMG_PATH" > "$PLIST_PATH"; then
            echo "[vpn-switch-update] hdiutil attach failed"
            cleanup_plist
            exit 1
        fi

        if ! command -v python3 >/dev/null 2>&1; then
            echo "[vpn-switch-update] python3 not found; cannot safely parse hdiutil plist, aborting"
            cleanup_plist
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
            cleanup_plist
            exit 1
        fi
        echo "[vpn-switch-update] mounted at $MOUNT_POINT"

        NEW_BUNDLE="$MOUNT_POINT/$BUNDLE_NAME"
        if [ ! -d "$NEW_BUNDLE" ]; then
            echo "[vpn-switch-update] $NEW_BUNDLE not found on mounted volume, aborting"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
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
            cleanup_plist
            exit 1
        fi

        OLD_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME"
        if [ ! -d "$OLD_BUNDLE" ]; then
            echo "[vpn-switch-update] installed bundle not found at $OLD_BUNDLE, aborting"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi

        # Refuse a symlinked NEW_BUNDLE outright: cp/ditto following a
        # crafted symlink out of the mounted DMG into the install tree is
        # exactly the kind of thing the identity checks below cannot catch
        # after the fact.
        if [ -L "$NEW_BUNDLE" ]; then
            echo "[vpn-switch-update] refusing to install: $NEW_BUNDLE is a symlink"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi

        # Bundle identity sanity, BEFORE anything is moved: both the
        # currently-installed bundle and the new one about to replace it
        # must report the expected CFBundleIdentifier. This is a sanity
        # check independent of the Team ID / codesign checks above -- it
        # guards against a wrong INSTALL_DIR/BUNDLE_NAME pairing pointing at
        # some other (still validly-signed, still Team-ID-matching)
        # application entirely. Every derived path below (STAGED,
        # OLD_ASIDE) is built from the same INSTALL_DIR/BUNDLE_NAME already
        # validated by the empty/root/unsafe-name guards near the top of
        # this script, so those guards protect these derived paths too.
        OLD_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD_BUNDLE/Contents/Info.plist" 2>/dev/null)" || OLD_BUNDLE_ID=""
        NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW_BUNDLE/Contents/Info.plist" 2>/dev/null)" || NEW_BUNDLE_ID=""
        if [ -z "$OLD_BUNDLE_ID" ] || [ "$OLD_BUNDLE_ID" != "$BUNDLE_ID" ]; then
            echo "[vpn-switch-update] refusing to install: $OLD_BUNDLE has unexpected or unreadable CFBundleIdentifier (got '$OLD_BUNDLE_ID', expected '$BUNDLE_ID')"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi
        if [ -z "$NEW_BUNDLE_ID" ] || [ "$NEW_BUNDLE_ID" != "$BUNDLE_ID" ]; then
            echo "[vpn-switch-update] refusing to install: $NEW_BUNDLE has unexpected or unreadable CFBundleIdentifier (got '$NEW_BUNDLE_ID', expected '$BUNDLE_ID')"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi

        # Atomic stage-and-swap. STAGED and OLD_ASIDE are both derived from
        # INSTALL_DIR/BUNDLE_NAME (validated above) plus this script's own
        # pid ($$), so they cannot collide with a concurrent run of this
        # same script.
        STAGED="$INSTALL_DIR/.$BUNDLE_NAME.update-staging.$$"
        OLD_ASIDE="$INSTALL_DIR/.$BUNDLE_NAME.previous.$$"

        /bin/rm -rf "$STAGED"

        echo "[vpn-switch-update] staging $NEW_BUNDLE to $STAGED"
        if ! /usr/bin/ditto "$NEW_BUNDLE" "$STAGED"; then
            echo "[vpn-switch-update] staging copy failed, installed bundle untouched"
            /bin/rm -rf "$STAGED"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi

        # Re-verify the STAGED copy against the same requirement -- proves
        # the ditto copy itself is intact and still satisfies the Team ID
        # pin, not merely that the mounted source did.
        echo "[vpn-switch-update] verifying staged copy $STAGED satisfies designated requirement"
        if ! /usr/bin/codesign --verify --deep --strict -R="$REQUIREMENT" "$STAGED"; then
            echo "[vpn-switch-update] refusing to install: staged copy $STAGED does not satisfy the designated requirement, installed bundle untouched"
            /bin/rm -rf "$STAGED"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi

        echo "[vpn-switch-update] moving $OLD_BUNDLE aside to $OLD_ASIDE"
        if ! /bin/mv "$OLD_BUNDLE" "$OLD_ASIDE"; then
            echo "[vpn-switch-update] could not move old bundle aside, installed bundle untouched"
            /bin/rm -rf "$STAGED"
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi

        echo "[vpn-switch-update] moving staged copy into place at $OLD_BUNDLE"
        if ! /bin/mv "$STAGED" "$OLD_BUNDLE"; then
            echo "[vpn-switch-update] moving staged copy into place failed, attempting rollback"
            if /bin/mv "$OLD_ASIDE" "$OLD_BUNDLE"; then
                echo "[vpn-switch-update] rollback succeeded, installed bundle restored"
            else
                echo "[vpn-switch-update] rollback FAILED -- no app may be installed at $OLD_BUNDLE, previous bundle may still be at $OLD_ASIDE"
            fi
            hdiutil detach "$MOUNT_POINT" -quiet || true
            cleanup_plist
            exit 1
        fi

        echo "[vpn-switch-update] removing set-aside old bundle $OLD_ASIDE"
        if ! /bin/rm -rf "$OLD_ASIDE"; then
            echo "[vpn-switch-update] warning: failed to remove set-aside old bundle at $OLD_ASIDE (new app is already installed and unaffected)"
        fi

        echo "[vpn-switch-update] detaching $MOUNT_POINT"
        hdiutil detach "$MOUNT_POINT" -quiet || true

        \(relaunchStep)

        /bin/rm -f "$PLIST_PATH"
        /bin/rm -f "$DMG_PATH"

        echo "[vpn-switch-update] update complete"
        """
    }
}
