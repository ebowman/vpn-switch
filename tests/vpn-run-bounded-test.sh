#!/bin/bash
# tests/vpn-run-bounded-test.sh — exercises the shared pure-shell bounded
# runner _vpn_run_bounded (defined identically, guarded by
# `declare -f _vpn_run_bounded`, in both lib/tailscale-ctl.sh and
# lib/nord-ctl.sh -- see dns-config-ci5's PART B and dns-config-w65).
#
# Regression under test: the watchdog subshell that _vpn_run_bounded starts
# MUST have its own stdout/stderr redirected to /dev/null. Without that
# redirect, a caller's own `out="$(_vpn_run_bounded 5 cmd)"` command
# substitution blocks until the watchdog subshell itself exits (i.e. up to
# the full timeout), even after `cmd` already finished -- measured
# regression: turned a 0.37s call into 15.29s. Case 1 below reproduces the
# capture pattern that exposed this, and case 1a proves the test suite
# itself CAN detect the bug by sourcing a sed-derived broken copy of the
# REAL lib/tailscale-ctl.sh (see case 1a's own comment for why the probe
# command must take a few hundred ms, not be near-instant).
#
# Runs entirely against the shared function sourced from the repo's own
# lib/*.sh (path overridable via VPN_RUN_BOUNDED_LIB, default
# lib/tailscale-ctl.sh); spawns only /bin/echo, /bin/sleep, /bin/sh,
# /usr/bin/true, /usr/bin/head, /usr/bin/tr as test subjects. Never
# touches real VPN/DNS state, network, or credentials.
#
# Exit status: 0 if every case passes, non-zero if any case fails.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VPN_RUN_BOUNDED_LIB="${VPN_RUN_BOUNDED_LIB:-${REPO_ROOT}/lib/tailscale-ctl.sh}"

SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpn-run-bounded-test.XXXXXX")"
SOURCE_BOTH_ERR="${TMPDIR:-/tmp}/vpn-run-bounded-test.source-both.$$.err"
cleanup() {
    rm -rf "${SCRATCH_DIR}"
    rm -f "${SOURCE_BOTH_ERR}" 2>/dev/null
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

# now — sub-second wall clock via perl's Time::HiRes (perl ships on macOS,
# including GitHub's macos-latest runners). Falls back to whole-second
# `date +%s` if perl is unavailable, so the suite still runs (with coarser
# timing assertions satisfied either way given the margins used below).
now() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'print time'
    else
        date +%s
    fi
}

elapsed_since() {
    # elapsed_since <start> — prints elapsed seconds (float or int
    # depending on `now`'s source) with awk, avoiding bc/bash arithmetic
    # limitations on floats.
    local start="$1"
    local end
    end="$(now)"
    awk -v s="${start}" -v e="${end}" 'BEGIN { printf "%.3f", (e - s) }'
}

ge_threshold() {
    # ge_threshold <value> <threshold> — true (0) if value >= threshold.
    awk -v v="$1" -v t="$2" 'BEGIN { exit !(v >= t) }'
}

le_threshold() {
    # le_threshold <value> <threshold> — true (0) if value <= threshold.
    awk -v v="$1" -v t="$2" 'BEGIN { exit !(v <= t) }'
}

# ---------------------------------------------------------------------------
# Track stray flag files across the whole run (case 6): snapshot the
# .vpn_run_bounded.* glob in $TMPDIR before/after every case that follows.
# ---------------------------------------------------------------------------
FLAG_GLOB="${TMPDIR:-/tmp}/.vpn_run_bounded.*"

# ===========================================================================
# Source the shared function. lib/tailscale-ctl.sh documents itself as
# having NO side effects when sourced (no top-level external calls, no
# required env vars -- TS_CTL_BIN/TS_CTL_CALL_TIMEOUT both default via
# ${VAR:-default}), so it sources cleanly under `set -u` in a fresh bash.
# VPN_RUN_BOUNDED_LIB lets this suite be pointed at an alternate copy of
# the lib (e.g. a deliberately broken one) for verifying the suite itself
# catches the regression; it defaults to the real lib/tailscale-ctl.sh.
# ===========================================================================
# shellcheck source=/dev/null
source "${VPN_RUN_BOUNDED_LIB}"

if ! declare -f _vpn_run_bounded >/dev/null 2>&1; then
    fail "_vpn_run_bounded is defined after sourcing ${VPN_RUN_BOUNDED_LIB}"
    echo ""
    echo "==================================================================="
    echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    echo "==================================================================="
    exit 1
else
    pass "_vpn_run_bounded is defined after sourcing ${VPN_RUN_BOUNDED_LIB}"
fi

# ---------------------------------------------------------------------------
# Case 1a (regression + self-check, tied to the REAL code): derive a
# broken copy of the actual sourced lib (VPN_RUN_BOUNDED_LIB) by using sed
# to strip ONLY the watchdog subshell's `>/dev/null 2>&1` redirect (the
# exact line `    ) >/dev/null 2>&1 &` -> `    ) &`), then source that
# broken copy in a subshell and confirm IT blocks a $(...) capture close
# to its timeout. This proves the suite can detect the exact regression,
# using the lib's own real source rather than a hand-maintained copy that
# could drift out of sync with it.
#
# Guard: assert the sed produced EXACTLY one changed line (diff prints one
# '<' and one '>' line for a single changed line, i.e. `grep -c '^[<>]'`
# == 2). If the lib's watchdog line shape ever changes, this self-check
# fails loudly instead of silently sedding zero lines and testing an
# unmodified (non-broken) copy.
#
# Why the probe command must take a few hundred ms rather than be
# near-instant (e.g. /bin/echo hi, ~1ms): the underlying bug is a race
# between (a) the parent's `kill -TERM "$watchdog_pid"` (sent right after
# the wrapped command exits) reaching the watchdog subshell BEFORE it
# forks its own `sleep`, vs. (b) the watchdog already having forked
# `sleep` by the time the signal arrives, in which case that orphaned
# `sleep` keeps inheriting (and holding open) the broken watchdog's
# un-redirected stdout/stderr -- which is the caller's $(...) pipe -- for
# the rest of its duration. With an ~1ms wrapped command, the parent
# almost always kills the watchdog before it forks sleep, so the bug does
# not reproduce reliably. Real callers this guards (tailscale status,
# shortcuts list) run 100ms+, which is why the original regression was a
# deterministic 15s hang. `sleep 0.3; echo hi` reproduces that same
# few-hundred-ms window and was measured to hang deterministically (see
# case 1a below).
# ---------------------------------------------------------------------------
BROKEN_LIB="${SCRATCH_DIR}/$(basename "${VPN_RUN_BOUNDED_LIB}").broken.sh"
sed 's/) >\/dev\/null 2>&1 &/) \&/' "${VPN_RUN_BOUNDED_LIB}" > "${BROKEN_LIB}"

DIFF_LINE_COUNT="$(diff "${VPN_RUN_BOUNDED_LIB}" "${BROKEN_LIB}" | grep -c '^[<>]' || true)"
if [ "${DIFF_LINE_COUNT}" -eq 2 ]; then
    pass "(1a setup) sed-derived broken copy of ${VPN_RUN_BOUNDED_LIB} differs by exactly 1 changed line (diff line count=${DIFF_LINE_COUNT})"
else
    fail "(1a setup) sed-derived broken copy of ${VPN_RUN_BOUNDED_LIB} differs by exactly 1 changed line (diff line count=${DIFF_LINE_COUNT}, expected 2) -- the lib's watchdog line shape may have changed"
fi

BROKEN_TIMEOUT_SECS=2
broken_hangs=0
broken_attempts=3
broken_elapsed="0"
broken_out=""
for i in $(seq 1 "${broken_attempts}"); do
    start="$(now)"
    set +e
    broken_out="$(
        # _vpn_run_bounded is already defined in this subshell (inherited
        # from the real lib sourced at top-of-script) and the real lib's
        # `if ! declare -f _vpn_run_bounded` guard means simply sourcing
        # the broken copy on top of it is a no-op -- unset it first so the
        # broken copy's definition actually takes effect here.
        unset -f _vpn_run_bounded
        # shellcheck source=/dev/null
        source "${BROKEN_LIB}"
        _vpn_run_bounded "${BROKEN_TIMEOUT_SECS}" /bin/sh -c 'sleep 0.3; echo hi'
    )"
    set -e
    broken_elapsed="$(elapsed_since "${start}")"
    if [ "${broken_out}" = "hi" ] && ge_threshold "${broken_elapsed}" "1.8"; then
        broken_hangs=$((broken_hangs + 1))
    fi
    echo "  (1a attempt ${i}/${broken_attempts}) elapsed=${broken_elapsed}s out=${broken_out}"
done
if [ "${broken_hangs}" -eq "${broken_attempts}" ]; then
    pass "(1a self-check) broken lib (redirect stripped) hangs ~timeout on all ${broken_attempts}/${broken_attempts} attempts -- proves this suite can detect the regression"
else
    fail "(1a self-check) broken lib (redirect stripped) hung on only ${broken_hangs}/${broken_attempts} attempts (expected ${broken_attempts}/${broken_attempts}; see per-attempt timings above for the measured distribution)"
fi

# ---------------------------------------------------------------------------
# Case 1: the real _vpn_run_bounded returns promptly under $(...) capture.
# Uses a ~0.3s wrapped command (not a near-instant one) so this exercises
# the same timing window as case 1a's regression -- see case 1a's comment
# for why that matters. Run 5 times; every run must complete under 1.5s.
# ---------------------------------------------------------------------------
CASE1_PROBE_ATTEMPTS=5
case1_all_fast=1
for i in $(seq 1 "${CASE1_PROBE_ATTEMPTS}"); do
    start="$(now)"
    set +e
    out="$(_vpn_run_bounded 3 /bin/sh -c 'sleep 0.3; echo hi')"
    rc=$?
    set -e
    elapsed="$(elapsed_since "${start}")"
    echo "  (1 attempt ${i}/${CASE1_PROBE_ATTEMPTS}) elapsed=${elapsed}s rc=${rc} out=${out}"
    if ! le_threshold "${elapsed}" "1.5" || [ "${rc}" -ne 0 ] || [ "${out}" != "hi" ]; then
        case1_all_fast=0
    fi
done
if [ "${case1_all_fast}" -eq 1 ]; then
    pass "(1) \$(_vpn_run_bounded 3 /bin/sh -c 'sleep 0.3; echo hi') completes in <1.5s, rc=0, out=hi on all ${CASE1_PROBE_ATTEMPTS}/${CASE1_PROBE_ATTEMPTS} attempts"
else
    fail "(1) \$(_vpn_run_bounded 3 /bin/sh -c 'sleep 0.3; echo hi') completes in <1.5s, rc=0, out=hi on all ${CASE1_PROBE_ATTEMPTS}/${CASE1_PROBE_ATTEMPTS} attempts (see per-attempt timings above)"
fi

# ---------------------------------------------------------------------------
# Case 2: timeout path returns 124 in 1-3s with empty captured output (no
# job-control "Terminated" noise leaking into the capture).
# ---------------------------------------------------------------------------
start="$(now)"
set +e
out2="$(_vpn_run_bounded 1 /bin/sleep 5 2>/dev/null)"
rc2=$?
set -e
elapsed2="$(elapsed_since "${start}")"
if [ "${rc2}" -eq 124 ] && [ -z "${out2}" ] && ge_threshold "${elapsed2}" "1" && le_threshold "${elapsed2}" "3"; then
    pass "(2) _vpn_run_bounded 1 /bin/sleep 5 returns 124 in 1-3s with empty output (${elapsed2}s, rc=${rc2}, out='${out2}')"
else
    fail "(2) _vpn_run_bounded 1 /bin/sleep 5 returns 124 in 1-3s with empty output (${elapsed2}s, rc=${rc2}, out='${out2}')"
fi

# ---------------------------------------------------------------------------
# Case 3: no stray 'sleep 30' child of this shell remains after a fast exit.
# ---------------------------------------------------------------------------
set +e
_vpn_run_bounded 30 /usr/bin/true
rc3=$?
set -e
sleep 1
set +e
STRAY="$(pgrep -f 'sleep 30' 2>/dev/null | while read -r p; do
    ppid="$(ps -o ppid= -p "${p}" 2>/dev/null | tr -d ' ')"
    [ "${ppid}" = "$$" ] && echo "${p}"
done)"
set -e
if [ "${rc3}" -eq 0 ] && [ -z "${STRAY}" ]; then
    pass "(3) no stray 'sleep 30' child of this shell remains after fast exit (rc=${rc3})"
else
    fail "(3) no stray 'sleep 30' child of this shell remains after fast exit (rc=${rc3}, stray pids='${STRAY}')"
fi

# ---------------------------------------------------------------------------
# Case 4: real exit status is preserved.
# ---------------------------------------------------------------------------
set +e
_vpn_run_bounded 5 /bin/sh -c 'exit 7'
rc4=$?
set -e
if [ "${rc4}" -eq 7 ]; then
    pass "(4) real exit status 7 is preserved (rc=${rc4})"
else
    fail "(4) real exit status 7 is preserved (rc=${rc4})"
fi

# ---------------------------------------------------------------------------
# Case 5: large stdout survives capture (300000 printable bytes via tr).
# ---------------------------------------------------------------------------
set +e
LARGE_LEN="$(_vpn_run_bounded 5 /usr/bin/head -c 300000 /dev/zero | tr '\0' 'a' | wc -c | tr -d ' ')"
set -e
if [ "${LARGE_LEN}" = "300000" ]; then
    pass "(5) large stdout (300000 bytes) survives capture (got ${LARGE_LEN})"
else
    fail "(5) large stdout (300000 bytes) survives capture (got ${LARGE_LEN})"
fi

# ---------------------------------------------------------------------------
# Case 6: no leftover .vpn_run_bounded.* flag files in $TMPDIR after all
# the above, including case 1a's broken-lib runs. (Case 1a's wrapped
# command always finishes well before its watchdog's timeout fires, so
# the watchdog's own `kill -0 cmd_pid` check finds it already dead and
# never writes a flag file in the first place -- there is nothing to
# exclude here.)
# ---------------------------------------------------------------------------
REAL_FLAG_LEFTOVERS=0
for f in ${FLAG_GLOB}; do
    if [ -e "${f}" ]; then
        REAL_FLAG_LEFTOVERS=$((REAL_FLAG_LEFTOVERS + 1))
    fi
done
if [ "${REAL_FLAG_LEFTOVERS}" -eq 0 ]; then
    pass "(6) no leftover .vpn_run_bounded.* flag files in \${TMPDIR:-/tmp} (found ${REAL_FLAG_LEFTOVERS})"
else
    fail "(6) no leftover .vpn_run_bounded.* flag files in \${TMPDIR:-/tmp} (found ${REAL_FLAG_LEFTOVERS})"
fi

# ---------------------------------------------------------------------------
# Case 7: sourcing both libs (tailscale-ctl.sh already sourced above, plus
# nord-ctl.sh) in one shell does not error, and _vpn_run_bounded remains
# defined exactly once (the `declare -f` guard works both ways).
# ---------------------------------------------------------------------------
set +e
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/nord-ctl.sh" 2>"${SOURCE_BOTH_ERR}"
SOURCE_BOTH_RC=$?
set -e
if [ "${SOURCE_BOTH_RC}" -eq 0 ] && declare -f _vpn_run_bounded >/dev/null 2>&1; then
    pass "(7) sourcing both lib/tailscale-ctl.sh and lib/nord-ctl.sh does not error and _vpn_run_bounded is defined"
else
    fail "(7) sourcing both lib/tailscale-ctl.sh and lib/nord-ctl.sh does not error and _vpn_run_bounded is defined (rc=${SOURCE_BOTH_RC})"
    cat "${SOURCE_BOTH_ERR}" >&2 2>/dev/null || true
fi

echo ""
echo "==================================================================="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "==================================================================="

if [ "${FAIL_COUNT}" -ne 0 ]; then
    exit 1
fi
exit 0
