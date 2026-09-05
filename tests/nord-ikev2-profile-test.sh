#!/bin/bash
# tests/nord-ikev2-profile-test.sh — exercises bin/nord-ikev2-profile.sh's
# NORD_IKEV2_ENVFILE handling (ownership/mode/symlink checks, the strict
# KEY=VALUE parser, hostname/control-character validation) plus a couple of
# environment-only and determinism checks.
#
# Runs entirely inside a scratch HOME under $TMPDIR; never touches the real
# ~/Library/Application Support/vpn-switch or the user's actual credentials.
#
# Exit status: 0 if every case passes (SKIPs do not fail the run), non-zero
# if any case fails.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GENERATOR="${REPO_ROOT}/bin/nord-ikev2-profile.sh"

SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nord-ikev2-profile-test.XXXXXX")"
cleanup() {
    rm -rf "${SCRATCH_ROOT}"
}
trap cleanup EXIT

FAIL_COUNT=0
PASS_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS: $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: $1"
}

skip() {
    echo "SKIP: $1"
}

# Runs the generator with a fresh scratch HOME. Sets globals:
#   RUN_HOME   the scratch HOME used
#   RUN_OUT    the expected default output path under RUN_HOME
#   RUN_STATUS the generator's exit status
#   RUN_STDOUT / RUN_STDERR  captured output
run_generator() {
    RUN_HOME="$(mktemp -d "${SCRATCH_ROOT}/home.XXXXXX")"
    RUN_OUT="${RUN_HOME}/Library/Application Support/vpn-switch/NordVPN-IKEv2.mobileconfig"
    RUN_STDOUT="$(mktemp "${SCRATCH_ROOT}/stdout.XXXXXX")"
    RUN_STDERR="$(mktemp "${SCRATCH_ROOT}/stderr.XXXXXX")"
    set +e
    HOME="${RUN_HOME}" env -u NORD_IKEV2_SERVER -u NORD_IKEV2_USER -u NORD_IKEV2_PASS \
        "$@" bash "${GENERATOR}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"
    RUN_STATUS=$?
    set -e
}

make_envfile() {
    # make_envfile <path> <content>
    printf '%s' "$2" > "$1"
    chmod 600 "$1"
}

# ---------------------------------------------------------------------------
# (a) Valid envfile produces a valid, mode-600 .mobileconfig containing the
#     escaped server/user, with the password appearing exactly once.
# ---------------------------------------------------------------------------
ENVFILE_A="${SCRATCH_ROOT}/a.env"
make_envfile "${ENVFILE_A}" 'NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER=alice
NORD_IKEV2_PASS=s3cr3tPW
'
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_A}"
if [ "${RUN_STATUS}" -eq 0 ] \
    && [ -f "${RUN_OUT}" ] \
    && plutil -lint "${RUN_OUT}" >/dev/null 2>&1 \
    && [ "$(stat -f '%Lp' "${RUN_OUT}")" = "600" ] \
    && grep -q 'us1234.nordvpn.com' "${RUN_OUT}" \
    && grep -q '<string>alice</string>' "${RUN_OUT}" \
    && [ "$(grep -c 's3cr3tPW' "${RUN_OUT}")" -eq 1 ]; then
    pass "(a) valid envfile produces valid mode-600 mobileconfig with server/user/single password"
else
    fail "(a) valid envfile produces valid mode-600 mobileconfig with server/user/single password (status=${RUN_STATUS})"
    cat "${RUN_STDERR}" >&2
fi

# ---------------------------------------------------------------------------
# (b) Shell-metacharacter payload in the password value must not execute:
#     no file is created at the injected path. Per bin/nord-ikev2-profile.sh's
#     documented parser contract, the value is taken as a literal byte
#     string (no eval/no source), so this line IS syntactically valid
#     KEY=VALUE input and the generator is NOT required to reject it outright
#     (bd dns-config-57f's own text says "Values may contain any bytes except
#     newline", which conflicts with its acceptance line's "results in an
#     error" -- flagged as a bead-internal ambiguity, not resolved here). The
#     security property that IS asserted, unambiguously, is: no shell
#     evaluation ever happens, so the injected `touch` never runs.
# ---------------------------------------------------------------------------
ENVFILE_B="${SCRATCH_ROOT}/b.env"
make_envfile "${ENVFILE_B}" 'NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER=alice
NORD_IKEV2_PASS=x; touch "$HOME/pwned"
'
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_B}"
PWNED_PATH="${RUN_HOME}/pwned"
if [ ! -e "${PWNED_PATH}" ]; then
    pass "(b) injection payload in PASS value never executes (no pwned file created)"
else
    fail "(b) injection payload in PASS value never executes (no pwned file created)"
fi

# ---------------------------------------------------------------------------
# (c) Unknown key is rejected.
# ---------------------------------------------------------------------------
ENVFILE_C="${SCRATCH_ROOT}/c.env"
make_envfile "${ENVFILE_C}" 'NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER=alice
NORD_IKEV2_PASS=s3cr3tPW
FOO=bar
'
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_C}"
if [ "${RUN_STATUS}" -ne 0 ] && [ ! -e "${RUN_OUT}" ]; then
    pass "(c) unknown key FOO=bar is rejected"
else
    fail "(c) unknown key FOO=bar is rejected (status=${RUN_STATUS})"
fi

# ---------------------------------------------------------------------------
# (d) Mode 644 envfile is rejected.
# ---------------------------------------------------------------------------
ENVFILE_D="${SCRATCH_ROOT}/d.env"
make_envfile "${ENVFILE_D}" 'NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER=alice
NORD_IKEV2_PASS=s3cr3tPW
'
chmod 644 "${ENVFILE_D}"
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_D}"
if [ "${RUN_STATUS}" -ne 0 ] && grep -q 'mode 600' "${RUN_STDERR}"; then
    pass "(d) mode 644 envfile is rejected"
else
    fail "(d) mode 644 envfile is rejected (status=${RUN_STATUS})"
fi

# ---------------------------------------------------------------------------
# (e) Envfile owned by another user: cannot be constructed without root.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    skip "(e) envfile owned by another user (running as root, would trivially pass; not tested)"
else
    skip "(e) envfile owned by another user (cannot create a file owned by someone else without root)"
fi

# ---------------------------------------------------------------------------
# (f) Symlink to a valid envfile is rejected.
# ---------------------------------------------------------------------------
ENVFILE_F_TARGET="${SCRATCH_ROOT}/f-target.env"
make_envfile "${ENVFILE_F_TARGET}" 'NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER=alice
NORD_IKEV2_PASS=s3cr3tPW
'
ENVFILE_F_LINK="${SCRATCH_ROOT}/f-link.env"
ln -s "${ENVFILE_F_TARGET}" "${ENVFILE_F_LINK}"
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_F_LINK}"
if [ "${RUN_STATUS}" -ne 0 ] && grep -q 'symlink' "${RUN_STDERR}"; then
    pass "(f) symlink to a valid envfile is rejected"
else
    fail "(f) symlink to a valid envfile is rejected (status=${RUN_STATUS})"
fi

# ---------------------------------------------------------------------------
# (g) Invalid hostname is rejected.
# ---------------------------------------------------------------------------
ENVFILE_G="${SCRATCH_ROOT}/g.env"
make_envfile "${ENVFILE_G}" 'NORD_IKEV2_SERVER=bad host!
NORD_IKEV2_USER=alice
NORD_IKEV2_PASS=s3cr3tPW
'
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_G}"
if [ "${RUN_STATUS}" -ne 0 ] && [ ! -e "${RUN_OUT}" ]; then
    pass "(g) invalid hostname 'bad host!' is rejected"
else
    fail "(g) invalid hostname 'bad host!' is rejected (status=${RUN_STATUS})"
fi

# ---------------------------------------------------------------------------
# (h) Password containing a literal tab is rejected, and the value is never
#     printed (stdout/stderr must not contain the literal password value).
# ---------------------------------------------------------------------------
ENVFILE_H="${SCRATCH_ROOT}/h.env"
TAB_PASS="$(printf 'sec\tret')"
printf 'NORD_IKEV2_SERVER=us1234.nordvpn.com\nNORD_IKEV2_USER=alice\nNORD_IKEV2_PASS=%s\n' "${TAB_PASS}" > "${ENVFILE_H}"
chmod 600 "${ENVFILE_H}"
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_H}"
if [ "${RUN_STATUS}" -ne 0 ] \
    && ! grep -qF "${TAB_PASS}" "${RUN_STDOUT}" "${RUN_STDERR}" \
    && [ ! -e "${RUN_OUT}" ]; then
    pass "(h) password with literal tab is rejected and never printed"
else
    fail "(h) password with literal tab is rejected and never printed (status=${RUN_STATUS})"
fi

# ---------------------------------------------------------------------------
# (i) Quoted value NORD_IKEV2_USER="alice" yields user alice in the output.
# ---------------------------------------------------------------------------
ENVFILE_I="${SCRATCH_ROOT}/i.env"
make_envfile "${ENVFILE_I}" 'NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER="alice"
NORD_IKEV2_PASS=s3cr3tPW
'
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_I}"
if [ "${RUN_STATUS}" -eq 0 ] && grep -q '<string>alice</string>' "${RUN_OUT}"; then
    pass "(i) quoted value NORD_IKEV2_USER=\"alice\" yields user alice"
else
    fail "(i) quoted value NORD_IKEV2_USER=\"alice\" yields user alice (status=${RUN_STATUS})"
fi

# ---------------------------------------------------------------------------
# (j) Running the generator twice on the same valid input produces
#     byte-identical output. PayloadUUIDs in the script are fixed constants
#     (not generated per-run), so no UUID-stripping is needed.
# ---------------------------------------------------------------------------
ENVFILE_J="${SCRATCH_ROOT}/j.env"
make_envfile "${ENVFILE_J}" 'NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER=alice
NORD_IKEV2_PASS=s3cr3tPW
'
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_J}"
OUT_J1="${SCRATCH_ROOT}/j1.mobileconfig"
cp "${RUN_OUT}" "${OUT_J1}"
run_generator env NORD_IKEV2_ENVFILE="${ENVFILE_J}"
OUT_J2="${SCRATCH_ROOT}/j2.mobileconfig"
cp "${RUN_OUT}" "${OUT_J2}"
if cmp -s "${OUT_J1}" "${OUT_J2}"; then
    pass "(j) two runs on identical input produce byte-identical output"
else
    fail "(j) two runs on identical input produce byte-identical output"
fi

# ---------------------------------------------------------------------------
# Environment-only invocation (no envfile) still works under HOME override.
# ---------------------------------------------------------------------------
RUN_HOME="$(mktemp -d "${SCRATCH_ROOT}/home.XXXXXX")"
RUN_OUT="${RUN_HOME}/Library/Application Support/vpn-switch/NordVPN-IKEv2.mobileconfig"
set +e
HOME="${RUN_HOME}" NORD_IKEV2_SERVER=us1234.nordvpn.com NORD_IKEV2_USER=alice NORD_IKEV2_PASS=s3cr3tPW \
    bash "${GENERATOR}" >"${SCRATCH_ROOT}/env-only.stdout" 2>"${SCRATCH_ROOT}/env-only.stderr"
ENV_ONLY_STATUS=$?
set -e
if [ "${ENV_ONLY_STATUS}" -eq 0 ] && [ -f "${RUN_OUT}" ] && plutil -lint "${RUN_OUT}" >/dev/null 2>&1; then
    pass "environment-only invocation (no NORD_IKEV2_ENVFILE) still works"
else
    fail "environment-only invocation (no NORD_IKEV2_ENVFILE) still works (status=${ENV_ONLY_STATUS})"
fi

echo ""
echo "==================================================================="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "==================================================================="

if [ "${FAIL_COUNT}" -ne 0 ]; then
    exit 1
fi
exit 0
