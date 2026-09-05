#!/bin/bash
# Assembles a signed, distributable DMG of VPN Switch.app: builds (via
# app/build.sh) the app bundle, stages it (renamed to "VPN Switch.app",
# the name Bundle.main reports once installed) in a temp directory
# alongside an /Applications symlink for drag-to-install, packs that into
# a read-only compressed disk image, and code-signs the DMG itself.
#
# Usage: app/release/make-dmg.sh
# Output: app/build/VPNSwitch-<version>.dmg (path printed on success).
#         <version> is CFBundleShortVersionString read back OUT of the
#         just-built bundle via app/release/read-app-version.sh, never
#         from the repo's Info.plist source directly — the filename must
#         reflect what was actually built.
#
# This script ALWAYS runs app/build.sh first rather than requiring a
# pre-built .app: build.sh is itself idempotent/fast to rerun, and always
# building from source guarantees the DMG can never silently contain a
# stale bundle left over from an earlier checkout.
#
# Signing: the DMG is signed with the same identity as the .app (see
# app/release/lib/resolve-codesign-identity.sh, shared with build.sh so
# the two never drift). Unlike build.sh, this script does NOT fall back
# to ad-hoc signing by default — an ad-hoc-signed DMG can never be
# notarized, so shipping one under a release filename would be a silently
# unusable artifact. Set ALLOW_ADHOC_DMG=1 to explicitly opt into an
# ad-hoc-signed DMG for local testing only; such a DMG must never be
# distributed.
#
# Idempotent: safe to run repeatedly. Removes any DMG already at the
# target path before creating the new one, and cleans up its staging
# directory and mount point on both success and failure via trap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${APP_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/VPNSwitch.app"
STAGED_APP_NAME="VPN Switch.app"
VOLUME_NAME="VPN Switch"

STAGING_DIR=""
MOUNT_POINT=""

cleanup() {
    # Detach unconditionally when a mount point was recorded, tolerating
    # failure, rather than gating on `mount | grep`. mktemp under TMPDIR
    # returns an UNRESOLVED path (/var/folders/...) while mount(8) prints the
    # RESOLVED one (/private/var/folders/...), so that guard never matched on
    # stock macOS and the detach was silently skipped — leaking a /Volumes
    # mount on every failure, which is precisely what this trap exists to
    # prevent. `|| true` keeps cleanup safe when nothing is attached.
    if [ -n "${MOUNT_POINT}" ]; then
        hdiutil detach "${MOUNT_POINT}" -quiet -force 2>/dev/null || true
    fi
    if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT

echo "==> Building VPNSwitch.app..."
"${APP_DIR}/build.sh"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "error: expected ${APP_BUNDLE} after build.sh, but it is missing" >&2
    exit 1
fi

# Read the version back OUT of the built bundle, matching build.sh's own
# approach, so the DMG filename always reflects what was actually built
# rather than what the repo's Info.plist source merely intends.
SHORT_VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" short)"
if [ -z "${SHORT_VERSION}" ]; then
    echo "error: could not read version from ${APP_BUNDLE}" >&2
    exit 1
fi

DMG_NAME="VPNSwitch-${SHORT_VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

# Same identity-resolution logic as build.sh (see the sourced file for
# rationale) so the app and its DMG are always signed with the same
# identity.
# shellcheck source=lib/resolve-codesign-identity.sh
source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"

if [ -z "${CODESIGN_IDENTITY}" ] || [ "${CODESIGN_IDENTITY}" = "-" ]; then
    if [ "${ALLOW_ADHOC_DMG:-}" = "1" ]; then
        echo "==> WARNING: no Developer ID identity found (or ad-hoc requested);" >&2
        echo "    ALLOW_ADHOC_DMG=1 set, so proceeding with an ad-hoc-signed DMG." >&2
        echo "    This DMG can NEVER be notarized and must not be distributed —" >&2
        echo "    local testing only." >&2
        CODESIGN_IDENTITY="-"
    else
        echo "error: no Developer ID Application identity found (CODESIGN_IDENTITY is unset or '-')." >&2
        echo "       An ad-hoc-signed DMG can never be notarized, so refusing to produce one" >&2
        echo "       under a release filename. Install a Developer ID certificate, set" >&2
        echo "       CODESIGN_IDENTITY explicitly, or set ALLOW_ADHOC_DMG=1 to override for" >&2
        echo "       local testing only (such a DMG must not be distributed)." >&2
        exit 1
    fi
fi

echo "==> Staging DMG contents..."
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpnswitch-dmg-staging.XXXXXX")"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/${STAGED_APP_NAME}"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> Removing any pre-existing DMG at ${DMG_PATH}..."
rm -f "${DMG_PATH}"

echo "==> Creating ${DMG_NAME}..."
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    echo "==> Ad-hoc code-signing ${DMG_NAME} (ALLOW_ADHOC_DMG=1; local testing only)..."
    codesign --force --sign - "${DMG_PATH}"
else
    echo "==> Code-signing ${DMG_NAME} with: ${CODESIGN_IDENTITY}"
    codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp "${DMG_PATH}"
fi

echo "==> Verifying DMG signature..."
codesign -dv "${DMG_PATH}"

echo "==> Done: ${DMG_PATH}"
