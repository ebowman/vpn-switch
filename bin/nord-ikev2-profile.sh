#!/bin/bash
# nord-ikev2-profile.sh — generate a native macOS IKEv2 VPN .mobileconfig for
# NordVPN's manually-configured IKEv2/IPsec service.
#
# This script FILE-GENERATES ONLY. It never installs the profile ('open' or
# 'profiles install'), never touches the Keychain, and never runs sudo.
#
# Usage:
#   NORD_IKEV2_SERVER=xx.nordvpn.com \
#   NORD_IKEV2_USER=service-username \
#   NORD_IKEV2_PASS=service-password \
#   bash bin/nord-ikev2-profile.sh
#
# Or point at a mode-600 file that sets the three vars instead of passing
# the password via the environment directly:
#   NORD_IKEV2_ENVFILE=/path/to/creds.env bash bin/nord-ikev2-profile.sh
#
# Inputs (env vars only — NEVER pass secrets on argv, they leak via 'ps'):
#   NORD_IKEV2_SERVER   required  IKEv2 server hostname, e.g. us1234.nordvpn.com
#   NORD_IKEV2_USER     required  NordVPN "service credentials" username
#                                 (Nord Account -> Service credentials; NOT
#                                 your account login email/password)
#   NORD_IKEV2_PASS     required  NordVPN service credentials password
#   NORD_IKEV2_ENVFILE  optional  path to a mode-600 file that sets the three
#                                 vars above (sourced instead of requiring
#                                 them directly in the environment)
#   NORD_IKEV2_OUT      optional  output path for the .mobileconfig
#                                 (default: "$HOME/Library/Application
#                                 Support/vpn-switch/NordVPN-IKEv2.mobileconfig")
#   NORD_IKEV2_SEARCH_DOMAINS
#                       optional  space-separated search domain(s) to inject
#                                 via the VPN payload's DNS.SearchDomains key
#                                 (dns-config-j9y.3 / ADR-003 R1). Default:
#                                 "home.arpa". Set to the empty string to
#                                 disable the DNS dict entirely (restores the
#                                 prior "no DNS override keys" behavior):
#                                   NORD_IKEV2_SEARCH_DOMAINS="" bash bin/nord-ikev2-profile.sh
#   NORD_IKEV2_DNS_SERVERS
#                       optional  space-separated DNS.ServerAddresses to embed
#                                 (Apple marks this key REQUIRED once a DNS
#                                 dict is present at all). Default: NordVPN's
#                                 own published resolvers, "103.86.96.100
#                                 103.86.99.100" (docs/switcher/nord-ikev2-setup.md).
#                                 Only meaningful when NORD_IKEV2_SEARCH_DOMAINS
#                                 is non-empty.
#
# Output: a .mobileconfig file, mode 600, written OUTSIDE this repo. The file
# CONTAINS THE SERVICE PASSWORD IN PLAINTEXT (Apple Configuration Profile
# format has no encryption for AuthPassword) — treat it like a credential.
#
# Repeated runs with the same inputs REPLACE the previously generated profile
# (once installed) rather than duplicating it, because PayloadUUIDs below are
# fixed constants, not freshly generated per run.
set -u

# ---------------------------------------------------------------------------
# Fixed PayloadUUIDs. Do not change these across regenerations: on a machine
# where the profile has been installed, keeping these stable means installing
# a freshly generated .mobileconfig REPLACES the existing profile instead of
# creating a duplicate. Generated once with `uuidgen` and hard-coded.
# ---------------------------------------------------------------------------
PROFILE_UUID="8f2c6f1e-8b1a-4a3a-9b7d-6a2e1c4f9a10"
VPN_PAYLOAD_UUID="3d7a5e2c-1f4b-4c8a-9e6d-2b8f5a3c7d41"
CERT_PAYLOAD_UUID="a19b4e6d-7c2f-4a1b-8d3e-5f9c1a2b6e72"

PAYLOAD_IDENTIFIER_ROOT="ie.boboco.vpn-switch.nordvpn-ikev2"
DISPLAY_NAME="NordVPN IKEv2"

# ---------------------------------------------------------------------------
# Resolve repo root using the case-guard pattern (bash 3.2 safe: no ${var,,},
# no declare -A).
# ---------------------------------------------------------------------------
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
case "${SCRIPT_SOURCE}" in
    */*) SCRIPT_PARENT="${SCRIPT_SOURCE%/*}" ;;
    *)   SCRIPT_PARENT="." ;;
esac
if ! SCRIPT_DIR="$(cd "${SCRIPT_PARENT}" && pwd)"; then
    echo "Error: could not resolve script directory from '${SCRIPT_PARENT}'" >&2
    exit 1
fi
if ! REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"; then
    echo "Error: could not resolve repo root" >&2
    exit 1
fi

CA_DER="${REPO_ROOT}/config/nord-ikev2/nordvpn-root.der"

# ---------------------------------------------------------------------------
# Load NORD_IKEV2_ENVFILE if given.
#
# Refused unless:
#   - the path is a regular file (not a symlink: a symlink lets an attacker
#     who controls the link target bypass the mode/owner checks below, which
#     `stat` would otherwise happily report for the link's target, not the
#     link itself);
#   - it is mode 600 (owner read/write only);
#   - it is owned by the user running this script (a mode-600 file owned by
#     someone else is still readable/writable by them, and by extension the
#     content is not something the current user should trust as their own
#     credentials).
#
# The file is NOT shell-sourced. It is parsed line-by-line as a strict
# KEY=VALUE format with NO shell evaluation (no eval, no indirect expansion,
# no `.`/source), so a line like `NORD_IKEV2_PASS=x; touch ~/pwned` is
# rejected outright rather than executed.
#
# Allowed keys (every other NORD_IKEV2_* variable this script reads,
# enumerated so the allowlist can't silently drift from what the rest of the
# script actually honours):
#   NORD_IKEV2_SERVER, NORD_IKEV2_USER, NORD_IKEV2_PASS,
#   NORD_IKEV2_SEARCH_DOMAINS, NORD_IKEV2_DNS_SERVERS, NORD_IKEV2_OUT
#
# Format rules:
#   - blank lines and lines whose first non-space character is '#' are
#     skipped;
#   - every other line must match exactly `KEY=VALUE` for one of the keys
#     above; anything else (unknown key, no '=', stray shell syntax) aborts
#     the whole run before any value is used;
#   - the value is everything after the first '=', taken completely
#     literally: no quote processing, no variable expansion, no escapes —
#     EXCEPT that if the value both starts and ends with a matching pair of
#     single or double quotes, exactly ONE such surrounding pair is stripped
#     (so existing files written as `KEY="value"` keep working). A value
#     that is just `""` or `''` becomes empty;
#   - values set in the file OVERRIDE the corresponding environment
#     variable, matching the previous `. "$file"` sourcing behavior (the
#     envfile, when given, is treated as the authoritative source, not a
#     fallback for unset vars).
# ---------------------------------------------------------------------------
if [ -n "${NORD_IKEV2_ENVFILE:-}" ]; then
    if [ -L "${NORD_IKEV2_ENVFILE}" ]; then
        echo "Error: NORD_IKEV2_ENVFILE '${NORD_IKEV2_ENVFILE}' is a symlink; point it directly at the real file" >&2
        exit 1
    fi
    if [ ! -f "${NORD_IKEV2_ENVFILE}" ]; then
        echo "Error: NORD_IKEV2_ENVFILE '${NORD_IKEV2_ENVFILE}' does not exist" >&2
        exit 1
    fi
    ENVFILE_MODE="$(stat -f '%Lp' "${NORD_IKEV2_ENVFILE}" 2>/dev/null)"
    if [ -z "${ENVFILE_MODE}" ]; then
        echo "Error: could not stat NORD_IKEV2_ENVFILE '${NORD_IKEV2_ENVFILE}'" >&2
        exit 1
    fi
    if [ "${ENVFILE_MODE}" != "600" ]; then
        echo "Error: NORD_IKEV2_ENVFILE '${NORD_IKEV2_ENVFILE}' must be mode 600 (found ${ENVFILE_MODE}); run: chmod 600 '${NORD_IKEV2_ENVFILE}'" >&2
        exit 1
    fi
    ENVFILE_UID="$(stat -f '%u' "${NORD_IKEV2_ENVFILE}" 2>/dev/null)"
    CURRENT_UID="$(id -u)"
    if [ -z "${ENVFILE_UID}" ]; then
        echo "Error: could not stat owner of NORD_IKEV2_ENVFILE '${NORD_IKEV2_ENVFILE}'" >&2
        exit 1
    fi
    if [ "${ENVFILE_UID}" != "${CURRENT_UID}" ]; then
        echo "Error: NORD_IKEV2_ENVFILE '${NORD_IKEV2_ENVFILE}' must be owned by the current user (uid ${CURRENT_UID}), found uid ${ENVFILE_UID}" >&2
        exit 1
    fi

    ENVFILE_LINE_NO=0
    while IFS= read -r _envfile_line || [ -n "${_envfile_line}" ]; do
        ENVFILE_LINE_NO=$((ENVFILE_LINE_NO + 1))

        # Skip blank lines (possibly whitespace-only).
        case "${_envfile_line}" in
            *[!' ']*) ;;
            *) continue ;;
        esac

        # Skip comment lines: first non-space char is '#'.
        _envfile_trimmed="${_envfile_line#"${_envfile_line%%[! ]*}"}"
        case "${_envfile_trimmed}" in
            '#'*) continue ;;
        esac

        case "${_envfile_line}" in
            NORD_IKEV2_SERVER=*|NORD_IKEV2_USER=*|NORD_IKEV2_PASS=*|NORD_IKEV2_SEARCH_DOMAINS=*|NORD_IKEV2_DNS_SERVERS=*|NORD_IKEV2_OUT=*)
                _envfile_key="${_envfile_line%%=*}"
                _envfile_val="${_envfile_line#*=}"
                ;;
            *)
                echo "Error: NORD_IKEV2_ENVFILE line ${ENVFILE_LINE_NO} is not KEY=VALUE for an allowed key" >&2
                exit 1
                ;;
        esac

        # Strip exactly one matching pair of surrounding quotes, if present.
        case "${_envfile_val}" in
            \"*\"|\'*\')
                if [ "${#_envfile_val}" -ge 2 ]; then
                    _envfile_val="${_envfile_val#?}"
                    _envfile_val="${_envfile_val%?}"
                fi
                ;;
        esac

        case "${_envfile_key}" in
            NORD_IKEV2_SERVER)          NORD_IKEV2_SERVER="${_envfile_val}" ;;
            NORD_IKEV2_USER)            NORD_IKEV2_USER="${_envfile_val}" ;;
            NORD_IKEV2_PASS)            NORD_IKEV2_PASS="${_envfile_val}" ;;
            NORD_IKEV2_SEARCH_DOMAINS)  NORD_IKEV2_SEARCH_DOMAINS="${_envfile_val}" ;;
            NORD_IKEV2_DNS_SERVERS)     NORD_IKEV2_DNS_SERVERS="${_envfile_val}" ;;
            NORD_IKEV2_OUT)             NORD_IKEV2_OUT="${_envfile_val}" ;;
        esac
    done < "${NORD_IKEV2_ENVFILE}"
    unset _envfile_line _envfile_trimmed _envfile_key _envfile_val ENVFILE_LINE_NO ENVFILE_MODE ENVFILE_UID CURRENT_UID
fi

# ---------------------------------------------------------------------------
# Validate required inputs.
# ---------------------------------------------------------------------------
MISSING=""
if [ -z "${NORD_IKEV2_SERVER:-}" ]; then
    MISSING="${MISSING} NORD_IKEV2_SERVER"
fi
if [ -z "${NORD_IKEV2_USER:-}" ]; then
    MISSING="${MISSING} NORD_IKEV2_USER"
fi
if [ -z "${NORD_IKEV2_PASS:-}" ]; then
    MISSING="${MISSING} NORD_IKEV2_PASS"
fi
if [ -n "${MISSING}" ]; then
    echo "Error: missing required variables:${MISSING}" >&2
    echo "Set them directly, or point NORD_IKEV2_ENVFILE at a mode-600 file that sets them." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Reject control characters (0x00-0x1F, 0x7F) in any value that will be
# embedded in the plist: a raw control character produces an unparseable
# plist even after XML-escaping (xml_escape only handles the five XML
# metacharacters). Checked with LC_ALL=C so byte ranges are stable regardless
# of locale. Never echo the value itself in the error for NORD_IKEV2_PASS.
# ---------------------------------------------------------------------------
_has_control_char() {
    # Returns 0 (true) if $1 contains a byte in 0x00-0x1F or 0x7F.
    LC_ALL=C
    case "$1" in
        *[$'\001'-$'\037']*|*$'\177'*) return 0 ;;
    esac
    return 1
}

if _has_control_char "${NORD_IKEV2_SERVER}"; then
    echo "Error: NORD_IKEV2_SERVER contains a control character" >&2
    exit 1
fi
if _has_control_char "${NORD_IKEV2_USER}"; then
    echo "Error: NORD_IKEV2_USER contains a control character" >&2
    exit 1
fi
if _has_control_char "${NORD_IKEV2_PASS}"; then
    echo "Error: NORD_IKEV2_PASS contains a control character" >&2
    exit 1
fi
if _has_control_char "${NORD_IKEV2_SEARCH_DOMAINS:-}"; then
    echo "Error: NORD_IKEV2_SEARCH_DOMAINS contains a control character" >&2
    exit 1
fi
if _has_control_char "${NORD_IKEV2_DNS_SERVERS:-}"; then
    echo "Error: NORD_IKEV2_DNS_SERVERS contains a control character" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate NORD_IKEV2_SERVER as a syntactically plausible DNS hostname before
# it is embedded (twice) in the plist as RemoteAddress/RemoteIdentifier.
# ---------------------------------------------------------------------------
case "${NORD_IKEV2_SERVER}" in
    *[!A-Za-z0-9.-]*)
        echo "Error: NORD_IKEV2_SERVER '${NORD_IKEV2_SERVER}' is not a valid hostname" >&2
        exit 1
        ;;
esac
if ! printf '%s\n' "${NORD_IKEV2_SERVER}" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'; then
    echo "Error: NORD_IKEV2_SERVER '${NORD_IKEV2_SERVER}' is not a valid hostname" >&2
    exit 1
fi

if [ ! -f "${CA_DER}" ]; then
    echo "Error: NordVPN root CA not found at ${CA_DER}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve output path and refuse if it resolves inside this repo.
# ---------------------------------------------------------------------------
OUT="${NORD_IKEV2_OUT:-${HOME}/Library/Application Support/vpn-switch/NordVPN-IKEv2.mobileconfig}"

OUT_PARENT="${OUT%/*}"
if [ "${OUT_PARENT}" = "${OUT}" ]; then
    OUT_PARENT="."
fi
if ! OUT_PARENT_ABS="$(mkdir -p "${OUT_PARENT}" 2>/dev/null && cd "${OUT_PARENT}" && pwd -P)"; then
    echo "Error: could not create/resolve output directory '${OUT_PARENT}'" >&2
    exit 1
fi
OUT_BASENAME="${OUT##*/}"
OUT_ABS="${OUT_PARENT_ABS}/${OUT_BASENAME}"

case "${OUT_ABS}" in
    "${REPO_ROOT}"|"${REPO_ROOT}"/*)
        echo "Error: refusing to write output inside the repo (${OUT_ABS} is under ${REPO_ROOT})" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Base64-encode the CA DER for embedding as PayloadContent <data>.
# 'base64' on macOS wraps at 76 cols by default, which plutil/Apple's parser
# both accept fine inside a plist <data> element.
# ---------------------------------------------------------------------------
if ! CA_B64="$(base64 < "${CA_DER}")"; then
    echo "Error: failed to base64-encode ${CA_DER}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Escape XML special characters in values that get interpolated into the
# plist (hostname/username should not contain any of these, but don't trust
# it).
# ---------------------------------------------------------------------------
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\\&apos;/g" -e 's/"/\&quot;/g'
}

SERVER_ESC="$(xml_escape "${NORD_IKEV2_SERVER}")"
USER_ESC="$(xml_escape "${NORD_IKEV2_USER}")"
PASS_ESC="$(xml_escape "${NORD_IKEV2_PASS}")"

# ---------------------------------------------------------------------------
# DNS dict (dns-config-j9y.3, ADR-003 R1). Defaulted ON: NORD_IKEV2_SEARCH_DOMAINS
# defaults to "home.arpa" so a fresh regeneration includes it without the
# caller having to know the flag exists; set it to the empty string to
# disable ("" bash bin/nord-ikev2-profile.sh) and restore the prior
# no-DNS-keys profile.
#
# Schema verified 2026-08-16 against Apple's Device Management reference
# (fetched, not guessed):
#   - developer.apple.com/.../devicemanagement/vpn.json: the VPN payload dict
#     has a top-level "DNS" key (type VPN.DNS, sibling of "IKEv2") alongside
#     IKEv2/IPSec/IPv4/etc.
#   - developer.apple.com/.../devicemanagement/vpn/dns-data.dictionary.json:
#     VPN.DNS fields --
#       DNSProtocol                 string,   REQUIRED (allowed: Cleartext,
#                                    HTTPS, TLS) -- we use "Cleartext".
#       ServerAddresses             [string], REQUIRED once the DNS dict is
#                                    present at all.
#       SearchDomains                [string], optional -- "used to fully
#                                    qualify single-label host names"; this is
#                                    the key this bead needs.
#       SupplementalMatchDomains,
#       SupplementalMatchDomainsNoSearch,
#       DomainName, PayloadCertificateUUID, ServerName, ServerURL
#                                     optional, not set here.
#
# SupplementalMatchDomains is deliberately NOT set: routing of *.home.arpa is
# already handled by /etc/resolver/home.arpa (port 5354, proven in
# dns-config-j9y.3's root-step measurement); NE supplemental-match DNS
# settings cannot carry a non-53 port, so setting it here would require a
# port-53 daemon this design avoids. Only the SEARCH suffix needs to come
# from the primary service (Nord's IKEv2 profile); the resolver file already
# routes the expanded name.
#
# ServerAddresses is REQUIRED by the schema the moment a DNS dict exists at
# all, even though this profile does not want to override Nord's
# server-pushed resolvers for actual name resolution -- explicit here purely
# to satisfy the schema; default is NordVPN's own documented DNS servers (the
# same ones the server pushes), so this does not change what upstream
# resolver traffic uses in practice.
NORD_IKEV2_SEARCH_DOMAINS="${NORD_IKEV2_SEARCH_DOMAINS-home.arpa}"
NORD_IKEV2_DNS_SERVERS="${NORD_IKEV2_DNS_SERVERS:-103.86.96.100 103.86.99.100}"

DNS_DICT_BLOCK=""
if [ -n "${NORD_IKEV2_SEARCH_DOMAINS}" ]; then
    SEARCH_DOMAINS_XML=""
    for _sd in ${NORD_IKEV2_SEARCH_DOMAINS}; do
        SEARCH_DOMAINS_XML="${SEARCH_DOMAINS_XML}
					<string>$(xml_escape "${_sd}")</string>"
    done
    SERVER_ADDRS_XML=""
    for _sa in ${NORD_IKEV2_DNS_SERVERS}; do
        SERVER_ADDRS_XML="${SERVER_ADDRS_XML}
					<string>$(xml_escape "${_sa}")</string>"
    done
    DNS_DICT_BLOCK="
			<key>DNS</key>
			<dict>
				<key>DNSProtocol</key>
				<string>Cleartext</string>
				<key>ServerAddresses</key>
				<array>${SERVER_ADDRS_XML}
				</array>
				<key>SearchDomains</key>
				<array>${SEARCH_DOMAINS_XML}
				</array>
			</dict>"
fi

# ---------------------------------------------------------------------------
# Build the .mobileconfig.
#
# IKEv2 dict keys, validated against Apple's Configuration Profile Reference
# (developer.apple.com/documentation/devicemanagement/vpn/ikev2-data.dictionary):
#   RemoteAddress          required, string  — server hostname
#   RemoteIdentifier        required, string  — server hostname
#   LocalIdentifier          required, string  — client identifier (Apple
#                             requires this key even for EAP auth; using the
#                             service username satisfies it without adding
#                             any new secret)
#   AuthenticationMethod     required, string  — "None" (EAP-only auth; see
#                             below)
#   ExtendedAuthEnabled      integer  — 1: per Apple's docs, "To enable
#                             EAP-only authentication, set
#                             AuthenticationMethod to None and
#                             ExtendedAuthEnabled to 1."
#   AuthName / AuthPassword  string   — EAP username/password
#   OnDemandEnabled           integer  — 0 (REQUIRED off; auto-connect would
#                             recreate the Nord auto-reconnect problem this
#                             profile exists to avoid)
#
# Deliberately NOT set: DNS.* (qsk.3c must observe what Nord's server
# pushes), IncludeAllNetworks (kill-switch-like behavior), OnDemandRules.
#
# com.apple.security.root payload: PayloadContent is <data> = base64 DER,
# per developer.apple.com/documentation/devicemanagement/certificateroot.
# This lets the client validate the IKEv2 server's certificate chain without
# a separate Keychain-trust step.
# ---------------------------------------------------------------------------
PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.vpn.managed</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadIdentifier</key>
			<string>${PAYLOAD_IDENTIFIER_ROOT}.vpn</string>
			<key>PayloadUUID</key>
			<string>${VPN_PAYLOAD_UUID}</string>
			<key>PayloadDisplayName</key>
			<string>${DISPLAY_NAME} connection</string>
			<key>UserDefinedName</key>
			<string>${DISPLAY_NAME}</string>
			<key>VPNType</key>
			<string>IKEv2</string>
			<key>IKEv2</key>
			<dict>
				<key>RemoteAddress</key>
				<string>${SERVER_ESC}</string>
				<key>RemoteIdentifier</key>
				<string>${SERVER_ESC}</string>
				<key>LocalIdentifier</key>
				<string>${USER_ESC}</string>
				<key>AuthenticationMethod</key>
				<string>None</string>
				<key>ExtendedAuthEnabled</key>
				<integer>1</integer>
				<key>AuthName</key>
				<string>${USER_ESC}</string>
				<key>AuthPassword</key>
				<string>${PASS_ESC}</string>
				<key>OnDemandEnabled</key>
				<integer>0</integer>
			</dict>${DNS_DICT_BLOCK}
		</dict>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadIdentifier</key>
			<string>${PAYLOAD_IDENTIFIER_ROOT}.cert</string>
			<key>PayloadUUID</key>
			<string>${CERT_PAYLOAD_UUID}</string>
			<key>PayloadDisplayName</key>
			<string>NordVPN Root CA</string>
			<key>PayloadContent</key>
			<data>
${CA_B64}
			</data>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>${DISPLAY_NAME}</string>
	<key>PayloadIdentifier</key>
	<string>${PAYLOAD_IDENTIFIER_ROOT}</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>${PROFILE_UUID}</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadRemovalDisallowed</key>
	<false/>
</dict>
</plist>
"

# ---------------------------------------------------------------------------
# Write with mode 600 from the start: create the file with restrictive
# permissions before any content (containing the plaintext password) lands
# in it, rather than writing then chmod'ing afterward.
# ---------------------------------------------------------------------------
if ! ( umask 077 && : > "${OUT_ABS}" ); then
    echo "Error: could not create output file ${OUT_ABS}" >&2
    exit 1
fi
chmod 600 "${OUT_ABS}" 2>/dev/null

if ! printf '%s' "${PLIST_CONTENT}" > "${OUT_ABS}"; then
    echo "Error: could not write profile to ${OUT_ABS}" >&2
    exit 1
fi
chmod 600 "${OUT_ABS}" 2>/dev/null

echo "Wrote ${OUT_ABS}"
echo "WARNING: this file contains the NordVPN service password IN PLAINTEXT (AuthPassword)." >&2
echo "It is mode 600 but is not encrypted. Treat it like a credential; do not copy it into this repo or share it." >&2

exit 0
