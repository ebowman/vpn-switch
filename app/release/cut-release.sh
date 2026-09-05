#!/bin/bash
# One-shot release cutter: runs the entire VPN Switch release pipeline —
# version bump, commit, push, DMG build, notarization, GitHub publish, and
# verification — as a single command, so cutting a release never depends
# on a human correctly remembering (and re-typing) a multi-step manual
# sequence.
#
# Usage: app/release/cut-release.sh <version>
#   <version> is a bare semantic version, X.Y.Z (no leading "v").
#
# This is the ONLY script in this repository that pushes to origin as
# part of a normal release. See docs/runbook.md "## Releasing" for the
# full narrative and the manual fallback sequence (still useful for
# troubleshooting a step in isolation).
#
# Steps (each printed as "==> [n/8] ..." and each one aborting BEFORE the
# next irreversible step if it fails):
#   1. Preconditions (all read-only checks).
#   2. Bump CFBundleShortVersionString / CFBundleVersion in
#      app/VPNSwitch/Info.plist.
#   3. Commit that bump.
#   4. Push to origin main.
#   5. app/release/make-dmg.sh
#   6. app/release/notarize-dmg.sh
#   7. app/release/publish-release.sh
#   8. Verify the published appcast.json reports the new version.
#
# CUT_DRY_RUN=1: runs step 1 for real (read-only; the `gh auth status`
# check is skipped if `gh` itself is not installed), then for steps 2-8
# prints the exact command that WOULD run and does nothing — no file is
# edited, no commit is made, no network write happens.
#
# CUT_ALLOW_BRANCH=1: for dry runs ONLY (silently ignored unless
# CUT_DRY_RUN=1 is also set) — skips the "current branch is main"
# precondition so the rest of a dry run can be exercised from a
# non-main branch (e.g. verifying this script itself from a feature
# branch). Never has any effect on a real (non-dry-run) invocation.
#
# Failure semantics:
#   - Steps 1-3 fail: nothing has been pushed or published; nothing to
#     clean up beyond the working tree itself.
#   - Step 4 (push) fails: the bump commit (step 3) is already made
#     locally and is left in place — re-run this script after fixing
#     whatever blocked the push (or push by hand and resume manually).
#   - Steps 6 or 7 fail: the bump is ALREADY PUSHED (step 4 succeeded).
#     Re-running `make notarize` / `make release` by hand is safe — both
#     are idempotent up to the point where the release tag already
#     exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"

INFO_PLIST="${APP_DIR}/VPNSwitch/Info.plist"
OWNER="ebowman"
REPO="vpn-switch"

DRY_RUN=0
if [ "${CUT_DRY_RUN:-}" = "1" ]; then
    DRY_RUN=1
fi

ALLOW_BRANCH=0
if [ "${DRY_RUN}" = "1" ] && [ "${CUT_ALLOW_BRANCH:-}" = "1" ]; then
    ALLOW_BRANCH=1
fi

usage() {
    echo "Usage: $(basename "$0") <version>" >&2
    echo "  <version> is a bare semantic version, e.g. 0.5.0 (no leading 'v')." >&2
    exit 1
}

if [ "$#" -ne 1 ]; then
    usage
fi

VERSION="$1"

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '${VERSION}' is not a valid X.Y.Z version." >&2
    exit 1
fi

run_or_print() {
    # Runs "$@" for real, or (in dry-run mode) prints it prefixed with
    # "[dry-run] would run:" and returns 0 without executing anything.
    if [ "${DRY_RUN}" = "1" ]; then
        echo "    [dry-run] would run: $*"
        return 0
    fi
    "$@"
}

# --- version_gt: numeric, component-wise comparison of X.Y.Z versions ----
# Returns 0 (true) if $1 is strictly greater than $2.
version_gt() {
    local a="$1" b="$2"
    local a_major a_minor a_patch b_major b_minor b_patch
    IFS='.' read -r a_major a_minor a_patch <<< "${a}"
    IFS='.' read -r b_major b_minor b_patch <<< "${b}"

    if [ "${a_major}" -gt "${b_major}" ]; then return 0; fi
    if [ "${a_major}" -lt "${b_major}" ]; then return 1; fi
    if [ "${a_minor}" -gt "${b_minor}" ]; then return 0; fi
    if [ "${a_minor}" -lt "${b_minor}" ]; then return 1; fi
    if [ "${a_patch}" -gt "${b_patch}" ]; then return 0; fi
    return 1
}

echo "==> [1/8] Checking preconditions..."

# --- current branch is main ------------------------------------------
CURRENT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" != "main" ]; then
    if [ "${ALLOW_BRANCH}" = "1" ]; then
        echo "    [dry-run] CUT_ALLOW_BRANCH=1: skipping 'branch is main' check (current: ${CURRENT_BRANCH})"
    else
        echo "error: current branch is '${CURRENT_BRANCH}', not 'main'. A release must be" >&2
        echo "       cut from main. Switch to main and try again." >&2
        exit 1
    fi
fi

# --- working tree is clean --------------------------------------------
if [ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]; then
    echo "error: working tree is not clean. Commit or stash your changes first:" >&2
    git -C "${REPO_ROOT}" status --short >&2
    exit 1
fi

# --- fetch origin and require HEAD == origin/main -----------------------
if git -C "${REPO_ROOT}" fetch origin >/dev/null 2>&1; then
    LOCAL_HEAD="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
    if REMOTE_HEAD="$(git -C "${REPO_ROOT}" rev-parse origin/main 2>/dev/null)"; then
        if [ "${LOCAL_HEAD}" != "${REMOTE_HEAD}" ]; then
            echo "error: local HEAD (${LOCAL_HEAD}) does not match origin/main (${REMOTE_HEAD})." >&2
            echo "       Push or pull to reconcile before cutting a release." >&2
            exit 1
        fi
    else
        echo "warning: could not resolve 'origin/main'; proceeding without verifying HEAD." >&2
    fi
else
    echo "warning: could not reach 'origin' to fetch; proceeding on the local state alone." >&2
fi

# --- gh auth status ok --------------------------------------------------
if command -v gh >/dev/null 2>&1; then
    if ! gh auth status >/dev/null 2>&1; then
        echo "error: 'gh auth status' failed. Run 'gh auth login' first." >&2
        exit 1
    fi
elif [ "${DRY_RUN}" = "1" ]; then
    echo "    [dry-run] 'gh' not found; skipping 'gh auth status' check."
else
    echo "error: 'gh' (GitHub CLI) is not installed. Install it and run 'gh auth login'." >&2
    exit 1
fi

# --- a Developer ID identity resolves ------------------------------------
# shellcheck source=lib/resolve-codesign-identity.sh
source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"
if [ -z "${CODESIGN_IDENTITY}" ] || [ "${CODESIGN_IDENTITY}" = "-" ]; then
    echo "error: no Developer ID Application identity found. A release DMG can never" >&2
    echo "       be ad-hoc signed. Install a Developer ID certificate, or set" >&2
    echo "       CODESIGN_IDENTITY explicitly, then try again." >&2
    exit 1
fi
echo "    [ok] Developer ID identity: ${CODESIGN_IDENTITY}"

# --- tag v<version> does not exist, locally or on origin -----------------
TAG="v${VERSION}"
if git -C "${REPO_ROOT}" rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "error: tag '${TAG}' already exists locally." >&2
    exit 1
fi
if REMOTE_TAGS="$(git -C "${REPO_ROOT}" ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null)"; then
    if [ -n "${REMOTE_TAGS}" ]; then
        echo "error: tag '${TAG}' already exists on 'origin'." >&2
        exit 1
    fi
else
    echo "warning: could not reach 'origin' to check for an existing '${TAG}' tag." >&2
fi

# --- <version> must be greater than the current Info.plist version -------
CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")"
if ! version_gt "${VERSION}" "${CURRENT_VERSION}"; then
    echo "error: ${VERSION} is not greater than current ${CURRENT_VERSION} (from ${INFO_PLIST})." >&2
    exit 1
fi
echo "    [ok] ${VERSION} > current ${CURRENT_VERSION}"

echo "==> [1/8] All preconditions satisfied."

# --- [2/8] Bump Info.plist ------------------------------------------------
echo "==> [2/8] Bumping version to ${VERSION}..."
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${INFO_PLIST}")"
NEXT_BUILD=$((CURRENT_BUILD + 1))

run_or_print /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${INFO_PLIST}"
run_or_print /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" "${INFO_PLIST}"

# --- [3/8] Commit ----------------------------------------------------------
echo "==> [3/8] Committing version bump..."
if ! run_or_print git -C "${REPO_ROOT}" commit -am "Bump version to ${VERSION}"; then
    echo "error: commit failed. Nothing has been pushed or published." >&2
    exit 1
fi

# --- [4/8] Push ------------------------------------------------------------
echo "==> [4/8] Pushing to origin main..."
if ! run_or_print git -C "${REPO_ROOT}" push origin main; then
    echo "error: push failed. The version-bump commit is ALREADY MADE LOCALLY and" >&2
    echo "       has been left in place. Fix whatever blocked the push (e.g. pull" >&2
    echo "       --rebase to reconcile with a concurrent change), then push by hand" >&2
    echo "       or re-run this script." >&2
    exit 1
fi

# --- [5/8] make-dmg.sh -------------------------------------------------
echo "==> [5/8] Building DMG..."
if ! run_or_print bash "${SCRIPT_DIR}/make-dmg.sh"; then
    echo "error: DMG build failed. The version bump is ALREADY PUSHED (step 4" >&2
    echo "       succeeded); no release or tag exists yet. Fix the build, then" >&2
    echo "       run 'make dmg', 'make notarize', and 'make release' by hand." >&2
    exit 1
fi

# --- [6/8] notarize-dmg.sh ----------------------------------------------
echo "==> [6/8] Notarizing DMG..."
if ! run_or_print bash "${SCRIPT_DIR}/notarize-dmg.sh"; then
    echo "error: notarization failed. The version bump is ALREADY PUSHED (step 4" >&2
    echo "       succeeded). Fix the underlying issue and re-run 'make notarize'" >&2
    echo "       (safe to re-run) followed by 'make release'." >&2
    exit 1
fi

# --- [7/8] publish-release.sh --------------------------------------------
echo "==> [7/8] Publishing release..."
if ! run_or_print bash "${SCRIPT_DIR}/publish-release.sh"; then
    echo "error: publishing failed. The version bump is ALREADY PUSHED (step 4" >&2
    echo "       succeeded), and notarization (step 6) already completed. Fix the" >&2
    echo "       underlying issue and re-run 'make release' (safe to re-run, up to" >&2
    echo "       the point where the release tag already exists)." >&2
    exit 1
fi

# --- [8/8] Verify the published appcast -----------------------------------
echo "==> [8/8] Verifying published appcast..."

APPCAST_URL="https://github.com/${OWNER}/${REPO}/releases/latest/download/appcast.json"
RELEASE_URL="https://github.com/${OWNER}/${REPO}/releases/tag/v${VERSION}"

if [ "${DRY_RUN}" = "1" ]; then
    echo "    [dry-run] would run: curl -fsSL ${APPCAST_URL} (retry up to 5x, 5s apart)"
    echo "    [dry-run] would assert latestVersion == ${VERSION} via python3 json"
    echo "    [dry-run] release URL would be: ${RELEASE_URL}"
else
    ATTEMPT=1
    MAX_ATTEMPTS=5
    APPCAST_JSON=""
    while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
        if APPCAST_JSON="$(curl -fsSL "${APPCAST_URL}" 2>/dev/null)"; then
            LATEST_VERSION="$(python3 -c '
import json
import sys

try:
    data = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
print(data.get("latestVersion", ""))
' "${APPCAST_JSON}" 2>/dev/null || true)"
            if [ "${LATEST_VERSION}" = "${VERSION}" ]; then
                break
            fi
        fi
        echo "    attempt ${ATTEMPT}/${MAX_ATTEMPTS}: appcast not yet reporting ${VERSION}; retrying in 5s..."
        ATTEMPT=$((ATTEMPT + 1))
        if [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; then
            sleep 5
        fi
    done

    if [ "${LATEST_VERSION:-}" != "${VERSION}" ]; then
        echo "error: appcast.json at ${APPCAST_URL} did not report latestVersion == ${VERSION}" >&2
        echo "       after ${MAX_ATTEMPTS} attempts (last seen: ${LATEST_VERSION:-<none>})." >&2
        echo "       The release itself was published; this is a verification-only failure" >&2
        echo "       (GitHub's 'latest' redirect can lag). Check manually: ${RELEASE_URL}" >&2
        exit 1
    fi
    echo "    [ok] appcast latestVersion == ${VERSION}"
fi

echo "==> Done: VPN Switch v${VERSION} cut and published."
echo "==> Release: ${RELEASE_URL}"
if [ "${DRY_RUN}" = "1" ]; then
    echo "==> (dry run: no files were changed, nothing was committed, pushed, or published)"
fi
