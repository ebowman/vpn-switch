#!/bin/bash
# Resolves CODESIGN_IDENTITY: the code-signing identity used by
# app/build.sh to sign VPNSwitch.app.
#
# Meant to be SOURCED, not executed, from another script's `set -euo
# pipefail` context, e.g.:
#
#   # shellcheck source=lib/resolve-codesign-identity.sh
#   source "${SCRIPT_DIR}/release/lib/resolve-codesign-identity.sh"
#
# Behaviour:
#   1. If CODESIGN_IDENTITY is already set (and non-empty) in the
#      environment, use it as-is (lets an operator pin an exact identity,
#      or pass the literal value `-` to force an ad-hoc signature).
#   2. Otherwise auto-detect the first "Developer ID Application: ..."
#      identity in the login keychain via `security find-identity`.
#   3. If neither is available, CODESIGN_IDENTITY is left empty — the
#      caller decides for itself whether an empty identity (ad-hoc
#      fallback) is acceptable.
#
# A Developer ID identity is keyed on identifier + team, so it is STABLE
# across rebuilds. An ad-hoc identity (`--sign -`) is derived from the
# binary's own hash and therefore changes on every rebuild, which resets
# any login-item registration, notification permission, and TCC grant
# keyed on the app's identity — the operator would be re-prompted (or
# silently lose VPNSwitch's login-item/notification setup) after every
# rebuild. Preferring a stable Developer ID identity is what keeps those
# grants intact across rebuilds.
#
# On exit: CODESIGN_IDENTITY is set (possibly to "").

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)" || true
    # `|| true`: callers source this under `set -euo pipefail`; a missing
    # `security` binary or an early pipe close must fall through to the
    # empty (ad-hoc) result rather than abort the caller.
fi
