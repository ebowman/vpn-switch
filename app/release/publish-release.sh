#!/bin/bash
# Publishes a GitHub release: generates the stable-named update manifest
# describing the DMG that was JUST built, then uploads both the DMG and
# the manifest as release assets via `gh release create`.
#
# This is the terminal step of the release pipeline:
#   app/build.sh -> app/release/make-dmg.sh -> app/release/notarize-dmg.sh
#   -> app/release/publish-release.sh (this script, invoked via `make release`)
#
# Usage:
#   app/release/publish-release.sh
#   app/release/publish-release.sh --source-only   # source only, run no flow
#
# Every precondition below fails fast with exit 1 and a specific,
# actionable message, naming exactly which precondition failed, so a bad
# release is caught here rather than discovered later (e.g. as a manifest
# describing the wrong binary, or a broken self-update).
#
# Preconditions, in order:
#   1. A git remote named "origin" exists, parses as a GitHub remote, and
#      resolves to host github.com, owner "ebowman", repo "vpn-switch" —
#      matching the pins baked into the app itself
#      (app/VPNSwitch/Sources/VPNSwitch/UpdateInstaller.swift,
#      pinnedDMGHost / pinnedDMGPathPrefix). A release published from any
#      other remote would produce a manifest whose dmgURL the app's own
#      updater rejects at upgrade time — fail here instead, where the
#      cause is obvious.
#   2. VERSION is non-empty, read from the BUILT app bundle's Info.plist
#      via app/release/read-app-version.sh (never a shell literal, never
#      the repo's Info.plist source directly) — see that script's header
#      for why.
#   3. The working tree is clean (`git status --porcelain` is empty) — a
#      release must describe an exact, reproducible commit.
#   4. The tag v$VERSION does not already exist, locally or on origin —
#      refuses to silently re-publish or shadow a prior release. An
#      unreachable remote degrades this check to a warning rather than an
#      error, since a network hiccup must not block a release.
#   5. The DMG exists at the expected path AND passes the same Gatekeeper
#      acceptance check UpdateInstaller runs before installing any
#      update: `spctl -a -t open --context context:primary-signature`.
#      This is the exact test used elsewhere in the pipeline
#      (app/release/notarize-dmg.sh) — never weakened here.
#
# Manifest generation:
#   The dmgSHA256 digest is computed from the DMG file THAT WAS JUST
#   VERIFIED ABOVE, so the manifest can never describe a different binary
#   than the one actually being uploaded.
#
#   The manifest JSON fields are exactly {latestVersion, notes, dmgURL,
#   dmgSHA256}, matching
#   app/VPNSwitch/Sources/VPNSwitch/UpdateManifest.swift's Codable field
#   names exactly. A mismatch here would silently break every future
#   update check, so the field names must never be changed without
#   updating that Swift type in lockstep.
#
#   The manifest FILENAME IS STABLE ACROSS RELEASES (appcast.json) — this
#   is deliberate and load-bearing: it is what makes GitHub's
#   /releases/latest/download/appcast.json redirect (see
#   UpdateFetcher.manifestURLString) always resolve to the manifest for
#   the most recent release, without the self-updater needing to know a
#   version number in advance. The DMG's filename, by contrast, IS
#   versioned (VPNSwitch-<version>.dmg) so multiple releases' DMGs can
#   coexist. Getting this backwards (a versioned manifest name, or a
#   stable DMG name) would silently and permanently break update
#   discovery — do not "fix" this without understanding why.
#
#   dmgURL is a real https://github.com/... release-download URL, because
#   UpdateInstaller pins dmgURL to host github.com AND path prefix
#   /ebowman/vpn-switch/releases/download/
#   (app/VPNSwitch/Sources/VPNSwitch/UpdateInstaller.swift,
#   pinnedDMGHost / pinnedDMGPathPrefix) and rejects anything else.
#
# Owner/repo derivation:
#   Parsed from `git remote get-url origin`, never hardcoded, so a fork or
#   repo rename works without editing this script (though see precondition
#   1 above: the resolved owner/repo must still match the app's pins, or
#   the release is refused). Handles both SSH
#   (git@github.com:OWNER/REPO.git) and HTTPS
#   (https://github.com/OWNER/REPO.git) forms, with or without a trailing
#   ".git". The parser is factored into parse_github_remote() below so it
#   can be exercised directly against arbitrary test inputs without ever
#   touching the real git remote configuration, via:
#     source app/release/publish-release.sh --source-only
#
# Publishing:
#   gh release create "v$VERSION" --title "VPN Switch v$VERSION" \
#       --generate-notes "$DMG_PATH" "$MANIFEST_PATH"
#
# This script performs a real network operation (gh release create) and
# is NEVER invoked as a side effect of a bare `make` or `make all` — only
# `make release`, run deliberately by a human operator, calls it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"

APP_NAME="VPNSwitch"
BUILD_DIR="${APP_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
MANIFEST_NAME="appcast.json"

# Pins that must match app/VPNSwitch/Sources/VPNSwitch/UpdateInstaller.swift
# (pinnedDMGHost / pinnedDMGPathPrefix) exactly. Kept here as named
# constants, not inlined, so the precondition-1 error message and the
# actual dmgURL construction can never drift from each other.
PINNED_HOST="github.com"
PINNED_OWNER="ebowman"
PINNED_REPO="vpn-switch"

# --- parse_github_remote --------------------------------------------------
# Parses a git remote URL (SSH or HTTPS github.com form) into "HOST OWNER
# REPO", space-separated, printed to stdout. Returns non-zero (and prints
# nothing) if the URL does not match either recognized form.
#
# Factored out as a standalone function (rather than inlined) specifically
# so it can be unit-exercised directly with arbitrary test strings, e.g.:
#   source app/release/publish-release.sh --source-only
#   parse_github_remote "git@github.com:OWNER/REPO.git"
#   parse_github_remote "https://github.com/OWNER/REPO"
parse_github_remote() {
    local url="$1"
    local host owner repo

    if [[ "${url}" =~ ^git@([^:]+):([^/]+)/(.+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        owner="${BASH_REMATCH[2]}"
        repo="${BASH_REMATCH[3]}"
    elif [[ "${url}" =~ ^https://([^/]+)/([^/]+)/([^/]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        owner="${BASH_REMATCH[2]}"
        repo="${BASH_REMATCH[3]}"
    else
        return 1
    fi

    repo="${repo%.git}"

    if [ -z "${host}" ] || [ -z "${owner}" ] || [ -z "${repo}" ]; then
        return 1
    fi

    echo "${host} ${owner} ${repo}"
}

# Allow this file to be sourced purely for its functions (e.g. to unit-test
# parse_github_remote) without running the release flow, by passing
# --source-only as the sole argument.
if [ "${1:-}" = "--source-only" ]; then
    return 0 2>/dev/null || exit 0
fi

echo "==> Checking release preconditions..."

# --- Precondition 1: origin exists, parses, and matches the app's pins ----
if ! REMOTE_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null)"; then
    echo "error: no git remote named 'origin' is configured." >&2
    echo "" >&2
    echo "       'make release' publishes to a GitHub repository via 'origin',"  >&2
    echo "       but this checkout has no remote at all (git remote -v is empty)." >&2
    echo "       Before running 'make release', create the GitHub repository and" >&2
    echo "       add it as 'origin', e.g.:" >&2
    echo "" >&2
    echo "         gh repo create ${PINNED_OWNER}/${PINNED_REPO} --private --source=. --remote=origin" >&2
    echo "         # or, if the repository already exists on GitHub:" >&2
    echo "         git remote add origin git@github.com:${PINNED_OWNER}/${PINNED_REPO}.git" >&2
    echo "" >&2
    echo "       Then rerun 'make release'." >&2
    exit 1
fi

if ! GITHUB_PARTS="$(parse_github_remote "${REMOTE_URL}")"; then
    echo "error: could not parse the 'origin' remote URL as a GitHub remote: ${REMOTE_URL}" >&2
    echo "       Expected either 'git@HOST:OWNER/REPO.git' or 'https://HOST/OWNER/REPO'." >&2
    exit 1
fi
read -r GIT_HOST OWNER REPO <<< "${GITHUB_PARTS}"
echo "==> origin: host=${GIT_HOST} owner=${OWNER} repo=${REPO}"

# The dmgURL below hardcodes github.com/ebowman/vpn-switch because
# UpdateInstaller pins the download host AND path prefix to exactly that
# (see pinnedDMGHost / pinnedDMGPathPrefix). Releasing from any other
# remote would therefore publish a manifest pointing at a URL the app's
# own updater rejects — a silent dead end discovered only at upgrade time.
# Fail here instead, where the cause is obvious.
if [ "${GIT_HOST}" != "${PINNED_HOST}" ] || [ "${OWNER}" != "${PINNED_OWNER}" ] || [ "${REPO}" != "${PINNED_REPO}" ]; then
    echo "error: 'origin' resolves to ${GIT_HOST}/${OWNER}/${REPO}, but the app pins" >&2
    echo "       downloads to ${PINNED_HOST}/${PINNED_OWNER}/${PINNED_REPO}." >&2
    echo "       Publishing from here would produce a manifest whose dmgURL the app" >&2
    echo "       itself rejects. Release from the ${PINNED_HOST}/${PINNED_OWNER}/${PINNED_REPO}" >&2
    echo "       remote, or update the pins in" >&2
    echo "       app/VPNSwitch/Sources/VPNSwitch/UpdateInstaller.swift and its tests" >&2
    echo "       together." >&2
    exit 1
fi

# --- Precondition 2: VERSION non-empty, read from the BUILT bundle --------
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "error: ${APP_BUNDLE} not found. Run app/release/make-dmg.sh (or app/build.sh) first." >&2
    exit 1
fi

VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" short)"
if [ -z "${VERSION}" ]; then
    echo "error: could not read a version from ${APP_BUNDLE} via app/release/read-app-version.sh." >&2
    exit 1
fi
echo "==> version (from built bundle): ${VERSION}"

# --- Precondition 3: working tree is clean ---------------------------------
if [ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]; then
    echo "error: working tree is not clean. A release must describe an exact," >&2
    echo "       reproducible commit. Commit or stash your changes and try again:" >&2
    echo "" >&2
    git -C "${REPO_ROOT}" status --short >&2
    exit 1
fi

# --- Precondition 4: tag v$VERSION does not already exist ------------------
TAG="v${VERSION}"
if git -C "${REPO_ROOT}" rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "error: tag '${TAG}' already exists locally. Bump the version before releasing" >&2
    echo "       again, or delete the stale tag if this was a mistake:" >&2
    echo "         git tag -d ${TAG}" >&2
    exit 1
fi

# Also check the REMOTE. A tag can exist upstream without existing locally
# (another machine, or a release made by hand), and the local check above
# would happily sail past it — leaving `gh release create` to fail late,
# AFTER the manifest has already been written. Fail here instead, before
# anything is produced. A network hiccup must not block a release, so an
# unreachable remote is a warning rather than an error.
if REMOTE_TAGS="$(git -C "${REPO_ROOT}" ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null)"; then
    if [ -n "${REMOTE_TAGS}" ]; then
        echo "error: tag '${TAG}' already exists on 'origin', though not locally." >&2
        echo "       A release for this version has probably already been published." >&2
        echo "       Bump the version, or inspect: git ls-remote --tags origin '${TAG}'" >&2
        exit 1
    fi
else
    echo "warning: could not reach 'origin' to check for an existing '${TAG}' tag;" >&2
    echo "         proceeding on the local check alone." >&2
fi

# --- Precondition 5: the DMG exists AND is notarized ------------------------
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

if [ ! -f "${DMG_PATH}" ]; then
    echo "error: DMG not found at ${DMG_PATH}." >&2
    echo "       Run app/release/make-dmg.sh && app/release/notarize-dmg.sh first." >&2
    exit 1
fi

echo "==> Verifying ${DMG_NAME} is notarized (spctl)..."
SPCTL_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/vpnswitch-release-spctl.XXXXXX")"
trap 'rm -f "${SPCTL_OUTPUT}"' EXIT
if ! spctl -a -t open --context context:primary-signature "${DMG_PATH}" > "${SPCTL_OUTPUT}" 2>&1; then
    echo "error: ${DMG_NAME} is not notarized (spctl rejected it). This DMG is not" >&2
    echo "       shippable. Run app/release/notarize-dmg.sh on it before releasing:" >&2
    echo "----- spctl output -----" >&2
    cat "${SPCTL_OUTPUT}" >&2
    echo "-------------------------" >&2
    exit 1
fi
echo "==> ${DMG_NAME} is notarized."

echo "==> All preconditions satisfied."

# --- Generate the manifest --------------------------------------------------
# The manifest FILENAME MUST BE STABLE ACROSS RELEASES (appcast.json), never
# versioned — see the header comment above for why this is load-bearing for
# GitHub's /releases/latest/download/ redirect. Do not rename this per
# release.
MANIFEST_PATH="${BUILD_DIR}/${MANIFEST_NAME}"

SHA="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
if [ -z "${SHA}" ]; then
    echo "error: could not compute a SHA-256 digest for ${DMG_PATH}." >&2
    exit 1
fi

RELEASE_NOTES_URL="https://${GIT_HOST}/${OWNER}/${REPO}/releases/tag/${TAG}"
# UpdateInstaller pins dmgURL to host github.com AND path prefix
# /ebowman/vpn-switch/releases/download/ (see
# app/VPNSwitch/Sources/VPNSwitch/UpdateInstaller.swift, pinnedDMGHost /
# pinnedDMGPathPrefix) — this must always be a real
# github.com/ebowman/vpn-switch release-download URL, never e.g. a raw
# git@ host or an enterprise GitHub host.
DMG_URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/${DMG_NAME}"

echo "==> Generating ${MANIFEST_NAME}..."
cat > "${MANIFEST_PATH}" <<EOF
{
  "latestVersion": "${VERSION}",
  "notes": "${RELEASE_NOTES_URL}",
  "dmgURL": "${DMG_URL}",
  "dmgSHA256": "${SHA}"
}
EOF
echo "==> Wrote ${MANIFEST_PATH}:"
cat "${MANIFEST_PATH}"

# --- Publish -----------------------------------------------------------
echo "==> Publishing release ${TAG} to ${OWNER}/${REPO}..."
gh release create "${TAG}" \
    --title "VPN Switch v${VERSION}" \
    --generate-notes \
    "${DMG_PATH}" \
    "${MANIFEST_PATH}"

echo "==> Done: published ${TAG} with ${DMG_NAME} and ${MANIFEST_NAME}."
